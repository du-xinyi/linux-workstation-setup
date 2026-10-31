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

# 从首个参数读取配置，将更新后的顶层字段写入第二个参数指定的文件。
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
                if ($0 ~ "^[[:space:]]*(" keys[i] "|\"" keys[i] "\"|\047" keys[i] "\047)[[:space:]]*=") {
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

# 更新 agents 表；布尔值由调用方完成校验并以 TOML 字面量传入。
update_codex_agents_config() {
    local path="$1"
    local out="$2"
    local enabled_value="$3"
    local interrupt_value="$4"

    CODEX_CFG_AGENTS_ENABLED="$enabled_value" \
    CODEX_CFG_AGENTS_MAX_THREADS="$CODEX_AGENTS_MAX_THREADS" \
    CODEX_CFG_SUBAGENT_MODEL="$CODEX_SUBAGENT_MODEL" \
    CODEX_CFG_SUBAGENT_REASONING="$CODEX_SUBAGENT_REASONING" \
    CODEX_CFG_AGENTS_INTERRUPT_MESSAGE="$interrupt_value" \
    awk '
        BEGIN {
            keys[1] = "enabled"
            keys[2] = "max_concurrent_threads_per_session"
            keys[3] = "default_subagent_model"
            keys[4] = "default_subagent_reasoning_effort"
            keys[5] = "interrupt_message"
            values[1] = ENVIRON["CODEX_CFG_AGENTS_ENABLED"]
            values[2] = ENVIRON["CODEX_CFG_AGENTS_MAX_THREADS"]
            values[3] = "\"" ENVIRON["CODEX_CFG_SUBAGENT_MODEL"] "\""
            values[4] = "\"" ENVIRON["CODEX_CFG_SUBAGENT_REASONING"] "\""
            values[5] = ENVIRON["CODEX_CFG_AGENTS_INTERRUPT_MESSAGE"]
            in_agents_table = 0
            agents_table_found = 0
        }

        function write_missing(    i) {
            for (i = 1; i <= 5; i++) {
                if (!written[i]) {
                    print keys[i] " = " values[i]
                    written[i] = 1
                }
            }
        }

        /^[[:space:]]*\[/ {
            if (in_agents_table) {
                write_missing()
            }

            table_header = $0
            sub(/[[:space:]]*#.*/, "", table_header)
            # TOML 表名允许裸键、双引号键和单引号键（\047 是单引号）。
            in_agents_table = (table_header ~ /^[[:space:]]*\[[[:space:]]*(agents|"agents"|\047agents\047)[[:space:]]*\][[:space:]]*$/)
            if (in_agents_table) {
                agents_table_found = 1
            }

            print
            next
        }

        in_agents_table {
            # max_threads 是旧版别名；统一迁移到当前正式键名，避免两个别名同时存在。
            if ($0 ~ /^[[:space:]]*(max_threads|"max_threads"|\047max_threads\047)[[:space:]]*=/) {
                if (!written[2]) {
                    print keys[2] " = " values[2]
                    written[2] = 1
                }
                next
            }

            for (i = 1; i <= 5; i++) {
                if ($0 ~ "^[[:space:]]*(" keys[i] "|\"" keys[i] "\"|\047" keys[i] "\047)[[:space:]]*=") {
                    if (!written[i]) {
                        print keys[i] " = " values[i]
                        written[i] = 1
                    }
                    next
                }
            }
        }

        { print }

        END {
            if (in_agents_table) {
                write_missing()
            } else if (!agents_table_found) {
                print ""
                print "[agents]"
                write_missing()
            }
        }
    ' "$path" >"$out"
}

# 更新 memories 表，保留其它记忆配置及子表。
update_codex_memories_config() {
    local path="$1"
    local out="$2"

    CODEX_CFG_EXTRACT_MODEL="$CODEX_EXTRACT_MODEL" \
    CODEX_CFG_CONSOLIDATION_MODEL="$CODEX_CONSOLIDATION_MODEL" \
    awk '
        BEGIN {
            keys[1] = "extract_model"
            keys[2] = "consolidation_model"
            values[1] = ENVIRON["CODEX_CFG_EXTRACT_MODEL"]
            values[2] = ENVIRON["CODEX_CFG_CONSOLIDATION_MODEL"]
            in_memories_table = 0
            memories_table_found = 0
        }

        function write_missing(    i) {
            for (i = 1; i <= 2; i++) {
                if (!written[i]) {
                    print keys[i] " = \"" values[i] "\""
                    written[i] = 1
                }
            }
        }

        /^[[:space:]]*\[/ {
            if (in_memories_table) {
                write_missing()
            }

            table_header = $0
            sub(/[[:space:]]*#.*/, "", table_header)
            in_memories_table = (table_header ~ /^[[:space:]]*\[[[:space:]]*(memories|"memories"|\047memories\047)[[:space:]]*\][[:space:]]*$/)
            if (in_memories_table) {
                memories_table_found = 1
            }

            print
            next
        }

        in_memories_table {
            for (i = 1; i <= 2; i++) {
                if ($0 ~ "^[[:space:]]*(" keys[i] "|\"" keys[i] "\"|\047" keys[i] "\047)[[:space:]]*=") {
                    if (!written[i]) {
                        print keys[i] " = \"" values[i] "\""
                        written[i] = 1
                    }
                    next
                }
            }
        }

        { print }

        END {
            if (in_memories_table) {
                write_missing()
            } else if (!memories_table_found) {
                print ""
                print "[memories]"
                write_missing()
            }
        }
    ' "$path" >"$out"
}

# 开关必须放在 [features] 表内，不能直接当作 shell 命令运行。
update_codex_features_config() {
    local path="$1"
    local out="$2"
    local multi_agent_value="$3"
    local memories_value="$4"

    CODEX_CFG_MULTI_AGENT="$multi_agent_value" \
    CODEX_CFG_MEMORIES="$memories_value" \
    awk '
        BEGIN {
            keys[1] = "multi_agent"
            keys[2] = "memories"
            values[1] = ENVIRON["CODEX_CFG_MULTI_AGENT"]
            values[2] = ENVIRON["CODEX_CFG_MEMORIES"]
            in_features = 0
            found_features = 0
        }
        function write_missing(    i) {
            for (i = 1; i <= 2; i++) {
                if (!written[i]) {
                    print keys[i] " = " values[i]
                    written[i] = 1
                }
            }
        }
        /^[[:space:]]*\[/ {
            if (in_features) write_missing()
            header = $0
            sub(/[[:space:]]*#.*/, "", header)
            in_features = (header ~ /^[[:space:]]*\[[[:space:]]*(features|"features"|\047features\047)[[:space:]]*\][[:space:]]*$/)
            if (in_features) found_features = 1
            print
            next
        }
        in_features {
            for (i = 1; i <= 2; i++) {
                if ($0 ~ "^[[:space:]]*(" keys[i] "|\"" keys[i] "\"|\047" keys[i] "\047)[[:space:]]*=") {
                    if (!written[i]) {
                        print keys[i] " = " values[i]
                        written[i] = 1
                    }
                    next
                }
            }
        }
        { print }
        END {
            if (in_features) {
                write_missing()
            } else if (!found_features) {
                print ""
                print "[features]"
                write_missing()
            }
        }
    ' "$path" >"$out"
}

# 校验环境变量并更新用户配置；配置位置遵循 CODEX_HOME。
configure_codex_base() {
    local codex_cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
    local config_dir
    local staging
    local original_exists=0
    local pair
    local key
    local val
    local names
    local agents_enabled_value
    local agents_interrupt_value
    local agents_tmp
    local memories_tmp
    local network_value
    local multi_agent_value
    local memories_value
    local network_tmp
    local features_tmp
    local top_level_tmp
    local codex_pairs=(
        "model|$CODEX_MODEL"
        "model_reasoning_effort|$CODEX_REASONING"
        "service_tier|$CODEX_SERVICE_TIER"
        "approval_policy|$CODEX_APPROVAL"
        "sandbox_mode|$CODEX_SANDBOX"
    )
    local codex_missing=()

    case "$CODEX_MULTI_AGENT" in
        enabled) multi_agent_value="true" ;;
        disabled) multi_agent_value="false" ;;
        *) echo "Invalid CODEX_MULTI_AGENT: $CODEX_MULTI_AGENT (expected enabled or disabled)" >&2; return 1 ;;
    esac
    case "$CODEX_MEMORIES" in
        enabled) memories_value="true" ;;
        disabled) memories_value="false" ;;
        *) echo "Invalid CODEX_MEMORIES: $CODEX_MEMORIES (expected enabled or disabled)" >&2; return 1 ;;
    esac
    case "$CODEX_SANDBOX" in
        read-only|workspace-write|danger-full-access) ;;
        *) echo "Invalid CODEX_SANDBOX: $CODEX_SANDBOX" >&2; return 1 ;;
    esac
    case "$CODEX_APPROVAL" in
        on-request|never) ;;
        *) echo "Invalid CODEX_APPROVAL: $CODEX_APPROVAL" >&2; return 1 ;;
    esac
    case "$CODEX_REASONING" in
        none|minimal|low|medium|high|xhigh|max|ultra) ;;
        *) echo "Invalid CODEX_REASONING: $CODEX_REASONING" >&2; return 1 ;;
    esac
    case "$CODEX_SUBAGENT_REASONING" in
        none|minimal|low|medium|high|xhigh|max|ultra) ;;
        *) echo "Invalid CODEX_SUBAGENT_REASONING: $CODEX_SUBAGENT_REASONING" >&2; return 1 ;;
    esac
    case "$CODEX_SERVICE_TIER" in
        default|fast) ;;
        *) echo "Invalid CODEX_SERVICE_TIER: $CODEX_SERVICE_TIER" >&2; return 1 ;;
    esac

    case "$CODEX_NETWORK" in
        enabled) network_value="true" ;;
        disabled) network_value="false" ;;
        *)
            echo "Invalid CODEX_NETWORK: $CODEX_NETWORK (expected enabled or disabled)" >&2
            return 1
            ;;
    esac

    case "$CODEX_AGENTS_ENABLED" in
        enabled) agents_enabled_value="true" ;;
        disabled) agents_enabled_value="false" ;;
        *)
            echo "Invalid CODEX_AGENTS_ENABLED: $CODEX_AGENTS_ENABLED (expected enabled or disabled)" >&2
            return 1
            ;;
    esac

    case "$CODEX_AGENTS_INTERRUPT_MESSAGE" in
        enabled) agents_interrupt_value="true" ;;
        disabled) agents_interrupt_value="false" ;;
        *)
            echo "Invalid CODEX_AGENTS_INTERRUPT_MESSAGE: $CODEX_AGENTS_INTERRUPT_MESSAGE (expected enabled or disabled)" >&2
            return 1
            ;;
    esac

    if [[ ! "$CODEX_AGENTS_MAX_THREADS" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid CODEX_AGENTS_MAX_THREADS: $CODEX_AGENTS_MAX_THREADS (expected a positive integer)" >&2
        return 1
    fi

    for pair in "${codex_pairs[@]}"; do
        key="${pair%%|*}"
        val="${pair#*|}"
        validate_codex_config_value "$key" "$val"
    done
    validate_codex_config_value "default_subagent_model" "$CODEX_SUBAGENT_MODEL"
    validate_codex_config_value "default_subagent_reasoning_effort" "$CODEX_SUBAGENT_REASONING"
    # validate_codex_config_value "extract_model" "$CODEX_EXTRACT_MODEL"
    # validate_codex_config_value "consolidation_model" "$CODEX_CONSOLIDATION_MODEL"

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

    for pair in "${codex_pairs[@]}"; do
        key="${pair%%|*}"
        if ! codex_top_level_has_key "$staging" "$key"; then
            codex_missing+=("$pair")
        fi
    done

    top_level_tmp="$(mktemp)"
    update_codex_top_level_config "$staging" "$top_level_tmp"
    cat "$top_level_tmp" >"$staging"
    rm -f -- "$top_level_tmp"

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
            # 与 agents 表一样，识别 TOML 允许的三种表名写法。
            in_workspace_table = (table_header ~ /^[[:space:]]*\[[[:space:]]*(sandbox_workspace_write|"sandbox_workspace_write"|\047sandbox_workspace_write\047)[[:space:]]*\][[:space:]]*$/)
            if (in_workspace_table) {
                workspace_table_found = 1
            }

            print
            next
        }

        before_first_table && /^[[:space:]]*(network_access|"network_access"|\047network_access\047)[[:space:]]*=/ {
            next
        }

        in_workspace_table && /^[[:space:]]*(network_access|"network_access"|\047network_access\047)[[:space:]]*=/ {
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
    ' "$staging" >"$network_tmp"
    cat "$network_tmp" >"$staging"
    rm -f -- "$network_tmp"

    features_tmp="$(mktemp)"
    update_codex_features_config "$staging" "$features_tmp" "$multi_agent_value" "$memories_value"
    cat "$features_tmp" >"$staging"
    rm -f -- "$features_tmp"

    agents_tmp="$(mktemp)"
    update_codex_agents_config \
        "$staging" "$agents_tmp" "$agents_enabled_value" "$agents_interrupt_value"
    cat "$agents_tmp" >"$staging"
    rm -f -- "$agents_tmp"

    memories_tmp="$(mktemp)"
    update_codex_memories_config "$staging" "$memories_tmp"
    cat "$memories_tmp" >"$staging"
    rm -f -- "$memories_tmp"

    # 系统有 Python 3.11+ 时，进行标准 TOML 语法校验（Ubuntu 24.04 可用）。
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c 'import tomllib' >/dev/null 2>&1; then
            if ! python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$staging"; then
                echo "Generated Codex config is invalid; original kept: $codex_cfg" >&2
                rm -f -- "$staging"
                return 1
            fi
        fi
    fi
    if (( original_exists )); then
        cp -p -- "$codex_cfg" "${codex_cfg}.bak"
    fi
    mv -f -- "$staging" "$codex_cfg"

    if [ "${#codex_missing[@]}" -gt 0 ]; then
        names=""
        for pair in "${codex_missing[@]}"; do names="$names ${pair%%|*}"; done
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

require_non_root "bash install-ai-tools-fixed.sh"
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
curl -fsSL https://opencode.ai/install | bash

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
