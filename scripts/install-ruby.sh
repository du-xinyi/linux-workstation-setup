#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=7
readonly RUBY_VERSION_REQUEST="${RUBY_VERSION:-auto}"
readonly RUBY_SERIES="${RUBY_SERIES:-3.4}"
readonly RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
readonly RBENV_BIN="$RBENV_ROOT/bin/rbenv"
readonly RUBY_BUILD_DIR="$RBENV_ROOT/plugins/ruby-build"

# 解析 Ruby 版本：
# - 显式设置 RUBY_VERSION 时直接使用指定版本；
# - 默认在 RUBY_SERIES 指定的稳定维护分支内选择最新补丁版
resolve_ruby_version() {
    if [ "$RUBY_VERSION_REQUEST" != "auto" ]; then
        printf '%s\n' "$RUBY_VERSION_REQUEST"
        return
    fi

    local version
    version="$(
        "$RBENV_BIN" install -l |
            awk -v series="$RUBY_SERIES" '
                $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && index($1, series ".") == 1 {
                    print $1
                }
            ' |
            sort -V |
            tail -n 1
    )"

    if [ -z "$version" ]; then
        echo "Unable to resolve the latest Ruby version for series ${RUBY_SERIES}." >&2
        echo "Use RUBY_VERSION=3.4.10 or RUBY_SERIES=3.4 to specify it explicitly." >&2
        exit 1
    fi

    printf '%s\n' "$version"
}

require_non_root
require_debian_like
require_sudo

apt_get_update_step 1

# 安装编译 Ruby 所需的系统依赖
print_step 2 "Installing Ruby build dependencies"
sudo apt-get install -y \
    autoconf \
    build-essential \
    curl \
    git \
    libdb-dev \
    libffi-dev \
    libgdbm-dev \
    libgmp-dev \
    liblzma-dev \
    libncurses-dev \
    libreadline-dev \
    libssl-dev \
    libyaml-dev \
    patch \
    rustc \
    uuid-dev \
    zlib1g-dev

# rbenv 负责管理多个 Ruby 版本
print_step 3 "Installing or updating rbenv"
if [ -d "$RBENV_ROOT/.git" ]; then
    git -C "$RBENV_ROOT" pull --ff-only
elif [ -e "$RBENV_ROOT" ]; then
    echo "rbenv directory exists but is not a Git repository: $RBENV_ROOT" >&2
    exit 1
else
    git clone --depth 1 https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
fi

# ruby-build 是 rbenv 的安装插件，提供可安装版本列表和源码构建逻辑
print_step 4 "Installing or updating ruby-build"
mkdir -p "$(dirname "$RUBY_BUILD_DIR")"
if [ -d "$RUBY_BUILD_DIR/.git" ]; then
    git -C "$RUBY_BUILD_DIR" pull --ff-only
elif [ -e "$RUBY_BUILD_DIR" ]; then
    echo "ruby-build directory exists but is not a Git repository: $RUBY_BUILD_DIR" >&2
    exit 1
else
    git clone --depth 1 https://github.com/rbenv/ruby-build.git "$RUBY_BUILD_DIR"
fi

# 先解析目标版本，再安装并设置为全局默认 Ruby
print_step 5 "Resolving and installing Ruby"
export RBENV_ROOT
export PATH="$RBENV_ROOT/bin:$PATH"
if [ -r "$HOME/.cargo/env" ]; then
    # 如果 Rust 组件已安装，优先使用 rustup 管理的 Rust
    # shellcheck disable=SC1090
    . "$HOME/.cargo/env"
fi
ruby_version="$(resolve_ruby_version)"
printf 'Selected Ruby: %s\n' "$ruby_version"
"$RBENV_BIN" install --skip-existing "$ruby_version"
"$RBENV_BIN" global "$ruby_version"
"$RBENV_BIN" rehash

print_step 6 "Configuring the current Shell"
select_shell_name_and_rc shell_name shell_rc bash

touch "$shell_rc"
if ! grep -Fq 'rbenv init' "$shell_rc"; then
    {
        echo
        echo '# Ruby version manager: rbenv'
        printf 'eval "$("$HOME/.rbenv/bin/rbenv" init - --no-rehash %s)"\n' "$shell_name"
    } >>"$shell_rc"
fi

# 验证 rbenv、Ruby 和 RubyGems 是否可运行
print_step 7 "Checking the Ruby environment"
export PATH="$RBENV_ROOT/shims:$PATH"
printf 'rbenv:  %s\n' "$("$RBENV_BIN" --version)"
printf 'Ruby:   %s\n' "$(ruby --version)"
printf 'RubyGems: %s\n' "$(gem --version)"
printf 'Config: %s\n' "$shell_rc"

echo
echo "Apply the Shell configuration now with: source $shell_rc"
