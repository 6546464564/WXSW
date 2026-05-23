#!/bin/bash
# 万象书屋 Android Monkey 增强稳定性测试
#
# 包含: 随机操作 + 文字输入 + 前后台切换 + 网络切换 +
#       内存监控 + 屏幕旋转 + 缩放手势 + 下拉刷新 + 业务流程 + 性能指标
#
# 用法:
#   ./scripts/run-monkey.sh                              # 默认 12 小时
#   MONKEY_DURATION=720 ./scripts/run-monkey.sh          # 跑 12 小时
#   MONKEY_SEED=12345 ./scripts/run-monkey.sh            # 指定随机种子
#
# 环境变量:
#   MONKEY_DURATION             测试时长(分钟), 默认 720
#   MONKEY_THROTTLE             操作间隔(ms), 默认 500
#   MONKEY_SEED                 随机种子, 不设则每次随机
#   MONKEY_SCREENSHOT_INTERVAL  截图间隔(秒), 默认 60
#   MONKEY_INSTALL_APK          是否先安装 APK (1=是, 默认 0)

set -euo pipefail
cd "$(dirname "$0")/.."

BASE_PACKAGE="com.wanxiang.reader"
DURATION=${MONKEY_DURATION:-720}
THROTTLE=${MONKEY_THROTTLE:-500}
SEED=${MONKEY_SEED:-$RANDOM}
SCREENSHOT_INTERVAL=${MONKEY_SCREENSHOT_INTERVAL:-60}
INSTALL_APK=${MONKEY_INSTALL_APK:-0}

ADB="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb"

# 自动检测已安装的包名 (debug / release)
if $ADB shell pm list packages 2>/dev/null | grep -q "${BASE_PACKAGE}.debug"; then
    PACKAGE="${BASE_PACKAGE}.debug"
elif $ADB shell pm list packages 2>/dev/null | grep -q "${BASE_PACKAGE}$"; then
    PACKAGE="${BASE_PACKAGE}"
else
    echo "❌ 未在设备上找到 ${BASE_PACKAGE} 或 ${BASE_PACKAGE}.debug"
    echo "   请先安装 App: MONKEY_INSTALL_APK=1 $0"
    exit 1
fi

LOG_DIR="/tmp/monkey_android_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

EVENTS_PER_SECOND=$((1000 / THROTTLE))
TOTAL_EVENTS=$((DURATION * 60 * EVENTS_PER_SECOND))

echo "🐵 万象书屋 Android 增强 Monkey 测试"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   包名: $PACKAGE"
echo "   测试时长: ${DURATION} 分钟"
echo "   操作间隔: ${THROTTLE}ms"
echo "   预计操作数: ~${TOTAL_EVENTS}"
echo "   随机种子: $SEED"
echo "   截图间隔: ${SCREENSHOT_INTERVAL}s"
echo "   日志目录: $LOG_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# 检查设备连接
DEVICE_COUNT=$($ADB devices | grep -c "device$" || true)
if [ "$DEVICE_COUNT" -eq 0 ]; then
    echo "❌ 未检测到 Android 设备或模拟器"
    exit 1
fi

