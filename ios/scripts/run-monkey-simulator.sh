#!/bin/bash
# 万象书屋 Fastbot 智能遍历测试 — 模拟器自动重启版
#
# 用法:
#   ./scripts/run-monkey-simulator.sh                      # 默认 iPhone 17 Pro (iOS 26.5)
#   ./scripts/run-monkey-simulator.sh <SIMULATOR_UDID>     # 指定模拟器
#   MONKEY_DURATION=5 ./scripts/run-monkey-simulator.sh    # 仅跑 5 分钟
#   MONKEY_TEST=stability ./scripts/run-monkey-simulator.sh
#
# 环境变量:
#   MONKEY_TEST             quick | stability (默认 quick)
#   MONKEY_DURATION         总测试时长(分钟), 默认 720
#   MONKEY_THROTTLE         操作间隔(ms), 默认 400
#   MONKEY_SCREENSHOT_INTERVAL  截图间隔(秒), 默认 60
#   RUN_DURATION            每轮时长(分钟), 默认 60

set -uo pipefail
cd "$(dirname "$0")/.."

MODE=${MONKEY_TEST:-quick}
THROTTLE=${MONKEY_THROTTLE:-400}
SCREENSHOT_INTERVAL=${MONKEY_SCREENSHOT_INTERVAL:-60}
TOTAL_DURATION=${MONKEY_DURATION:-720}
RUN_DURATION=${RUN_DURATION:-60}

if [ "$MODE" = "stability" ]; then
    TEST_TARGET="WanxiangUITests/MonkeyStabilityTest/testMonkeyRun"
else
    TEST_TARGET="WanxiangUITests/MonkeyTest/testFastbotTraversal"
fi

SIM_UDID=${1:-$(xcrun simctl list devices available | grep "iPhone 17 Pro " | grep -oE '[A-F0-9-]{36}' | tail -1)}

if [ -z "$SIM_UDID" ]; then
    echo "❌ 未找到可用的 iOS 模拟器"
    echo "   可用模拟器: xcrun simctl list devices available"
    exit 1
fi

SIM_NAME=$(xcrun simctl list devices | grep "$SIM_UDID" | sed 's/(.*//' | xargs)

LOG_BASE="/tmp/fastbot_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_BASE"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   🤖 Fastbot 智能遍历测试 (模拟器版)    ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  模式:       $MODE"
echo "  测试目标:   $TEST_TARGET"
echo "  模拟器:     $SIM_NAME ($SIM_UDID)"
echo "  总时长:     ${TOTAL_DURATION} 分钟"
echo "  每轮时长:   ${RUN_DURATION} 分钟"
echo "  操作间隔:   ${THROTTLE}ms"
echo "  日志目录:   $LOG_BASE/"
echo ""
echo "──────────────────────────────────────────"
echo ""

xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
open -a Simulator

START_TS=$(date +%s)
END_TS=$((START_TS + TOTAL_DURATION * 60))
RUN_COUNT=0
TOTAL_CRASHES=0
TOTAL_ACTIONS=0
TOTAL_SCREENS=0

