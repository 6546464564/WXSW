#!/usr/bin/env bash
# ============================================================
# 万象书屋: Mac 端一键解压 + 装环境 + 验证
# ============================================================
#
# 用法:
#   把 wxsw-mac-migration/ 整个目录传到 Mac 任意位置 (建议 ~/Downloads/),
#   然后:
#     cd ~/Downloads/wxsw-mac-migration
#     bash setup-mac.sh
#
#   每个大步骤都会问 [Y/n], 默认 Y. 全程幂等, 重跑安全.
#
# 选项:
#   --yes        全自动, 不问任何问题 (危险, 慎用)
#   --skip-brew  跳过 Homebrew/工具安装
#   --skip-build 跳过最后的 gradle/npm 验证
#   --target DIR 指定项目解压目录 (默认 ~/Desktop/wxsw)
# ============================================================

set -euo pipefail

# ---------- 颜色 / 工具函数 ----------
if [[ -t 1 ]]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_C=$'\033[36m'; C_B=$'\033[1m'; C_N=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_C=""; C_B=""; C_N=""
fi

step()  { echo; echo "${C_C}${C_B}==> $*${C_N}"; }
ok()    { echo "    ${C_G}[OK]${C_N} $*"; }
warn()  { echo "    ${C_Y}[!] ${C_N} $*"; }
err()   { echo "    ${C_R}[X] ${C_N} $*" >&2; }
ask()   {
  # ask "提示" -> 返回 0 (Y) 或 1 (N)
  local prompt="$1"
  if [[ "$AUTO_YES" == "1" ]]; then
    echo "    [自动] $prompt -> Y"
    return 0
  fi
  read -r -p "    $prompt [Y/n] " ans
  [[ -z "$ans" || "$ans" == "y" || "$ans" == "Y" ]]
}

# ---------- 解析参数 ----------
AUTO_YES=0
SKIP_BREW=0
SKIP_BUILD=0
TARGET="$HOME/Desktop/wxsw"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)     AUTO_YES=1;       shift ;;
    --skip-brew)  SKIP_BREW=1;      shift ;;
    --skip-build) SKIP_BUILD=1;     shift ;;
    --target)     TARGET="$2";      shift 2 ;;
    -h|--help)
      sed -n '2,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

PKG_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PKG_DIR"

cat <<EOF
${C_C}${C_B}
╔══════════════════════════════════════════════╗
║  万象书屋 · Mac 一键迁移                      ║
║  $(date '+%Y-%m-%d %H:%M:%S')                              ║
╚══════════════════════════════════════════════╝${C_N}

包目录: $PKG_DIR
目标:   $TARGET
EOF

# ---------- 0. 环境检测 ----------
step "0. 检测 macOS 环境"
MACOS_VER=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
ARCH=$(uname -m)
echo "    macOS:    $MACOS_VER"
echo "    arch:     $ARCH (Apple Silicon=arm64, Intel=x86_64)"
[[ "$ARCH" == "arm64" || "$ARCH" == "x86_64" ]] || { err "未知架构: $ARCH"; exit 1; }

# 必备工具
for tool in tar shasum curl; do
  command -v "$tool" >/dev/null || { err "缺少 $tool, 请装 Xcode 命令行工具: xcode-select --install"; exit 1; }
done
ok "macOS + 基础工具齐"

# ---------- 1. 校验 SHA256 ----------
step "1. 校验包完整性 (SHA256)"
if [[ ! -f SHA256SUMS.txt ]]; then
  warn "没找到 SHA256SUMS.txt, 跳过校验"
else
  if shasum -a 256 -c SHA256SUMS.txt 2>/dev/null; then
    ok "三个 tar.gz 全部校验通过"
  else
    err "校验失败! 文件可能传输损坏, 请重新传"
    if ! ask "继续? (不建议)"; then exit 1; fi
  fi
fi

# ---------- 2. 解压代码 ----------
step "2. 解压项目代码"
if [[ ! -f code-snapshot.tar.gz ]]; then
  err "没找到 code-snapshot.tar.gz"
  exit 1
fi

if [[ -d "$TARGET/WXSW" ]]; then
  warn "$TARGET/WXSW 已存在"
  if ask "覆盖? (会先备份成 WXSW.bak.\$timestamp)"; then
    mv "$TARGET/WXSW" "$TARGET/WXSW.bak.$(date +%s)"
  else
    echo "    跳过解压"
    SKIP_EXTRACT=1
  fi