DEVICE_MODEL=$($ADB shell getprop ro.product.model 2>/dev/null | tr -d '\r')
ANDROID_VER=$($ADB shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
SCREEN_SIZE=$($ADB shell wm size 2>/dev/null | grep -oE '[0-9]+x[0-9]+' | tail -1 || echo "1080x1920")
SCREEN_W=$(echo "$SCREEN_SIZE" | cut -dx -f1)
SCREEN_H=$(echo "$SCREEN_SIZE" | cut -dx -f2)
echo "📱 设备: $DEVICE_MODEL (Android $ANDROID_VER) 分辨率: ${SCREEN_W}x${SCREEN_H}"

# 可选: 安装 APK
if [ "$INSTALL_APK" = "1" ]; then
    echo "📦 构建并安装 APK..."
    ./gradlew assembleDebug 2>&1 | tail -3
    APK_PATH=$(find app/build -name "*.apk" -path "*/debug/*" | head -1)
    if [ -n "$APK_PATH" ]; then
        $ADB install -r "$APK_PATH" 2>&1
        echo "✅ APK 已安装"
    else
        echo "⚠️  未找到 debug APK，跳过安装"
    fi
fi

# 清理之前的崩溃日志
$ADB shell rm -f /sdcard/crash-dump.log 2>/dev/null || true

# 获取 Activity 列表
echo ""
echo "📋 获取 Activity 列表..."
ACTIVITIES=$($ADB shell dumpsys package "$PACKAGE" | grep -oE "[a-zA-Z0-9_.]*Activity" | sort -u)
TOTAL_ACTIVITIES=$(echo "$ACTIVITIES" | wc -l | xargs)
echo "   应用共有 $TOTAL_ACTIVITIES 个 Activity"
echo "$ACTIVITIES" > "$LOG_DIR/all_activities.txt"

# 获取启动 Activity
LAUNCH_ACTIVITY=$($ADB shell dumpsys package "$PACKAGE" | grep -A5 "android.intent.action.MAIN" | grep -oE "$PACKAGE/[a-zA-Z0-9_.]*" | head -1 || echo "")

# 清空 logcat
$ADB logcat -c 2>/dev/null || true

# 启动 App
echo ""
echo "🚀 启动应用..."
$ADB shell am force-stop "$PACKAGE" 2>/dev/null || true
sleep 1
$ADB shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
sleep 3

# 后台收集 logcat (崩溃检测)
$ADB logcat -v time "*:E" 2>/dev/null > "$LOG_DIR/logcat_errors.log" &
LOGCAT_PID=$!

# 增强测试计数器
BG_FG_COUNT=0
NET_TOGGLE_COUNT=0
ROTATION_COUNT=0
TEXT_INPUT_COUNT=0
PINCH_COUNT=0
PULL_REFRESH_COUNT=0
FLOW_COUNT=0
SLOW_COUNT=0
CRASH_RECOVERY=0
TOTAL_ACTION=0
DARK_MODE_COUNT=0
RAPID_BURST_COUNT=0
MULTI_TASK_COUNT=0
BOUNDARY_INPUT_COUNT=0
ANOMALY_COUNT=0
DATA_CLEAR_COUNT=0
DEEP_LINK_COUNT=0
NOTIFICATION_COUNT=0

# 内存监控记录文件
echo "timestamp,pss_kb,heap_kb" > "$LOG_DIR/memory_log.csv"

# ──── 辅助函数 ────

rand() {
    echo $((RANDOM % $1))
}

rand_range() {
    echo $(($1 + RANDOM % ($2 - $1 + 1)))
}

check_app_running() {
    $ADB shell pidof "$PACKAGE" >/dev/null 2>&1
}

restart_app() {
    CRASH_RECOVERY=$((CRASH_RECOVERY + 1))
    echo "🔄 重启 App (crash #$CRASH_RECOVERY)"
    $ADB shell am force-stop "$PACKAGE" 2>/dev/null || true
    sleep 2
    $ADB shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
    sleep 3
}

log_memory() {
    local ts=$(date +%H:%M:%S)
    local mem=$($ADB shell dumpsys meminfo "$PACKAGE" 2>/dev/null | grep "TOTAL PSS" | head -1 | grep -oE '[0-9]+' | head -1 || echo "0")
    local heap=$($ADB shell dumpsys meminfo "$PACKAGE" 2>/dev/null | grep "Native Heap" | head -1 | grep -oE '[0-9]+' | head -1 || echo "0")
    echo "$ts,$mem,$heap" >> "$LOG_DIR/memory_log.csv"
    echo "💾 内存: PSS=${mem}KB NativeHeap=${heap}KB"
}

tap_xy() {
    $ADB shell input tap "$1" "$2" 2>/dev/null || true
}

swipe_xy() {
    $ADB shell input swipe "$1" "$2" "$3" "$4" "${5:-300}" 2>/dev/null || true
}

type_text() {
    $ADB shell input text "$1" 2>/dev/null || true
}

press_key() {
    $ADB shell input keyevent "$1" 2>/dev/null || true
}

# ──── 增强操作函数 ────

do_random_tap() {
    local x=$(rand_range 50 $((SCREEN_W - 50)))
    local y=$(rand_range 100 $((SCREEN_H - 100)))
    tap_xy "$x" "$y"
}

do_random_swipe() {
    local dir=$(rand 4)
    local cx=$((SCREEN_W / 2))
    local cy=$((SCREEN_H / 2))
    case $dir in
        0) swipe_xy "$cx" "$((cy + 300))" "$cx" "$((cy - 300))" ;; # up
        1) swipe_xy "$cx" "$((cy - 300))" "$cx" "$((cy + 300))" ;; # down
        2) swipe_xy "$((cx + 300))" "$cy" "$((cx - 300))" "$cy" ;; # left
        3) swipe_xy "$((cx - 300))" "$cy" "$((cx + 300))" "$cy" ;; # right
    esac
}

