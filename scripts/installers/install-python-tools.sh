#!/usr/bin/env bash

# 安装 Miniconda 与独立的 uv/uvx，配置当前用户的 Shell 并验证命令版本。
# 脚本参数传给 Miniconda 安装器；uv 安装目录使用 UV_INSTALL_DIR 配置。

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly INSTALLER="$ROOT_DIR/vendor/Miniconda3-latest-Linux-x86_64.sh"
readonly SETUP_STEP_TOTAL=4
readonly UV_BIN_DIR="${UV_INSTALL_DIR:-$HOME/.local/bin}"
install_prefix="${HOME:-/opt}/miniconda3"
installer_args=("$@")

# 仅对子进程清除 PYTHONPATH，避免外部 Python 模块路径干扰 Conda。
run_without_pythonpath() {
    env -u PYTHONPATH "$@"
}

# 下载完成后再执行;子 shell 退出时清理临时安装器
install_uv() (
    if [ -x "$UV_BIN_DIR/uv" ] && [ -x "$UV_BIN_DIR/uvx" ]; then
        echo "Existing uv installation detected at $UV_BIN_DIR; reusing it."
        return
    fi

    local_tmp="$(mktemp -d)"
    trap 'rm -rf -- "$local_tmp"' EXIT
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --retry 3 --connect-timeout 15 --max-time 300 \
            https://astral.sh/uv/install.sh -o "$local_tmp/install-uv.sh"
    elif command -v wget >/dev/null 2>&1; then
        wget --timeout=30 --tries=3 -O "$local_tmp/install-uv.sh" https://astral.sh/uv/install.sh
    else
        echo "curl or wget is required to download the uv installer." >&2
        exit 1
    fi
    # 由本脚本统一管理 Shell 路径,独立于 Conda 环境
    env -u UV_UNMANAGED_INSTALL UV_INSTALL_DIR="$UV_BIN_DIR" UV_NO_MODIFY_PATH=1 \
        sh "$local_tmp/install-uv.sh"
)

require_non_root "./scripts/installers/install-python-tools.sh"
case "$UV_BIN_DIR" in
    /*) ;;
    *) echo "UV_INSTALL_DIR must be an absolute path." >&2; exit 1 ;;
esac

print_step 1 "Installing Miniconda"
if [ ! -r "$INSTALLER" ]; then
    echo "Official Miniconda installer not found; downloading it now."
    "$ROOT_DIR/vendor/download-installers.sh" miniconda
fi

# 默认使用非交互安装，减少入口脚本需要传入的参数
# 如果默认安装目录已存在，则切换为更新模式，使脚本可以重复运行
if [ "$#" -eq 0 ]; then
    installer_args=(-b -p "$install_prefix" -c)
    if [ -d "$install_prefix" ]; then
        installer_args+=(-u)
    fi
fi

# 获取传递给官方安装器的安装目录，以便安装后使用对应的 conda
for ((i = 0; i < ${#installer_args[@]}; i++)); do
    case "${installer_args[i]}" in
        -p)
            if ((i + 1 < ${#installer_args[@]})); then
                install_prefix="${installer_args[i + 1]}"
                ((i += 1))
            fi
            ;;
        -p?*)
            install_prefix="${installer_args[i]#-p}"
            ;;
    esac
done

if [ -n "${PYTHONPATH:-}" ]; then
    echo "PYTHONPATH is set; temporarily unsetting it for Miniconda commands."
fi

run_without_pythonpath sh "$INSTALLER" "${installer_args[@]}"

conda_bin="$install_prefix/bin/conda"
if [ ! -x "$conda_bin" ]; then
    echo "Miniconda was installed, but conda was not found at the expected path: $conda_bin" >&2
    echo "If you changed the directory during interactive installation, specify it explicitly with -p." >&2
    exit 1
fi

print_step 2 "Configuring Conda"
run_without_pythonpath "$conda_bin" config --set auto_activate false

select_shell_name_and_rc shell_name shell_rc ""

if [ -n "$shell_name" ]; then
    run_without_pythonpath "$conda_bin" init "$shell_name"
else
    printf -v conda_path_line 'export PATH="%s/bin:$PATH"' "$install_prefix"
    touch "$shell_rc"
    if ! grep -Fqx "$conda_path_line" "$shell_rc"; then
        {
            echo
            echo '# Conda 命令路径'
            echo "$conda_path_line"
        } >>"$shell_rc"
    fi
fi

print_step 3 "Installing uv"
install_uv

# 转义含空格的安装路径，并避免重复追加相同的 PATH 配置。
printf -v uv_path_line 'export PATH=%q:"$PATH"' "$UV_BIN_DIR"
touch "$shell_rc"
if ! grep -Fqx "$uv_path_line" "$shell_rc"; then
    {
        echo
        echo '# uv 和 uvx 命令路径'
        echo "$uv_path_line"
    } >> "$shell_rc"
fi

print_step 4 "Checking Conda and uv"
run_without_pythonpath "$conda_bin" --version
"$UV_BIN_DIR/uv" --version
"$UV_BIN_DIR/uvx" --version

echo
echo "uv and uvx installed at: $UV_BIN_DIR"
echo "Conda base environment auto-activation: disabled"
if [ -n "$shell_name" ]; then
    echo "Conda initialization added to: $shell_rc"
    echo "Apply it now with: source $shell_rc"
else
    echo "Conda does not provide automatic initialization for ${SHELL:-the current shell}."
    echo "Conda command path added to: $shell_rc"
    echo "Apply it now with: source $shell_rc"
fi
