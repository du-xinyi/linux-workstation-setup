#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=4

# 可通过 FONT_PACKAGES 覆盖默认字体包列表，包名之间使用空格分隔
readonly FONT_PACKAGES="${FONT_PACKAGES:-fontconfig fonts-dejavu-core fonts-liberation2 fonts-firacode fonts-jetbrains-mono fonts-cascadia-code fonts-noto-core fonts-noto-extra fonts-noto-mono fonts-noto-cjk fonts-noto-color-emoji fonts-crosextra-carlito fonts-crosextra-caladea fonts-lmodern fonts-stix}"

check_font() {
    local label="$1"
    local pattern="$2"
    local status="not found"

    if fc-list : family | grep -i "$pattern" >/dev/null; then
        status="available"
    fi
    printf '  %-18s %s\n' "$label" "$status"
}

echo "======================================"
echo " Ubuntu/Debian Common Fonts Installer"
echo "======================================"

require_non_root "./scripts/install-fonts.sh"
require_debian_like
require_sudo "sudo was not found. Install it and grant sudo access to the current user."

apt_get_update_step 1

print_step 2 "Installing common fonts"
# 将用户提供的空格分隔包列表转换为数组，避免路径名展开
read -r -a font_packages <<<"$FONT_PACKAGES"
sudo apt-get install -y "${font_packages[@]}"

print_step 3 "Rebuilding the font cache"
fc-cache -f

print_step 4 "Checking installed font families"
check_font "Noto CJK"     'Noto.*CJK'
check_font "Noto Emoji"   'Noto Color Emoji'
check_font "Fira Code"    'Fira Code'
check_font "JetBrains Mono" 'JetBrains Mono'
check_font "Cascadia Code"  'Cascadia'
check_font "Carlito"      'Carlito'
check_font "Caladea"      'Caladea'
check_font "Latin Modern" 'Latin Modern'
check_font "STIX"         'STIX'

echo
echo "======================================"
echo "Installation complete"
echo "======================================"