do_text_input() {
    local texts=("test" "hello" "search" "book" "novel" "fantasy" "romance" "action" "story")
    local idx=$(rand ${#texts[@]})
    local t="${texts[$idx]}"
    # Tap on a potential text field area (top area for search)
    tap_xy $((SCREEN_W / 2)) 150
    sleep 1
    type_text "$t"
    TEXT_INPUT_COUNT=$((TEXT_INPUT_COUNT + 1))
    echo "📝 输入文本: $t"
    sleep 1
    press_key KEYCODE_ENTER
    sleep 2
}

do_bg_fg() {
    echo "🏠 切换到后台..."
    press_key KEYCODE_HOME
    local wait_s=$(rand_range 2 6)
    sleep "$wait_s"
    echo "🔙 恢复前台 (后台 ${wait_s}s)"
    $ADB shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
    sleep 2
    BG_FG_COUNT=$((BG_FG_COUNT + 1))
}

do_network_toggle() {
    echo "🌐 关闭网络..."
    $ADB shell svc wifi disable 2>/dev/null || true
    $ADB shell svc data disable 2>/dev/null || true
    local wait_s=$(rand_range 3 8)
    sleep "$wait_s"
    echo "🌐 恢复网络 (断网 ${wait_s}s)"
    $ADB shell svc wifi enable 2>/dev/null || true
    $ADB shell svc data enable 2>/dev/null || true
    sleep 3
    NET_TOGGLE_COUNT=$((NET_TOGGLE_COUNT + 1))
}

do_rotation() {
    local orientations=(0 1 2 3) # 0=自然 1=90 2=180 3=270
    local idx=$(rand 3)
    local target=${orientations[$((idx + 1))]}
    echo "🔄 旋转屏幕: $target"
    $ADB shell settings put system accelerometer_rotation 0 2>/dev/null || true
    $ADB shell settings put system user_rotation "$target" 2>/dev/null || true
    ROTATION_COUNT=$((ROTATION_COUNT + 1))
    sleep 2
    $ADB shell settings put system user_rotation 0 2>/dev/null || true
    $ADB shell settings put system accelerometer_rotation 1 2>/dev/null || true
    sleep 1
}

do_pinch() {
    local cx=$((SCREEN_W / 2))
    local cy=$((SCREEN_H / 2))
    if [ $(rand 2) -eq 0 ]; then
        # Zoom in: two fingers moving apart (simulated as two quick swipes)
        swipe_xy "$cx" "$cy" "$((cx + 200))" "$((cy + 200))" 500 &
        swipe_xy "$cx" "$cy" "$((cx - 200))" "$((cy - 200))" 500
        wait
        echo "🔍 放大手势"
    else
        # Zoom out: two fingers moving together
        swipe_xy "$((cx + 200))" "$((cy + 200))" "$cx" "$cy" 500 &
        swipe_xy "$((cx - 200))" "$((cy - 200))" "$cx" "$cy" 500
        wait
        echo "🔍 缩小手势"
    fi
    PINCH_COUNT=$((PINCH_COUNT + 1))
}

do_pull_refresh() {
    local cx=$((SCREEN_W / 2))
    swipe_xy "$cx" 300 "$cx" $((SCREEN_H * 3 / 4)) 400
    echo "⬇️ 下拉刷新"
    PULL_REFRESH_COUNT=$((PULL_REFRESH_COUNT + 1))
    sleep 2
}

do_flow_search() {
    echo "📚 流程: 搜索"
    local searches=("fantasy" "novel" "romance" "action" "magic" "reborn")
    local q="${searches[$(rand ${#searches[@]})]}"
    tap_xy $((SCREEN_W / 2)) 150
    sleep 1
    type_text "$q"
    sleep 1
    press_key KEYCODE_ENTER
    sleep 3
    do_random_tap
    sleep 2
    FLOW_COUNT=$((FLOW_COUNT + 1))
}

do_flow_browse() {
    echo "📚 流程: 浏览"
    local cx=$((SCREEN_W / 2))
    # Tap bottom tab
    tap_xy "$cx" $((SCREEN_H - 60))
    sleep 2
    for i in $(seq 1 3); do
        do_random_swipe
        sleep 1
    done
    do_random_tap
    sleep 3
    FLOW_COUNT=$((FLOW_COUNT + 1))
}

do_flow_read() {
    echo "📚 流程: 阅读"
    local tab_x=$((SCREEN_W / 6))
    tap_xy "$tab_x" $((SCREEN_H - 60))
    sleep 2
    tap_xy $((SCREEN_W / 4)) $((SCREEN_H / 3))
    sleep 3
    for i in $(seq 1 5); do
        swipe_xy $((SCREEN_W * 3 / 4)) $((SCREEN_H / 2)) $((SCREEN_W / 4)) $((SCREEN_H / 2)) 300
        sleep 1
    done
    press_key KEYCODE_BACK
    sleep 1
    FLOW_COUNT=$((FLOW_COUNT + 1))
}

do_business_flow() {
    local flow=$(rand 3)
    case $flow in
        0) do_flow_search ;;
        1) do_flow_browse ;;
        *) do_flow_read ;;
    esac
}

