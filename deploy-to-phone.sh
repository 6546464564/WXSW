#!/bin/bash
# 一键编译 + 安装到所有当前已连接 iPhone
set -e

PROJECT="/Users/stark/Desktop/WXSW/ios/WanxiangBook.xcodeproj"
APP_PATH="/Users/stark/Library/Developer/Xcode/DerivedData/WanxiangBook-ezanytlvprscbxbiugjduyikkohy/Build/Products/Release-iphoneos/WanxiangBook.app"
BUNDLE_ID="com.wanxiang.reader"

# 手动排除列表 (如不需要某台设备可加到这里)
EXCLUDE_IDS=("C8CF2FE7-CD99-51C6-97F7-28BA9368AC59")

# 自动获取所有已连接的真机设备 ID (只取 connected 或 available (paired), 排除 unavailable)
echo "🔍 检测已连接手机..."
ALL_IDS=($(xcrun devicectl list devices 2>/dev/null | grep -E "\bconnected\b|available \(paired\)" | grep -v -i "simulator" | awk '{print $3}'))
DEVICE_IDS=()
for id in "${ALL_IDS[@]}"; do
  excluded=false
  for ex in "${EXCLUDE_IDS[@]}"; do
    if [[ "$id" == "$ex" ]]; then excluded=true; break; fi
  done
  $excluded || DEVICE_IDS+=("$id")
done

if [ ${#DEVICE_IDS[@]} -eq 0 ]; then
  echo "❌ 没有检测到已连接手机，请连接设备后重试"
  exit 1
fi

echo "✅ 检测到 ${#DEVICE_IDS[@]} 台可用设备"
PRIMARY_DEVICE="${DEVICE_IDS[0]}"

echo "📦 开始编译 (目标设备: $PRIMARY_DEVICE)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme WanxiangBook \
  -configuration Release \
  -destination "platform=iOS,id=$PRIMARY_DEVICE" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM=6UX5G5838X \
  CODE_SIGN_STYLE=Automatic \
  build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -20

for DEVICE_ID in "${DEVICE_IDS[@]}"; do
  echo "📲 安装到 $DEVICE_ID..."
  xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1 | tail -2 || echo "⚠️  安装失败（可能需要手机上信任开发者）"
  xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" 2>&1 | tail -1 || true
done

echo "✅ 全部完成！"
