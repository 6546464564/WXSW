#!/bin/bash
# 万象书屋: 不依赖 SSH，通过 HTTPS Admin API 更新书城 mirror
# 适用: 小火箭/Shadowrocket 开启时仍可执行（走 Cloudflare HTTPS）
#
# 用法:
#   ADMIN_PASSWORD=你的密码 bash deploy/deploy-mirror-https.sh
#   # 本地抓女频 + 上传 (需服务器已部署 publish 接口):
#   ADMIN_PASSWORD=xxx bash deploy/deploy-mirror-https.sh --publish-local
set -euo pipefail

BASE="${BACKEND_URL:-https://wxsw.app}"
PASSWORD="${ADMIN_PASSWORD:-${ADMIN_PWD:-}}"
COOKIE_JAR="$(mktemp)"
BACKEND_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cleanup() { rm -f "$COOKIE_JAR"; }
trap cleanup EXIT

if [[ -z "$PASSWORD" ]]; then
  echo "请设置 ADMIN_PASSWORD 环境变量"
  exit 1
fi

echo ">>> 登录 $BASE ..."
LOGIN=$(curl -sS -m 20 -c "$COOKIE_JAR" -X POST "$BASE/api/admin/login" \
  -H 'Content-Type: application/json' \
  -d "{\"password\":\"$PASSWORD\"}")
echo "$LOGIN" | grep -q '"ok":true' || { echo "登录失败: $LOGIN"; exit 1; }

if [[ "${1:-}" == "--publish-local" ]]; then
  echo ">>> 本地抓取 mirror (含 ranksFemale) 并上传..."
  cd "$BACKEND_DIR"
  node scripts/publish-mirror-remote.js
  exit 0
fi

echo ">>> 触发服务端 mirror 刷新..."
REFRESH=$(curl -sS -m 120 -b "$COOKIE_JAR" -X POST "$BASE/api/admin/bookstore-mirror/refresh" \
  -H 'Content-Type: application/json')
echo "$REFRESH"

if echo "$REFRESH" | grep -q '"ok":true'; then
  echo ">>> mirror 刷新成功"
else
  echo ">>> mirror 刷新失败"
  exit 1
fi

echo ">>> 检查 ranksFemale ..."
HAS_FEMALE=$(curl -sS -m 20 "$BASE/api/bookstore/mirror" | python3 -c "
import sys, json
d = json.load(sys.stdin)
rf = d.get('ranksFemale')
print('yes' if rf and sum(len(v) for v in rf.values()) > 0 else 'no')
" 2>/dev/null || echo "unknown")

if [[ "$HAS_FEMALE" == "no" ]]; then
  echo ""
  echo "⚠️  线上 mirror 仍无 ranksFemale — 服务器代码偏旧，需 SSH 部署新 backend 后执行:"
  echo "    ADMIN_PASSWORD=xxx bash deploy/deploy-mirror-https.sh --publish-local"
  echo "    或: bash deploy/deploy-to-server.sh"
fi
