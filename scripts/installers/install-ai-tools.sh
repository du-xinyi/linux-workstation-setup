#!/usr/bin/env bash

# 安装 AI 工具、CC Switch，并配置 MCP、Codex 和全局协作规范；需要预先安装 Node.js/npm。

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

# 优先复用仓库的公共函数；独立下载此文件时也能直接运行。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/../../scripts/lib/common.sh" ]]; then
    ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
    # shellcheck disable=SC1091
    . "$ROOT_DIR/scripts/lib/common.sh"
else
    ROOT_DIR=""
    require_non_root() {
        if (( EUID == 0 )); then
            echo "Please run as a normal user, not root: $1" >&2
            return 1
        fi
    }
    require_debian_like() {
        if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
            echo "This installer requires Ubuntu/Debian with APT and dpkg." >&2
            return 1
        fi
    }
    require_sudo() {
        if ! command -v sudo >/dev/null 2>&1; then
            echo "${1:-sudo was not found.}" >&2
            return 1
        fi
    }
    select_shell_rc() {
        case "${SHELL:-/bin/bash}" in
            */zsh) printf '%s\n' "$HOME/.zshrc" ;;
            *)     printf '%s\n' "$HOME/.bashrc" ;;
        esac
    }
    print_step() { printf '\n[%s/%s] %s\n' "$1" "$SETUP_STEP_TOTAL" "$2"; }
    apt_get_update_step() {
        print_step "$1" "Updating APT package index"
        sudo apt-get update
    }
fi
readonly ROOT_DIR
readonly SETUP_STEP_TOTAL=9

# MCP 服务器
# 无需鉴权的 MCP 端点
readonly MCP_CONTEXT7_URL="https://mcp.context7.com/mcp"
readonly MCP_PLAYWRIGHT_SPEC="@playwright/mcp@latest"
readonly OPENCODE_BIN="${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"

# Codex 模型配置，可通过同名环境变量覆盖

# 主模型
readonly CODEX_MODEL="${CODEX_MODEL:-gpt-6.1-sol}"
# 推理强度
readonly CODEX_REASONING="${CODEX_REASONING:-high}"
# 服务等级：default 或 fast
readonly CODEX_SERVICE_TIER="${CODEX_SERVICE_TIER:-default}"

# 子 Agent 模型与推理强度
readonly CODEX_SUBAGENT_MODEL="${CODEX_SUBAGENT_MODEL:-gpt-6.1-sol}"
readonly CODEX_SUBAGENT_REASONING="${CODEX_SUBAGENT_REASONING:-medium}"

# 记忆提取与合并模型
readonly CODEX_EXTRACT_MODEL="${CODEX_EXTRACT_MODEL:-gpt-6-luna}"
readonly CODEX_CONSOLIDATION_MODEL="${CODEX_CONSOLIDATION_MODEL:-gpt-6.1-terra}"

# Codex 权限与功能配置，可通过同名环境变量覆盖

# 命令审批策略：on-request（推荐）或 never
readonly CODEX_APPROVAL="${CODEX_APPROVAL:-never}"

# 文件系统沙箱：read-only、workspace-write 或 danger-full-access
# 保留原脚本的无沙箱、免审批设置；请仅在可信环境中使用。
readonly CODEX_SANDBOX="${CODEX_SANDBOX:-danger-full-access}"

# workspace-write 模式的网络权限：enabled / disabled
readonly CODEX_NETWORK="${CODEX_NETWORK:-enabled}"

# 多代理和记忆开关：enabled / disabled
readonly CODEX_MULTI_AGENT="${CODEX_MULTI_AGENT:-enabled}"
readonly CODEX_MEMORIES="${CODEX_MEMORIES:-enabled}"
readonly CODEX_AGENTS_ENABLED="${CODEX_AGENTS_ENABLED:-enabled}"
readonly CODEX_AGENTS_MAX_THREADS="${CODEX_AGENTS_MAX_THREADS:-6}"
readonly CODEX_AGENTS_INTERRUPT_MESSAGE="${CODEX_AGENTS_INTERRUPT_MESSAGE:-enabled}"

