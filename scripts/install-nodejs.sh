#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT_DIR
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=13

# 默认值均可通过同名环境变量覆盖
readonly NODE_MAJOR="${NODE_MAJOR:-24}"
readonly NPM_VERSION="${NPM_VERSION:-latest}"
readonly NPM_DIR="${NPM_DIR:-$HOME/.local/npm}"
readonly NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"

readonly KEYRING_DIR="/etc/apt/keyrings"
readonly NODESOURCE_KEYRING="${KEYRING_DIR}/nodesource.gpg"
readonly NODESOURCE_LIST="/etc/apt/sources.list.d/nodesource.list"
readonly GH_KEYRING="${KEYRING_DIR}/githubcli-archive-keyring.gpg"
readonly GH_LIST="/etc/apt/sources.list.d/github-cli.list"

# oh-my-openagent 目标平台：both、opencode 或 codex
readonly OMO_PLATFORM="${OMO_PLATFORM:-both}"
readonly BUN_DIR="${BUN_DIR:-$HOME/.bun}"

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

omo_installs_opencode() {
    [ "$OMO_PLATFORM" = "opencode" ] || [ "$OMO_PLATFORM" = "both" ]
}

omo_installs_codex() {
    [ "$OMO_PLATFORM" = "codex" ] || [ "$OMO_PLATFORM" = "both" ]
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
        override-omo-models)
            local model="$1"
            local fallback="$2"
            local count
            count="$(jq '[
                (if (.agents | type) == "object" then .agents[] else empty end),
                (if (.categories | type) == "object" then .categories[] else empty end)
            ] | map(select(type == "object")) | length' "$tmp")"
            jq --arg model "$model" --arg fallback "$fallback" '
                (if (.agents | type) == "object" then
                    .agents |= with_entries(
                        if (.value | type) == "object" then
                            .value.model = $model
                            | .value.fallback_models = [$fallback]
                        else
                            .
                        end
                    )
                else . end)
                | (if (.categories | type) == "object" then
                    .categories |= with_entries(
                        if (.value | type) == "object" then
                            .value.model = $model
                            | .value.fallback_models = [$fallback]
                        else
                            .
                        end
                    )
                else . end)
            ' "$tmp" >"$next"
            mv "$next" "$path"
            echo "Overrode $count agent/category models -> $model (fallback: $fallback)"
            ;;
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
echo " Ubuntu/Debian Node.js + npm Development Environment Installer"
echo "======================================"

require_non_root "./scripts/install-nodejs.sh"
require_debian_like
require_sudo "sudo was not found. Install it and grant sudo access to the current user."

apt_get_update_step 1

print_step 2 "Installing base dependencies"
sudo apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    build-essential \
    jq

print_step 3 "Adding the NodeSource Node.js ${NODE_MAJOR}.x repository"

# 将 NodeSource 签名密钥限制在该 apt 源范围内
sudo install -d -m 0755 "$KEYRING_DIR"
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor \
    | sudo tee "$NODESOURCE_KEYRING" >/dev/null
sudo chmod 0644 "$NODESOURCE_KEYRING"
echo "deb [signed-by=${NODESOURCE_KEYRING}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    | sudo tee "$NODESOURCE_LIST" >/dev/null
sudo apt-get update

print_step 4 "Installing Node.js"
sudo apt-get install -y nodejs

print_step 5 "Configuring the user-level npm global directory"
mkdir -p "$NPM_DIR"
npm config set prefix "$NPM_DIR"

SHELL_RC="$(select_shell_rc)"

if [ "$NPM_DIR" = "$HOME/.local/npm" ]; then
    readonly PATH_LINE="export PATH=\"\$HOME/.local/npm/bin:\$PATH\""
else
    readonly PATH_LINE="export PATH=\"${NPM_DIR}/bin:\$PATH\""
fi
touch "$SHELL_RC"
if ! grep -Fqx "$PATH_LINE" "$SHELL_RC"; then
    {
        echo
        echo '# npm 全局命令'
        echo "$PATH_LINE"
    } >>"$SHELL_RC"
fi

export PATH="$NPM_DIR/bin:$PATH"
echo "Shell configuration file: $SHELL_RC"

print_step 6 "Configuring npm"
npm config set registry "$NPM_REGISTRY"
echo "npm registry: $NPM_REGISTRY"

print_step 7 "Installing development and AI CLI tools"
npm install -g "npm@${NPM_VERSION}"
# 仅允许确实需要生命周期脚本的包运行安装脚本
npm install -g --allow-scripts=opencode-ai,yarn,@ast-grep/cli \
    pnpm \
    yarn \
    typescript \
    eslint \
    prettier \
    @openai/codex \
    opencode-ai \
    @ast-grep/cli

