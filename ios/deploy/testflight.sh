#!/bin/bash
# ===========================================================
# 万象书屋 iOS · 一键发布到 TestFlight
# 用法: bash ios/deploy/testflight.sh [--version 1.0.1]
# ===========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$SCRIPT_DIR/project.yml"
XCODEPROJ="$SCRIPT_DIR/WanxiangBook.xcodeproj"
BUILD_DIR="$SCRIPT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/WanxiangBook.xcarchive"
EXPORT_PATH="$BUILD_DIR/ipa-release"
EXPORT_OPTS="$BUILD_DIR/ExportOptions-upload.plist"
TEAM_ID="6UX5G5838X"
SCHEME="WanxiangBook"

# ── 参数解析 ─────────────────────────────────────────────
NEW_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) NEW_VERSION="$2"; shift 2;;
        *) echo "未知参数: $1"; exit 1;;
    esac
done

echo "╔══════════════════════════════════════╗"
echo "║  万象书屋 iOS · TestFlight 发布脚本  ║"
echo "╚══════════════════════════════════════╝"

# ── Step 1: 更新版本号 ───────────────────────────────────
CURRENT_BUILD=$(grep 'CFBundleVersion:' "$PROJECT_YML" | head -1 | sed 's/.*"\(.*\)".*/\1/')
DATE_PREFIX=$(date +"%Y%m%d")

# 自动计算新 Build 号: 日期前缀 + 序号（今天第几次发布）
if [[ "$CURRENT_BUILD" == ${DATE_PREFIX}* ]]; then
    # 同一天: 取末尾序号 +1
    SUFFIX="${CURRENT_BUILD#${DATE_PREFIX}}"
    SUFFIX="${SUFFIX#.}"
    NEXT_SUFFIX=$(( ${SUFFIX:-0} + 1 ))
    NEW_BUILD="${DATE_PREFIX}.${NEXT_SUFFIX}"
else
    # 新的一天: 从 1 开始
    NEW_BUILD="${DATE_PREFIX}.1"
fi

if [[ -n "$NEW_VERSION" ]]; then
    echo ">>> 版本号: $NEW_VERSION (Build $NEW_BUILD)"
    sed -i '' "s/CFBundleShortVersionString: \".*\"/CFBundleShortVersionString: \"$NEW_VERSION\"/" "$PROJECT_YML"
else
    CURRENT_VERSION=$(grep 'CFBundleShortVersionString:' "$PROJECT_YML" | head -1 | sed 's/.*"\(.*\)".*/\1/')
    NEW_VERSION="$CURRENT_VERSION"
    echo ">>> 版本号: $NEW_VERSION (Build $NEW_BUILD)"
fi

sed -i '' "s/CFBundleVersion: \".*\"/CFBundleVersion: \"$NEW_BUILD\"/" "$PROJECT_YML"

# ── Step 2: 重新生成 Xcode 项目 ──────────────────────────
echo ">>> 生成 Xcode 项目..."
cd "$SCRIPT_DIR"
xcodegen generate --quiet

# ── Step 3: 确保 ExportOptions 存在 ─────────────────────
mkdir -p "$BUILD_DIR"
cat > "$EXPORT_OPTS" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>6UX5G5838X</string>
    <key>uploadSymbols</key>
    <true/>
    <key>compileBitcode</key>
    <false/>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>upload</string>
</dict>
</plist>
PLIST

# ── Step 4: Archive ──────────────────────────────────────
echo ">>> 归档 (Archive)..."
rm -rf "$ARCHIVE_PATH"
xcodebuild archive \
    -project "$XCODEPROJ" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    -allowProvisioningUpdates \
    -quiet
echo "    Archive 完成: $ARCHIVE_PATH"

# ── Step 5: Upload (带重试) ──────────────────────────────
echo ">>> 上传到 TestFlight..."
rm -rf "$EXPORT_PATH"

UPLOAD_SUCCESS=false
for attempt in 1 2 3; do
    echo "    第 $attempt 次尝试..."
    set +e
    OUTPUT=$(xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTS" \
        -allowProvisioningUpdates \
        2>&1)
    EXIT_CODE=$?
    set -e

    if echo "$OUTPUT" | grep -q "EXPORT SUCCEEDED"; then
        UPLOAD_SUCCESS=true
        echo "    ✅ 上传成功"
        break
    elif echo "$OUTPUT" | grep -q "Redundant Binary Upload"; then
        # Build 已存在 = 之前某次上传已成功（超时后服务端已收到）
        UPLOAD_SUCCESS=true
        echo "    ✅ 该 Build 已在 App Store Connect 上存在（之前上传已成功）"
        break
    else
        echo "    ❌ 失败，等待 15 秒后重试..."
        echo "$OUTPUT" | grep -E "error:|timed out|FAILED" | head -3 || true
        sleep 15
    fi
done

if [[ "$UPLOAD_SUCCESS" == false ]]; then
    echo "❌ 三次尝试均失败，请检查网络或手动通过 Xcode Organizer 上传"
    exit 1
fi

# ── Step 6: 提交版本号变更 ───────────────────────────────
echo ">>> 提交版本号到 Git..."
cd "$(dirname "$SCRIPT_DIR")"  # 跳到仓库根目录
git add "ios/project.yml" "ios/WanxiangBook.xcodeproj/project.pbxproj" 2>/dev/null || true
git commit -m "chore(ios): release v${NEW_VERSION} (build ${NEW_BUILD}) to TestFlight" 2>/dev/null || true
git push origin main 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  🎉 TestFlight 发布完成!                          ║"
printf "║  版本: %-40s ║\n" "${NEW_VERSION} (Build ${NEW_BUILD})"
echo "║  苹果审核完成后测试员即可收到推送                 ║"
echo "╚══════════════════════════════════════════════════╝"
