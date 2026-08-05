#!/usr/bin/env bash
# 万象书屋 · 一键全量检查
#
# 覆盖 4 层:
#   1. backend 单测        (node --test test/*.test.js)
#   2. backend 覆盖率      (node --experimental-test-coverage)
#   3. iOS 单测            (xcodebuild test -only-testing:WanxiangBookTests)
#   4. iOS 覆盖率报告      (xcrun xccov)
#
# 用法:
#   ./scripts/check-all.sh            全部跑
#   ./scripts/check-all.sh backend    只跑 backend 1+2
#   ./scripts/check-all.sh ios        只跑 iOS 3+4
#
# 退出码: 0 = 全通过; 非 0 = 有失败层

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND="$ROOT/backend"
IOS="$ROOT/ios"
DERIVED="$ROOT/.build/check-ios"
LOG_DIR="${TMPDIR:-/tmp}/wxsw-check"
mkdir -p "$LOG_DIR"

PASS=0
FAIL=0
TARGET="${1:-all}"

step() { echo; echo "=== [$1] $2 ==="; }
report() {
  if [ "$1" -eq 0 ]; then echo "  ✅ $2"; PASS=$((PASS + 1));
  else echo "  ❌ $2  (日志: $LOG_DIR/$3)"; FAIL=$((FAIL + 1)); fi
}

run_backend() {
  step "1/4" "backend 单测 (node --test)"
  (cd "$BACKEND" && node --experimental-require-module --test test/*.test.js) > "$LOG_DIR/backend-test.log" 2>&1
  report $? "backend 单测" "backend-test.log"

  step "2/4" "backend 覆盖率 (node --experimental-test-coverage)"
  (cd "$BACKEND" && node --experimental-require-module --experimental-test-coverage --test test/*.test.js) > "$LOG_DIR/backend-cov.log" 2>&1
  local cov_exit=$?
  if [ "$cov_exit" -eq 0 ]; then
    rg "^# all files" "$LOG_DIR/backend-cov.log" || true
  fi
  report "$cov_exit" "backend 覆盖率" "backend-cov.log"
}

run_ios() {
  step "3/4" "iOS 单测 (xcodebuild, 仅 WanxiangBookTests)"
  rm -rf "$DERIVED"
  (cd "$IOS" && xcodebuild test -scheme WanxiangBook \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:WanxiangBookTests -enableCodeCoverage YES \
    -derivedDataPath "$DERIVED") > "$LOG_DIR/ios-test.log" 2>&1
  report $? "iOS 单测" "ios-test.log"

  step "4/4" "iOS 覆盖率报告"
  local XC
  XC=$(find "$DERIVED/Logs/Test" -name "*.xcresult" 2>/dev/null | head -1)
  if [ -n "$XC" ]; then
    xcrun xccov view --report --only-targets "$XC" 2>/dev/null | tail -6 || true
    report 0 "iOS 覆盖率报告" "ios-test.log"
  else
    report 1 "iOS 覆盖率报告 (找不到 xcresult)" "ios-test.log"
  fi
}

if [ "$TARGET" = "all" ] || [ "$TARGET" = "backend" ]; then run_backend; fi
if [ "$TARGET" = "all" ] || [ "$TARGET" = "ios" ]; then run_ios; fi

echo
echo "=========================================="
echo "  万象书屋检查结果: $PASS 通过 / $FAIL 失败"
echo "=========================================="
[ "$FAIL" -eq 0 ]
