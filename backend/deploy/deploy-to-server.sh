#!/bin/bash
# 万象书屋 - 本地一键部署到服务器
# 用法: bash deploy/deploy-to-server.sh
set -euo pipefail

SERVER="root@wxsw.app"
BACKEND_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo ">>> 打包后端代码..."
tar czf /tmp/wanxiang-backend.tar.gz \
    --exclude='node_modules' --exclude='data/*.db*' \
    --exclude='data/backup' --exclude='.env' \
    --exclude='test' --exclude='*.test.js' \
    --exclude='wanxiang.sqlite' \
    -C "$BACKEND_DIR" .

echo ">>> 上传到服务器 ($SERVER)..."
scp /tmp/wanxiang-backend.tar.gz "$SERVER:/tmp/"

echo ">>> 执行远程更新..."
ssh "$SERVER" '/opt/wanxiang/update.sh'

rm -f /tmp/wanxiang-backend.tar.gz
echo ">>> 部署完成!"
