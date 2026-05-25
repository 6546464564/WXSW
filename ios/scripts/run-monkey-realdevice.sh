#!/bin/bash
# 万象书屋 Monkey 测试 — 真机自动重启版
#
# 解决真机上 XCTest "Lost connection" 导致测试终止的问题
# 每次崩溃后自动重启测试，持续到总时间结束
#
# 用法:
#   ./scripts/run-monkey-realdevice.sh              # 默认 8 小时
#   TOTAL_HOURS=2 ./scripts/run-monkey-realdevice.sh # 跑 2 小时
#
# 环境变量:
#   TOTAL_HOURS         总测试时长(小时), 默认 8
#   DEVICE_ID           设备 UDID, 默认自动检测
#   RUN_DURATION        每轮测试时长(分钟), 默认 60

set -uo pipefail
cd "$(dirname "$0")/.."

TOTAL_HOURS=${TOTAL_HOURS:-12}
RUN_DURATION=${RUN_DURATION:-60}
DEVICE_ID=${DEVICE_ID:-$(xcrun devicectl list devices 2>/dev/null | grep -E "connected|available" | grep -v unavailable | grep -oE '[A-F0-9-]{36}' | head -1)}

if [ -z "$DEVICE_ID" ]; then
    echo "❌ 未找到已连接的 iOS 真机"
    exit 1
fi

DEVICE_NAME=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" | head -1 | sed 's/  .*//' | xargs)
LOG_BASE="${LOG_BASE:-/tmp/monkey_realdevice_$(date +%Y%m%d_%H%M%S)_${DEVICE_ID:0:8}}"
mkdir -p "$LOG_BASE"

echo "🐵 万象书屋 Monkey 真机测试 (自动重启版)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   设备: $DEVICE_NAME"
echo "   UDID: $DEVICE_ID"
echo "   总时长: ${TOTAL_HOURS} 小时"
echo "   每轮: ${RUN_DURATION} 分钟"
echo "   日志: $LOG_BASE/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo ">>> 预构建测试包..."
xcodebuild build-for-testing \
    -project WanxiangBook.xcodeproj \
    -scheme WanxiangBook \
    -destination "platform=iOS,id=$DEVICE_ID" \
    -derivedDataPath "$LOG_BASE/DerivedData" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM=6UX5G5838X \
    CODE_SIGN_STYLE=Automatic \
    -quiet || {
    echo "❌ 预构建失败，请检查设备是否解锁、已信任、并开启开发者模式"
    exit 1
}

START_TS=$(date +%s)
END_TS=$((START_TS + TOTAL_HOURS * 3600))
RUN_COUNT=0
TOTAL_CRASHES=0

while [ "$(date +%s)" -lt "$END_TS" ]; do
    RUN_COUNT=$((RUN_COUNT + 1))
    REMAINING_MIN=$(( (END_TS - $(date +%s)) / 60 ))
    DURATION=$((REMAINING_MIN < RUN_DURATION ? REMAINING_MIN : RUN_DURATION))

    if [ "$DURATION" -le 0 ]; then break; fi

    RESULT_DIR="$LOG_BASE/run_${RUN_COUNT}"
    mkdir -p "$RESULT_DIR"

    echo ""
    echo "═══════════════════════════════════════"
    echo "🔄 第 $RUN_COUNT 轮 (剩余 ${REMAINING_MIN} 分钟, 本轮 ${DURATION} 分钟)"
    echo "═══════════════════════════════════════"

    MONKEY_DURATION=$DURATION \
    MONKEY_THROTTLE=500 \
    MONKEY_SCREENSHOT_INTERVAL=300 \
    xcodebuild test-without-building \
        -project WanxiangBook.xcodeproj \
        -scheme WanxiangBook \
        -destination "platform=iOS,id=$DEVICE_ID" \
        -only-testing:WanxiangUITests/MonkeyStabilityTest/testMonkeyRun \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        -derivedDataPath "$LOG_BASE/DerivedData" \
        -resultBundlePath "$RESULT_DIR/result.xcresult" \
        DEVELOPMENT_TEAM=6UX5G5838X \
        CODE_SIGN_STYLE=Automatic \
        2>&1 | tee "$RESULT_DIR/xcodebuild.log" | grep -E "\[Monkey\]|error:|TEST (SUCCEEDED|FAILED)" || true

    EXIT_CODE=${PIPESTATUS[0]}

    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ 第 $RUN_COUNT 轮完成 (无崩溃)"
    else
        TOTAL_CRASHES=$((TOTAL_CRASHES + 1))
        echo "⚠️  第 $RUN_COUNT 轮失败 (exit=$EXIT_CODE), 30秒后自动重启..."
        sleep 30
    fi

    CRASHES_IN_RUN=$(grep -c "crash #" "$RESULT_DIR/xcodebuild.log" 2>/dev/null || echo "0")
    ACTIONS_IN_RUN=$(grep -oP 'actions=\K[0-9]+' "$RESULT_DIR/xcodebuild.log" 2>/dev/null | tail -1 || echo "0")
    echo "   本轮: actions=$ACTIONS_IN_RUN crashes_recovered=$CRASHES_IN_RUN"
done

ELAPSED_H=$(( ($(date +%s) - START_TS) / 3600 ))
ELAPSED_M=$(( (($(date +%s) - START_TS) % 3600) / 60 ))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 真机 Monkey 测试总结"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   总轮数: $RUN_COUNT"
echo "   测试终止次数: $TOTAL_CRASHES"
echo "   总运行时长: ${ELAPSED_H}h ${ELAPSED_M}m"
echo "   日志目录: $LOG_BASE/"
echo ""
echo "📁 各轮结果:"
for d in "$LOG_BASE"/run_*/; do
    [ -d "$d" ] || continue
    RN=$(basename "$d" | sed 's/run_//')
    RESULT="✅"
    grep -q "TEST FAILED" "$d/xcodebuild.log" 2>/dev/null && RESULT="⚠️"
    ACTS=$(grep -oP 'actions=\K[0-9]+' "$d/xcodebuild.log" 2>/dev/null | tail -1 || echo "?")
    echo "   第${RN}轮: $RESULT actions=$ACTS"
done
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
