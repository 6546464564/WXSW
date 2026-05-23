#!/bin/bash
# 万象书屋 Monkey 测试 — 模拟器版
#
# 用法:
#   ./scripts/run-monkey-simulator.sh                      # 默认使用 iPhone 17 Pro (iOS 26.5)
#   ./scripts/run-monkey-simulator.sh <SIMULATOR_UDID>     # 指定模拟器
#   MONKEY_DURATION=5 ./scripts/run-monkey-simulator.sh    # 仅跑 5 分钟
#   MONKEY_TEST=quick ./scripts/run-monkey-simulator.sh    # 快速模式 (MonkeyTest, 5 分钟)
#
# 环境变量:
#   MONKEY_TEST             quick | stability (默认 quick)
#   MONKEY_DURATION         测试时长(分钟), quick 默认 720, stability 默认 720
#   MONKEY_THROTTLE         操作间隔(ms), 默认 500
#   MONKEY_SCREENSHOT_INTERVAL  截图间隔(秒), 默认 60

set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${MONKEY_TEST:-quick}
THROTTLE=${MONKEY_THROTTLE:-500}
SCREENSHOT_INTERVAL=${MONKEY_SCREENSHOT_INTERVAL:-60}

if [ "$MODE" = "stability" ]; then
    DURATION=${MONKEY_DURATION:-720}
    TEST_TARGET="WanxiangUITests/MonkeyStabilityTest/testMonkeyRun"
else
    DURATION=${MONKEY_DURATION:-720}
    TEST_TARGET="WanxiangUITests/MonkeyTest/testFastbotTraversal"
fi

SIM_UDID=${1:-$(xcrun simctl list devices available | grep "iPhone 17 Pro " | grep -oE '[A-F0-9-]{36}' | tail -1)}

if [ -z "$SIM_UDID" ]; then
    echo "❌ 未找到可用的 iOS 模拟器"
    echo "   可用模拟器: xcrun simctl list devices available"
    exit 1
fi

SIM_NAME=$(xcrun simctl list devices | grep "$SIM_UDID" | sed 's/(.*//' | xargs)

LOG_DIR="/tmp/monkey_sim_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

echo "🐵 万象书屋 Monkey 测试 (模拟器)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   模式: $MODE"
echo "   模拟器: $SIM_NAME ($SIM_UDID)"
echo "   测试时长: ${DURATION} 分钟"
echo "   操作间隔: ${THROTTLE}ms"
echo "   截图间隔: ${SCREENSHOT_INTERVAL}s"
echo "   日志目录: $LOG_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 确保模拟器已启动
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
open -a Simulator

echo "📱 开始构建并运行..."
echo ""

MONKEY_DURATION=$DURATION \
MONKEY_THROTTLE=$THROTTLE \
MONKEY_SCREENSHOT_INTERVAL=$SCREENSHOT_INTERVAL \
xcodebuild test \
    -project WanxiangBook.xcodeproj \
    -scheme WanxiangBook \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -only-testing:"$TEST_TARGET" \
    -allowProvisioningUpdates \
    -derivedDataPath "$LOG_DIR/DerivedData" \
    -resultBundlePath "$LOG_DIR/result.xcresult" \
    2>&1 | tee "$LOG_DIR/xcodebuild.log"

EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

grep -o '\[Monkey\].*' "$LOG_DIR/xcodebuild.log" 2>/dev/null | tail -5 || true

exit $EXIT_CODE
