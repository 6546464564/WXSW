#!/bin/bash
# 万象书屋 - 本地一键部署到服务器
# 用法: bash deploy/deploy-to-server.sh
#
# 小火箭/Shadowrocket: 已配置 ProxyCommand=none 直连 IP, 避免 fake-ip 干扰 SSH。
# 若 SSH 仍失败 (kex 阶段断开), 多为 VPS fail2ban 封 IP — 用控制台解封,
# 或先走 HTTPS: bash deploy/deploy-mirror-https.sh
set -euo pipefail

SERVER="root@31.220.30.21"
SSH_OPTS=(-o ConnectTimeout=20 -o ProxyCommand=none -o BatchMode=yes)
BACKEND_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo ">>> 打包后端代码..."
tar czf /tmp/wanxiang-backend.tar.gz \
    --exclude='node_modules' --exclude='data/*.db*' \
    --exclude='data/backup' --exclude='.env' \
    --exclude='test' --exclude='*.test.js' \
    --exclude='wanxiang.sqlite' \
    -C "$BACKEND_DIR" .

echo ">>> 上传到服务器 ($SERVER)..."
scp "${SSH_OPTS[@]}" /tmp/wanxiang-backend.tar.gz "$SERVER:/tmp/"

echo ">>> 执行远程更新..."
ssh "${SSH_OPTS[@]}" "$SERVER" '/opt/wanxiang/update.sh'

rm -f /tmp/wanxiang-backend.tar.gz
echo ">>> 部署完成!"
