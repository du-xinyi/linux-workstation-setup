#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=9

# 通过 dpkg 查询 apt 包安装状态，用于安装后的验证
check_pkg() { dpkg -s "$1" >/dev/null 2>&1 && echo "installed" || echo "MISSING"; }

# 通过 flatpak info 查询 Flatpak 应用安装状态，用于安装后的验证
check_fp() { flatpak info "$1" >/dev/null 2>&1 && echo "installed" || echo "MISSING"; }

# 使用自定义传感器显示完整一行，保留其他传感器并开启登录自启。
configure_sysmonitor() {
    local status_script="$HOME/.local/lib/indicator-sysmonitor/system_status.py"
    install -Dm755 "$ROOT_DIR/scripts/system_status.py" "$status_script"
    /usr/bin/python3 - "$status_script" <<'PY'
import json
from pathlib import Path
import shlex
import sys

config_path = Path.home() / ".indicator-sysmonitor.json"
config = json.loads(config_path.read_text()) if config_path.exists() else {}
config["on_startup"] = True
config.setdefault("sensors", {})["workstation_status"] = [
    "CPU / NVIDIA GPU status",
    shlex.join(["/usr/bin/python3", sys.argv[1]]),
]
config["custom_text"] = "{workstation_status}"
config["interval"] = 3
config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n")
PY
    install -Dm644 /usr/share/applications/indicator-sysmonitor.desktop \
        "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/indicator-sysmonitor.desktop"
}

# Ubuntu 24.04 仓库没有 hardinfo2，使用上游发布的预编译包。
# 上游仅在 pre 发布中提供二进制包，正式版由发行版自行构建。
# https://github.com/hardinfo2/hardinfo2/releases/tag/release-2.3.0pre
install_hardinfo2() (
    # 子 shell 的 EXIT trap 确保下载或安装失败时也清理临时文件。
    if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "24.04" ]; then
        sudo apt-get install -y hardinfo2
        return
    fi

    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64) asset_arch=amd64 ;;
        arm64) asset_arch=aarch64 ;;
        *)
            echo "No upstream Ubuntu 24.04 Hardinfo2 package configured for $arch." >&2
            exit 1
            ;;
    esac

    tmpdir="$(mktemp -d /tmp/hardinfo2.XXXXXX)"
    trap 'rm -rf -- "$tmpdir"' EXIT
    deb="$tmpdir/hardinfo2.deb"
    url="https://github.com/hardinfo2/hardinfo2/releases/download/release-2.3.0pre/hardinfo2_2.3.0-Ubuntu-24.04_${asset_arch}.deb"
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 -o "$deb" "$url"
    if [ "$(dpkg-deb -f "$deb" Package)" != "hardinfo2" ] ||
       [ "$(dpkg-deb -f "$deb" Architecture)" != "$arch" ]; then
        echo "Downloaded Hardinfo2 package has an unexpected name or architecture." >&2
        exit 1
    fi
    # 允许 APT 的 _apt 用户读取安装包，并由 APT 处理依赖。
    chmod 755 "$tmpdir"
    chmod 644 "$deb"
    sudo apt-get install -y "$deb"
)

# 内核不支持该参数或当前值已是目标值时跳过；仅在需要变更时写入持久配置并立即应用
apply_sysctl() {
    local key="$1"
    local value="$2"
    local conf="$3"
    local current

    if ! current="$(sysctl -n "$key" 2>/dev/null)"; then
        echo "  $key not available on this kernel; skipping."
        return
    fi
    if [ "$current" = "$value" ]; then
        echo "  $key already $value; skipping."
        return
    fi
    sudo tee "$conf" <<<"$key = $value" >/dev/null
    sudo sysctl -w "$key=$value"
}

echo "======================================"
echo " Extras Installer"
echo "======================================"

require_non_root "./scripts/install-extras.sh"
require_debian_like
require_sudo

# 安装后续步骤所需依赖
print_step 1 "Installing dependencies"
sudo apt-get install -y bubblewrap software-properties-common flatpak gnome-software-plugin-flatpak

# indicator-sysmonitor 在顶栏显示 CPU/内存/网络等指标，仅在 PPA 中提供
print_step 2 "Adding indicator-sysmonitor PPA"
sudo add-apt-repository -y ppa:fossfreedom/indicator-sysmonitor