print_step 8 "Checking the environment"
printf 'Node:       '; node -v
printf 'npm:        '; npm -v
printf 'npm prefix: '; npm config get prefix
printf 'npm root:   '; npm root -g
printf 'pnpm:       '; pnpm --version
printf 'yarn:       '; yarn --version
printf 'TypeScript: '; tsc --version
printf 'ESLint:     '; eslint --version
printf 'Prettier:   '; prettier --version
printf 'Codex:      '; codex --version || true
printf 'OpenCode:   '; opencode --version || true
printf 'ast-grep:   '; sg --version || true

# oh-my-openagent
# 在 Node/npm 之后安装，确保 OpenCode 与 Codex 已在 PATH 中
# 组件名之后的参数会原样透传给上游安装器

omo_needs_bun=false
case "$OMO_PLATFORM" in
    opencode|both) omo_needs_bun=true ;;
    codex)         ;;
    *)
        echo "Invalid OMO_PLATFORM: $OMO_PLATFORM (expected opencode, codex, or both)" >&2
        exit 1
        ;;
esac

bun_bin=""
if [ "$omo_needs_bun" = "true" ]; then
    print_step 9 "Ensuring Bun is available for oh-my-openagent"
    if command -v bun >/dev/null 2>&1; then
        bun_bin="$(command -v bun)"
    elif [ -x "$BUN_DIR/bin/bun" ]; then
        bun_bin="$BUN_DIR/bin/bun"
    else
        echo "Bun not found; installing via the official installer."
        curl -fsSL https://bun.sh/install | bash
        bun_bin="$BUN_DIR/bin/bun"
    fi
    # 确保子进程能找到 bun，避免部分 OMO provisioning 回退到 node 路径
    case ":${PATH:-}:" in
        *":$BUN_DIR/bin:"*) ;;
        *) export PATH="$BUN_DIR/bin:${PATH:-}" ;;
    esac
    printf 'Bun:        %s\n' "$("$bun_bin" --version)"
fi

print_step 10 "Installing oh-my-openagent ($OMO_PLATFORM edition)"
# 复用已验证可用的 ast-grep 二进制，避开 OMO provisioning 路径问题
if [ -x "$NPM_DIR/bin/sg" ]; then
    export OMO_AST_GREP_SG_PATH="$NPM_DIR/bin/sg"
fi
# 这里不传订阅参数，后面统一修正生成的 OpenCode 模型前缀
case "$OMO_PLATFORM" in
    opencode|both)
        "$bun_bin" x oh-my-openagent install --platform="$OMO_PLATFORM" \
            --no-tui \
            --claude=no --gemini=no --copilot=no \
            --skip-auth \
            "$@"
        ;;
    codex)
        npx --yes lazycodex-ai install "$@"
        ;;
esac

omo_config="$HOME/.config/opencode/oh-my-openagent.json"
[ -f "$omo_config" ] || omo_config="$HOME/.config/opencode/oh-my-openagent.jsonc"
if [ -f "$omo_config" ]; then
    edit_jsonc_config override-omo-models \
        "$omo_config" \
        "${OMO_MODEL:-zhipuai-coding-plan/glm-5.2}" \
        "${OMO_FALLBACK_MODEL:-deepseek/deepseek-v4-pro}"
fi

print_step 11 "Installing GitHub CLI (gh)"
# GitHub 发布的 keyring 已是 dearmor 后的格式
sudo install -d -m 0755 "$KEYRING_DIR"
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee "$GH_KEYRING" >/dev/null
sudo chmod 0644 "$GH_KEYRING"
echo "deb [arch=$(dpkg --print-architecture) signed-by=${GH_KEYRING}] https://cli.github.com/packages stable main" \
    | sudo tee "$GH_LIST" >/dev/null
sudo apt-get update
sudo apt-get install -y gh
printf 'gh:         %s\n' "$(gh --version | head -1)"

print_step 12 "Checking oh-my-openagent"
if [ "$omo_needs_bun" = "true" ]; then
    "$bun_bin" x oh-my-openagent doctor || true
fi
printf 'Platform:   %s\n' "$OMO_PLATFORM"

# MCP 服务器
# Context7 与 Playwright 均无需凭据

print_step 13 "Installing MCP servers: Context7 / Playwright ($OMO_PLATFORM edition)"

if omo_installs_opencode; then
    if [ -z "$opencode_config" ]; then
        opencode_config="$(opencode_config_file)"
        mkdir -p "$(dirname "$opencode_config")"
    fi

    edit_jsonc_config ensure-mcp "$opencode_config" "$MCP_CONTEXT7_URL" "$MCP_PLAYWRIGHT_SPEC"
fi

if omo_installs_codex; then
    # 服务器尚未注册时 codex mcp get 会返回非零状态
    codex mcp get context7 >/dev/null 2>&1 \
        || codex mcp add context7 --url "$MCP_CONTEXT7_URL"
    codex mcp get playwright >/dev/null 2>&1 \
        || codex mcp add playwright -- npx -y "$MCP_PLAYWRIGHT_SPEC"
fi

configure_codex_base

echo
echo "======================================"
echo "Installation complete"
echo "======================================"
