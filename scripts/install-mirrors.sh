#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=5

# 镜像提供商:tuna(清华 TUNA)、aliyun(阿里云)、ustc(中科大)
# 可通过 MIRROR_PROVIDER 环境变量整体切换;也可用更具体的同名环境变量
# 覆盖单项地址:APT_MIRROR_HOST / PIP_INDEX_URL / PIP_TRUSTED_HOST /
# CONDA_CHANNEL_MAIN / CONDA_CHANNEL_R / CONDA_CLOUD_BASE
readonly MIRROR_PROVIDER="${MIRROR_PROVIDER:-tuna}"

# 待替换的官方 apt 域名;仅替换域名,路径(/ubuntu、/debian-security 等)保持不变
readonly -a APT_OFFICIAL_DOMAINS=(
    "archive.ubuntu.com"
    "security.ubuntu.com"
    "deb.debian.org"
    "security.debian.org"
)

# 按提供商解析各源默认地址,写入 _default_* 变量
resolve_mirror_defaults() {
    case "$MIRROR_PROVIDER" in
        tuna)
            _default_apt_host="mirrors.tuna.tsinghua.edu.cn"
            _default_pip_index="https://pypi.tuna.tsinghua.edu.cn/simple"
            _default_pip_host="pypi.tuna.tsinghua.edu.cn"
            _default_conda_main="https://mirrors.nju.edu.cn/anaconda/pkgs/main"
            _default_conda_r="https://mirrors.nju.edu.cn/anaconda/pkgs/r"
            _default_conda_cloud="https://chinanet.mirrors.ustc.edu.cn/anaconda/cloud/"
            ;;
        aliyun)
            _default_apt_host="mirrors.aliyun.com"
            _default_pip_index="https://mirrors.aliyun.com/pypi/simple/"
            _default_pip_host="mirrors.aliyun.com"
            _default_conda_main="https://mirrors.aliyun.com/anaconda/pkgs/main"
            _default_conda_r="https://mirrors.aliyun.com/anaconda/pkgs/r"
            _default_conda_cloud="https://mirrors.aliyun.com/anaconda/cloud"
            ;;
        ustc)
            _default_apt_host="mirrors.ustc.edu.cn"
            _default_pip_index="https://pypi.mirrors.ustc.edu.cn/simple/"
            _default_pip_host="pypi.mirrors.ustc.edu.cn"
            _default_conda_main="https://mirrors.ustc.edu.cn/anaconda/pkgs/main"
            _default_conda_r="https://mirrors.ustc.edu.cn/anaconda/pkgs/r"
            _default_conda_cloud="https://mirrors.ustc.edu.cn/anaconda/cloud"
            ;;
        *)
            echo "Unsupported MIRROR_PROVIDER: $MIRROR_PROVIDER (expected tuna, aliyun, or ustc)" >&2
            return 1
            ;;
    esac
}

resolve_mirror_defaults
readonly APT_MIRROR_HOST="${APT_MIRROR_HOST:-$_default_apt_host}"
readonly PIP_INDEX_URL="${PIP_INDEX_URL:-$_default_pip_index}"
readonly PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-$_default_pip_host}"
readonly CONDA_CHANNEL_MAIN="${CONDA_CHANNEL_MAIN:-$_default_conda_main}"
readonly CONDA_CHANNEL_R="${CONDA_CHANNEL_R:-$_default_conda_r}"
readonly CONDA_CLOUD_BASE="${CONDA_CLOUD_BASE:-$_default_conda_cloud}"

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

