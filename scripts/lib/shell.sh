#!/usr/bin/env bash

# 当前 Shell 的名称与配置文件选择

# 根据登录 Shell 环境变量输出配置路径，不创建文件或探测当前解释器。
select_shell_rc() {
    case "${SHELL:-}" in
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

    case "${SHELL:-}" in
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
