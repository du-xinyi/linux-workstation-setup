#!/usr/bin/env bash

# APT 包索引更新;由 common.sh 先加载 runtime.sh

# 参数为步骤编号；SKIP_APT_UPDATE=1 表示统一入口已完成更新。
# sudo/apt-get 的失败状态直接传回调用方，避免忽略索引更新失败。
apt_get_update_step() {
    local number="$1"

    print_step "$number" "Updating package indexes"
    if [ "${SKIP_APT_UPDATE:-0}" = "1" ]; then
        echo "Package indexes already updated by setup.sh; skipping."
        return
    fi

    sudo apt-get update
}
