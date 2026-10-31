#!/usr/bin/env bash

# 统一配置 APT、pip、uv 与 Conda 清华镜像；APT 修改系统文件，其余写入用户目录。

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=6

# 统一使用清华 TUNA，不从环境变量读取镜像地址。
readonly APT_MIRROR_HOST="mirrors.tuna.tsinghua.edu.cn"
readonly PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
readonly PIP_TRUSTED_HOST="pypi.tuna.tsinghua.edu.cn"
readonly CONDA_CHANNEL_MAIN="https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main"
readonly CONDA_CHANNEL_R="https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r"
readonly CONDA_CLOUD_BASE="https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud"

# 待替换的官方 apt 域名;仅替换域名,路径(/ubuntu、/debian-security 等)保持不变
readonly -a APT_OFFICIAL_DOMAINS=(
    "archive.ubuntu.com"
    "security.ubuntu.com"
    "deb.debian.org"
    "security.debian.org"
)

# 输出系统 codename,便于核对镜像是否覆盖当前发行版
detect_apt_codename() {
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        printf '%s\n' "${VERSION_CODENAME:-${VERSION:-unknown}}"
    else
        printf '%s\n' "unknown"
    fi
}

# 列出系统上实际存在的 apt 源文件(传统 .list 与 deb822 .sources)
collect_apt_source_files() {
    local f

    if [ -f /etc/apt/sources.list ]; then
        printf '%s\n' "/etc/apt/sources.list"
    fi
    for f in /etc/apt/sources.list.d/*.list; do
        if [ -f "$f" ]; then
            printf '%s\n' "$f"
        fi
    done
    for f in /etc/apt/sources.list.d/*.sources; do
        if [ -f "$f" ]; then
            printf '%s\n' "$f"
        fi
    done
}

# 原地替换已存在源文件中的官方地址，不新增发行版或仓库组件。
configure_apt() {
    local f
    local domain
    local sed_args=()

    # 对每个官方域名生成替换规则,http 与 https 均升级为镜像 https
    for domain in "${APT_OFFICIAL_DOMAINS[@]}"; do
        sed_args+=(-e "s|http://${domain}|https://${APT_MIRROR_HOST}|g")
        sed_args+=(-e "s|https://${domain}|https://${APT_MIRROR_HOST}|g")
    done

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        sudo sed -i "${sed_args[@]}" "$f"
        printf '  updated    %s\n' "$f"
    done < <(collect_apt_source_files)

}

# 重写用户 pip.conf 为本脚本管理的镜像配置，无需预先安装 pip。
configure_pip() {
    local pip_conf_dir="$HOME/.config/pip"
    local pip_conf="$pip_conf_dir/pip.conf"

    mkdir -p "$pip_conf_dir"
    {
        printf '[global]\n'
        printf 'index-url = %s\n' "$PIP_INDEX_URL"
        printf 'trusted-host = %s\n' "$PIP_TRUSTED_HOST"
    } > "$pip_conf"
    printf '  wrote      %s\n' "$pip_conf"

    if command -v pip >/dev/null 2>&1; then
        printf '  pip index  %s\n' "$(pip config get global.index-url 2>/dev/null || echo "$PIP_INDEX_URL")"
    fi
}

# 重写用户 uv.toml；无需预先安装 uv，遵循 XDG_CONFIG_HOME。
configure_uv() {
    local uv_conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/uv"
    local uv_conf="$uv_conf_dir/uv.toml"

    mkdir -p "$uv_conf_dir"
    cat > "$uv_conf" <<EOF
[[index]]
url = "$PIP_INDEX_URL"
default = true
EOF
    printf '  wrote      %s\n' "$uv_conf"
}

# 重写用户 .condarc；即使 Conda 尚未安装，后续安装也可读取此配置。
configure_conda() {
    local condarc="$HOME/.condarc"

    cat > "$condarc" <<EOF
auto_activate_base: false
channels:
  - defaults
show_channel_urls: true
default_channels:
  - $CONDA_CHANNEL_MAIN
  - $CONDA_CHANNEL_R
custom_channels:
  conda-forge: $CONDA_CLOUD_BASE
  pytorch: $CONDA_CLOUD_BASE
EOF
    printf '  wrote      %s\n' "$condarc"

    # conda 已安装时清空索引缓存,避免残留旧渠道元数据
    if command -v conda >/dev/null 2>&1; then
        if conda clean -i -y >/dev/null 2>&1; then
            echo "  cleared    conda index cache"
        fi
    else
        echo "  conda not found; config will take effect after Miniconda/Anaconda is installed"
    fi
}

echo "======================================"
echo " Tsinghua TUNA Mirror Installer (apt / pip / uv / conda)"
echo "======================================"

require_non_root "./scripts/installers/install-mirrors.sh"
require_debian_like
require_sudo "sudo was not found. Install it and grant sudo access to the current user."

print_step 1 "Using Tsinghua TUNA mirrors"
printf '  apt host   %s\n' "$APT_MIRROR_HOST"
printf '  pip index  %s\n' "$PIP_INDEX_URL"
printf '  uv index   %s\n' "$PIP_INDEX_URL"
printf '  conda      %s\n' "$CONDA_CHANNEL_MAIN"

print_step 2 "Switching apt sources to $APT_MIRROR_HOST"
printf '  codename   %s\n' "$(detect_apt_codename)"
configure_apt

print_step 3 "Refreshing apt package indexes"
if [ "${SKIP_APT_UPDATE:-0}" = "1" ]; then
    echo "Package indexes already updated by setup.sh; skipping."
else
    sudo apt-get update
fi

print_step 4 "Configuring pip index"
configure_pip

print_step 5 "Configuring uv index"
configure_uv

print_step 6 "Configuring conda channels"
configure_conda

echo
echo "======================================"
echo " Mirror configuration complete"
echo "======================================"