fi

if [[ "${SKIP_EXTRACT:-0}" != "1" ]]; then
  mkdir -p "$TARGET"
  echo "    解压中 (大文件几十秒)..."
  tar xzf code-snapshot.tar.gz -C "$TARGET"
  ok "解压完成 -> $TARGET/WXSW"
fi

PROJECT="$TARGET/WXSW"

# ---------- 3. 解压 Cursor 历史 (备份位置, 不动 Cursor) ----------
step "3. 解压 Cursor 聊天历史 (作为档案备份)"
if [[ -f cursor-history.tar.gz ]]; then
  CURSOR_BAK="$HOME/Desktop/wxsw-cursor-history-backup"
  mkdir -p "$CURSOR_BAK"
  tar xzf cursor-history.tar.gz -C "$CURSOR_BAK"
  ok "Cursor 历史 -> $CURSOR_BAK"
  echo "    用 VS Code/Cursor 打开 .jsonl 文件可查阅"
  echo "    详见 $CURSOR_BAK/cursor-history/README.md (如何尝试恢复进 Cursor)"
else
  warn "没找到 cursor-history.tar.gz, 跳过"
fi

# ---------- 4. 解压 secrets ----------
step "4. 解压敏感文件 (secrets)"
if [[ -f secrets.tar.gz ]]; then
  SEC_TMP="$(mktemp -d)/secrets-staging"
  mkdir -p "$SEC_TMP"
  tar xzf secrets.tar.gz -C "$SEC_TMP"
  ok "secrets 已解到临时目录: $SEC_TMP"
  echo "    ${C_Y}请按 $SEC_TMP/secrets/README.md 把每个文件放回 $PROJECT/ 内对应位置${C_N}"
  echo "    用完手动删: rm -rf \"$(dirname "$SEC_TMP")\""
else
  warn "没找到 secrets.tar.gz (项目密钥已在 code 包里, 这步可跳)"
fi

# ---------- 5. Homebrew + 工具链 ----------
# 关键约束: Homebrew 安装 + Cask 安装会调 sudo (写 /opt/homebrew, 拖 .app 到 /Applications),
# 当前会话如果没有 TTY (远程 SSH 非交互 / IDE 集成终端 / 后台执行), sudo 会挂死等密码.
# 我们检测 TTY, 没 TTY 就把命令打印出来让用户去 Terminal.app 自己跑一次, 不在脚本里硬卡住.

# 把"Mac 上要装的工具命令"先写好, 后面要么自己跑要么打印
INSTALL_CMDS_FILE="$PKG_DIR/install-tools.sh"
cat > "$INSTALL_CMDS_FILE" <<'TOOLS'
#!/usr/bin/env bash
# 万象书屋 Mac 工具链安装 (sudo 部分单独跑)
# 用法: 在 Mac 自带的 Terminal.app 里跑 (不要在 IDE 集成终端):
#   bash install-tools.sh
set -e