while [ "$(date +%s)" -lt "$END_TS" ]; do
    RUN_COUNT=$((RUN_COUNT + 1))
    REMAINING_MIN=$(( (END_TS - $(date +%s)) / 60 ))
    DURATION=$((REMAINING_MIN < RUN_DURATION ? REMAINING_MIN : RUN_DURATION))

    if [ "$DURATION" -le 0 ]; then break; fi

    RESULT_DIR="$LOG_BASE/run_${RUN_COUNT}"
    mkdir -p "$RESULT_DIR"

    echo ""
    echo "╔═══════════════════════════════════════╗"
    echo "║  🔄 第 $RUN_COUNT 轮 | 剩余 ${REMAINING_MIN}m | 本轮 ${DURATION}m"
    echo "╚═══════════════════════════════════════╝"
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
        -derivedDataPath "$LOG_BASE/DerivedData" \
        -resultBundlePath "$RESULT_DIR/result.xcresult" \
        2>&1 | tee "$RESULT_DIR/xcodebuild.log" | grep -E "\[Monkey\]|error:|TEST (SUCCEEDED|FAILED)|crash|STUCK|memory" || true

    EXIT_CODE=${PIPESTATUS[0]}

    ACTIONS_IN_RUN=$(grep -oP 'actions=\K[0-9]+' "$RESULT_DIR/xcodebuild.log" 2>/dev/null | tail -1 || echo "0")
    SCREENS_IN_RUN=$(grep -oP 'screens=\K[0-9]+' "$RESULT_DIR/xcodebuild.log" 2>/dev/null | tail -1 || echo "0")
    CRASHES_IN_RUN=$(grep -c "crash #" "$RESULT_DIR/xcodebuild.log" 2>/dev/null || echo "0")
    STUCKS_IN_RUN=$(grep -c "STUCK" "$RESULT_DIR/xcodebuild.log" 2>/dev/null || echo "0")
    PEAK_MEM=$(grep -oP 'peak_mem=\K[0-9.]+' "$RESULT_DIR/xcodebuild.log" 2>/dev/null | tail -1 || echo "?")

    TOTAL_ACTIONS=$((TOTAL_ACTIONS + ${ACTIONS_IN_RUN:-0}))
    TOTAL_SCREENS=$((TOTAL_SCREENS > ${SCREENS_IN_RUN:-0} ? TOTAL_SCREENS : ${SCREENS_IN_RUN:-0}))

    echo ""
    echo "  ──────────────────────────────────"
    if [ $EXIT_CODE -eq 0 ]; then
        echo "  ✅ 第 $RUN_COUNT 轮完成"
    else
        TOTAL_CRASHES=$((TOTAL_CRASHES + 1))
        echo "  ⚠️  第 $RUN_COUNT 轮异常退出 (exit=$EXIT_CODE)"
        echo "     3秒后自动重启下一轮..."
        sleep 3
    fi
    echo "  📊 操作: $ACTIONS_IN_RUN | 页面: $SCREENS_IN_RUN | 崩溃恢复: $CRASHES_IN_RUN | 卡死: $STUCKS_IN_RUN | 峰值内存: ${PEAK_MEM}MB"
    echo "  ──────────────────────────────────"
done

ELAPSED_MIN=$(( ($(date +%s) - START_TS) / 60 ))

echo ""
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          📊 Fastbot 测试总结             ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  总轮数:         $RUN_COUNT"
echo "  总操作数:       $TOTAL_ACTIONS"
echo "  发现页面数:     $TOTAL_SCREENS"
echo "  测试终止次数:   $TOTAL_CRASHES"
echo "  总运行时长:     ${ELAPSED_MIN} 分钟"
echo "  日志目录:       $LOG_BASE/"
echo ""
echo "  各轮详情:"
echo "  ─────────────────────────────────"
for d in "$LOG_BASE"/run_*/; do
    [ -d "$d" ] || continue
    RN=$(basename "$d" | sed 's/run_//')
    RESULT="✅"
    grep -q "TEST FAILED" "$d/xcodebuild.log" 2>/dev/null && RESULT="⚠️"
    ACTS=$(grep -oP 'actions=\K[0-9]+' "$d/xcodebuild.log" 2>/dev/null | tail -1 || echo "?")
    SCRNS=$(grep -oP 'screens=\K[0-9]+' "$d/xcodebuild.log" 2>/dev/null | tail -1 || echo "?")
    echo "    第${RN}轮: $RESULT  actions=$ACTS  screens=$SCRNS"
done
echo "  ─────────────────────────────────"
echo ""

if [ -f "$LOG_BASE/run_${RUN_COUNT}/result.xcresult" ]; then
    echo "  💡 查看最后一轮详细报告:"
    echo "     xcresulttool get --path $LOG_BASE/run_${RUN_COUNT}/result.xcresult --format json"
fi
echo ""