do_dark_mode() {
    echo "🌗 暗色模式切换"
    local current=$($ADB shell settings get secure ui_night_mode 2>/dev/null | tr -d '\r')
    if [ "$current" = "2" ]; then
        $ADB shell cmd uimode night yes 2>/dev/null || true
        echo "🌙 深色模式 ON"
    else
        $ADB shell cmd uimode night no 2>/dev/null || true
        echo "☀️ 浅色模式 ON"
    fi
    DARK_MODE_COUNT=$((DARK_MODE_COUNT + 1))
    sleep 3
    $ADB shell cmd uimode night auto 2>/dev/null || true
    sleep 1
}

do_rapid_burst() {
    local count=$(rand_range 10 25)
    echo "⚡ 快速连续操作 x$count"
    for i in $(seq 1 "$count"); do
        local x=$(rand_range 100 $((SCREEN_W - 100)))
        local y=$(rand_range 200 $((SCREEN_H - 200)))
        tap_xy "$x" "$y"
        usleep 50000 2>/dev/null || sleep 0.05
    done
    RAPID_BURST_COUNT=$((RAPID_BURST_COUNT + 1))
}

do_multi_task() {
    echo "🔀 多任务切换"
    press_key KEYCODE_HOME
    sleep 1
    $ADB shell am start -a android.intent.action.VIEW -d "https://www.baidu.com" 2>/dev/null || true
    sleep 3
    $ADB shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
    sleep 2
    MULTI_TASK_COUNT=$((MULTI_TASK_COUNT + 1))
}