# 1. Homebrew
if ! command -v brew >/dev/null; then
  echo "==> 装 Homebrew (会要你输入 Mac 登录密码)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Apple Silicon 上 brew 在 /opt/homebrew, 持久化 PATH
  if [[ "$(uname -m)" == "arm64" && -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null || \
      echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
  fi
else
  echo "==> Homebrew 已装"
fi

# 2. JDK 17 (Cask, 需要 sudo 密码)
/usr/libexec/java_home -v 17 >/dev/null 2>&1 || brew install --cask zulu@17

# 3. Node 22 (Formula, 不需要 sudo)
command -v node >/dev/null && node -v 2>/dev/null | grep -q v22 || brew install node@22

# 4. Android Studio (Cask, 需要 sudo)
[[ -d "/Applications/Android Studio.app" ]] || brew install --cask android-studio

# 5. Cursor IDE (Cask, 需要 sudo)
[[ -d "/Applications/Cursor.app" ]] || brew install --cask cursor

echo
echo "==> 工具链装完. 回原来跑 setup-mac.sh 的会话,"
echo "    或者直接重跑: bash setup-mac.sh --skip-brew"
TOOLS
chmod +x "$INSTALL_CMDS_FILE"

if [[ "$SKIP_BREW" == "1" ]]; then
  warn "--skip-brew 跳过工具链安装"
elif [[ ! -t 0 || ! -t 1 ]]; then
  step "5. ⚠️ 工具链安装 (检测到无 TTY, 不能在当前会话跑 sudo)"
  cat <<EOF
    当前会话不是真终端, sudo 拿不到密码会卡死.
    安装工具的命令已经单独写到一个脚本里, 请你:

    ${C_Y}1. 打开 Mac 自带的 ${C_B}Terminal.app${C_N}${C_Y} (Cmd+Space 搜 "终端")${C_N}
    ${C_Y}2. 在 Terminal.app 里跑:${C_N}

       cd "$PKG_DIR"
       bash install-tools.sh

    ${C_Y}3. 装完之后 (5-10 分钟), 回到这个会话或者重跑:${C_N}

       cd "$PKG_DIR"
       bash setup-mac.sh --skip-brew

    跳过工具安装继续后面步骤 (可能编译失败)? 输入 yes 继续, 任意键退出:
EOF
  if [[ "$AUTO_YES" != "1" ]]; then
    read -r resp
    if [[ "$resp" != "yes" ]]; then
      warn "已退出. 在 Terminal.app 装完工具后重跑 setup-mac.sh"
      exit 0
    fi
  fi
  SKIP_BREW=1
else
  step "5. 检测 / 安装 Homebrew + 工具链"

  # 提前 sudo -v 一次, 让密码缓存 5 分钟, 后续 cask 不再问
  if ! sudo -n true 2>/dev/null; then
    echo "    需要管理员密码 (用于 brew 装系统级工具, 5 分钟内不再问)..."
    if ! sudo -v; then
      warn "sudo 失败, 改为用 install-tools.sh 单独跑"
      echo "    在 Terminal.app 里跑: cd \"$PKG_DIR\" && bash install-tools.sh"
      SKIP_BREW=1
    else
      # 后台 keep-alive, 防止安装中途 sudo 缓存过期
      ( while true; do sudo -n true 2>/dev/null; sleep 60; kill -0 $$ 2>/dev/null || exit; done ) &
      SUDO_KEEPALIVE_PID=$!
      trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null || true" EXIT
    fi
  fi

  if [[ "$SKIP_BREW" != "1" ]]; then
    if ! command -v brew >/dev/null; then
      if ask "未检测到 Homebrew, 现在装? (官方安装脚本, 5 分钟)"; then
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [[ "$ARCH" == "arm64" && -x /opt/homebrew/bin/brew ]]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
          grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null || \
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
        fi
      else
        warn "跳过 Homebrew, 后续工具需要你手动装"
        SKIP_BREW=1
      fi
    else
      ok "Homebrew 已存在: $(brew --version | head -1)"
    fi
  fi

  if [[ "$SKIP_BREW" != "1" ]]; then
    install_one() {
      local kind="$1" name="$2" check_cmd="$3" ask_msg="$4"
      if eval "$check_cmd" >/dev/null 2>&1; then
        ok "$name 已安装"
      else
        if ask "$ask_msg"; then
          echo "    brew install $kind $name ..."
          if [[ "$kind" == "--cask" ]]; then
            brew install --cask "$name" || warn "$name 安装失败, 可能已存在或网络问题"
          else
            brew install "$name" || warn "$name 安装失败"
          fi
        fi
      fi
    }

    install_one "--cask" "zulu@17" \
      "/usr/libexec/java_home -v 17" \
      "装 Zulu JDK 17? (Android 编译必需, ~250MB)"

    install_one "" "node@22" \
      "command -v node && node -v | grep -q v22" \
      "装 Node.js 22? (后端 backend/ 需要)"

    install_one "--cask" "android-studio" \
      "test -d /Applications/Android\\ Studio.app" \
      "装 Android Studio? (~1GB, 后续要它装 Android SDK)"

    install_one "--cask" "cursor" \
      "test -d /Applications/Cursor.app" \
      "装 Cursor IDE? (你正在用的编辑器)"
  fi
fi

# ---------- 6. 配 Android SDK 路径 ----------
step "6. Android SDK 路径"
SDK_DEFAULT="$HOME/Library/Android/sdk"
LOCAL_PROP="$PROJECT/android/local.properties"
if [[ -d "$SDK_DEFAULT" ]]; then
  if [[ ! -f "$LOCAL_PROP" ]] || ! grep -q "^sdk.dir=" "$LOCAL_PROP" 2>/dev/null; then
    echo "sdk.dir=$SDK_DEFAULT" > "$LOCAL_PROP"
    ok "已写入 $LOCAL_PROP -> sdk.dir=$SDK_DEFAULT"
  else
    ok "local.properties 已存在并指向 SDK"
  fi
else
  warn "Android SDK 还没装. 第一次开 Android Studio 它会引导你装."
  warn "装完后再回来跑: echo \"sdk.dir=$SDK_DEFAULT\" > \"$LOCAL_PROP\""
fi

# ---------- 7. (可选) 验证 Android 编译 ----------
step "7. 验证 Android 端能编译"
if [[ "$SKIP_BUILD" == "1" ]]; then
  warn "--skip-build 跳过"
elif [[ ! -d "$SDK_DEFAULT" ]]; then
  warn "Android SDK 未装, 跳过编译验证 (装完 Android Studio 后再来)"
elif ! /usr/libexec/java_home -v 17 >/dev/null 2>&1; then
  warn "JDK 17 未装, 跳过编译验证"
elif ask "现在跑一次 ./gradlew :app:assembleAppDebug 验证? (5-10 分钟)"; then
  pushd "$PROJECT/android" >/dev/null
  export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  echo "    JAVA_HOME=$JAVA_HOME"
  if ./gradlew :app:assembleAppDebug --no-daemon -q; then
    APK=$(find app/build/outputs/apk/app/debug -name "*.apk" 2>/dev/null | head -1)
    if [[ -n "$APK" ]]; then
      ok "编译成功! 产物: $APK"
    else
      warn "编译退出 0 但没找到 APK, 检查 android/app/build/outputs/"
    fi
  else
    err "Gradle 构建失败, 看上面的错误日志"
  fi
  popd >/dev/null
fi

# ---------- 8. (可选) 验证后端依赖 ----------
step "8. 验证后端 npm 依赖"
if [[ "$SKIP_BUILD" == "1" ]]; then
  warn "--skip-build 跳过"
elif ! command -v npm >/dev/null; then
  warn "npm 未装, 跳过后端验证"
elif ask "现在跑一次 npm install + 启动验证?"; then
  pushd "$PROJECT/backend" >/dev/null
  if npm install --no-audit --no-fund; then
    ok "依赖安装完成"
    # 跑个 health check (后台启动 5 秒, curl, 杀)
    PORT=3099 node server.js >/tmp/wanxiang-test.log 2>&1 &
    NODE_PID=$!
    sleep 3
    if curl -fsS "http://127.0.0.1:3099/api/health" >/dev/null 2>&1; then
      ok "后端启动 + /api/health 通"
    else
      warn "后端起来了但 health 没响应, 看 /tmp/wanxiang-test.log"
    fi
    kill $NODE_PID 2>/dev/null || true
    wait $NODE_PID 2>/dev/null || true
  else
    err "npm install 失败"
  fi
  popd >/dev/null
fi

# ---------- 9. 结尾摘要 ----------
step "✅ 全部完成! 下一步:"
cat <<EOF

${C_G}项目位置${C_N}        $PROJECT
${C_G}Cursor 历史${C_N}     $HOME/Desktop/wxsw-cursor-history-backup/
${C_G}服务器仍在跑${C_N}     http://104.224.156.240/
${C_G}Admin 后台${C_N}      http://104.224.156.240/admin
${C_G}APK 下载${C_N}        http://104.224.156.240/dl/wanxiang-latest.apk

打开项目:
  open -a "Android Studio" "$PROJECT"
  # 或
  open -a "Cursor" "$PROJECT"

跑 Android 调试 (装好 SDK + AVD 后):
  cd "$PROJECT/android"
  ./gradlew :app:installAppDebug

启动后端本地调试:
  cd "$PROJECT/backend"
  npm start

SSH 到服务器:
  ssh root@104.224.156.240

iOS 工程化 (建议 Flutter 起步):
  brew install --cask flutter
  cd ~/Desktop/wxsw
  flutter create --org com.wanxiang wanxiang_ios
  cd wanxiang_ios && open ios/Runner.xcworkspace

EOF
