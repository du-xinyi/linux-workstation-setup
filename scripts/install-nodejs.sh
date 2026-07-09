#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=8

# 以下安装参数可通过同名环境变量覆盖
readonly NODE_MAJOR="${NODE_MAJOR:-24}"
readonly NPM_VERSION="${NPM_VERSION:-latest}"
readonly NPM_DIR="${NPM_DIR:-$HOME/.local/npm}"
readonly NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
readonly KEYRING_DIR="/etc/apt/keyrings"
readonly NODESOURCE_KEYRING="${KEYRING_DIR}/nodesource.gpg"
readonly NODESOURCE_LIST="/etc/apt/sources.list.d/nodesource.list"

echo "======================================"
echo " Ubuntu/Debian Node.js + npm Development Environment Installer"
echo "======================================"

require_non_root "./scripts/install-nodejs.sh"
require_debian_like
require_sudo "sudo was not found. Install it and grant sudo access to the current user."

apt_get_update_step 1

print_step 2 "Installing base dependencies"
sudo apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    build-essential

print_step 3 "Adding the NodeSource Node.js ${NODE_MAJOR}.x repository"

# 单独安装签名密钥并使用 signed-by 限制密钥作用范围
sudo install -d -m 0755 "$KEYRING_DIR"
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor \
    | sudo tee "$NODESOURCE_KEYRING" >/dev/null
sudo chmod 0644 "$NODESOURCE_KEYRING"
echo "deb [signed-by=${NODESOURCE_KEYRING}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    | sudo tee "$NODESOURCE_LIST" >/dev/null
sudo apt-get update

print_step 4 "Installing Node.js"
sudo apt-get install -y nodejs

print_step 5 "Configuring the user-level npm global directory"
mkdir -p "$NPM_DIR"
npm config set prefix "$NPM_DIR"

SHELL_RC="$(select_shell_rc)"

if [ "$NPM_DIR" = "$HOME/.local/npm" ]; then
    readonly PATH_LINE='export PATH="$HOME/.local/npm/bin:$PATH"'
else
    readonly PATH_LINE="export PATH=\"${NPM_DIR}/bin:\$PATH\""
fi
touch "$SHELL_RC"
if ! grep -Fqx "$PATH_LINE" "$SHELL_RC"; then
    {
        echo
        echo '# npm 全局命令'
        echo "$PATH_LINE"
    } >>"$SHELL_RC"
fi

export PATH="$NPM_DIR/bin:$PATH"
echo "Shell configuration file: $SHELL_RC"

print_step 6 "Configuring npm"
npm config set registry "$NPM_REGISTRY"
echo "npm registry: $NPM_REGISTRY"

print_step 7 "Installing development and AI CLI tools"
npm install -g "npm@${NPM_VERSION}"
# 仅允许确实需要生命周期脚本的包执行安装脚本
npm install -g --allow-scripts=opencode-ai,yarn \
    pnpm \
    yarn \
    typescript \
    eslint \
    prettier \
    @openai/codex \
    opencode-ai

print_step 8 "Checking the environment"
printf 'Node:       '; node -v
printf 'npm:        '; npm -v
printf 'npm prefix: '; npm config get prefix
printf 'npm root:   '; npm root -g
printf 'pnpm:       '; pnpm --version
printf 'yarn:       '; yarn --version
printf 'TypeScript: '; tsc --version
printf 'ESLint:     '; eslint --version
printf 'Prettier:   '; prettier --version
printf 'Codex:      '; codex --version || true
printf 'OpenCode:   '; opencode --version || true

echo
echo "======================================"
echo "Installation complete"
echo "======================================"
echo "To apply the PATH change now, run: source $SHELL_RC"
echo "Current npm global directory: $(npm root -g)"
