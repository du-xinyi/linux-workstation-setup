#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=10

# 通过 dpkg 查询 apt 包安装状态，用于安装后的验证
check_pkg() { dpkg -s "$1" >/dev/null 2>&1 && echo "installed" || echo "MISSING"; }

# 通过 flatpak info 查询 Flatpak 应用安装状态，用于安装后的验证
check_fp() { flatpak info "$1" >/dev/null 2>&1 && echo "installed" || echo "MISSING"; }

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

# Solaar 稳定 PPA 提供比系统仓库更新的 Logitech 设备管理器
print_step 2 "Adding Solaar PPA"
sudo add-apt-repository -y ppa:solaar-unifying/stable

# indicator-sysmonitor 在顶栏显示 CPU/内存/网络等指标，仅在 PPA 中提供
print_step 3 "Adding indicator-sysmonitor PPA"
sudo add-apt-repository -y ppa:fossfreedom/indicator-sysmonitor

# 添加 Flathub 作为 Flatpak 应用来源
print_step 4 "Adding Flathub remote"
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

apt_get_update_step 5

# ubuntu-restricted-extras 会拉入 ttf-mscorefonts-installer，需预先接受微软字体 EULA 避免交互式卡住
print_step 6 "Installing apt extras"
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
    hardinfo2 \
    indicator-sysmonitor \
    lm-sensors \
    ncdu \
    net-tools \
    nvme-cli \
    p7zip-full \
    p7zip-rar \
    smartmontools \
    solaar \
    ubuntu-restricted-extras \
    unrar \
    vlc \
    wget

# 使用 Flatpak 安装桌面应用，获取独立运行环境或更新版本
print_step 7 "Installing Mission Center, Loupe, and Pinta"
flatpak install -y flathub \
    io.missioncenter.MissionCenter \
    org.gnome.Loupe \
    com.github.PintaProject.Pinta

# Solaar 需要访问部分 HID 设备，加入 plugdev 组提供非特权访问权限
print_step 8 "Adding current user to plugdev group"
if getent group plugdev | grep -qw "$USER"; then
    echo "  $USER already in plugdev; skipping."
else
    sudo usermod -a -G plugdev "$USER"
fi

# bubblewrap 和 Flatpak 依赖非特权用户命名空间，需启用并解除 AppArmor 对其的限制
print_step 9 "Configuring unprivileged user namespaces"
apply_sysctl kernel.unprivileged_userns_clone 1 /etc/sysctl.d/99-userns.conf
apply_sysctl kernel.apparmor_restrict_unprivileged_userns 0 /etc/sysctl.d/99-apparmor-userns.conf

print_step 10 "Checking installed extras"
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
printf '  %-24s %s\n' "Solaar" "$(check_pkg solaar)"
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
echo "Log out and back in for the plugdev group membership to take effect."
echo "A reboot is recommended to ensure the kernel parameters persist."
