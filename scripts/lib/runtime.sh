#!/usr/bin/env bash

# 安装进度输出与运行环境检查

# 参数：步骤编号、说明文本；总步数由调用方的 SETUP_STEP_TOTAL 提供。
print_step() {
    local number="$1"
    shift
    printf '\n[%s/%s] %s...\n' "$number" "$SETUP_STEP_TOTAL" "$*"
}

# 安装中的用户配置应归当前用户所有；root 调用时退出，可附带重试示例。
require_non_root() {
    local example="${1:-}"

    if [ "${EUID}" -eq 0 ]; then
        echo "Do not run this script as root." >&2
        if [ -n "$example" ]; then
            echo "Example: $example" >&2
        fi
        exit 1
    fi
}

# 加载 /etc/os-release 并限制发行版；ID、VERSION_ID 等变量留给安装器使用。
require_debian_like() {
    if [ ! -r /etc/os-release ]; then
        echo "Unable to identify the operating system; only Ubuntu/Debian is supported." >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian) ;;
        *)
            echo "Unsupported operating system: ${PRETTY_NAME:-unknown}; only Ubuntu/Debian is supported." >&2
            exit 1
            ;;
    esac
}

# 仅检查 sudo 命令是否存在，不预先认证；可用首个参数覆盖失败提示。
require_sudo() {
    local message="${1:-sudo was not found. Install it and configure sudo access first.}"

    if ! command -v sudo >/dev/null 2>&1; then
        echo "$message" >&2
        exit 1
    fi
}
