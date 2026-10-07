#!/usr/bin/env bash

# 下载并校验官方 MuJoCo Release，安装原生程序、开发库与示例模型。

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=5
readonly MUJOCO_VERSION="${MUJOCO_VERSION:-3.15.0}"
readonly MUJOCO_INSTALL_ROOT="${MUJOCO_INSTALL_ROOT:-/opt/mujoco}"
readonly INSTALL_DIR="$MUJOCO_INSTALL_ROOT"
readonly MUJOCO_BIN_DIR="$INSTALL_DIR/bin"
readonly ZSH_RC="$HOME/.zshrc"

require_non_root "./scripts/installers/install-simulators.sh"
require_debian_like
require_sudo

if [ "$#" -ne 0 ]; then
    echo "This installer takes no arguments; configure it with MUJOCO_* environment variables." >&2
    exit 2
fi
if [[ ! "$MUJOCO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "MUJOCO_VERSION must be a version number such as 3.15.0." >&2
    exit 2
fi
case "$MUJOCO_INSTALL_ROOT" in
    /*) ;;
    *) echo "MUJOCO_INSTALL_ROOT must be an absolute path." >&2; exit 2 ;;
esac
case "$(dpkg --print-architecture)" in
    amd64) asset_arch=x86_64 ;;
    arm64) asset_arch=aarch64 ;;
    *) echo "MuJoCo installer supports only amd64 and arm64 Linux releases." >&2; exit 1 ;;
esac
readonly ASSET="mujoco-$MUJOCO_VERSION-linux-$asset_arch.tar.gz"
readonly RELEASE_URL="https://github.com/google-deepmind/mujoco/releases/download/$MUJOCO_VERSION"

# 校验成功后才解压和写入目标目录；失败或完成时均清理临时文件。
install_mujoco_release() (
    tmpdir="$(mktemp -d /tmp/mujoco-release.XXXXXX)"
    trap 'rm -rf -- "$tmpdir"' EXIT
    curl -fLsS --retry 3 --connect-timeout 15 --max-time 600 \
        -o "$tmpdir/$ASSET" "$RELEASE_URL/$ASSET"
    curl -fLsS --retry 3 --connect-timeout 15 --max-time 120 \
        -o "$tmpdir/$ASSET.sha256" "$RELEASE_URL/$ASSET.sha256"

    # 仅使用校验文件的摘要，不信任其中的文件路径。
    read -r expected_hash _ < "$tmpdir/$ASSET.sha256"
    if [[ ! "$expected_hash" =~ ^[[:xdigit:]]{64}$ ]]; then
        echo "Invalid SHA256 checksum from MuJoCo Release." >&2
        exit 1
    fi
    (cd -- "$tmpdir" && printf '%s  %s\n' "$expected_hash" "$ASSET" | sha256sum --check --strict -)
    tar -xzf "$tmpdir/$ASSET" --no-same-owner -C "$tmpdir"
    release_dir="$tmpdir/mujoco-$MUJOCO_VERSION"
    for file in bin/simulate bin/testspeed lib/libmujoco.so include/mujoco/mujoco.h model/humanoid/humanoid.xml; do
        if [ ! -f "$release_dir/$file" ]; then
            echo "Missing file in MuJoCo Release: $file" >&2
            exit 1
        fi
    done
    [ -x "$release_dir/bin/simulate" ] && [ -x "$release_dir/bin/testspeed" ]
    sudo install -d -m 755 -- "$INSTALL_DIR"
    # 固定目录内更新文件；由 root 写入，不继承临时解压文件的用户所有权。
    sudo cp -a --no-preserve=ownership -- "$release_dir/." "$INSTALL_DIR/"
)

apt_get_update_step 1

print_step 2 "Installing download and desktop rendering dependencies"
sudo apt-get install -y ca-certificates curl tar coreutils libgl1 libglfw3

print_step 3 "Installing MuJoCo $MUJOCO_VERSION from GitHub Release"
install_mujoco_release

print_step 4 "Configuring native MuJoCo command and development paths"

# 直接更新 Zsh 中的托管配置块，重复安装或更换目录时不累积旧配置。
configure_zsh() (
    local begin='# >>> MuJoCo environment >>>'
    local end='# <<< MuJoCo environment <<<'
    local legacy_source tmpfile path_line absolute_path_line quoted_absolute_path_line
    printf -v legacy_source '. %q' "${XDG_CONFIG_HOME:-$HOME/.config}/mujoco/env.sh"
    touch "$ZSH_RC"
    tmpfile="$(mktemp)"
    trap 'rm -f -- "$tmpfile"' EXIT
    MUJOCO_LEGACY_SOURCE="$legacy_source" awk -v begin="$begin" -v end="$end" '
        BEGIN { legacy = ENVIRON["MUJOCO_LEGACY_SOURCE"] }
        $0 == begin { managed = 1; next }
        $0 == end { managed = 0; next }
        !managed && $0 != legacy { print }
    ' "$ZSH_RC" > "$tmpfile"
    # 用户目录保留字面量 $HOME，由 Zsh 启动时展开。
    case "$MUJOCO_BIN_DIR" in
        "$HOME/.local/bin")
            path_line='export PATH="$HOME/.local/bin:$PATH"'
            ;;
        "$HOME"/*)
            printf -v path_line 'export PATH="$HOME"/%q:"$PATH"' "${MUJOCO_BIN_DIR#"$HOME"/}"
            ;;
        *)
            printf -v path_line 'export PATH=%q:"$PATH"' "$MUJOCO_BIN_DIR"
            ;;
    esac
    # 同时识别此前生成的绝对路径形式；在托管块之外已配置时不重复添加。
    printf -v absolute_path_line 'export PATH=%q:"$PATH"' "$MUJOCO_BIN_DIR"
    printf -v quoted_absolute_path_line 'export PATH="%s:$PATH"' "$MUJOCO_BIN_DIR"
    if grep -Fqx -e "$path_line" -e "$absolute_path_line" -e "$quoted_absolute_path_line" "$tmpfile"; then
        path_line=''
    fi
    {
        echo "$begin"
        printf 'export MUJOCO_DIR=%q\n' "$INSTALL_DIR"
        if [ -n "$path_line" ]; then
            printf '%s\n' "$path_line"
        fi
        echo "$end"
    } >> "$tmpfile"
    cat "$tmpfile" > "$ZSH_RC"
)
configure_zsh

print_step 5 "Checking native physics simulation"
# testspeed 新版使用命名选项，旧版使用位置参数；均不需要图形上下文。
help_output="$("$INSTALL_DIR/bin/testspeed" --help 2>&1 || true)"
if [[ "$help_output" == *--nstep* ]]; then
    test_output="$("$INSTALL_DIR/bin/testspeed" --nstep=100 --nthread=1 "$INSTALL_DIR/model/humanoid/humanoid.xml" 2>&1)"
else
    test_output="$("$INSTALL_DIR/bin/testspeed" "$INSTALL_DIR/model/humanoid/humanoid.xml" 100 1 2>&1)"
fi
# 部分版本发生模型加载错误时仍返回 0，需确认确实输出了步进统计。
if [[ "$test_output" != *"Time per step"* ]]; then
    printf '%s\n' "$test_output" >&2
    echo "MuJoCo physics smoke test did not complete." >&2
    exit 1
fi
echo "MuJoCo $MUJOCO_VERSION: native physics simulation OK"

echo
echo "MuJoCo installation: $INSTALL_DIR"
echo "Native viewer: $MUJOCO_BIN_DIR/simulate (requires a desktop session)"
echo "Apply environment with: source $ZSH_RC"
echo "Run: simulate \"\$MUJOCO_DIR/model/humanoid/humanoid.xml\""
