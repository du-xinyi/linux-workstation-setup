#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

usage() {
    cat <<'EOF'
Usage:
  ./setup.sh
  ./setup.sh all
  ./setup.sh all --continue-on-error
  ./setup.sh all --skip rust,miniconda
  ./setup.sh <component> [installer arguments...]

Components:
  all             Install all components in the recommended order
  mirrors         Switch apt/pip/conda sources to a domestic mirror
  npm             Install Node.js, npm, and common frontend CLI tools
  ai-tools        Install AI CLI tools (Codex, OpenCode, ast-grep) and MCP servers
  fcitx5-rime     Install Fcitx 5, Rime, and Rime Ice
  fonts           Install common Latin, programming, CJK, and Emoji fonts
  zsh             Install and configure Zsh, Oh My Zsh, and plugins
  ruby            Install Ruby using rbenv and ruby-build
  rust            Install Rust using the official rustup installer
  cpp             Install C/C++ toolchain: amd64/arm64/armhf/riscv64 cross + bare-metal + common libs
  miniconda       Install Miniconda using the official installer
  extras          Install extra applications (Solaar, etc.)
  list            List available components
  help            Show this help

Examples:
  ./setup.sh
  ./setup.sh all
  ./setup.sh all --continue-on-error
  ./setup.sh all --skip rust,miniconda
  ./setup.sh npm
  ./setup.sh ai-tools
  ./setup.sh zsh
  ./setup.sh ruby
  ./setup.sh rust
  ./setup.sh cpp
  ./setup.sh miniconda
  ./setup.sh extras
  MIRROR_PROVIDER=aliyun ./setup.sh mirrors
EOF
}

list_components() {
    printf '%s\n' all mirrors fonts zsh npm ai-tools rust ruby cpp miniconda extras fcitx5-rime
}

normalize_component() {
    case "$1" in
        mirrors|apt-mirror|mirror)
            printf '%s\n' mirrors
            ;;
        cpp|cxx|c++)
            printf '%s\n' cpp
            ;;
        npm|ai-tools|fonts|zsh|ruby|rust|miniconda|extras|fcitx5-rime)
            printf '%s\n' "$1"
            ;;
        rime)
            printf '%s\n' fcitx5-rime
            ;;
        conda)
            printf '%s\n' miniconda
            ;;
        *)
            return 1
            ;;
    esac
}

component_requires_apt() {
    case "$1" in
        fonts|fcitx5-rime|zsh|npm|ai-tools|ruby|cpp|extras) return 0 ;;
        *) return 1 ;;
    esac
}

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

run_component() {
    local component="$1"
    shift

    case "$component" in
        mirrors)
            "$ROOT_DIR/scripts/install-mirrors.sh" "$@"
            ;;
        npm)
            "$ROOT_DIR/scripts/install-nodejs.sh" "$@"
            ;;
        ai-tools)
            "$ROOT_DIR/scripts/install-ai-tools.sh" "$@"
            ;;
        fcitx5-rime|rime)
            "$ROOT_DIR/scripts/install-fcitx5-rime.sh" "$@"
            ;;
        fonts)
            "$ROOT_DIR/scripts/install-fonts.sh" "$@"
            ;;
        zsh)
            "$ROOT_DIR/scripts/install-zsh.sh" "$@"
            ;;
        ruby)
            "$ROOT_DIR/scripts/install-ruby.sh" "$@"
            ;;
        rust)
            "$ROOT_DIR/scripts/install-rust.sh" "$@"
            ;;
        cpp)
            "$ROOT_DIR/scripts/install-cpp.sh" "$@"
            ;;
        miniconda|conda)
            "$ROOT_DIR/scripts/install-miniconda.sh" "$@"
            ;;
        extras)
            "$ROOT_DIR/scripts/install-extras.sh" "$@"
            ;;
        *)
            printf 'Unknown component: %s\n\n' "$component" >&2
            usage >&2
            exit 2
            ;;
    esac
}

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
    fonts
    zsh
    npm
    ai-tools
    rust
    ruby
    cpp
    miniconda
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
