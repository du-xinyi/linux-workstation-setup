#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=8

# 配置 ----------------------------------------------------------------

# Linux 用户态目标架构(dpkg 架构名),空格分隔;支持 amd64/arm64/armhf/riscv64
readonly CPP_TARGETS_RAW="${CPP_TARGETS:-amd64 arm64 armhf riscv64}"
# 是否安装裸机/嵌入式工具链(1 装,0 跳过)
readonly CPP_BAREMETAL="${CPP_BAREMETAL:-1}"
# 是否安装本机常用开发库(1 装,0 跳过)
readonly CPP_COMMON_LIBS="${CPP_COMMON_LIBS:-1}"

# 工具链包列表 -------------------------------------------------------

readonly -a NATIVE_PKGS=(
    build-essential
    cmake
    ninja-build
    pkg-config
    ccache
    make
    binutils
)

readonly -a CLANG_PKGS=(
    clang
    clang-format
    clang-tidy
    clangd
    lld
)

readonly -a DEBUG_PKGS=(
    gdb-multiarch
    valgrind
    cppcheck
)

# 本机常用开发库(仅服务本机开发;交叉开发建议用 vcpkg/conan)
readonly -a COMMON_LIBS_PKGS=(
    zlib1g-dev
    libssl-dev
    libcurl4-openssl-dev
    nlohmann-json3-dev
    libfmt-dev
    libspdlog-dev
    libsqlite3-dev
    libeigen3-dev
    libgtest-dev
    libgmock-dev
    catch2
    libxml2-dev
)

# 裸机/嵌入式:RISC-V 用 picolibc,ARM Cortex-M 用 newlib + libstdc++-newlib
# gcc-riscv64-unknown-elf 自带 g++(riscv64-unknown-elf-g++)
readonly -a BAREMETAL_PKGS=(
    gcc-riscv64-unknown-elf
    binutils-riscv64-unknown-elf
    picolibc-riscv64-unknown-elf
    gcc-arm-none-eabi
    binutils-arm-none-eabi
    libnewlib-arm-none-eabi
    libstdc++-arm-none-eabi-newlib
)

# 辅助函数 -----------------------------------------------------------

# dpkg 架构 -> GNU triplet
arch_to_triplet() {
    case "$1" in
        amd64)   printf 'x86_64-linux-gnu\n' ;;
        arm64)   printf 'aarch64-linux-gnu\n' ;;
        armhf)   printf 'arm-linux-gnueabihf\n' ;;
        riscv64) printf 'riscv64-linux-gnu\n' ;;
        *)       return 1 ;;
    esac
}

# 打印单个工具的版本(用于验证)
check_tool() {
    local label="$1"
    local cmd="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf '  %-10s %s\n' "$label" "$("$cmd" --version 2>&1 | head -1)"
    else
        printf '  %-10s %s\n' "$label" "MISSING"
    fi
}

# 主流程 -------------------------------------------------------------

echo "======================================"
echo " C/C++ Build Environment Installer"
echo "======================================"

require_non_root "./scripts/install-cpp.sh"
require_debian_like
require_sudo "sudo was not found. Install it and grant sudo access to the current user."

host_arch="$(dpkg --print-architecture)"
read -r -a targets <<<"$CPP_TARGETS_RAW"

# 为非本机目标架构构建 Linux 交叉工具链包列表
cross_pkgs=()
for t in "${targets[@]}"; do
    [ "$t" = "$host_arch" ] && continue
    if ! triplet="$(arch_to_triplet "$t")"; then
        echo "Unsupported target architecture in CPP_TARGETS: $t" >&2
        echo "Supported: amd64 arm64 armhf riscv64" >&2
        exit 1
    fi
    suffix="${triplet//_/-}"
    cross_pkgs+=("binutils-${suffix}" "gcc-${suffix}" "g++-${suffix}")
done

apt_get_update_step 1

