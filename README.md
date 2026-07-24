# Linux Workstation Setup

目录按职责分为两类：

```text
.
├── setup.sh                       # 统一入口
├── scripts/                       # 自定义安装与配置脚本
│   ├── install-fcitx5-rime.sh
│   ├── install-fonts.sh
│   ├── install-miniconda.sh
│   ├── install-mirrors.sh
│   ├── install-nodejs.sh
│   ├── install-ruby.sh
│   ├── install-cpp.sh
│   ├── install-extras.sh
│   ├── install-zsh.sh
│   ├── install-rust.sh
│   └── lib/
│       └── common.sh              # 安装脚本公共函数
└── vendor/                        # 本地上游安装器目录
    ├── README.md
    └── download-installers.sh     # 下载上游安装器
```

## 使用

查看组件：

```bash
./setup.sh list
```

安装全部组件：

```bash
./setup.sh
# 或
./setup.sh all
```

安装全部组件，并在某个组件失败后继续安装后续组件：

```bash
./setup.sh all --continue-on-error
```

安装全部组件，但跳过指定组件：

```bash
./setup.sh all --skip ruby,miniconda
```

安装组件：

```bash
./setup.sh mirrors
./setup.sh npm
./setup.sh fcitx5-rime
./setup.sh fonts
./setup.sh zsh
./setup.sh ruby
./setup.sh rust
./setup.sh cpp
./setup.sh miniconda
./setup.sh extras
```

统一入口会将组件名之后的参数原样传递给对应安装器。运行
`./setup.sh help` 可查看完整帮助。不指定组件时会按开发环境优先的顺序安装全部组件：
Mirrors、Fonts、Zsh、Node.js/npm、Rust、Ruby、C/C++、Miniconda、Extras、Fcitx 5 Rime。Mirrors
排在最前，使后续组件的包下载直接走国内镜像；由于 Zsh 脚本会生成 `~/.zshrc`，它会在
Node.js、Rust、Ruby、C/C++ 和 Miniconda 之前运行，避免后续写入的 Shell 配置被覆盖。Rust 会在
Ruby 之前安装，Ruby 构建时会优先加载 rustup 管理的 Cargo 环境。`all` 模式会先统一运行一次
`apt-get update`，然后让各组件跳过自己的重复包索引更新；当 Mirrors 未被 `--skip` 跳过时，
这次预更新会交给 Mirrors 组件（它先换源再刷新索引，避免用官方源做无谓的首次更新）；
Node.js 添加 NodeSource 仓库后仍会再次刷新包索引。

Mirrors 脚本将 apt、pip 与 conda 的软件源切换到国内镜像，默认使用清华 TUNA，可通过
`MIRROR_PROVIDER` 环境变量在 `tuna`、`aliyun`、`ustc` 之间切换；也可用更具体的同名环境
变量覆盖单项地址：`APT_MIRROR_HOST`、`PIP_INDEX_URL`、`PIP_TRUSTED_HOST`、
`CONDA_CHANNEL_MAIN`、`CONDA_CHANNEL_R`、`CONDA_CLOUD_BASE`。

- **apt**：扫描 `/etc/apt/sources.list` 与 `/etc/apt/sources.list.d/` 下的 `*.list`、
  `*.sources`（含 Ubuntu 24.04 / Debian 12 的 deb822 格式），将 `archive.ubuntu.com`、
  `security.ubuntu.com`、`deb.debian.org`、`security.debian.org` 替换为镜像域名并升级为
  HTTPS，路径保持不变。仅当文件仍引用官方域名时，首次备份为同名 `.orig` 文件，确保
  `.orig` 始终是官方源；换源后执行一次 `apt-get update`。脚本可重复运行且幂等。
- **pip**：写入 `~/.config/pip/pip.conf`（XDG 标准位置），并同步到 `~/.pip/pip.conf`
  以兼容旧版 pip；首次覆盖前各备份一次为 `.bak`。
- **conda**：写入 `~/.condarc`，镜像化 `defaults` 的 `main`/`r` 渠道，并把 `conda-forge`、
  `pytorch` 指向镜像；若 conda 已安装，会清空索引缓存。conda 尚未安装时配置同样写入，
  待 Miniconda 安装后即生效。

恢复官方 apt 源：

