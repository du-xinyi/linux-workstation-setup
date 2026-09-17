#!/usr/bin/env bash

set -Eeuo pipefail

zshrc_tmp=""
cleanup() {
    if [ -n "$zshrc_tmp" ] && [ -e "$zshrc_tmp" ]; then
        rm -f "$zshrc_tmp"
    fi
}
trap cleanup EXIT
trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=6
readonly ZSH_DIR="${ZSH_DIR:-$HOME/.oh-my-zsh}"
readonly ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$ZSH_DIR/custom}"
readonly ZSHRC="$HOME/.zshrc"
readonly LOGIN_USER="$(id -un)"

require_non_root
require_debian_like
require_sudo

print_step 1 "Installing Zsh and dependencies"
if [ "${SKIP_APT_UPDATE:-0}" = "1" ]; then
    echo "Package indexes already updated by setup.sh; skipping."
else
    sudo apt-get update
fi
sudo apt-get install -y zsh git

readonly ZSH_BIN="$(command -v zsh)"
if [ -z "$ZSH_BIN" ] || [ ! -x "$ZSH_BIN" ]; then
    echo "Zsh was installed but no executable was found in PATH." >&2
    exit 1
fi

print_step 2 "Installing or updating Oh My Zsh"
if [ -d "$ZSH_DIR/.git" ]; then
    git -C "$ZSH_DIR" pull --ff-only
elif [ -e "$ZSH_DIR" ]; then
    echo "Oh My Zsh directory exists but is not a Git repository: $ZSH_DIR" >&2
    exit 1
else
    git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$ZSH_DIR"
fi

print_step 3 "Installing Zsh plugins"
declare -A plugins=(
    [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting.git"
    [conda-zsh-completion]="https://github.com/conda-incubator/conda-zsh-completion.git"
)
for plugin in "${!plugins[@]}"; do
    plugin_dir="$ZSH_CUSTOM_DIR/plugins/$plugin"
    if [ -d "$plugin_dir/.git" ]; then
        git -C "$plugin_dir" pull --ff-only
    elif [ -e "$plugin_dir" ]; then
        echo "Plugin directory exists but is not a Git repository: $plugin_dir" >&2
        exit 1
    else
        git clone --depth 1 "${plugins[$plugin]}" "$plugin_dir"
    fi
done

print_step 4 "Writing the Zsh configuration"
zshrc_tmp="$(mktemp "${ZSHRC}.tmp.XXXXXX")"

# 使用安装时的实际 Oh My Zsh 路径，避免自定义 ZSH_DIR 时配置仍指向默认目录。
printf 'export ZSH=%q\n' "$ZSH_DIR" > "$zshrc_tmp"
cat >> "$zshrc_tmp" <<'EOF_ZSHRC'
# 由 linux-workstation-setup/scripts/install-zsh.sh 自动生成

ZSH_THEME="ys"

zstyle ':omz:update' mode reminder
zstyle ':omz:update' frequency 14

plugins=(
  git
  extract
  pip
  zsh-syntax-highlighting
  conda-zsh-completion
)

source "$ZSH/oh-my-zsh.sh"

# 不匹配通配符保持原样（类似 bash）
setopt nonomatch

# 历史优化
setopt hist_ignore_all_dups
setopt hist_reduce_blanks
setopt share_history
setopt inc_append_history_time

# 历史文件
HISTFILE=$HOME/.zsh_history

# 内存历史
HISTSIZE=50000

# 文件历史
SAVEHIST=50000
EOF_ZSHRC

# 先检查语法，再用独立的 Zsh 进程实际加载配置。
zsh -n "$zshrc_tmp"
zsh -df -c 'source "$1"' zsh "$zshrc_tmp"

if [ -f "$ZSHRC" ] && cmp -s "$zshrc_tmp" "$ZSHRC"; then
    echo "Zsh configuration is already up to date."
    rm -f "$zshrc_tmp"
    zshrc_tmp=""
else
    # 仅在检查通过后原子替换现有文件，避免留下无效配置。
    chmod 644 "$zshrc_tmp"
    mv -f "$zshrc_tmp" "$ZSHRC"
    zshrc_tmp=""
fi

print_step 5 "Setting Zsh as the default shell"
if ! grep -Fxq "$ZSH_BIN" /etc/shells; then
    echo "Zsh executable is not listed in /etc/shells: $ZSH_BIN" >&2
    echo "Refusing to change the login shell automatically." >&2
    exit 1
fi

current_login_shell="$(getent passwd "$LOGIN_USER" | cut -d: -f7)"
if [ -z "$current_login_shell" ]; then
    echo "Could not determine the current login shell for user: $LOGIN_USER" >&2
    exit 1
fi

if [ "$current_login_shell" = "$ZSH_BIN" ]; then
    echo "Default shell is already Zsh: $ZSH_BIN"
else
    printf 'Changing default shell: %s -> %s\n' "$current_login_shell" "$ZSH_BIN"
    sudo chsh -s "$ZSH_BIN" "$LOGIN_USER"
fi

print_step 6 "Verifying the installation"
configured_login_shell="$(getent passwd "$LOGIN_USER" | cut -d: -f7)"
if [ "$configured_login_shell" != "$ZSH_BIN" ]; then
    echo "Failed to set the default shell to Zsh." >&2
    printf 'Expected: %s\n' "$ZSH_BIN" >&2
    printf 'Actual:   %s\n' "$configured_login_shell" >&2
    exit 1
fi

printf '  %-16s %s\n' "Zsh" "$(zsh --version)"
printf '  %-16s %s\n' "Oh My Zsh" "$ZSH_DIR"
printf '  %-16s %s\n' "Config" "$ZSHRC"
printf '  %-16s %s\n' "Default shell" "$configured_login_shell"

echo
echo "Zsh installation is complete."
if [ "${SHELL:-}" = "$ZSH_BIN" ]; then
    echo "This session is already using Zsh as its login shell."
else
    echo "The current terminal may still be Bash because its environment was created before chsh ran."
    echo "Log out and log back in, or open a new login session, to use Zsh by default."
    printf 'To switch this terminal immediately, run: exec %q -l\n' "$ZSH_BIN"
fi
