#!/bin/bash
# 万象书屋 iOS · 从真机/模拟器拉取崩溃报告
# 用法: bash ios/scripts/pull-crashes.sh [UDID]
# 输出: ios/logs/device-crashes/

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/logs/device-crashes"
mkdir -p "$OUT"

UDID="${1:-}"
if [ -z "$UDID" ]; then
  UDID=$(xcrun xctrace list devices 2>/dev/null | rg -m1 'iPhone.*\([0-9A-F-]+\)' -o | rg -o '[0-9A-F-]{36}' || true)
fi

if [ -z "$UDID" ]; then
  echo "❌ 未找到设备。用法: bash ios/scripts/pull-crashes.sh <UDID>"
  exit 1
fi

echo "📱 设备: $UDID"
echo "📂 输出: $OUT"

# 1. 系统 DiagnosticReports (.ips)
DEVICE_CRASH_DIR=$(xcrun devicectl device info crashes --device "$UDID" 2>/dev/null | rg -o '/var/containers/[^ ]+' | head -1 || true)
if [ -n "$DEVICE_CRASH_DIR" ]; then
  echo "→ 尝试 devicectl crashes..."
fi

# idevicecrashreport (libimobiledevice) 或 devicectl copy
if command -v idevicecrashreport >/dev/null 2>&1; then
  idevicecrashreport -u "$UDID" -e -k "$OUT/" 2>/dev/null || true
  COUNT=$(find "$OUT" -name '*.ips' 2>/dev/null | wc -l | tr -d ' ')
  echo "✅ idevicecrashreport: $COUNT 份 .ips"
else
  # fallback: xcrun simctl (模拟器)
  if xcrun simctl list devices | rg -q "$UDID"; then
    SIM_CRASH="$HOME/Library/Logs/DiagnosticReports"
    cp -f "$SIM_CRASH"/WanxiangBook*.ips "$OUT/" 2>/dev/null || true
    echo "✅ 模拟器 crash 已复制"
  else
    echo "⚠️  请安装 libimobiledevice (brew install libimobiledevice) 或使用 Xcode → Window → Devices → View Device Logs 手动导出"
  fi
fi

# 2. App 内 last_crash.txt (需 app 容器, devicectl 下载)
echo ""
echo "📋 本地已有 SE 分析报告: ios/logs/se-crash-analysis.md"
echo "📋 App 内崩溃日志路径: Documents/CrashLogs/last_crash.txt (下次启动后可见)"

# 3. 快速分类
python3 << 'PY' "$OUT"
import json, glob, sys, os
from collections import Counter
out = sys.argv[1] if len(sys.argv) > 1 else "."
files = glob.glob(os.path.join(out, "*.ips"))
if not files:
    print("无 .ips 文件可分析")
    sys.exit(0)
types = Counter()
for p in files:
    with open(p) as f:
        f.readline()
        data = json.load(f)
    triggered = next((t for t in data.get("threads", []) if t.get("triggered")), None)
    text = " ".join(fr.get("symbol","") for fr in (triggered or {}).get("frames", [])[:12])
    if "swift_abortAllocationFailure" in text: types["OOM"] += 1
    elif "MovableLockLock" in text or "_pthread_mutex" in text: types["MUTEX"] += 1
    elif "XCTElementSnapshot" in text: types["XCTest"] += 1
    else: types["OTHER"] += 1
print(f"=== {len(files)} 份 crash 分类 ===")
for k,v in types.most_common():
    print(f"  {k}: {v}")
PY