```bash
sudo cp /etc/apt/sources.list.orig /etc/apt/sources.list
```

字体脚本默认安装 DejaVu、Liberation、Fira Code、JetBrains Mono、Cascadia
Code、Noto（含扩展、等宽、CJK 和彩色 Emoji）、Carlito、Caladea，以及用于
LaTeX 和数学排版的 Latin Modern 与 STIX。可以使用以空格分隔的
`FONT_PACKAGES` 环境变量覆盖默认包列表。

Zsh 脚本安装 Oh My Zsh 和语法高亮插件，并生成基础 Shell 与历史记录配置。
执行时会直接覆盖现有的 `~/.zshrc`。插件列表中还包含
`conda-zsh-completion`（来自 `conda-incubator/conda-zsh-completion`），为
`conda` 提供 Tab 补全（子命令、环境名、包名）。该插件在 `conda init` 注册的
`conda` 函数上同样生效；conda 未安装时仅在按 Tab 时返回空，不影响 Shell 启动。

Miniconda 封装脚本会在安装成功后设置 `auto_activate: false`，避免启动
Shell 时自动进入 base 环境，并根据当前 Shell 运行对应的 `conda init`。不传
参数时默认以非交互方式安装到 `$HOME/miniconda3`；如果该目录已存在，则自动
使用更新模式，便于重复运行。
Node.js、Rust 和 Miniconda 安装脚本会分别将 npm、Cargo 和 Conda 所需配置
写入当前 Shell 的配置文件：Zsh 使用 `~/.zshrc`，Bash 使用 `~/.bashrc`，
其他 Shell 回退到 `~/.profile`。如需修改默认目录，仍可向官方安装器传入
`-p` 参数。

Rust 和 Miniconda 组件依赖 `vendor/` 中的上游安装器。安装器不存在时，对应
组件会自动从官方地址下载。也可以提前手动下载：

```bash
./vendor/download-installers.sh
./vendor/download-installers.sh rust
./vendor/download-installers.sh miniconda
```

Extras 脚本安装常用拓展程序：

- **bubblewrap** — 非特权容器运行时，为 Flatpak 提供沙箱隔离，并配置内核 user namespaces 及 AppArmor 豁免
- **Solaar** — Logitech 设备管理器（`ppa:solaar-unifying/stable`），将当前用户加入 `plugdev` 组
- **Hardinfo2** — 系统硬件信息与基准测试工具（apt）
- **System Monitor** — GNOME 系统资源监控器（apt）
- **indicator-sysmonitor** — 顶栏显示 CPU/内存/网络等指标的指示器（`ppa:fossfreedom/indicator-sysmonitor`）
- **ubuntu-restricted-extras** — 多媒体编解码器、微软字体等受限组件（apt，预接受 EULA）
- **VLC** — 多媒体播放器（apt）
- **lm-sensors / nvme-cli / smartmontools** — 硬件温度、NVMe 与磁盘健康监控（apt）
- **net-tools** — 经典网络工具（apt）
- **GParted / Baobab / ncdu** — 分区、磁盘用量分析与目录占用分析（apt）
- **p7zip-full / p7zip-rar / unrar** — 压缩归档支持（apt）
- **Blueman** — 蓝牙设备管理器（apt）
- **Flameshot** — 截图工具（apt）
- **GNOME Tweaks** — GNOME 高级设置工具（apt）
- **GNOME Shell Extension Manager** — 浏览与管理 GNOME 扩展（apt）
- **curl** — 命令行 HTTP 客户端（apt）
- **wget** — 命令行下载工具（apt）
- **Pinta** — 轻量图像编辑器（Flatpak）
- **Mission Center / Loupe** — 现代系统资源监控器与图片查看器（Flatpak）

安装后需重新登录使 `plugdev` 组成员身份生效。

Ruby 脚本通过 Git 安装 rbenv 和 ruby-build，默认自动选择 Ruby 3.4 维护分支
中的最新补丁版，并根据当前 Shell 写入 rbenv 初始化配置。可通过
`RUBY_SERIES`、`RUBY_VERSION` 和 `RBENV_ROOT` 覆盖默认分支、Ruby 版本与安装
目录。

C/C++ 脚本安装一套完整的构建环境，覆盖 Linux 用户态（amd64/arm64/armhf/riscv64）与裸机/嵌入式（RISC-V、ARM Cortex-M）两类目标：

