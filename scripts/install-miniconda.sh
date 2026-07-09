#!/usr/bin/env bash

set -Eeuo pipefail

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly INSTALLER="$ROOT_DIR/vendor/Miniconda3-latest-Linux-x86_64.sh"
install_prefix="${HOME:-/opt}/miniconda3"
installer_args=("$@")

run_without_pythonpath() {
    env -u PYTHONPATH "$@"
}

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

echo
echo "Conda base environment auto-activation: disabled"
if [ -n "$shell_name" ]; then
    echo "Conda initialization added to: $shell_rc"
    echo "Apply it now with: source $shell_rc"
else
    echo "Conda does not provide automatic initialization for ${SHELL:-the current shell}."
    echo "Conda command path added to: $shell_rc"
    echo "Apply it now with: source $shell_rc"
fi
