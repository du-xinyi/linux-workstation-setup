#!/usr/bin/env bash

# 当前用户登录 Shell 的名称与配置文件选择

# 输出账户数据库中的登录 Shell，读取失败时回退到 $SHELL。
# setup.sh all 中 zsh 组件执行 chsh 后，进程环境里的 $SHELL 仍是旧值，
# 因此优先读取 passwd，确保后续组件写入新登录 Shell 的配置文件。
login_shell() {
    local shell_path=""

    if command -v getent >/dev/null 2>&1; then
        shell_path="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)" || shell_path=""
    fi
    printf '%s\n' "${shell_path:-${SHELL:-}}"
}

# 根据登录 Shell 输出配置路径，不创建文件或探测当前解释器。
select_shell_rc() {
    case "$(login_shell)" in
        */zsh)  printf '%s\n' "$HOME/.zshrc" ;;
        */bash) printf '%s\n' "$HOME/.bashrc" ;;
        *)      printf '%s\n' "$HOME/.profile" ;;
    esac
}

# 前两个参数是接收 Shell 名称和配置路径的变量名，通过 printf -v 回写。
# 未识别的 Shell 使用 .profile；第三个参数指定回退名称，允许显式传空串。
select_shell_name_and_rc() {
    local name_var="$1"
    local rc_var="$2"
    local fallback_name="bash"
    local selected_shell_name
    local selected_shell_rc

    if [ "$#" -ge 3 ]; then
        fallback_name="$3"
    fi

    case "$(login_shell)" in
        */zsh)
            selected_shell_name="zsh"
            selected_shell_rc="$HOME/.zshrc"
            ;;
        */bash)
            selected_shell_name="bash"
            selected_shell_rc="$HOME/.bashrc"
            ;;
        *)
            selected_shell_name="$fallback_name"
            selected_shell_rc="$HOME/.profile"
            ;;
    esac

    printf -v "$name_var" '%s' "$selected_shell_name"
    printf -v "$rc_var" '%s' "$selected_shell_rc"
}
