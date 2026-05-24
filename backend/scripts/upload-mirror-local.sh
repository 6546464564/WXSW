#!/bin/bash
# 万象书屋: 本机抓起点 mirror → 上传线上 (服务器 IP 常被 403)
#
# 用法:
#   ADMIN_PASSWORD=你的密码 bash scripts/upload-mirror-local.sh
#
# 可选:
#   BACKEND_URL=https://wxsw.app ADMIN_PASSWORD=xxx bash scripts/upload-mirror-local.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${ADMIN_PASSWORD:-}" && -z "${ADMIN_PWD:-}" ]]; then
  echo "请设置 ADMIN_PASSWORD"
  exit 1
fi

node scripts/publish-mirror-remote.js