- **本机工具链**：`build-essential`（gcc/g++/make）、`cmake`、`ninja-build`、
  `pkg-config`、`ccache`、`binutils`。
- **clang 工具链**：`clang`、`clang-format`、`clang-tidy`、`clangd`、`lld`。
- **调试与静态分析**：`gdb-multiarch`（替代普通 gdb，可调试任意架构）、`valgrind`、`cppcheck`。
- **Linux 交叉工具链**：为目标架构列表中与主机不同的每个架构安装 `binutils-<triplet>`、
  `gcc-<triplet>`、`g++-<triplet>`（如 `aarch64-linux-gnu-g++`、`riscv64-linux-gnu-g++`、
  `arm-linux-gnueabihf-g++`），并随依赖拉入对应架构的 `libc6-dev-<arch>-cross` 与
  `libstdc++-dev`（即完整 sysroot）；主机架构使用本机 gcc/g++，不重复安装交叉包。
- **裸机/嵌入式工具链**：`gcc-riscv64-unknown-elf`（+ `binutils`、`picolibc`，且自带
  `riscv64-unknown-elf-g++`）、`gcc-arm-none-eabi`（+ `binutils`、`libnewlib`、
  `libstdc++-arm-none-eabi-newlib`）。设 `CPP_BAREMETAL=0` 可跳过。
- **验证**：安装末尾会对每个 Linux 目标架构编译一段 C++ 并用 `file` 确认产物架构，再对裸机
  编译器用 `-c` 编译目标文件做冒烟测试（裸机完整链接需启动代码与链接脚本，故仅编译不链接）。

默认 Linux 目标架构为 `amd64 arm64 armhf riscv64`，可通过 `CPP_TARGETS` 环境变量覆盖（空格分隔的
dpkg 架构名，支持 `amd64`/`arm64`/`armhf`/`riscv64`）。例如仅装 arm64 交叉：

```bash
CPP_TARGETS="amd64 arm64" ./setup.sh cpp
```

Node.js/npm 脚本会安装 `jq` 作为配置编辑工具；装好 Node.js 与全局 CLI 工具（含
`opencode-ai`、`@openai/codex` 和 `@ast-grep/cli`）之后，会注册两个 MCP 服务器
（Context7 / Playwright）。Context7 用远程 `https://mcp.context7.com/mcp`，Playwright 用本地 stdio
`npx -y @playwright/mcp@latest`，两者均无需鉴权。OpenCode 端写入
`opencode.json[c]` 的 `mcp` 段（仅新增缺失项，不覆盖已有配置）；Codex 端用 `codex mcp add`
注册。

此外脚本会通过 GitHub 官方 apt 源安装 `gh`（GitHub CLI）。`@ast-grep/cli` 由 npm 全局安装并提供
`sg` 命令。

脚本还会把 Codex 的基础配置写入 `~/.codex/config.toml`。建议组合为
`gpt-5.6-sol`、`high`、`default`、`on-request`、`workspace-write` 和启用网络；模型、推理强度、
服务等级、审批策略与沙箱模式作为顶层标量写入，网络开关按 Codex 当前格式写入
`[sandbox_workspace_write].network_access`。脚本会移除旧版误写的顶层 `network_access` 字符串，
保留其它注释、配置键与表段；各值可用 `CODEX_MODEL` / `CODEX_REASONING` /
`CODEX_SERVICE_TIER` / `CODEX_APPROVAL` / `CODEX_SANDBOX` / `CODEX_NETWORK` 环境变量覆盖。
其中 `CODEX_NETWORK` 接受 `enabled` 或 `disabled`，并分别映射为 TOML 布尔值 `true` 或 `false`。

## 维护约定

- `vendor/` 用于保存上游发布的原始安装器。安装器文件不提交到 Git 仓库，
  通过 `vendor/download-installers.sh` 下载。
- `scripts/` 保存环境检查、默认配置和对官方安装器的封装。
- `scripts/lib/common.sh` 保存跨安装器复用的通用函数，例如系统检查、sudo
  检查、步骤输出和 Shell 配置文件选择。
- 新增组件时，同时更新 `setup.sh` 的命令分派和本文件的目录说明。
