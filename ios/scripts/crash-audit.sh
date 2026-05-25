#!/bin/bash
# 万象书屋 iOS · 静态闪退风险扫描 (全自动, 无需真机)
# 用法: bash ios/scripts/crash-audit.sh

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)/Sources/WanxiangBook"
echo "🔍 扫描目录: $ROOT"
echo ""

fail=0

check() {
  local title="$1" pattern="$2" extra="${3:-}"
  local count
  count=$(rg -c "$pattern" "$ROOT" $extra 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')
  if [ "${count:-0}" -gt 0 ]; then
    echo "⚠️  $title ($count 处)"
    rg -n "$pattern" "$ROOT" $extra 2>/dev/null | head -8
    echo ""
    fail=$((fail + 1))
  else
    echo "✅ $title"
  fi
}

check "fatalError / preconditionFailure" 'fatalError|preconditionFailure|precondition\('
check "ForEach(id: bookUrl) 重复 ID 风险" 'ForEach\([^)]*id: \\.bookUrl'
check "force unwrap as!" ' as!' --glob '*.swift'
check "try! 强制 try" 'try!' --glob '*.swift'
check "JSONSerialization 无 isValidJSONObject 守卫" 'JSONSerialization\.data\(withJSONObject:' --glob '*.swift'
check "逐条 results.append (SearchView)" 'results\.append' --glob '**/SearchView.swift'
check "candidates.append 逐条更新 (换源)" 'candidates\.append' --glob '**/ChangeSourceView.swift'

echo ""
if [ "$fail" -eq 0 ]; then
  echo "🎉 未发现已知高危模式"
else
  echo "📋 共 $fail 类问题需人工确认 (部分可能已有防护)"
fi
