#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=4

echo "======================================"
echo " Git Installer"
echo "======================================"

require_non_root "./scripts/install-git.sh"
require_debian_like
require_sudo

apt_get_update_step 1

print_step 2 "Installing Git"
sudo apt-get install -y git ca-certificates openssh-client

print_step 3 "Configuring persistent HTTPS credentials"
# 使用当前用户的全局配置；重复运行不会累加 credential.helper 条目。
git config --global --replace-all credential.helper store
echo "Credentials will be saved in plaintext by Git after successful authentication."
echo "For HTTPS remotes, enter your username and access token when first prompted."

print_step 4 "Verifying Git"
git --version

echo
echo "======================================"
echo " Installation complete"
echo "======================================"
