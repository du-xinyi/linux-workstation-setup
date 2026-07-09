# Linux Workstation Setup

目录按职责分为两类：

```text
.
├── setup.sh                       # 统一入口
├── scripts/                       # 自定义安装与配置脚本
│   ├── install-fcitx5-rime.sh
│   ├── install-fonts.sh
│   ├── install-miniconda.sh
│   ├── install-nodejs.sh
│   ├── install-ruby.sh
│   ├── install-zsh.sh
│   ├── install-rust.sh
│   └── lib/
│       └── common.sh              # 安装脚本公共函数
└── vendor/                        # 本地上游安装器目录
    └── README.md
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
./setup.sh npm
./setup.sh fcitx5-rime
./setup.sh fonts
./setup.sh zsh
./setup.sh ruby
./setup.sh rust
./setup.sh miniconda
```

统一入口会将组件名之后的参数原样传递给对应安装器。运行
`./setup.sh help` 可查看完整帮助。不指定组件时会按开发环境优先的顺序安装全部组件：
Fonts、Zsh、Node.js/npm、Rust、Ruby、Miniconda、Fcitx 5 Rime。由于 Zsh
脚本会生成 `~/.zshrc`，它会在 Node.js、Rust、Ruby 和 Miniconda 之前运行，
避免后续写入的 Shell 配置被覆盖。Rust 会在 Ruby 之前安装，Ruby 构建时会优先
加载 rustup 管理的 Cargo 环境。`all` 模式会先统一运行一次 `apt-get update`，
然后让各组件跳过自己的重复包索引更新；Node.js 添加 NodeSource 仓库后仍会再次
刷新包索引。

字体脚本默认安装 DejaVu、Liberation、Fira Code、JetBrains Mono、Cascadia
Code、Noto（含扩展、等宽、CJK 和彩色 Emoji）、Carlito、Caladea，以及用于
LaTeX 和数学排版的 Latin Modern 与 STIX。可以使用以空格分隔的
`FONT_PACKAGES` 环境变量覆盖默认包列表。

Zsh 脚本安装 Oh My Zsh 和语法高亮插件，并生成基础 Shell 与历史记录配置。
执行时会直接覆盖现有的 `~/.zshrc`。

Miniconda 封装脚本会在安装成功后设置 `auto_activate: false`，避免启动
Shell 时自动进入 base 环境，并根据当前 Shell 运行对应的 `conda init`。不传
参数时默认以非交互方式安装到 `$HOME/miniconda3`；如果该目录已存在，则自动
使用更新模式，便于重复运行。
Node.js、Rust 和 Miniconda 安装脚本会分别将 npm、Cargo 和 Conda 所需配置
写入当前 Shell 的配置文件：Zsh 使用 `~/.zshrc`，Bash 使用 `~/.bashrc`，
其他 Shell 回退到 `~/.profile`。如需修改默认目录，仍可向官方安装器传入
`-p` 参数。

Ruby 脚本通过 Git 安装 rbenv 和 ruby-build，默认自动选择 Ruby 3.4 维护分支
中的最新补丁版，并根据当前 Shell 写入 rbenv 初始化配置。可通过
`RUBY_SERIES`、`RUBY_VERSION` 和 `RBENV_ROOT` 覆盖默认分支、Ruby 版本与安装
目录。

## 维护约定

- `vendor/` 用于本地保存上游发布的原始安装器，安装器文件不提交到 Git 仓库。
- `scripts/` 保存环境检查、默认配置和对官方安装器的封装。
- `scripts/lib/common.sh` 保存跨安装器复用的通用函数，例如系统检查、sudo
  检查、步骤输出和 Shell 配置文件选择。
- 新增组件时，同时更新 `setup.sh` 的命令分派和本文件的目录说明。