# 添加 Flathub 作为 Flatpak 应用来源
print_step 3 "Adding Flathub remote"
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

apt_get_update_step 4

# ubuntu-restricted-extras 会拉入 ttf-mscorefonts-installer，需预先接受微软字体 EULA 避免交互式卡住
print_step 5 "Installing apt extras"
echo ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true | sudo debconf-set-selections
sudo apt-get install -y \
    baobab \
    blueman \
    curl \
    flameshot \
    gnome-shell-extension-manager \
    gnome-system-monitor \
    gnome-tweaks \
    gparted \
    indicator-sysmonitor \
    lm-sensors \
    ncdu \
    net-tools \
    nvme-cli \
    p7zip-full \
    p7zip-rar \
    python3-psutil \
    smartmontools \
    ubuntu-restricted-extras \
    unrar \
    vlc \
    wget

configure_sysmonitor

print_step 6 "Installing Hardinfo2"
install_hardinfo2

# 使用 Flatpak 安装桌面应用，获取独立运行环境或更新版本
print_step 7 "Installing Mission Center, Loupe, and Pinta"
flatpak install -y flathub \
    io.missioncenter.MissionCenter \
    org.gnome.Loupe \
    com.github.PintaProject.Pinta

# bubblewrap 和 Flatpak 依赖非特权用户命名空间，需启用并解除 AppArmor 对其的限制
print_step 8 "Configuring unprivileged user namespaces"
apply_sysctl kernel.unprivileged_userns_clone 1 /etc/sysctl.d/99-userns.conf
apply_sysctl kernel.apparmor_restrict_unprivileged_userns 0 /etc/sysctl.d/99-apparmor-userns.conf

print_step 9 "Checking installed extras"
printf '  %-24s %s\n' "bubblewrap" "$(check_pkg bubblewrap)"
printf '  %-24s %s\n' "flatpak" "$(check_pkg flatpak)"
printf '  %-24s %s\n' "curl" "$(check_pkg curl)"
printf '  %-24s %s\n' "wget" "$(check_pkg wget)"
printf '  %-24s %s\n' "net-tools" "$(check_pkg net-tools)"
printf '  %-24s %s\n' "Hardinfo2" "$(check_pkg hardinfo2)"
printf '  %-24s %s\n' "lm-sensors" "$(check_pkg lm-sensors)"
printf '  %-24s %s\n' "nvme-cli" "$(check_pkg nvme-cli)"
printf '  %-24s %s\n' "smartmontools" "$(check_pkg smartmontools)"
printf '  %-24s %s\n' "System Monitor" "$(check_pkg gnome-system-monitor)"
printf '  %-24s %s\n' "indicator-sysmonitor" "$(check_pkg indicator-sysmonitor)"
printf '  %-24s %s\n' "Blueman" "$(check_pkg blueman)"
printf '  %-24s %s\n' "VLC" "$(check_pkg vlc)"
printf '  %-24s %s\n' "ubuntu-restricted-extras" "$(check_pkg ubuntu-restricted-extras)"
printf '  %-24s %s\n' "GParted" "$(check_pkg gparted)"
printf '  %-24s %s\n' "Baobab" "$(check_pkg baobab)"
printf '  %-24s %s\n' "ncdu" "$(check_pkg ncdu)"
printf '  %-24s %s\n' "p7zip-full" "$(check_pkg p7zip-full)"
printf '  %-24s %s\n' "p7zip-rar" "$(check_pkg p7zip-rar)"
printf '  %-24s %s\n' "unrar" "$(check_pkg unrar)"
printf '  %-24s %s\n' "Flameshot" "$(check_pkg flameshot)"
printf '  %-24s %s\n' "GNOME Tweaks" "$(check_pkg gnome-tweaks)"
printf '  %-24s %s\n' "GNOME Ext. Manager" "$(check_pkg gnome-shell-extension-manager)"
printf '  %-24s %s\n' "Mission Center" "$(check_fp io.missioncenter.MissionCenter)"
printf '  %-24s %s\n' "Loupe" "$(check_fp org.gnome.Loupe)"
printf '  %-24s %s\n' "Pinta" "$(check_fp com.github.PintaProject.Pinta)"

echo
echo "======================================"
echo "Installation complete"
echo "======================================"
echo "A reboot is recommended to ensure the kernel parameters persist."
echo "Start or restart indicator-sysmonitor to load the CPU/GPU display configuration."
