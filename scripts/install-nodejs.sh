#!/usr/bin/env bash

set -Eeuo pipefail

trap 'echo "Error: command failed at line ${LINENO}." >&2' ERR

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/scripts/lib/common.sh"

readonly SETUP_STEP_TOTAL=14

# 以下安装参数可通过同名环境变量覆盖
readonly NODE_MAJOR="${NODE_MAJOR:-24}"
readonly NPM_VERSION="${NPM_VERSION:-latest}"
readonly NPM_DIR="${NPM_DIR:-$HOME/.local/npm}"
readonly NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
readonly KEYRING_DIR="/etc/apt/keyrings"
readonly NODESOURCE_KEYRING="${KEYRING_DIR}/nodesource.gpg"
readonly NODESOURCE_LIST="/etc/apt/sources.list.d/nodesource.list"
readonly GH_KEYRING="${KEYRING_DIR}/githubcli-archive-keyring.gpg"
readonly GH_LIST="/etc/apt/sources.list.d/github-cli.list"
# oh-my-openagent 安装平台：both（默认）、opencode、codex
readonly OMO_PLATFORM="${OMO_PLATFORM:-both}"
readonly BUN_DIR="${BUN_DIR:-$HOME/.bun}"
# superpowers 插件说明符
readonly SUPERPOWERS_OPENCODE_SPEC="superpowers@git+https://github.com/obra/superpowers.git"
readonly SUPERPOWERS_CODEX_SELECTOR="superpowers@openai-curated"
# MCP 服务器配置：Context7（远程）、Playwright（本地 stdio）
readonly MCP_CONTEXT7_URL="https://mcp.context7.com/mcp"
readonly MCP_PLAYWRIGHT_SPEC="@playwright/mcp@latest"

# 解析 OpenCode 配置文件路径：优先已存在的 .jsonc / .json，否则默认 .jsonc
opencode_config_file() {
    local dir="$HOME/.config/opencode"
    local candidate
    for candidate in "$dir/opencode.jsonc" "$dir/opencode.json"; do
        if [ -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    printf '%s\n' "$dir/opencode.jsonc"
}

echo "======================================"
echo " Ubuntu/Debian Node.js + npm Development Environment Installer"
echo "======================================"

require_non_root "./scripts/install-nodejs.sh"
require_debian_like
require_sudo "sudo was not found. Install it and grant sudo access to the current user."

apt_get_update_step 1

print_step 2 "Installing base dependencies"
sudo apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    build-essential

print_step 3 "Adding the NodeSource Node.js ${NODE_MAJOR}.x repository"

# 单独安装签名密钥并使用 signed-by 限制密钥作用范围
sudo install -d -m 0755 "$KEYRING_DIR"
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor \
    | sudo tee "$NODESOURCE_KEYRING" >/dev/null
sudo chmod 0644 "$NODESOURCE_KEYRING"
echo "deb [signed-by=${NODESOURCE_KEYRING}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    | sudo tee "$NODESOURCE_LIST" >/dev/null
sudo apt-get update

print_step 4 "Installing Node.js"
sudo apt-get install -y nodejs

print_step 5 "Configuring the user-level npm global directory"
mkdir -p "$NPM_DIR"
npm config set prefix "$NPM_DIR"

SHELL_RC="$(select_shell_rc)"

if [ "$NPM_DIR" = "$HOME/.local/npm" ]; then
    readonly PATH_LINE='export PATH="$HOME/.local/npm/bin:$PATH"'
else
    readonly PATH_LINE="export PATH=\"${NPM_DIR}/bin:\$PATH\""
fi
touch "$SHELL_RC"
if ! grep -Fqx "$PATH_LINE" "$SHELL_RC"; then
    {
        echo
        echo '# npm 全局命令'
        echo "$PATH_LINE"
    } >>"$SHELL_RC"
fi

export PATH="$NPM_DIR/bin:$PATH"
echo "Shell configuration file: $SHELL_RC"

print_step 6 "Configuring npm"
npm config set registry "$NPM_REGISTRY"
echo "npm registry: $NPM_REGISTRY"

print_step 7 "Installing development and AI CLI tools"
npm install -g "npm@${NPM_VERSION}"
# 仅允许确实需要生命周期脚本的包执行安装脚本（@ast-grep/cli 的 postinstall 用于放置原生二进制）
npm install -g --allow-scripts=opencode-ai,yarn,@ast-grep/cli \
    pnpm \
    yarn \
    typescript \
    eslint \
    prettier \
    @openai/codex \
    opencode-ai \
    @ast-grep/cli

print_step 8 "Checking the environment"
printf 'Node:       '; node -v
printf 'npm:        '; npm -v
printf 'npm prefix: '; npm config get prefix
printf 'npm root:   '; npm root -g
printf 'pnpm:       '; pnpm --version
printf 'yarn:       '; yarn --version
printf 'TypeScript: '; tsc --version
printf 'ESLint:     '; eslint --version
printf 'Prettier:   '; prettier --version
printf 'Codex:      '; codex --version || true
printf 'OpenCode:   '; opencode --version || true
printf 'ast-grep:   '; sg --version || true

# ── oh-my-openagent ──────────────────────────────────────────────
# 安装在 Node.js/npm 之后，OpenCode 与 Codex CLI 此时均已就绪。
# 组件名之后的参数（如 --no-tui --claude=max20）原样透传给官方安装器。

omo_needs_bun=false
case "$OMO_PLATFORM" in
    opencode|both) omo_needs_bun=true ;;
    codex)         ;;
    *)
        echo "Invalid OMO_PLATFORM: $OMO_PLATFORM (expected opencode, codex, or both)" >&2
        exit 1
        ;;
