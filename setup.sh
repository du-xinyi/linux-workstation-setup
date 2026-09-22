#!/usr/bin/env bash

# 工作站安装统一入口：单独运行组件，或按依赖顺序执行全部组件。
# 组件后的参数透传给安装器；all 模式负责跳过列表、索引更新和失败汇总。

set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

# 输出入口用法，不执行安装或环境检查。
usage() {
    cat <<'EOF'
Usage:
  ./setup.sh
  ./setup.sh all
  ./setup.sh all --continue-on-error
  ./setup.sh all --skip rust,python-tools
  ./setup.sh <component> [installer arguments...]

Components:
  all             Install all components in the recommended order
  mirrors         Switch apt/pip/conda sources to a domestic mirror
  git             Install Git with HTTPS and SSH support
  npm             Install Node.js, npm, and common frontend CLI tools
  ai-tools        Install AI CLI tools (Codex, OpenCode, ast-grep) and MCP servers
  fcitx5-rime     Install Fcitx 5, Rime, and Rime Ice
  fonts           Install common Latin, programming, CJK, and Emoji fonts
  zsh             Install and configure Zsh, Oh My Zsh, and plugins
  ruby            Install Ruby using rbenv and ruby-build
  rust            Install Rust using the official rustup installer
  cpp             Install C/C++ toolchain: amd64/arm64/armhf/riscv64 cross + bare-metal + common libs
  python          Install system Python tools and common libraries using apt
  python-tools    Install Miniconda and uv (aliases: miniconda, conda)
  extras          Install extra applications
  list            List available components
  help            Show this help

Examples:
  ./setup.sh
  ./setup.sh all
  ./setup.sh all --continue-on-error
  ./setup.sh all --skip rust,python-tools
  ./setup.sh npm
  ./setup.sh git
  ./setup.sh ai-tools
  ./setup.sh zsh
  ./setup.sh ruby
  ./setup.sh rust
  ./setup.sh cpp
  ./setup.sh python
  ./setup.sh python-tools
  ./setup.sh extras
  MIRROR_PROVIDER=aliyun ./setup.sh mirrors
EOF
}

# 每行输出一个标准组件名，便于终端查看和脚本读取。
list_components() {
    printf '%s\n' all mirrors git fonts zsh npm ai-tools rust ruby cpp python python-tools extras fcitx5-rime
}

# 将跳过列表中的别名转为标准名；未知名称返回非零状态。
normalize_component() {
    case "$1" in
        mirrors|apt-mirror|mirror)
            printf '%s\n' mirrors
            ;;
        cpp|cxx|c++)
            printf '%s\n' cpp
            ;;
        git|npm|ai-tools|fonts|zsh|ruby|rust|python|python-tools|extras|fcitx5-rime)
            printf '%s\n' "$1"
            ;;
        rime)
            printf '%s\n' fcitx5-rime
            ;;
        miniconda|conda)
            printf '%s\n' python-tools
            ;;
        *)
            return 1
            ;;
    esac
}

# 标记需要提前刷新 APT 索引的组件；换源组件另行处理。
component_requires_apt() {
    case "$1" in
        git|fonts|fcitx5-rime|zsh|npm|ai-tools|ruby|cpp|python|extras) return 0 ;;
        *) return 1 ;;
    esac
}

# 查询已归一化的跳过列表，不修改安装顺序。
is_skipped_component() {
    local component="$1"
    local skipped

    for skipped in "${SKIP_COMPONENTS[@]}"; do
        if [ "$component" = "$skipped" ]; then
            return 0
        fi
    done

    return 1
}

# 解析逗号分隔的 --skip 参数；空值或未知组件视为用法错误。
add_skip_components() {
    local raw="$1"
    local requested
    local normalized
    local item

    if [ -z "$raw" ]; then
        printf 'The --skip option requires a comma-separated component list.\n' >&2
        exit 2
    fi

    IFS=',' read -r -a requested <<<"$raw"
    for item in "${requested[@]}"; do
        if [ -z "$item" ]; then
            printf 'Invalid empty component in --skip: %s\n' "$raw" >&2
            exit 2
        fi

        if ! normalized="$(normalize_component "$item")"; then
            printf 'Unknown component in --skip: %s\n' "$item" >&2
            exit 2
        fi

        SKIP_COMPONENTS+=("$normalized")
    done
}

