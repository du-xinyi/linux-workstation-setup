#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=3

# 由 APT 管理的系统 Python 开发工具与常用库
readonly -a PYTHON_PKGS=(
    python3
    python3-pip
    python3-venv
    python3-dev
    python3-setuptools
    python3-wheel
    python3-requests
    python3-aiohttp
    python3-yaml
    python3-bs4
    python3-lxml
    python3-numpy
    python3-scipy
    python3-pandas
    python3-matplotlib
    python3-pil
    python3-openpyxl
    python3-tqdm
    python3-rich
    python3-click
    python3-psutil
    python3-pytest
    python3-pytest-cov
    python3-ipython
)

echo "======================================"
echo " System Python Development Installer"
echo "======================================"

require_non_root "./scripts/install-python.sh"
require_debian_like
require_sudo

apt_get_update_step 1

print_step 2 "Installing system Python tools and libraries"
sudo apt-get install -y "${PYTHON_PKGS[@]}"

print_step 3 "Checking installed Python packages"
missing=0
for pkg in "${PYTHON_PKGS[@]}"; do
    if status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" &&
       [ "$status" = "install ok installed" ]; then
        printf '  %-24s installed\n' "$pkg"
    else
        printf '  %-24s MISSING\n' "$pkg" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] || exit 1

# 明确使用系统解释器,避免 PATH 中的 Conda 或 venv 覆盖验证目标
/usr/bin/python3 --version
echo "Installation complete. Packages are available to /usr/bin/python3."