# 使用官方原生安装器，并让后续终端能找到用户目录中的命令。
install_claude_code() {
    local shell_rc
    local path_line='export PATH="$HOME/.local/bin:$PATH"'

    curl -fsSL https://claude.ai/install.sh | bash

    shell_rc="$(select_shell_rc)"
    touch "$shell_rc"
    if ! grep -Fqx "$path_line" "$shell_rc"; then
        printf '\n# Claude Code\n%s\n' "$path_line" >> "$shell_rc"
    fi
    export PATH="$HOME/.local/bin:$PATH"
}

# 解析最新正式版后下载官方 DEB，由 APT 处理依赖；退出时清理临时文件。
install_cc_switch() (
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64) asset_arch=x86_64 ;;
        arm64) asset_arch=arm64 ;;
        *) echo "No CC Switch DEB configured for architecture: $arch" >&2; exit 1 ;;
    esac

    # 使用网页重定向获取 tag，无需 GitHub API 凭据或配额。
    release_base="https://github.com/farion1231/cc-switch/releases"
    release_url="$(curl -fLsS --retry 3 --connect-timeout 15 --max-time 120 \
        -o /dev/null -w '%{url_effective}' "$release_base/latest")"
    release_tag="${release_url##*/}"
    if [[ ! "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Unable to resolve the latest CC Switch release: $release_url" >&2
        exit 1
    fi
    echo "Latest CC Switch release: $release_tag"

    tmpdir="$(mktemp -d /tmp/cc-switch.XXXXXX)"
    trap 'rm -rf -- "$tmpdir"' EXIT
    deb="$tmpdir/cc-switch.deb"
    url="$release_base/download/$release_tag/CC-Switch-${release_tag}-Linux-${asset_arch}.deb"
    curl -fL --retry 3 --connect-timeout 15 --max-time 600 -o "$deb" "$url"
    if [ "$(dpkg-deb -f "$deb" Package)" != "cc-switch" ] ||
       [ "$(dpkg-deb -f "$deb" Architecture)" != "$arch" ]; then
        echo "Downloaded CC Switch package has an unexpected name or architecture." >&2
        exit 1
    fi
    # APT 的 _apt 用户需要读取临时目录内的安装包。
    chmod 755 "$tmpdir"
    chmod 644 "$deb"
    sudo apt-get install -y "$deb"
)

# 读取合并后的 OpenCode 配置，仅注册尚不存在的 MCP 服务。
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

# 只查首个 TOML 表之前的键；兼容裸键、双引号键和单引号键。
codex_top_level_has_key() {
    local path="$1"
    local key="$2"

    awk -v key="$key" '
        /^[[:space:]]*\[/ { exit 1 }
        $0 ~ "^[[:space:]]*(" key "|\"" key "\"|\047" key "\047)[[:space:]]*=" { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$path"
}

# 拒绝无法直接嵌入双引号 TOML 字符串的字符，防止写出无效配置。
validate_codex_config_value() {
    local key="$1"
    local value="$2"

    if [[ "$value" == *'"'* || "$value" == *\\* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        echo "Invalid $key: the value cannot contain quotes, backslashes, or newlines." >&2
        return 1
    fi
}

# 更新 TOML 中单个表的键，结果写入 out；table 为空串表示首个表之前的顶层键。
# 规则参数（值为 TOML 字面量，字符串需自带引号）：
#   set:KEY=VALUE    原位替换或补齐该键，重复出现的同名键只保留一个
#   del:KEY          删除该键
#   alias:OLD=NEW    将旧键名迁移为 NEW（NEW 须同时由 set 指定）
# 键名兼容裸键、双引号键和单引号键（\047 是单引号）；表不存在时追加到文件末尾。
toml_update_table() {
    local path="$1"
    local out="$2"
    local table="$3"
    shift 3

    TOML_TABLE="$table" TOML_RULES="$(printf '%s\n' "$@")" awk '
        function key_re(k) {
            return "^[[:space:]]*(" k "|\"" k "\"|\047" k "\047)[[:space:]]*="
        }

        function write_missing(    i) {
            for (i = 1; i <= n; i++) {
                if (!written[i]) {
                    print keys[i] " = " values[i]
                    written[i] = 1
                }
            }
        }

        # 返回当前行对应的 set 规则序号；-1 表示需删除，0 表示不受管理。
        function managed_key(    i, k) {
            for (k in deleted) if ($0 ~ key_re(k)) return -1
            for (i = 1; i <= n; i++) if ($0 ~ key_re(keys[i])) return i
            for (k in alias_to) if ($0 ~ key_re(k)) return alias_to[k]
            return 0
        }

        BEGIN {
            table = ENVIRON["TOML_TABLE"]
            count = split(ENVIRON["TOML_RULES"], rules, "\n")
            n = 0
            for (j = 1; j <= count; j++) {
                if (rules[j] == "") continue
                p = index(rules[j], ":")
                op = substr(rules[j], 1, p - 1)
                rest = substr(rules[j], p + 1)
                q = index(rest, "=")
                key = q ? substr(rest, 1, q - 1) : rest
                value = q ? substr(rest, q + 1) : ""
                if (op == "set") {
                    keys[++n] = key
                    values[n] = value
                    index_of[key] = n
                } else if (op == "del") {
                    deleted[key] = 1
                } else if (op == "alias") {
                    alias_target[key] = value
                }
            }
            for (k in alias_target) alias_to[k] = index_of[alias_target[k]]
            in_table = (table == "")
            found = in_table
        }

        /^[[:space:]]*\[/ {
            if (in_table) write_missing()
            if (table == "") {
                in_table = 0
            } else {
                header = $0
                sub(/[[:space:]]*#.*/, "", header)
                in_table = (header ~ "^[[:space:]]*\\[[[:space:]]*(" table "|\"" table "\"|\047" table "\047)[[:space:]]*\\][[:space:]]*$")
                if (in_table) found = 1
            }
            print
            next
        }

        in_table {
            i = managed_key()
            if (i < 0) next
            if (i > 0) {
                if (!written[i]) {
                    print keys[i] " = " values[i]
                    written[i] = 1
                }
                next
            }
        }

        { print }

        END {
            if (in_table) {
                write_missing()
            } else if (!found) {
                print ""
                print "[" table "]"
                write_missing()
            }
        }
    ' "$path" >"$out"
}

# 对暂存文件原位应用 toml_update_table，参数与其去掉 path/out 后相同。
toml_apply() {
    local staging="$1"
    local tmp
    shift

    tmp="$(mktemp)"
    if ! toml_update_table "$staging" "$tmp" "$@"; then
        rm -f -- "$tmp"
        return 1
    fi
    cat "$tmp" >"$staging"
    rm -f -- "$tmp"
}

# 将 enabled/disabled 开关转为 TOML 布尔值，写入第一个参数指定的变量。
parse_toggle() {
    local out_var="$1"
    local name="$2"
    local value="$3"

    case "$value" in
        enabled) printf -v "$out_var" '%s' true ;;
        disabled) printf -v "$out_var" '%s' false ;;
        *)
            echo "Invalid $name: $value (expected enabled or disabled)" >&2
            return 1
            ;;
    esac
}

# 校验值是否属于空格分隔的候选列表。
require_choice() {
    local name="$1"
    local value="$2"
    local choices="$3"

    case " $choices " in
        *" $value "*) ;;
        *) echo "Invalid $name: $value (expected one of: $choices)" >&2; return 1 ;;
    esac
}

# 校验环境变量并更新用户配置；配置位置遵循 CODEX_HOME。
configure_codex_base() {
    local codex_cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
    local reasoning_levels="none minimal low medium high xhigh max ultra"
    local config_dir
    local staging
    local original_exists=0
    local key
    local names
    local multi_agent_value
    local memories_value
    local network_value
    local agents_enabled_value
    local agents_interrupt_value
    local top_level_keys=(model model_reasoning_effort service_tier approval_policy sandbox_mode)
    local codex_missing=()

    parse_toggle multi_agent_value CODEX_MULTI_AGENT "$CODEX_MULTI_AGENT"
    parse_toggle memories_value CODEX_MEMORIES "$CODEX_MEMORIES"
    parse_toggle network_value CODEX_NETWORK "$CODEX_NETWORK"
    parse_toggle agents_enabled_value CODEX_AGENTS_ENABLED "$CODEX_AGENTS_ENABLED"
    parse_toggle agents_interrupt_value CODEX_AGENTS_INTERRUPT_MESSAGE "$CODEX_AGENTS_INTERRUPT_MESSAGE"
    require_choice CODEX_SANDBOX "$CODEX_SANDBOX" "read-only workspace-write danger-full-access"
    require_choice CODEX_APPROVAL "$CODEX_APPROVAL" "on-request never"
    require_choice CODEX_REASONING "$CODEX_REASONING" "$reasoning_levels"
    require_choice CODEX_SUBAGENT_REASONING "$CODEX_SUBAGENT_REASONING" "$reasoning_levels"
    require_choice CODEX_SERVICE_TIER "$CODEX_SERVICE_TIER" "default fast"

    if [[ ! "$CODEX_AGENTS_MAX_THREADS" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid CODEX_AGENTS_MAX_THREADS: $CODEX_AGENTS_MAX_THREADS (expected a positive integer)" >&2
        return 1
    fi

    # 以下值会嵌入双引号 TOML 字符串
    validate_codex_config_value model "$CODEX_MODEL"
    validate_codex_config_value default_subagent_model "$CODEX_SUBAGENT_MODEL"
    validate_codex_config_value extract_model "$CODEX_EXTRACT_MODEL"
    validate_codex_config_value consolidation_model "$CODEX_CONSOLIDATION_MODEL"

    config_dir="$(dirname "$codex_cfg")"
    mkdir -p "$config_dir"
    if [ -L "$codex_cfg" ] || { [ -e "$codex_cfg" ] && [ ! -f "$codex_cfg" ]; }; then
        echo "Codex config is not a regular file: $codex_cfg" >&2
        return 1
    fi
    if [ -f "$codex_cfg" ]; then
        original_exists=1
    fi
    # 所有修改都先写在临时文件，避免中途失败导致用户配置损坏。
    staging="$(mktemp "$config_dir/.config.toml.XXXXXX")"
    if (( original_exists )); then
        cp -p -- "$codex_cfg" "$staging"
    else
        chmod 600 "$staging"
    fi

    for key in "${top_level_keys[@]}"; do
        if ! codex_top_level_has_key "$staging" "$key"; then
            codex_missing+=("$key")
        fi
    done

    # 网络权限属于 workspace-write 沙箱表，顶层同名键不会被 Codex 识别，需删除。
    # max_threads 是旧版别名；统一迁移到当前正式键名，避免两个别名同时存在。
    if ! toml_apply "$staging" "" \
            "set:model=\"$CODEX_MODEL\"" \
            "set:model_reasoning_effort=\"$CODEX_REASONING\"" \
            "set:service_tier=\"$CODEX_SERVICE_TIER\"" \
            "set:approval_policy=\"$CODEX_APPROVAL\"" \
            "set:sandbox_mode=\"$CODEX_SANDBOX\"" \
            "del:network_access" ||
        ! toml_apply "$staging" sandbox_workspace_write \
            "set:network_access=$network_value" ||
        ! toml_apply "$staging" features \
            "set:multi_agent=$multi_agent_value" \
            "set:memories=$memories_value" ||
        ! toml_apply "$staging" agents \
            "set:enabled=$agents_enabled_value" \
            "set:max_concurrent_threads_per_session=$CODEX_AGENTS_MAX_THREADS" \
            "set:default_subagent_model=\"$CODEX_SUBAGENT_MODEL\"" \
            "set:default_subagent_reasoning_effort=\"$CODEX_SUBAGENT_REASONING\"" \
            "set:interrupt_message=$agents_interrupt_value" \
            "alias:max_threads=max_concurrent_threads_per_session" ||
        ! toml_apply "$staging" memories \
            "set:extract_model=\"$CODEX_EXTRACT_MODEL\"" \
            "set:consolidation_model=\"$CODEX_CONSOLIDATION_MODEL\""; then
        echo "Failed to update Codex config; original kept: $codex_cfg" >&2
        rm -f -- "$staging"
        return 1
    fi

    # 系统有 Python 3.11+ 时，进行标准 TOML 语法校验（Ubuntu 24.04 可用）。
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
        if ! python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$staging"; then
            echo "Generated Codex config is invalid; original kept: $codex_cfg" >&2
            rm -f -- "$staging"
            return 1
        fi
    fi
    if (( original_exists )); then
        cp -p -- "$codex_cfg" "${codex_cfg}.bak"
    fi
    mv -f -- "$staging" "$codex_cfg"

    if [ "${#codex_missing[@]}" -gt 0 ]; then
        names=" ${codex_missing[*]}"
        echo "Codex config -> $codex_cfg (added top-level:$names; agents and memories synchronized)"
    else
        echo "Codex config -> $codex_cfg (base, agents and memories synchronized)"
    fi
}

# 从仓库模板安装全局协作规范；默认遵循 CODEX_HOME，并保留已有文件。
install_codex_agent_instructions() {
    local source="$ROOT_DIR/config/codex/AGENTS.md"
    local target="${1:-${CODEX_HOME:-$HOME/.codex}/AGENTS.md}"

    if [ ! -f "$source" ]; then
        echo "Repository AGENTS.md template not found; skipping: $source" >&2
        return 0
    fi

    if [ -e "$target" ] || [ -L "$target" ]; then
        if cmp -s -- "$source" "$target"; then
            echo "Codex instructions already up to date: $target"
        else
            echo "Codex instructions differ from the repository template; keeping existing: $target"
            printf 'Compare with: diff -u -- %q %q\n' "$target" "$source"
        fi
    else
        mkdir -p "$(dirname "$target")"
        cp -- "$source" "$target"
        echo "Codex instructions installed: $target"
    fi
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

echo "======================================"
echo " Ubuntu/Debian AI Tools Installer (Codex / Claude Code / OpenCode / ast-grep / CC Switch)"
echo "======================================"

require_non_root "./setup.sh ai-tools"
require_debian_like
require_sudo "sudo was not found. Install it and grant sudo access to the current user."

# Codex 与 ast-grep 通过 npm 全局安装，依赖已配置好的 npm 前缀
if ! command -v npm >/dev/null 2>&1; then
    echo "npm was not found. Run './setup.sh npm' first." >&2
    exit 1
fi
if ! command -v npx >/dev/null 2>&1; then
    echo "npx was not found. Check your Node.js/npm installation." >&2
    exit 1
fi
NPM_PREFIX_BIN="$(npm config get prefix)/bin"
export PATH="$NPM_PREFIX_BIN:$PATH"

apt_get_update_step 1

print_step 2 "Installing base dependencies"
sudo apt-get install -y \
    ca-certificates \
    curl \
    jq

print_step 3 "Installing Codex and ast-grep"
npm install -g --allow-scripts=@ast-grep/cli \
    @openai/codex@latest \
    @ast-grep/cli@latest

print_step 4 "Installing Claude Code"
install_claude_code

print_step 5 "Installing OpenCode"
curl -fsSL https://opencode.ai/v2/install | bash

# MCP 服务器
# Context7 与 Playwright 均无需凭据

print_step 6 "Installing MCP servers: Context7 / Playwright"

configure_opencode_mcp

# 服务器尚未注册时 codex mcp get 会返回非零状态
codex mcp get context7 >/dev/null 2>&1 \
    || codex mcp add context7 --url "$MCP_CONTEXT7_URL"
codex mcp get playwright >/dev/null 2>&1 \
    || codex mcp add playwright -- npx -y "$MCP_PLAYWRIGHT_SPEC"

print_step 7 "Configuring Codex"
configure_codex_base
install_codex_agent_instructions

print_step 8 "Installing the latest CC Switch release"
install_cc_switch

print_step 9 "Checking the environment"
printf 'Codex:      '; codex --version || true
printf 'Claude Code: '; "$HOME/.local/bin/claude" --version
printf 'OpenCode:   '; "$OPENCODE_BIN" --version || true
printf 'ast-grep:   '; sg --version || true
printf 'CC Switch:  '; dpkg-query -W -f='${Version}\n' cc-switch

echo
echo "======================================"
echo "Installation complete"
echo "======================================"
echo "Open a new terminal and run 'claude' to sign in and get started."
echo "Launch CC Switch from the application menu or run 'cc-switch' in a desktop session."
