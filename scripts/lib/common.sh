#!/usr/bin/env bash

# linux-workstation-setup 安装脚本公共函数

print_step() {
    local number="$1"
    shift
    printf '\n[%s/%s] %s...\n' "$number" "$SETUP_STEP_TOTAL" "$*"
}

apt_get_update_step() {
    local number="$1"

    print_step "$number" "Updating package indexes"
    if [ "${SKIP_APT_UPDATE:-0}" = "1" ]; then
        echo "Package indexes already updated by setup.sh; skipping."
        return
    fi

    sudo apt-get update
}

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

require_sudo() {
    local message="${1:-sudo was not found. Install it and configure sudo access first.}"

    if ! command -v sudo >/dev/null 2>&1; then
        echo "$message" >&2
        exit 1
    fi
}

select_shell_rc() {
    case "${SHELL:-}" in
        */zsh)  printf '%s\n' "$HOME/.zshrc" ;;
        */bash) printf '%s\n' "$HOME/.bashrc" ;;
        *)      printf '%s\n' "$HOME/.profile" ;;
    esac
}

select_shell_name_and_rc() {
    local name_var="$1"
    local rc_var="$2"
    local fallback_name="bash"
    local selected_shell_name
    local selected_shell_rc

    if [ "$#" -ge 3 ]; then
        fallback_name="$3"
    fi

    case "${SHELL:-}" in
        */zsh)
            selected_shell_name="zsh"
            selected_shell_rc="$HOME/.zshrc"
            ;;
        */bash)
            selected_shell_name="bash"
            selected_shell_rc="$HOME/.bashrc"
            ;;
        *)
            selected_shell_name="$fallback_name"
            selected_shell_rc="$HOME/.profile"
            ;;
    esac

    printf -v "$name_var" '%s' "$selected_shell_name"
    printf -v "$rc_var" '%s' "$selected_shell_rc"
}
