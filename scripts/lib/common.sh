#!/usr/bin/env bash

# 安装脚本公共入口;按依赖顺序加载,保持现有函数接口。
# 库文件不设置 Shell 选项、trap 或全局路径变量。
# 使用当前文件的位置定位模块，不依赖调用方的工作目录或 ROOT_DIR。
# shellcheck source=scripts/lib/runtime.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/runtime.sh"
# shellcheck source=scripts/lib/apt.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/apt.sh"
# shellcheck source=scripts/lib/shell.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/shell.sh"
