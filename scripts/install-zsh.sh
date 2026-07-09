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

readonly SETUP_STEP_TOTAL=5
readonly ZSH_DIR="${ZSH_DIR:-$HOME/.oh-my-zsh}"
readonly ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$ZSH_DIR/custom}"
readonly ZSHRC="$HOME/.zshrc"

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
cat > "$zshrc_tmp" <<'EOF'
# 由 linux-workstation-setup/scripts/install-zsh.sh 自动生成

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="ys"

zstyle ':omz:update' mode reminder
zstyle ':omz:update' frequency 14

plugins=(
  git
  extract
  pip
  zsh-syntax-highlighting
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

EOF

# 先检查语法，再用独立的 Zsh 进程实际加载配置
zsh -n "$zshrc_tmp"
zsh -df -c 'source "$1"' zsh "$zshrc_tmp"

# 仅在两项检查都通过后替换现有文件，避免写入无效的 .zshrc
chmod 644 "$zshrc_tmp"
mv -f "$zshrc_tmp" "$ZSHRC"
zshrc_tmp=""

print_step 5 "Checking the configuration"
printf '  %-12s %s\n' "Zsh" "$(zsh --version)"
printf '  %-12s %s\n' "Oh My Zsh" "$ZSH_DIR"
printf '  %-12s %s\n' "Config" "$ZSHRC"

if [ "${SHELL:-}" != "$(command -v zsh)" ]; then
    echo
    echo "Default shell:"
    printf '  %s\n' "chsh -s $(command -v zsh)"
fi

echo
echo "Apply now:"
printf '  %s\n' "exec zsh"
