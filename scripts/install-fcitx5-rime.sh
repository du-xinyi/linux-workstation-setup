#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=8

# 以下安装参数可通过同名环境变量覆盖
readonly PLUM_DIR="${PLUM_DIR:-$HOME/.local/share/plum}"
readonly RIME_DIR="${RIME_DIR:-$HOME/.local/share/fcitx5/rime}"
readonly RIME_RECIPE="${RIME_RECIPE:-iDvel/rime-ice}"

echo "======================================"
echo " Fcitx 5 + Rime Ice Installer"
echo "======================================"

require_non_root "./scripts/install-fcitx5-rime.sh"
require_debian_like
require_sudo

apt_get_update_step 1

print_step 2 "Installing Fcitx 5, Rime, and GUI integration"
sudo apt-get install -y \
    fcitx5 \
    fcitx5-config-qt \
    fcitx5-frontend-gtk3 \
    fcitx5-frontend-gtk4 \
    fcitx5-frontend-qt5 \
    fcitx5-rime \
    git \
    im-config

print_step 3 "Setting Fcitx 5 as the default input method framework"
im-config -n fcitx5

print_step 4 "Installing or updating Plum"
if [ -d "$PLUM_DIR/.git" ]; then
    git -C "$PLUM_DIR" pull --ff-only
else
    if [ -e "$PLUM_DIR" ]; then
        echo "The Plum directory exists but is not a Git repository: $PLUM_DIR" >&2
        exit 1
    fi
    git clone --depth 1 https://github.com/rime/plum.git "$PLUM_DIR"
fi

print_step 5 "Preparing the Rime configuration directory"
mkdir -p "$RIME_DIR"

print_step 6 "Installing Rime Ice with Plum"
rime_dir="$RIME_DIR" bash "$PLUM_DIR/rime-install" "$RIME_RECIPE"

print_step 7 "Writing Sichuan-accent fuzzy-pinyin settings"
cat > "$RIME_DIR/rime_ice.custom.yaml" <<'EOF'
# Rime patch
# encoding: utf-8

patch:
  # 四川口音常见模糊音；追加规则，不替换雾凇拼音原有规则
  "speller/algebra/+":
    # 平翘舌：z/c/s 与 zh/ch/sh
    - derive/^([zcs])h/$1/
    - derive/^([zcs])([^h])/$1h$2/
    # 鼻边音：n 与 l
    - derive/^l/n/
    - derive/^n/l/
    # 前后鼻音
    - derive/ang$/an/
    - derive/an$/ang/
    - derive/eng$/en/
    - derive/en$/eng/
    - derive/in$/ing/
    - derive/ing$/in/
EOF

# 每页显示 9 个候选词，可用数字键 1–9 直接选择
cat > "$RIME_DIR/default.custom.yaml" <<'EOF'
# Rime patch
# encoding: utf-8

patch:
  schema_list:
    - schema: rime_ice
  menu/page_size: 9
EOF

print_step 8 "Adjusting Fcitx 5 preedit display"
readonly FCITX_CONFIG="$HOME/.config/fcitx5/config"
mkdir -p "$(dirname "$FCITX_CONFIG")"
if [ -f "$FCITX_CONFIG" ]; then
    if grep -q '^PreeditEnabledByDefault=' "$FCITX_CONFIG"; then
        sed -i 's/^PreeditEnabledByDefault=.*/PreeditEnabledByDefault=False/' "$FCITX_CONFIG"
    elif grep -q '^\[Behavior\]$' "$FCITX_CONFIG"; then
        sed -i '/^\[Behavior\]$/a PreeditEnabledByDefault=False' "$FCITX_CONFIG"
    else
        printf '\n[Behavior]\nPreeditEnabledByDefault=False\n' >> "$FCITX_CONFIG"
    fi
else
    printf '[Behavior]\nPreeditEnabledByDefault=False\n' > "$FCITX_CONFIG"
fi

echo
echo "======================================"
echo "Installation complete"
echo "======================================"
echo "Rime configuration directory: $RIME_DIR"
echo "Log out and back in, then run fcitx5-configtool."
echo "Search for Rime in the input method list and add it."
