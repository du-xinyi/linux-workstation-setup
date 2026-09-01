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
readonly OPENCODE_BIN="${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"

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

configure_opencode_mcp() {
    local config_json

    if ! config_json="$("$OPENCODE_BIN" debug config)"; then
        echo "Failed to read the OpenCode configuration." >&2
        return 1
    fi

    if jq -e '(.mcp | type) == "object" and (.mcp | has("context7"))' \
        >/dev/null <<<"$config_json"; then
        echo "OpenCode MCP server already configured: context7"
    else
        "$OPENCODE_BIN" mcp add context7 --url "$MCP_CONTEXT7_URL"
    fi

    if jq -e '(.mcp | type) == "object" and (.mcp | has("playwright"))' \
        >/dev/null <<<"$config_json"; then
        echo "OpenCode MCP server already configured: playwright"
    else
        "$OPENCODE_BIN" mcp add playwright -- npx -y "$MCP_PLAYWRIGHT_SPEC"
    fi
}

codex_top_level_has_key() {
    local path="$1"
    local key="$2"

    awk -v key="$key" '
        /^[[:space:]]*\[/ { exit 1 }
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$path"
}

validate_codex_config_value() {
    local key="$1"
    local value="$2"

    if [[ "$value" == *'"'* || "$value" == *\\* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        echo "Invalid $key: the value cannot contain quotes, backslashes, or newlines." >&2
        return 1
    fi
}

update_codex_top_level_config() {
    local path="$1"
    local out="$2"

    CODEX_CFG_MODEL="$CODEX_MODEL" \
    CODEX_CFG_REASONING="$CODEX_REASONING" \
    CODEX_CFG_SERVICE_TIER="$CODEX_SERVICE_TIER" \
    CODEX_CFG_APPROVAL="$CODEX_APPROVAL" \
    CODEX_CFG_SANDBOX="$CODEX_SANDBOX" \
    awk '
        BEGIN {
            keys[1] = "model"
            keys[2] = "model_reasoning_effort"
            keys[3] = "service_tier"
            keys[4] = "approval_policy"
            keys[5] = "sandbox_mode"
            values[1] = ENVIRON["CODEX_CFG_MODEL"]
            values[2] = ENVIRON["CODEX_CFG_REASONING"]
            values[3] = ENVIRON["CODEX_CFG_SERVICE_TIER"]
            values[4] = ENVIRON["CODEX_CFG_APPROVAL"]
            values[5] = ENVIRON["CODEX_CFG_SANDBOX"]
            in_top_level = 1
        }

        function write_missing(    i) {
            for (i = 1; i <= 5; i++) {
                if (!written[i]) {
                    print keys[i] " = \"" values[i] "\""
                    written[i] = 1
                }
            }
        }

        in_top_level && /^[[:space:]]*\[/ {
            write_missing()
            in_top_level = 0
        }

        in_top_level {
            for (i = 1; i <= 5; i++) {
                if ($0 ~ "^[[:space:]]*" keys[i] "[[:space:]]*=") {
                    print keys[i] " = \"" values[i] "\""
                    written[i] = 1
                    next
                }
            }
        }

        { print }

        END {
            if (in_top_level) {
                write_missing()
            }
        }
    ' "$path" >"$out"
}

configure_codex_base() {
    local codex_cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
    local pair
    local key
    local val
    local names
    local network_value
    local network_tmp
    local top_level_tmp
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

    for pair in "${codex_pairs[@]}"; do
        key="${pair%%|*}"
        val="${pair#*|}"
        validate_codex_config_value "$key" "$val"
    done

    mkdir -p "$(dirname "$codex_cfg")"
    [ -f "$codex_cfg" ] || : > "$codex_cfg"

    for pair in "${codex_pairs[@]}"; do
        key="${pair%%|*}"
        if ! codex_top_level_has_key "$codex_cfg" "$key"; then
            codex_missing+=("$pair")
        fi
    done

    top_level_tmp="$(mktemp)"
    update_codex_top_level_config "$codex_cfg" "$top_level_tmp"
    mv "$top_level_tmp" "$codex_cfg"

    # 网络权限属于 workspace-write 沙箱表，顶层同名字符串不会被 Codex 识别
    network_tmp="$(mktemp)"
    awk -v value="$network_value" '
        BEGIN {
            before_first_table = 1
            in_workspace_table = 0
            workspace_table_found = 0
            network_written = 0
        }

        /^[[:space:]]*\[/ {
            if (in_workspace_table && !network_written) {
                print "network_access = " value
                network_written = 1
            }

            before_first_table = 0
            table_header = $0
            sub(/[[:space:]]*#.*/, "", table_header)
            in_workspace_table = (table_header ~ /^[[:space:]]*\[[[:space:]]*sandbox_workspace_write[[:space:]]*\][[:space:]]*$/)
            if (in_workspace_table) {
                workspace_table_found = 1
            }

            print
            next
        }

        before_first_table && /^[[:space:]]*network_access[[:space:]]*=/ {
            next
        }

        in_workspace_table && /^[[:space:]]*network_access[[:space:]]*=/ {
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

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

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
printf 'OpenCode:   '; "$OPENCODE_BIN" --version || true
printf 'ast-grep:   '; sg --version || true

# MCP 服务器
# Context7 与 Playwright 均无需凭据

print_step 6 "Installing MCP servers: Context7 / Playwright"

configure_opencode_mcp

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
