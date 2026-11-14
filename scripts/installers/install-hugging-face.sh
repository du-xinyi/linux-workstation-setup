#!/usr/bin/env bash

# 使用 uv 的隔离工具环境安装 Hugging Face CLI。
set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=3

if [ "$#" -gt 0 ]; then
    echo "Usage: ./setup.sh hugging-face" >&2
    exit 2
fi
require_non_root "./setup.sh hugging-face"

uv_bin="${UV_INSTALL_DIR:-$HOME/.local/bin}/uv"
if [ ! -x "$uv_bin" ]; then
    if ! uv_bin="$(command -v uv)"; then
        echo "uv was not found. Run ./setup.sh python-tools first." >&2
        exit 1
    fi
fi

print_step 1 "Installing Hugging Face CLI"
"$uv_bin" tool install --upgrade huggingface_hub

print_step 2 "Configuring Hugging Face CLI command path"
tool_bin_dir="$("$uv_bin" tool dir --bin)"
export PATH="$tool_bin_dir:$PATH"
shell_rc="$(select_shell_rc)"
printf -v hf_path_line 'export PATH=%q:"$PATH"' "$tool_bin_dir"
touch "$shell_rc"
if ! grep -Fqx "$hf_path_line" "$shell_rc"; then
    {
        echo
        echo '# uv 工具命令路径（包括 Hugging Face CLI）'
        echo "$hf_path_line"
    } >>"$shell_rc"
fi

print_step 3 "Checking Hugging Face CLI"
"$tool_bin_dir/hf" version
"$tool_bin_dir/hf" --help

echo
echo "Hugging Face CLI installed at: $tool_bin_dir/hf"
echo "Apply the command path with: source $shell_rc"
echo "Log in when needed with: hf auth login"
