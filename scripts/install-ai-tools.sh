#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=6

# MCP 服务器
# 无需鉴权的 MCP 端点
readonly MCP_CONTEXT7_URL="https://mcp.context7.com/mcp"
readonly MCP_PLAYWRIGHT_SPEC="@playwright/mcp@latest"

# Codex 基础配置，可通过同名环境变量覆盖

# 默认模型
readonly CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"

# 推理强度
readonly CODEX_REASONING="${CODEX_REASONING:-high}"

# 服务等级
readonly CODEX_SERVICE_TIER="${CODEX_SERVICE_TIER:-default}"

# 命令审批策略：untrusted、on-request（推荐）或 never
readonly CODEX_APPROVAL="${CODEX_APPROVAL:-on-request}"

# 文件系统沙箱：read-only、workspace-write（推荐）或 danger-full-access
readonly CODEX_SANDBOX="${CODEX_SANDBOX:-workspace-write}"

# workspace-write 沙箱的网络访问开关
readonly CODEX_NETWORK="${CODEX_NETWORK:-enabled}"

# 优先沿用已有 OpenCode 配置格式，新配置默认使用 JSONC
opencode_config_file() {
    local dir="$HOME/.config/opencode"
    local candidate
    for candidate in "$dir/opencode.jsonc" "$dir/opencode.json"; do
        if [ -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '%s\n' "$dir/opencode.jsonc"
}

strip_jsonc_comments() {
    local path="$1"

    if [ ! -f "$path" ]; then
        printf '{}\n'
        return 0
    fi

    awk '
    {
        out = ""
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            n = substr($0, i + 1, 1)

            if (in_block) {
                if (c == "*" && n == "/") {
                    in_block = 0
                    i++
                }
                continue
            }

            if (in_str) {
                out = out c
                if (escaped) {
                    escaped = 0
                } else if (c == "\\") {
                    escaped = 1
                } else if (c == quote) {
                    in_str = 0
                }
                continue
            }

            if (c == "\"" || c == "'\''") {
                in_str = 1
                quote = c
                out = out c
                continue
            }
            if (c == "/" && n == "/") {
                break
            }
            if (c == "/" && n == "*") {
                in_block = 1
                i++
                continue
            }

            out = out c
        }
        print out
    }' "$path"
}

jsonc_to_temp_json() {
    local path="$1"
    local out="$2"

    strip_jsonc_comments "$path" \
        | jq -s 'if length == 0 then {} elif length == 1 and (.[0] | type) == "object" then .[0] elif length == 1 then {} else error("expected one JSON object") end' >"$out" || {
        echo "Failed to parse $path as JSON/JSONC." >&2
        return 1
    }
}

edit_jsonc_config() {
    local mode="$1"
    local path="$2"
    shift 2
    local tmp
    local next

    tmp="$(mktemp)"
    next="$(mktemp)"
    if ! jsonc_to_temp_json "$path" "$tmp"; then
        rm -f "$tmp" "$next"
        return 1
    fi

    case "$mode" in
        ensure-mcp)
            local context7_url="$1"
            local playwright_spec="$2"
            local missing_context7
            local missing_playwright
            missing_context7="$(jq 'if ((.mcp | type) == "object" and (.mcp | has("context7"))) then 0 else 1 end' "$tmp")"
            missing_playwright="$(jq 'if ((.mcp | type) == "object" and (.mcp | has("playwright"))) then 0 else 1 end' "$tmp")"
            jq --arg context7_url "$context7_url" --arg playwright_spec "$playwright_spec" '
                if (.mcp | type) == "object" then . else .mcp = {} end
                | if (.mcp | has("context7")) then . else
                    .mcp.context7 = {
                        "type": "remote",
                        "url": $context7_url,
                        "enabled": true
                    }
                end
                | if (.mcp | has("playwright")) then . else
                    .mcp.playwright = {
                        "type": "local",
                        "command": ["npx", "-y", $playwright_spec],
                        "enabled": true
                    }
                end
            ' "$tmp" >"$next"
            if [ "$missing_context7" -eq 1 ]; then
                echo "- mcp.context7"
            fi
            if [ "$missing_playwright" -eq 1 ]; then
                echo "- mcp.playwright"
            fi
            if [ "$missing_context7" -eq 1 ] || [ "$missing_playwright" -eq 1 ]; then
                mv "$next" "$path"
                echo "Updated MCP servers in $path"
            else
                echo "MCP servers already configured in $path"
            fi
            ;;
        *)
            rm -f "$tmp" "$next"
            echo "Unknown config edit mode: $mode" >&2
            return 1
            ;;
    esac

    rm -f "$tmp" "$next"
}