esac

bun_bin=""
if [ "$omo_needs_bun" = "true" ]; then
    print_step 9 "Ensuring Bun is available for oh-my-openagent"
    if command -v bun >/dev/null 2>&1; then
        bun_bin="$(command -v bun)"
    elif [ -x "$BUN_DIR/bin/bun" ]; then
        bun_bin="$BUN_DIR/bin/bun"
    else
        echo "Bun not found; installing via the official installer."
        curl -fsSL https://bun.sh/install | bash
        bun_bin="$BUN_DIR/bin/bun"
    fi
    # 把 bun 加入当前进程 PATH，使 oh-my-openagent 子进程能 spawnSync 到 bun
    # （否则会回退到 node CLI 入口，导致 ast-grep 等 skill 的 provisioning 被跳过）
    case ":${PATH:-}:" in
        *":$BUN_DIR/bin:"*) ;;
        *) export PATH="$BUN_DIR/bin:${PATH:-}" ;;
    esac
    printf 'Bun:        %s\n' "$("$bun_bin" --version)"
fi

print_step 10 "Installing oh-my-openagent ($OMO_PLATFORM edition)"
# 让 oh-my-openagent 直接用已装的 sg，避免其内置 provisioning 因上游路径 bug 失败
if [ -x "$NPM_DIR/bin/sg" ]; then
    export OMO_AST_GREP_SG_PATH="$NPM_DIR/bin/sg"
fi
# 组件名之后的参数（如 --claude=max20）原样透传给官方安装器，后出现的同名参数生效。
# 非交互默认订阅：智谱 Z.ai Coding Plan（GLM）；claude/gemini/copilot 为 --no-tui 必填项，全 no。
case "$OMO_PLATFORM" in
    opencode|both)
        "$bun_bin" x oh-my-openagent install --platform="$OMO_PLATFORM" \
            --no-tui \
            --claude=no --gemini=no --copilot=no \
            --zai-coding-plan=yes \
            --skip-auth \
            "$@"
        ;;
    codex)
        npx --yes lazycodex-ai install "$@"
        ;;
esac

# 安装器写错 provider 前缀（zai- 应为 zhipuai-）且默认兜底到不可用的 opencode/gpt-5-nano，故统一覆盖：GLM-5.2 主、DeepSeek V4 Pro 备。
omo_config="$HOME/.config/opencode/oh-my-openagent.json"
[ -f "$omo_config" ] || omo_config="$HOME/.config/opencode/oh-my-openagent.jsonc"
if [ -f "$omo_config" ]; then
    node - "$omo_config" "${OMO_MODEL:-zhipuai-coding-plan/glm-5.2}" "${OMO_FALLBACK_MODEL:-deepseek/deepseek-v4-pro}" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
const model = process.argv[3];
const fallback = process.argv[4];

