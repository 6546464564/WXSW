#!/bin/bash
#
# take-appstore-screenshots.sh
# 万象书屋 · 自动跑 5 张 App Store 截图
#
# 前置:
#   1. Xcode → Settings → Components → 装 iOS 17+ Simulator runtime
#   2. 装 fastlane (可选, 让 snapshot 自动化更舒服)
#
# 用法:
#   ./scripts/take-appstore-screenshots.sh
#
# 输出:
#   ./screenshots/{device}/{timestamp}-N.png
#

set -e

cd "$(dirname "$0")/.."

DEVICES=(
  "iPhone 15 Pro Max"     # 6.9" 必填
  "iPhone 15 Plus"        # 6.5" 必填
  "iPad Pro (12.9-inch) (6th generation)"  # 13" 必填
)

OUT_DIR="$PWD/screenshots/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

echo "=== 万象书屋 App Store 截图 ==="
echo "输出目录: $OUT_DIR"

for device in "${DEVICES[@]}"; do
  echo ""
  echo "=== Device: $device ==="
  device_dir="$OUT_DIR/$(echo "$device" | tr ' ()' '___')"
  mkdir -p "$device_dir"

  # 1. 启动模拟器
  xcrun simctl boot "$device" 2>/dev/null || true

  # 2. 安装 App (需要先 Archive 出 .app)
  if [ -d "build/Debug-iphonesimulator/WanxiangBook.app" ]; then
    xcrun simctl install "$device" "build/Debug-iphonesimulator/WanxiangBook.app"
  else
    echo "⚠️  没找到 build/Debug-iphonesimulator/WanxiangBook.app"
    echo "    先跑: xcodebuild build (并选 iOS Simulator 真实 destination)"
    continue
  fi

  # 3. 启动 App
  xcrun simctl launch "$device" com.wanxiang.reader

  sleep 3

  # 4. 截 5 张 (等待动画完成)
  for i in 1 2 3 4 5; do
    sleep 2
    fname="$device_dir/screenshot-$i.png"
    xcrun simctl io "$device" screenshot "$fname"
    echo "  ✓ $fname"
  done

  # 5. 关闭模拟器
  xcrun simctl shutdown "$device" 2>/dev/null || true
done

echo ""
echo "=== 完成 ==="
echo "截图在: $OUT_DIR"
echo ""
echo "下一步(必须):"
echo "  1. 找设计师叠加大字标题文案 (推荐 Sketch / Figma)"
echo "  2. 上传到 App Store Connect"
echo ""
echo "提示: M4_APPSTORE_COPY.md 里有现成文案可用"