# 判断文件是否仍引用官方域名(即尚未换源)
apt_file_uses_official() {
    local f="$1"
    local domain

    for domain in "${APT_OFFICIAL_DOMAINS[@]}"; do
        if grep -q "$domain" "$f" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

configure_apt() {
    local f
    local domain
    local backup_created=0
    local sed_args=()

    # 对每个官方域名生成替换规则,http 与 https 均升级为镜像 https
    for domain in "${APT_OFFICIAL_DOMAINS[@]}"; do
        sed_args+=(-e "s|http://${domain}|https://${APT_MIRROR_HOST}|g")
        sed_args+=(-e "s|https://${domain}|https://${APT_MIRROR_HOST}|g")
    done

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # 仅当文件仍含官方域名,且 .orig 不存在时备份,保证 .orig 始终为官方源
        if apt_file_uses_official "$f" && [ ! -f "${f}.orig" ]; then
            sudo cp -a "$f" "${f}.orig"
            backup_created=1
            printf '  backed up  %s -> %s.orig\n' "$f" "$f"
        fi
        sudo sed -i "${sed_args[@]}" "$f"
        printf '  updated    %s\n' "$f"
    done < <(collect_apt_source_files)

    if [ "$backup_created" -eq 0 ]; then
        echo "  no official-source backup needed (already mirrored or no official sources)"
    fi
}

configure_pip() {
    local pip_conf_dir="$HOME/.config/pip"
    local pip_conf="$pip_conf_dir/pip.conf"
    local legacy_pip_conf_dir="$HOME/.pip"
    local legacy_pip_conf="$legacy_pip_conf_dir/pip.conf"

    mkdir -p "$pip_conf_dir"
    # 首次覆盖前备份一次用户已有配置
    if [ -f "$pip_conf" ] && [ ! -f "${pip_conf}.bak" ]; then
        cp -a "$pip_conf" "${pip_conf}.bak"
        printf '  backed up  %s -> %s.bak\n' "$pip_conf" "$pip_conf"
    fi
    {
        printf '[global]\n'
        printf 'index-url = %s\n' "$PIP_INDEX_URL"
        printf 'trusted-host = %s\n' "$PIP_TRUSTED_HOST"
    } > "$pip_conf"
    printf '  wrote      %s\n' "$pip_conf"

    # 同步写入旧版路径,兼容旧 pip 与部分工具
    mkdir -p "$legacy_pip_conf_dir"
    if [ -f "$legacy_pip_conf" ] && [ ! -f "${legacy_pip_conf}.bak" ]; then
        cp -a "$legacy_pip_conf" "${legacy_pip_conf}.bak"
        printf '  backed up  %s -> %s.bak\n' "$legacy_pip_conf" "$legacy_pip_conf"
    fi
    {
        printf '[global]\n'
        printf 'index-url = %s\n' "$PIP_INDEX_URL"
        printf 'trusted-host = %s\n' "$PIP_TRUSTED_HOST"
    } > "$legacy_pip_conf"
    printf '  wrote      %s\n' "$legacy_pip_conf"

    if command -v pip >/dev/null 2>&1; then
        printf '  pip index  %s\n' "$(pip config get global.index-url 2>/dev/null || echo "$PIP_INDEX_URL")"
    fi
}

configure_conda() {
    local condarc="$HOME/.condarc"

    # 同时配置默认渠道镜像与常用社区渠道(conda-forge / pytorch)
    cat > "$condarc" <<EOF
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
echo " Mirror Source Installer (apt / pip / conda)"
echo "======================================"

require_non_root "./scripts/install-mirrors.sh"
require_debian_like
require_sudo "sudo was not found. Install it and grant sudo access to the current user."

print_step 1 "Selecting mirror provider"
printf '  provider   %s\n' "$MIRROR_PROVIDER"
printf '  apt host   %s\n' "$APT_MIRROR_HOST"
printf '  pip index  %s\n' "$PIP_INDEX_URL"
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

print_step 5 "Configuring conda channels"
configure_conda

echo
echo "======================================"
echo " Mirror configuration complete"
echo "======================================"
echo "To restore official apt sources later, copy the .orig backups:"
echo "  sudo cp /etc/apt/sources.list.orig /etc/apt/sources.list"
