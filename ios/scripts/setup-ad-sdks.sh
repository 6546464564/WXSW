#!/bin/bash
# 万象书屋: 一键拷贝广告 SDK xcframework 到工程
# 用法: ./scripts/setup-ad-sdks.sh
# 注意: SDK 不入 git, 每次新机器 clone 后跑一遍

set -e
cd "$(dirname "$0")/.."

SRC=$HOME/Desktop/sdk
DEST=$PWD/Frameworks

if [ ! -d "$SRC" ]; then
    echo "❌ 找不到 $SRC, 请先把厂商 SDK 解压到 ~/Desktop/sdk/"
    echo "   预期目录:"
    echo "   ~/Desktop/sdk/穿山甲union_platform_iOS_<version>/"
    echo "   ~/Desktop/sdk/优量汇GDT_iOS_SDK_<version>/"
    exit 1
fi

mkdir -p "$DEST"

CSJ=$(find "$SRC" -maxdepth 2 -type d -name 'BUAdSDK.xcframework' | head -1)
GDT=$(find "$SRC" -maxdepth 3 -type d -name 'GDTMobSDK.xcframework' | head -1)
TQUIC=$(find "$SRC" -maxdepth 3 -type d -name 'Tquic.xcframework' | head -1)
CSJ_BUNDLE=$(find "$SRC" -maxdepth 2 -type d -name 'CSJAdSDK.bundle' | head -1)

[ -d "$CSJ" ]    && cp -R "$CSJ" "$DEST/"        && echo "✓ BUAdSDK"
[ -d "$GDT" ]    && cp -R "$GDT" "$DEST/"        && echo "✓ GDTMobSDK"
[ -d "$TQUIC" ]  && cp -R "$TQUIC" "$DEST/"      && echo "✓ Tquic (GDT 必需)"
[ -d "$CSJ_BUNDLE" ] && cp -R "$CSJ_BUNDLE" "$DEST/" && echo "✓ CSJAdSDK.bundle"

echo ""
echo "完成. 现在跑:"
echo "  xcodegen generate"
echo "  open WanxiangBook.xcodeproj"