print_step 2 "Installing native build toolchain"
sudo apt-get install -y "${NATIVE_PKGS[@]}"

print_step 3 "Installing clang toolchain"
sudo apt-get install -y "${CLANG_PKGS[@]}"

print_step 4 "Installing debug and static analysis tools"
sudo apt-get install -y "${DEBUG_PKGS[@]}"

print_step 5 "Installing common development libraries"
if [ "$CPP_COMMON_LIBS" = "1" ]; then
    sudo apt-get install -y "${COMMON_LIBS_PKGS[@]}"
else
    echo "  CPP_COMMON_LIBS=0; skipping common libraries."
fi

print_step 6 "Installing cross toolchains (${targets[*]})"
if [ "${#cross_pkgs[@]}" -eq 0 ]; then
    echo "  host is the only target; no cross toolchain needed."
else
    sudo apt-get install -y "${cross_pkgs[@]}"
fi

print_step 7 "Installing bare-metal toolchains (RISC-V, ARM Cortex-M)"
if [ "$CPP_BAREMETAL" = "1" ]; then
    sudo apt-get install -y "${BAREMETAL_PKGS[@]}"
else
    echo "  CPP_BAREMETAL=0; skipping bare-metal toolchains."
fi

print_step 8 "Verifying the toolchain"
check_tool "gcc"    gcc
check_tool "g++"    g++
check_tool "clang"  clang
check_tool "cmake"  cmake
check_tool "ninja"  ninja
check_tool "ccache" ccache
check_tool "gdb"    gdb

echo
echo "  Cross-build smoke test:"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
cat > "$tmpdir/hello.cpp" <<'EOF'
#include <iostream>
int main() {
    std::cout << "OK " << (sizeof(void*) * 8) << "-bit C++\n";
    return 0;
}
EOF
cat > "$tmpdir/hello.c" <<'EOF'
#include <stdio.h>
int main(void) {
    printf("OK\n");
    return 0;
}
EOF

# Linux 系列:本机架构编译并运行;交叉架构编译后用 file 确认目标架构
for t in "${targets[@]}"; do
    triplet="$(arch_to_triplet "$t")"
    bin="$tmpdir/hello_$t"
    if [ "$t" = "$host_arch" ]; then
        if g++ "$tmpdir/hello.cpp" -o "$bin" 2>/dev/null; then
            printf '  %-10s build:OK  run:%s\n' "$t" "$("$bin" 2>/dev/null || echo FAILED)"
        else
            printf '  %-10s build:FAILED\n' "$t"
        fi
    else
        if "$triplet-g++" "$tmpdir/hello.cpp" -o "$bin" 2>/dev/null; then
            arch="$(file -b "$bin" 2>/dev/null | cut -d, -f1-2)"
            printf '  %-10s build:OK  %s\n' "$t" "$arch"
        else
            printf '  %-10s build:FAILED\n' "$t"
        fi
    fi
done

# 裸机工具链:仅编译到目标文件(-c),不链接可执行文件(裸机链接需启动代码与链接脚本)
echo "  Bare-metal compile test (-c):"
for gcc in riscv64-unknown-elf-gcc arm-none-eabi-gcc; do
    obj="$tmpdir/bm_${gcc}.o"
    if command -v "$gcc" >/dev/null 2>&1; then
        if "$gcc" -c "$tmpdir/hello.c" -o "$obj" 2>/dev/null; then
            printf '  %-28s compile:OK\n' "$gcc"
        else
            printf '  %-28s compile:FAILED\n' "$gcc"
        fi
    else
        printf '  %-28s MISSING\n' "$gcc"
    fi
done

echo
echo "======================================"
echo " Installation complete"
echo "======================================"
echo "Native compilers:    gcc / g++ / clang"
echo "Cross targets:       ${targets[*]}"
if [ "$CPP_BAREMETAL" = "1" ]; then
    echo "Bare-metal:          riscv64-unknown-elf / arm-none-eabi"
fi
