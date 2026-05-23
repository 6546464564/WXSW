#!/bin/bash
# 万象书屋 Monkey 稳定性测试 — 真机 12 小时
#
# 用法:
#   ./scripts/run-monkey.sh                          # 使用第一个连接的 iPhone
#   ./scripts/run-monkey.sh <UDID>                   # 指定设备
#   MONKEY_DURATION=60 ./scripts/run-monkey.sh       # 仅跑 1 小时
#
# 环境变量:
#   MONKEY_DURATION        测试时长(分钟), 默认 720 (12h)
#   MONKEY_THROTTLE        操作间隔(ms), 默认 500
#   MONKEY_SCREENSHOT_INTERVAL  截图间隔(秒), 默认 300
#   TEAM_ID                开发者 Team ID, 默认 6UX5G5838X

set -euo pipefail
cd "$(dirname "$0")/.."

DURATION=${MONKEY_DURATION:-720}
THROTTLE=${MONKEY_THROTTLE:-500}
SCREENSHOT_INTERVAL=${MONKEY_SCREENSHOT_INTERVAL:-300}
TEAM_ID=${TEAM_ID:-6UX5G5838X}
UDID=${1:-$(xcrun xctrace list devices 2>/dev/null | grep -i "iphone" | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}

if [ -z "$UDID" ]; then
    echo "❌ 未找到连接的 iPhone。请通过 USB 连接设备或指定 UDID。"
    echo "   可用设备: xcrun xctrace list devices"
    exit 1
fi

LOG_DIR="/tmp/monkey_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

echo "🐵 万象书屋 Monkey 稳定性测试"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   设备 UDID: $UDID"
echo "   测试时长: ${DURATION} 分钟 ($(echo "scale=1; $DURATION/60" | bc)h)"
echo "   操作间隔: ${THROTTLE}ms"
echo "   截图间隔: ${SCREENSHOT_INTERVAL}s"
echo "   日志目录: $LOG_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📱 开始构建并运行..."
echo ""

MONKEY_DURATION=$DURATION \
MONKEY_THROTTLE=$THROTTLE \
MONKEY_SCREENSHOT_INTERVAL=$SCREENSHOT_INTERVAL \
xcodebuild test \
    -project WanxiangBook.xcodeproj \
    -scheme WanxiangBook \
    -destination "platform=iOS,id=$UDID" \
    -only-testing:WanxiangUITests/MonkeyStabilityTest/testMonkeyRun \
    -allowProvisioningUpdates \
    -resultBundlePath "$LOG_DIR/result.xcresult" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    2>&1 | tee "$LOG_DIR/xcodebuild.log"

EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Monkey 测试完成 (无崩溃)"
else
    echo "⚠️  Monkey 测试结束 (exit=$EXIT_CODE，可能有崩溃)"
fi
echo "   结果: $LOG_DIR/result.xcresult"
echo "   日志: $LOG_DIR/xcodebuild.log"
echo ""
echo "📊 查看测试结果:"
echo "   open $LOG_DIR/result.xcresult"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 提取摘要
grep -o '\[Monkey\].*' "$LOG_DIR/xcodebuild.log" | tail -5

exit $EXIT_CODE
