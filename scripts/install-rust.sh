#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly INSTALLER="$ROOT_DIR/vendor/rustup-init.sh"
readonly CARGO_ENV_LINE='. "$HOME/.cargo/env"'
rustup_args=("$@")

# 默认使用非交互的最小安装，减少入口脚本需要传入的参数
if [ "$#" -eq 0 ]; then
    rustup_args=(-y --profile minimal)
fi

# 跳过系统已存在 rustc/cargo 时的路径检查；后续会验证 rustup shim 是否优先生效
export RUSTUP_INIT_SKIP_PATH_CHECK=yes

SHELL_RC="$(select_shell_rc)"

# 当前脚本内优先加载已有 Cargo 环境，便于判断 rustup 是否已经安装
if [ -r "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
fi

if command -v rustup >/dev/null 2>&1 && [ -e "$HOME/.rustup/settings.toml" ]; then
    echo "Existing rustup installation detected; updating the stable toolchain."
    rustup update stable
    rustup default stable
else
    if [ ! -r "$INSTALLER" ]; then
        echo "Official Rust installer not found: $INSTALLER" >&2
        exit 1
    fi

    sh "$INSTALLER" "${rustup_args[@]}"
fi

touch "$SHELL_RC"
if ! grep -Fqx "$CARGO_ENV_LINE" "$SHELL_RC"; then
    {
        echo
        echo '# Rust 和 Cargo 环境'
        echo "$CARGO_ENV_LINE"
    } >>"$SHELL_RC"
fi

# 当前脚本内立即加载 Cargo 环境，避免验证阶段仍命中 /usr/bin 下的系统 Rust
if [ -r "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
fi

echo
echo "Rust environment added to: $SHELL_RC"
echo "Apply it now with: source $SHELL_RC"

echo
echo "Checking the Rust environment"
printf 'rustup: '; rustup --version
printf 'rustc:  '; rustc --version
printf 'cargo:  '; cargo --version
printf 'rustup path: %s\n' "$(command -v rustup)"
printf 'rustc path:  %s\n' "$(command -v rustc)"
printf 'cargo path:  %s\n' "$(command -v cargo)"

case "$(command -v rustc)" in
    "$HOME"/.cargo/bin/*) ;;
    *)
        echo "Warning: rustc is not resolved from $HOME/.cargo/bin. Check your PATH order." >&2
        ;;
esac