# all 模式共用一次索引更新；若将执行 mirrors，则交给它在换源后更新。
update_package_indexes_once() {
    local component

    for component in "${ALL_COMPONENTS[@]}"; do
        if is_skipped_component "$component"; then
            continue
        fi

        # mirrors 组件会先换源再刷新索引,避免此处用官方源做无谓的预更新
        if [ "$component" = "mirrors" ]; then
            return
        fi

        if component_requires_apt "$component"; then
            printf '\n========== Updating package indexes ==========\n'
            require_non_root
            require_debian_like
            require_sudo
            sudo apt-get update
            return
        fi
    done
}

# 以独立进程执行安装器，保留参数边界并向调用方传递退出状态。
run_component() {
    local component="$1"
    shift

    case "$component" in
        mirrors)
            "$ROOT_DIR/scripts/installers/install-mirrors.sh" "$@"
            ;;
        git)
            "$ROOT_DIR/scripts/installers/install-git.sh" "$@"
            ;;
        npm)
            "$ROOT_DIR/scripts/installers/install-nodejs.sh" "$@"
            ;;
        ai-tools)
            "$ROOT_DIR/scripts/installers/install-ai-tools.sh" "$@"
            ;;
        fcitx5-rime|rime)
            "$ROOT_DIR/scripts/installers/install-fcitx5-rime.sh" "$@"
            ;;
        fonts)
            "$ROOT_DIR/scripts/installers/install-fonts.sh" "$@"
            ;;
        zsh)
            "$ROOT_DIR/scripts/installers/install-zsh.sh" "$@"
            ;;
        ruby)
            "$ROOT_DIR/scripts/installers/install-ruby.sh" "$@"
            ;;
        rust)
            "$ROOT_DIR/scripts/installers/install-rust.sh" "$@"
            ;;
        cpp)
            "$ROOT_DIR/scripts/installers/install-cpp.sh" "$@"
            ;;
        python)
            "$ROOT_DIR/scripts/installers/install-python.sh" "$@"
            ;;
        python-tools|miniconda|conda)
            "$ROOT_DIR/scripts/installers/install-python-tools.sh" "$@"
            ;;
        extras)
            "$ROOT_DIR/scripts/installers/install-extras.sh" "$@"
            ;;
        *)
            printf 'Unknown component: %s\n\n' "$component" >&2
            usage >&2
            exit 2
            ;;
    esac
}

# 默认遇错停止；继续模式会收集失败组件，最终仍返回失败状态。
run_all() {
    local continue_on_error="${1:-false}"
    local component
    local failed_components=()

    update_package_indexes_once

    for component in "${ALL_COMPONENTS[@]}"; do
        if is_skipped_component "$component"; then
            printf '\n========== Skipping %s ==========\n' "$component"
            continue
        fi

        printf '\n========== Installing %s ==========\n' "$component"
        if SKIP_APT_UPDATE=1 run_component "$component"; then
            printf '\n========== Completed %s ==========\n' "$component"
        else
            failed_components+=("$component")
            printf '\n========== Failed %s ==========\n' "$component" >&2
            if [ "$continue_on_error" != "true" ]; then
                printf 'Stop after failure. Re-run with "./setup.sh all --continue-on-error" to continue past failed components.\n' >&2
                return 1
            fi
        fi
    done

    if [ "${#failed_components[@]}" -ne 0 ]; then
        printf '\nInstallation finished with failed components:\n' >&2
        printf '  %s\n' "${failed_components[@]}" >&2
        return 1
    fi

    printf '\nAll components installed successfully.\n'
}

readonly ALL_COMPONENTS=(
    mirrors
    git
    fonts
    zsh
    npm
    ai-tools
    rust
    ruby
    cpp
    python
    python-tools
    extras
    fcitx5-rime
)
SKIP_COMPONENTS=()

if [ "$#" -eq 0 ]; then
    run_all false
    exit
fi

component="$1"
shift

case "$component" in
    all)
        continue_on_error=false
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --continue-on-error)
                    continue_on_error=true
                    ;;
                --skip)
                    if [ "$#" -lt 2 ]; then
                        printf 'The --skip option requires a comma-separated component list.\n' >&2
                        exit 2
                    fi
                    add_skip_components "$2"
                    shift
                    ;;
                --skip=*)
                    add_skip_components "${1#--skip=}"
                    ;;
                *)
                    printf 'Unknown "all" option: %s\n' "$1" >&2
                    exit 2
                    ;;
            esac
            shift
        done
        run_all "$continue_on_error"
        ;;
    list)
        list_components
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        run_component "$component" "$@"
        ;;
esac