do_boundary_input() {
    local variants=(
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        "emoji_test_input"
        "special_chars_test"
        "sql_injection_test"
        "spaces_tabs_test"
    )
    local idx=$(rand ${#variants[@]})
    local text="${variants[$idx]}"
    echo "🔤 边界输入: ${text:0:20}..."
    tap_xy $((SCREEN_W / 2)) 150
    sleep 1
    type_text "$text"
    BOUNDARY_INPUT_COUNT=$((BOUNDARY_INPUT_COUNT + 1))
    sleep 1
    press_key KEYCODE_BACK
    sleep 1
}

do_screenshot_check() {
    local sc_file="/sdcard/anomaly_check.png"
    $ADB shell screencap -p "$sc_file" 2>/dev/null || true
    local size=$($ADB shell stat -c%s "$sc_file" 2>/dev/null | tr -d '\r' || echo "0")
    if [ "$size" -lt 1000 ]; then
        ANOMALY_COUNT=$((ANOMALY_COUNT + 1))
        echo "⚠️ 异常: 截图极小 (${size}B), 可能黑屏"
        $ADB pull "$sc_file" "$LOG_DIR/anomaly_${TOTAL_ACTION}.png" 2>/dev/null || true
    fi
    $ADB shell rm "$sc_file" 2>/dev/null || true
    echo "📸 UI异常检查"
}

do_data_clear() {
    echo "🗑️ 清理缓存并重启"
    $ADB shell pm clear "$PACKAGE" 2>/dev/null || true
    sleep 2
    $ADB shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 2>/dev/null || true
    sleep 4
    DATA_CLEAR_COUNT=$((DATA_CLEAR_COUNT + 1))
}

do_deep_link() {
    echo "🔗 深度链接测试"
    local activities_arr=($ACTIVITIES)
    if [ ${#activities_arr[@]} -gt 0 ]; then
        local idx=$(rand ${#activities_arr[@]})
        local target="${activities_arr[$idx]}"
        $ADB shell am start -n "$PACKAGE/$target" 2>/dev/null || true
        DEEP_LINK_COUNT=$((DEEP_LINK_COUNT + 1))
        echo "🔗 打开: $target"
        sleep 3
    fi
}

do_notification_check() {
    echo "🔔 通知栏检查"
    $ADB shell cmd statusbar expand-notifications 2>/dev/null || true
    sleep 2
    tap_xy $((SCREEN_W / 2)) $((SCREEN_H / 2))
    sleep 1
    $ADB shell cmd statusbar collapse 2>/dev/null || true
    sleep 1
    NOTIFICATION_COUNT=$((NOTIFICATION_COUNT + 1))
}

# ──── 定期截图 (后台) ────
(
    SC_COUNT=0
    while true; do
        sleep "$SCREENSHOT_INTERVAL"
        SC_COUNT=$((SC_COUNT + 1))
        $ADB shell screencap -p "/sdcard/monkey_ss_${SC_COUNT}.png" 2>/dev/null
        $ADB pull "/sdcard/monkey_ss_${SC_COUNT}.png" "$LOG_DIR/" 2>/dev/null || true
        $ADB shell rm "/sdcard/monkey_ss_${SC_COUNT}.png" 2>/dev/null || true
        echo "📸 截图 #${SC_COUNT}"
    done
) &
SCREENSHOT_PID=$!

# ──── 定期内存监控 (后台) ────
(
    while true; do
        sleep 120
        log_memory
    done
) &
MEMORY_PID=$!

# ──── 主循环: Monkey 基础 + 增强操作交替 ────

echo ""
echo "🐒 开始增强 Monkey 测试 (${DURATION}分钟)..."
echo ""

START_TS=$(date +%s)
END_TS=$((START_TS + DURATION * 60))

# 基础 Monkey 分批运行 (每批 500 事件)
BATCH_SIZE=500
BATCH_EVENTS_DONE=0

while [ "$(date +%s)" -lt "$END_TS" ]; do
    # 检查 app 是否还活着
    if ! check_app_running; then
        restart_app
    fi

    # 每一轮: 跑一批基础 monkey 事件
    REMAINING=$((TOTAL_EVENTS - BATCH_EVENTS_DONE))
    if [ "$REMAINING" -le 0 ]; then
        REMAINING=$BATCH_SIZE
    fi
    BATCH=$((REMAINING < BATCH_SIZE ? REMAINING : BATCH_SIZE))

    $ADB shell monkey \
        -p "$PACKAGE" \
        -s "$((SEED + BATCH_EVENTS_DONE))" \
        --throttle "$THROTTLE" \
        --pct-touch 40 \
        --pct-motion 15 \
        --pct-trackball 0 \
        --pct-nav 15 \
        --pct-majornav 5 \
        --pct-syskeys 5 \
        --pct-appswitch 10 \
        --pct-flip 0 \
        --pct-anyevent 10 \
        --monitor-native-crashes \
        --kill-process-after-error \
        --ignore-timeouts \
        --ignore-security-exceptions \
        -v -v \
        "$BATCH" \
        2>&1 | tee -a "$LOG_DIR/monkey.log" | tail -1

    BATCH_EVENTS_DONE=$((BATCH_EVENTS_DONE + BATCH))
    TOTAL_ACTION=$((TOTAL_ACTION + BATCH))

    # 检查时间
    if [ "$(date +%s)" -ge "$END_TS" ]; then break; fi

    # ---- 增强操作 (每批基础事件后执行一组) ----
    if ! check_app_running; then restart_app; fi

    local_roll=$((RANDOM % 100))

    ACTION_START=$(date +%s%N 2>/dev/null || date +%s)

    if [ $local_roll -lt 12 ]; then
        do_text_input
    elif [ $local_roll -lt 18 ]; then
        do_bg_fg
    elif [ $local_roll -lt 22 ]; then
        do_network_toggle
    elif [ $local_roll -lt 28 ]; then
        do_rotation
    elif [ $local_roll -lt 34 ]; then
        do_pinch
    elif [ $local_roll -lt 40 ]; then
        do_pull_refresh
    elif [ $local_roll -lt 52 ]; then
        do_business_flow
    elif [ $local_roll -lt 58 ]; then
        do_dark_mode
    elif [ $local_roll -lt 66 ]; then
        do_rapid_burst
    elif [ $local_roll -lt 72 ]; then
        do_multi_task
    elif [ $local_roll -lt 78 ]; then
        do_boundary_input
    elif [ $local_roll -lt 84 ]; then
        do_screenshot_check
    elif [ $local_roll -lt 88 ]; then
        do_deep_link
    elif [ $local_roll -lt 92 ]; then
        do_notification_check
    elif [ $local_roll -lt 95 ]; then
        do_data_clear
    else
        do_random_tap
        sleep 1
        do_random_swipe
    fi

    TOTAL_ACTION=$((TOTAL_ACTION + 1))

    ACTION_END=$(date +%s%N 2>/dev/null || date +%s)
    # 检测慢操作 (ns → ms)
    if [ "${#ACTION_START}" -gt 10 ]; then
        ACTION_MS=$(( (ACTION_END - ACTION_START) / 1000000 ))
        if [ "$ACTION_MS" -gt 5000 ]; then
            SLOW_COUNT=$((SLOW_COUNT + 1))
            echo "⏱️ 慢操作: ${ACTION_MS}ms"
        fi
    fi

    # 每 10 轮打印状态
    if [ $((TOTAL_ACTION % 10)) -eq 0 ]; then
        ELAPSED=$(( $(date +%s) - START_TS ))
        echo "[Monkey] total=$TOTAL_ACTION crashes=$CRASH_RECOVERY slow=$SLOW_COUNT elapsed=${ELAPSED}s flows=$FLOW_COUNT"
    fi
done

# 停止后台任务
kill $LOGCAT_PID 2>/dev/null || true
kill $SCREENSHOT_PID 2>/dev/null || true
kill $MEMORY_PID 2>/dev/null || true

# 确保网络和旋转恢复正常
$ADB shell svc wifi enable 2>/dev/null || true
$ADB shell svc data enable 2>/dev/null || true
$ADB shell settings put system accelerometer_rotation 1 2>/dev/null || true
$ADB shell settings put system user_rotation 0 2>/dev/null || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 增强测试结果"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CRASH_COUNT=$(grep -c "CRASH:" "$LOG_DIR/monkey.log" 2>/dev/null || echo "0")
ANR_COUNT=$(grep -c "ANR" "$LOG_DIR/monkey.log" 2>/dev/null || echo "0")
NATIVE_CRASH=$(grep -c "Native crash" "$LOG_DIR/monkey.log" 2>/dev/null || echo "0")

echo "   基础 Monkey 事件:  $BATCH_EVENTS_DONE"
echo "   增强操作总数:      $TOTAL_ACTION"
echo "   ── 崩溃统计 ──"
echo "   崩溃(Java):        $CRASH_COUNT"
echo "   ANR:               $ANR_COUNT"
echo "   Native 崩溃:       $NATIVE_CRASH"
echo "   崩溃恢复:          $CRASH_RECOVERY"
echo "   ── 增强操作 ──"
echo "   前后台切换:        $BG_FG_COUNT 次"
echo "   网络切换:          $NET_TOGGLE_COUNT 次"
echo "   屏幕旋转:          $ROTATION_COUNT 次"
echo "   文字输入:          $TEXT_INPUT_COUNT 次"
echo "   缩放手势:          $PINCH_COUNT 次"
echo "   下拉刷新:          $PULL_REFRESH_COUNT 次"
echo "   业务流程:          $FLOW_COUNT 次"
echo "   暗色模式切换:      $DARK_MODE_COUNT 次"
echo "   快速连续操作:      $RAPID_BURST_COUNT 次"
echo "   多任务切换:        $MULTI_TASK_COUNT 次"
echo "   边界输入:          $BOUNDARY_INPUT_COUNT 次"
echo "   UI异常检出:        $ANOMALY_COUNT 次"
echo "   深度链接:          $DEEP_LINK_COUNT 次"
echo "   通知栏检查:        $NOTIFICATION_COUNT 次"
echo "   数据清理重启:      $DATA_CLEAR_COUNT 次"
echo "   慢操作 (>5s):      $SLOW_COUNT"

VISITED_ACTIVITIES=$(grep "cmp=" "$LOG_DIR/monkey.log" 2>/dev/null | grep -oE "$PACKAGE/[a-zA-Z0-9_.]*" | sort -u | wc -l | xargs)
echo "   Activity 覆盖:    ${VISITED_ACTIVITIES}/${TOTAL_ACTIVITIES}"

# 最终内存快照
echo "   ── 内存 ──"
log_memory

# 保存统计
grep "cmp=" "$LOG_DIR/monkey.log" 2>/dev/null | grep -oE "$PACKAGE/[a-zA-Z0-9_.]*" | sort -u > "$LOG_DIR/visited_activities.txt" || true
grep -A 20 "CRASH:" "$LOG_DIR/monkey.log" > "$LOG_DIR/crashes.txt" 2>/dev/null || true
grep -A 20 "ANR" "$LOG_DIR/monkey.log" > "$LOG_DIR/anrs.txt" 2>/dev/null || true
$ADB shell cat /sdcard/crash-dump.log > "$LOG_DIR/device_crashes.txt" 2>/dev/null || true

FATAL_COUNT=$(grep -c "FATAL EXCEPTION" "$LOG_DIR/logcat_errors.log" 2>/dev/null || echo "0")
echo "   Logcat FATAL:      $FATAL_COUNT"

SCREENSHOT_TOTAL=$(ls "$LOG_DIR"/monkey_ss_*.png 2>/dev/null | wc -l | xargs)
echo "   截图数量:          $SCREENSHOT_TOTAL"

# 性能分析: App 启动时间
LAUNCH_TIME=$($ADB shell am start-activity -W "$LAUNCH_ACTIVITY" 2>/dev/null | grep "TotalTime" | grep -oE '[0-9]+' || echo "N/A")
echo "   App 启动耗时:      ${LAUNCH_TIME}ms"

# GFX 性能信息
echo "   ── GPU 渲染 ──"
GFX=$($ADB shell dumpsys gfxinfo "$PACKAGE" 2>/dev/null | grep -E "Total frames|Janky frames|Number Missed" | head -3)
echo "$GFX" | while IFS= read -r line; do echo "   $line"; done
echo "$GFX" > "$LOG_DIR/gfxinfo.txt"

echo ""
TOTAL_ISSUES=$((CRASH_COUNT + ANR_COUNT + NATIVE_CRASH))
if [ "$TOTAL_ISSUES" -eq 0 ]; then
    echo "✅ 增强 Monkey 测试通过 (无崩溃/ANR)"
else
    echo "⚠️  发现 $TOTAL_ISSUES 个问题"
    echo "   详情: $LOG_DIR/crashes.txt"
fi
echo ""
echo "📁 完整日志: $LOG_DIR/"
echo "   monkey.log        - Monkey 输出"
echo "   logcat_errors.log - Logcat 错误"
echo "   crashes.txt       - 崩溃堆栈"
echo "   memory_log.csv    - 内存监控"
echo "   gfxinfo.txt       - GPU 渲染统计"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit ${TOTAL_ISSUES:-0}