configure_codex_base() {
    local codex_cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
    local pair
    local key
    local val
    local names
    local network_value
    local network_tmp
    local codex_pairs=(
        "model|$CODEX_MODEL"
        "model_reasoning_effort|$CODEX_REASONING"
        "service_tier|$CODEX_SERVICE_TIER"
        "approval_policy|$CODEX_APPROVAL"
        "sandbox_mode|$CODEX_SANDBOX"
    )
    local codex_missing=()

    case "$CODEX_NETWORK" in
        enabled) network_value="true" ;;
        disabled) network_value="false" ;;
        *)
            echo "Invalid CODEX_NETWORK: $CODEX_NETWORK (expected enabled or disabled)" >&2
            return 1
            ;;
    esac

    mkdir -p "$(dirname "$codex_cfg")"
    [ -f "$codex_cfg" ] || : > "$codex_cfg"

    for pair in "${codex_pairs[@]}"; do
        key="${pair%%|*}"
        val="${pair#*|}"
        if grep -qE "^${key} =" "$codex_cfg"; then
            sed -i -E "s|^${key} = .*|${key} = \"${val}\"|" "$codex_cfg"
        else
            codex_missing+=("$pair")
        fi
    done

    # 倒序插入缺失键，保证最终顺序与 codex_pairs 一致
    for ((i=${#codex_missing[@]}-1; i>=0; i--)); do
        key="${codex_missing[i]%%|*}"
        val="${codex_missing[i]#*|}"
        sed -i "1i${key} = \"${val}\"" "$codex_cfg"
    done

    # 网络权限属于 workspace-write 沙箱表，顶层同名字符串不会被 Codex 识别
    network_tmp="$(mktemp)"
    awk -v value="$network_value" '
        BEGIN {
            before_first_table = 1
            in_workspace_table = 0
            workspace_table_found = 0
            network_written = 0
        }

        /^\[/ {
            if (in_workspace_table && !network_written) {
                print "network_access = " value
                network_written = 1
            }

            before_first_table = 0
            in_workspace_table = ($0 == "[sandbox_workspace_write]")
            if (in_workspace_table) {
                workspace_table_found = 1
            }

            print
            next
        }

        before_first_table && /^network_access[[:space:]]*=/ {
            next
        }

        in_workspace_table && /^network_access[[:space:]]*=/ {
            print "network_access = " value
            network_written = 1
            next
        }

        { print }

        END {
            if (in_workspace_table && !network_written) {
                print "network_access = " value
            } else if (!workspace_table_found) {
                print ""
                print "[sandbox_workspace_write]"
                print "network_access = " value
            }
        }
    ' "$codex_cfg" >"$network_tmp"
    mv "$network_tmp" "$codex_cfg"

    if [ "${#codex_missing[@]}" -gt 0 ]; then
        names=""
        for pair in "${codex_missing[@]}"; do names="$names ${pair%%|*}"; done
        echo "Codex base config -> $codex_cfg (added:$names)"
    else
        echo "Codex base config -> $codex_cfg (all present)"
    fi
}

echo "======================================"
echo " Ubuntu/Debian AI CLI Tools Installer (Codex / OpenCode / ast-grep)"
echo "======================================"

require_non_root "./scripts/install-ai-tools.sh"
require_debian_like
require_sudo "sudo was not found. Install it and grant sudo access to the current user."

# Codex 与 ast-grep 通过 npm 全局安装，依赖已配置好的 npm 前缀
if ! command -v npm >/dev/null 2>&1; then
    echo "npm was not found. Run './setup.sh npm' first." >&2
    exit 1
fi
NPM_PREFIX_BIN="$(npm config get prefix)/bin"
export PATH="$NPM_PREFIX_BIN:$PATH"

apt_get_update_step 1

print_step 2 "Installing base dependencies"
sudo apt-get install -y \
    curl \
    jq

print_step 3 "Installing Codex and ast-grep"
npm install -g --allow-scripts=@ast-grep/cli \
    @openai/codex \
    @ast-grep/cli

print_step 4 "Installing OpenCode"
curl -fsSL https://opencode.ai/install | bash

print_step 5 "Checking the environment"
printf 'Codex:      '; codex --version || true
printf 'OpenCode:   '; "$HOME/.opencode/bin/opencode" --version || true
printf 'ast-grep:   '; sg --version || true

# MCP 服务器
# Context7 与 Playwright 均无需凭据

print_step 6 "Installing MCP servers: Context7 / Playwright"

opencode_config="$(opencode_config_file)"
mkdir -p "$(dirname "$opencode_config")"

edit_jsonc_config ensure-mcp "$opencode_config" "$MCP_CONTEXT7_URL" "$MCP_PLAYWRIGHT_SPEC"

# 服务器尚未注册时 codex mcp get 会返回非零状态
codex mcp get context7 >/dev/null 2>&1 \
    || codex mcp add context7 --url "$MCP_CONTEXT7_URL"
codex mcp get playwright >/dev/null 2>&1 \
    || codex mcp add playwright -- npx -y "$MCP_PLAYWRIGHT_SPEC"

configure_codex_base

echo
echo "======================================"
echo "Installation complete"
echo "======================================"
