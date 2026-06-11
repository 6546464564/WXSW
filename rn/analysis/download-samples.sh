#!/bin/bash
# 在本机终端运行（需先 ipatool auth login）
set -euo pipefail

OUT="$(cd "$(dirname "$0")" && pwd)/ipas"
mkdir -p "$OUT"

apps=(
  "6778257611:乒练记"
  "6775929974:手工档案"
  "6775421568:奏奏读字幕"
  "6777298805:池务通"
  "6777498851:昆野图志"
  "6775470380:生字停留"
)

echo "输出目录: $OUT"
ipatool auth info || { echo "请先执行: ipatool auth login"; exit 1; }

for entry in "${apps[@]}"; do
  id="${entry%%:*}"
  name="${entry##*:}"
  echo ">>> 下载 $name ($id)"
  ipatool download -i "$id" -o "$OUT" --purchase || echo "失败: $name"
done

echo "完成。IPA 在 $OUT"
