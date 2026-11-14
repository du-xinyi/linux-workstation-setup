#!/usr/bin/env bash

# 工作站安装统一入口：单独运行组件，或按依赖顺序执行全部组件。
# 组件后的参数透传给安装器；all 模式负责跳过列表、索引更新和失败汇总。

set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

# 组件表是组件信息的唯一来源，顺序即 all 模式的安装顺序（开发环境优先）：
# Mirrors 最先换源；Zsh 生成 ~/.zshrc，须在追加 Shell 配置的组件之前；
# Rust 先于 Ruby，使 Ruby 构建时可用 rustup 管理的 rustc。
# 字段：标准名|安装脚本|别名（空格分隔）|需要 APT 索引（1/0）|说明
readonly COMPONENT_TABLE=(
    "mirrors|install-mirrors.sh|mirror apt-mirror|0|Configure Tsinghua TUNA mirrors for apt/pip/uv/conda"
    "git|install-git.sh||1|Install Git with HTTPS and SSH support"
    "fonts|install-fonts.sh||1|Install common Latin, programming, CJK, and Emoji fonts"
    "zsh|install-zsh.sh||1|Install and configure Zsh, Oh My Zsh, and plugins"
    "npm|install-nodejs.sh||1|Install Node.js, npm, gh, and common frontend CLI tools"
    "ai-tools|install-ai-tools.sh||1|Install Codex, Claude Code, OpenCode, ast-grep, CC Switch, and MCP servers"
    "rust|install-rust.sh||0|Install Rust using the official rustup installer"
    "ruby|install-ruby.sh||1|Install Ruby using rbenv and ruby-build"
    "cpp|install-cpp.sh|cxx c++|1|Install C/C++ toolchains, cross compilers, and common libraries"
    "python|install-python.sh||1|Install system Python tools and common libraries using apt"
    "python-tools|install-python-tools.sh|miniconda conda|0|Install Miniconda and uv"
    "hugging-face|install-hugging-face.sh|huggingface hf|0|Install Hugging Face CLI (hf) using uv"
    "simulators|install-simulators.sh|mujoco|1|Install and configure simulators (currently MuJoCo)"
    "extras|install-extras.sh||1|Install extra desktop applications"
    "fcitx5-rime|install-fcitx5-rime.sh|rime|1|Install Fcitx 5, Rime, and Rime Ice"
)

ALL_COMPONENTS=()
declare -A COMPONENT_SCRIPT=()
declare -A COMPONENT_ALIAS=()
declare -A COMPONENT_NEEDS_APT=()
declare -A COMPONENT_DESC=()

# 由组件表生成查询结构；别名与标准名都映射到标准名。
load_component_table() {
    local row name script aliases needs_apt desc alias

    for row in "${COMPONENT_TABLE[@]}"; do
        IFS='|' read -r name script aliases needs_apt desc <<<"$row"
        ALL_COMPONENTS+=("$name")
        COMPONENT_SCRIPT[$name]="$script"
        COMPONENT_NEEDS_APT[$name]="$needs_apt"
        COMPONENT_DESC[$name]="$desc"
        COMPONENT_ALIAS[$name]="$name"
        for alias in $aliases; do
            COMPONENT_ALIAS[$alias]="$name"
        done
    done
    readonly ALL_COMPONENTS COMPONENT_SCRIPT COMPONENT_ALIAS COMPONENT_NEEDS_APT COMPONENT_DESC
}
load_component_table

# 输出入口用法，不执行安装或环境检查；组件列表由组件表生成。
usage() {
    local row name aliases desc

    cat <<'EOF'
Usage:
  ./setup.sh [all] [--continue-on-error] [--skip <component,...>]
  ./setup.sh <component> [installer arguments...]
  ./setup.sh list | help

Components (in "all" install order):
EOF
    for row in "${COMPONENT_TABLE[@]}"; do
        IFS='|' read -r name _ aliases _ desc <<<"$row"
        if [ -n "$aliases" ]; then
            desc="$desc (aliases: ${aliases// /, })"
        fi
        printf '  %-14s  %s\n' "$name" "$desc"
    done
    cat <<'EOF'

Examples:
  ./setup.sh
  ./setup.sh all --continue-on-error
  ./setup.sh all --skip rust,python-tools
  ./setup.sh npm
  ./setup.sh python-tools -b -p "$HOME/tools/miniconda3"
EOF
}

# 每行输出一个标准组件名，便于终端查看和脚本读取。
list_components() {
    printf '%s\n' all "${ALL_COMPONENTS[@]}"
}

# 将组件名或别名转为标准名；未知名称返回非零状态。
normalize_component() {
    [ -n "$1" ] && [ -n "${COMPONENT_ALIAS[$1]+set}" ] || return 1
    printf '%s\n' "${COMPONENT_ALIAS[$1]}"
}

# 标记需要提前刷新 APT 索引的组件；换源组件另行处理。
component_requires_apt() {
    [ "${COMPONENT_NEEDS_APT[$1]:-0}" = "1" ]
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
    local component

    if ! component="$(normalize_component "$1")"; then
        printf 'Unknown component: %s\n\n' "$1" >&2
        usage >&2
        exit 2
    fi
    shift

    "$ROOT_DIR/scripts/installers/${COMPONENT_SCRIPT[$component]}" "$@"
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