function stripJsonc(s) {
    let out = '', i = 0, inStr = false, strCh = '';
    while (i < s.length) {
        const c = s[i], next = s[i + 1];
        if (inStr) {
            out += c;
            if (c === '\\') { out += (next ?? ''); i += 2; continue; }
            if (c === strCh) inStr = false;
            i += 1; continue;
        }
        if (c === '"' || c === "'") { inStr = true; strCh = c; out += c; i += 1; continue; }
        if (c === '/' && next === '/') { while (i < s.length && s[i] !== '\n') i++; continue; }
        if (c === '/' && next === '*') { i += 2; while (i < s.length && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; continue; }
        out += c; i += 1;
    }
    return out;
}

const obj = JSON.parse(stripJsonc(fs.readFileSync(path, 'utf8')));
let n = 0;
for (const sect of ['agents', 'categories']) {
    if (obj[sect] && typeof obj[sect] === 'object') {
        for (const a of Object.values(obj[sect])) {
            if (a && typeof a === 'object') {
                a.model = model;
                a.fallback_models = [fallback];
                n += 1;
            }
        }
    }
}
fs.writeFileSync(path, JSON.stringify(obj, null, 2) + '\n');
console.log(`Overrode ${n} agent/category models -> ${model} (fallback: ${fallback})`);
NODE
fi

print_step 11 "Installing GitHub CLI (gh)"
# GitHub CLI 的 apt 源（官方 keyring 已是 gpg 二进制，无需 dearmor）
sudo install -d -m 0755 "$KEYRING_DIR"
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee "$GH_KEYRING" >/dev/null
sudo chmod 0644 "$GH_KEYRING"
echo "deb [arch=$(dpkg --print-architecture) signed-by=${GH_KEYRING}] https://cli.github.com/packages stable main" \
    | sudo tee "$GH_LIST" >/dev/null
sudo apt-get update
sudo apt-get install -y gh
printf 'gh:         %s\n' "$(gh --version | head -1)"

print_step 12 "Checking oh-my-openagent"
if [ "$omo_needs_bun" = "true" ]; then
    "$bun_bin" x oh-my-openagent doctor || true
fi
printf 'Platform:   %s\n' "$OMO_PLATFORM"

# ── superpowers ──────────────────────────────────────────────────
# obra/superpowers：与 oh-my-openagent 同样按 OMO_PLATFORM 安装到对应平台。

print_step 13 "Installing superpowers ($OMO_PLATFORM edition)"

if [ "$OMO_PLATFORM" = "opencode" ] || [ "$OMO_PLATFORM" = "both" ]; then
    # OpenCode：把插件说明符加入 opencode 配置的 plugin 数组（不存在则创建）
    config_file="$(opencode_config_file)"
    mkdir -p "$(dirname "$config_file")"

    node - "$config_file" "$SUPERPOWERS_OPENCODE_SPEC" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
const spec = process.argv[3];

// 字符串感知的 JSONC 注释剥离，避免误伤 URL 中的 "//"
function stripJsonc(s) {
    let out = '';
    let i = 0;
    let inStr = false;
    let strCh = '';
    while (i < s.length) {
        const c = s[i];
        const next = s[i + 1];
        if (inStr) {
            out += c;
            if (c === '\\') { out += (next ?? ''); i += 2; continue; }
            if (c === strCh) inStr = false;
            i += 1;
            continue;
        }
        if (c === '"' || c === "'") { inStr = true; strCh = c; out += c; i += 1; continue; }
        if (c === '/' && next === '/') { while (i < s.length && s[i] !== '\n') i++; continue; }
        if (c === '/' && next === '*') { i += 2; while (i < s.length && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; continue; }
        out += c;
        i += 1;
    }
    return out;
}

let raw = '{}';
try { raw = fs.readFileSync(path, 'utf8'); } catch (e) { /* 文件不存在 */ }
let obj;
try {
    obj = JSON.parse(stripJsonc(raw));
} catch (e) {
    console.error(`Failed to parse ${path} as JSON/JSONC: ${e.message}`);
    process.exit(1);
}
if (typeof obj !== 'object' || obj === null) obj = {};
if (!Array.isArray(obj.plugin)) obj.plugin = [];
if (!obj.plugin.includes(spec)) {
    obj.plugin.push(spec);
    fs.writeFileSync(path, JSON.stringify(obj, null, 2) + '\n');
    console.log(`Added "${spec}" to ${path}`);
} else {
    console.log(`"${spec}" already present in ${path}`);
}
NODE
fi

if [ "$OMO_PLATFORM" = "codex" ] || [ "$OMO_PLATFORM" = "both" ]; then
    # Codex CLI：从默认 openai-curated 市场安装 superpowers
    # 状态列为第二列（"installed" 或 "not"）；用 awk 精确判断，避免误匹配 "not installed"
    if codex plugin list 2>/dev/null | awk '$1=="superpowers@openai-curated" && $2=="installed"{found=1} END{exit !found}'; then
        echo "superpowers already installed for Codex CLI; skipping."
    else
        codex plugin add "$SUPERPOWERS_CODEX_SELECTOR"
    fi
fi

# ── MCP 服务器：Context7 / Playwright ─────────────────────────────
# Context7、Playwright 均无需鉴权。

print_step 14 "Installing MCP servers: Context7 / Playwright ($OMO_PLATFORM edition)"

if [ "$OMO_PLATFORM" = "opencode" ] || [ "$OMO_PLATFORM" = "both" ]; then
    # OpenCode：写入 opencode.json[c] 的 mcp 段（仅新增缺失项，不覆盖已有配置）
    config_file="$(opencode_config_file)"
    mkdir -p "$(dirname "$config_file")"

    node - "$config_file" "$MCP_CONTEXT7_URL" "$MCP_PLAYWRIGHT_SPEC" <<'NODE'
const fs = require('fs');
const path = process.argv[2];
const context7Url = process.argv[3];
const playwrightSpec = process.argv[4];

// 字符串感知的 JSONC 注释剥离，避免误伤 URL 中的 "//"
function stripJsonc(s) {
    let out = '';
    let i = 0;
    let inStr = false;
    let strCh = '';
    while (i < s.length) {
        const c = s[i];
        const next = s[i + 1];
        if (inStr) {
            out += c;
            if (c === '\\') { out += (next ?? ''); i += 2; continue; }
            if (c === strCh) inStr = false;
            i += 1;
            continue;
        }
        if (c === '"' || c === "'") { inStr = true; strCh = c; out += c; i += 1; continue; }
        if (c === '/' && next === '/') { while (i < s.length && s[i] !== '\n') i++; continue; }
        if (c === '/' && next === '*') { i += 2; while (i < s.length && !(s[i] === '*' && s[i + 1] === '/')) i++; i += 2; continue; }
        out += c;
        i += 1;
    }
    return out;
}

let raw = '{}';
try { raw = fs.readFileSync(path, 'utf8'); } catch (e) { /* 文件不存在 */ }
let obj;
try {
    obj = JSON.parse(stripJsonc(raw));
} catch (e) {
    console.error(`Failed to parse ${path} as JSON/JSONC: ${e.message}`);
    process.exit(1);
}
if (typeof obj !== 'object' || obj === null) obj = {};
if (typeof obj.mcp !== 'object' || obj.mcp === null) obj.mcp = {};

// 期望的两项配置
const desired = {
    context7: { type: 'remote', url: context7Url, enabled: true },
    playwright: { type: 'local', command: ['npx', '-y', playwrightSpec], enabled: true },
};

let changed = false;
for (const [name, entry] of Object.entries(desired)) {
    // 仅新增缺失的服务器；已存在则保留用户配置（可能已自定义 URL 或禁用）
    if (!(name in obj.mcp)) {
        obj.mcp[name] = entry;
        changed = true;
        console.log(`- mcp.${name}`);
    }
}
if (changed) {
    fs.writeFileSync(path, JSON.stringify(obj, null, 2) + '\n');
    console.log(`Updated MCP servers in ${path}`);
} else {
    console.log(`MCP servers already configured in ${path}`);
}
NODE
fi

if [ "$OMO_PLATFORM" = "codex" ] || [ "$OMO_PLATFORM" = "both" ]; then
    # Codex CLI：用 codex mcp add 注册；codex mcp get 返回非零表示尚未配置
    codex mcp get context7 >/dev/null 2>&1 \
        || codex mcp add context7 --url "$MCP_CONTEXT7_URL"
    codex mcp get playwright >/dev/null 2>&1 \
        || codex mcp add playwright -- npx -y "$MCP_PLAYWRIGHT_SPEC"
fi

echo
echo "======================================"
echo "Installation complete"
echo "======================================"
