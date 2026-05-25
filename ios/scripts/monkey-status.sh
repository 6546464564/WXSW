#!/bin/bash
# 查看真机 Monkey 运行状态
# 用法: bash ios/scripts/monkey-status.sh

echo "📱 已连接设备:"
xcrun devicectl list devices 2>/dev/null | awk 'NR==1 || /connected|available \(paired\)/' | grep -v unavailable || true
echo ""
echo "   说明: connected = USB 已连接; available(paired) = 仅无线配对"
echo ""

for dir in /tmp/monkey_18h_*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🐵 $name"
    latest=$(ls -d "$dir"/run_*/xcodebuild.log 2>/dev/null | sort -V | tail -1)
    if [ -n "$latest" ]; then
        actions=$(grep -oP 'actions=\K[0-9]+' "$latest" 2>/dev/null | tail -1 || echo "?")
        crashes=$(grep -oP 'crashes=\K[0-9]+' "$latest" 2>/dev/null | tail -1 || echo "?")
        last=$(grep "\[Monkey\]" "$latest" 2>/dev/null | tail -1)
        echo "   actions=$actions  crashes=$crashes"
        echo "   最新: $last"
    else
        echo "   尚无测试日志"
    fi
    if pgrep -f "$dir" >/dev/null 2>&1 || pgrep -f "LOG_BASE=$dir" >/dev/null 2>&1; then
        echo "   状态: 🟢 运行中"
    elif pgrep -f "DerivedData.*$(basename "$dir")" >/dev/null 2>&1; then
        echo "   状态: 🟢 xcodebuild 运行中"
    else
        echo "   状态: ⚪ 未检测到进程"
    fi
done

echo ""
echo "💡 实时日志: tail -f /tmp/monkey_18h_iphone13/run_*/xcodebuild.log | grep Monkey"
