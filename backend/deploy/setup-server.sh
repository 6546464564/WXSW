#!/usr/bin/env bash
# ============================================================
# 万象书屋 - 新服务器一键部署脚本
# 目标: Ubuntu/Debian 服务器, Docker + Nginx 方案
# 用法: bash setup-server.sh
# ============================================================
set -euo pipefail

SERVER_IP="wxsw.app"
APP_DIR="/opt/wanxiang"
ADMIN_PWD="wanxiang2026"
DEVICE_SECRET=$(head -c 32 /dev/urandom | xxd -p | tr -d '\n')

echo "╔══════════════════════════════════════════════════╗"
echo "║     万象书屋 · 新服务器部署脚本                  ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── 0. 基础环境 ──────────────────────────────────────
echo ">>> [1/7] 更新系统 & 安装基础工具..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget git unzip nano ufw openssh-server

# 确保 SSH 正常运行
systemctl enable ssh
systemctl restart ssh
echo ">>> SSH 已启动 (端口 22)"

# ── 1. 防火墙 ──────────────────────────────────────
echo ""
echo ">>> [2/7] 配置防火墙..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp     # SSH
ufw allow 80/tcp     # HTTP
ufw allow 443/tcp    # HTTPS
ufw --force enable
ufw status
echo ">>> 防火墙已启用: 允许 22, 80, 443"

# ── 2. 安装 Docker ──────────────────────────────────
echo ""
echo ">>> [3/7] 安装 Docker..."
if command -v docker &>/dev/null; then
    echo "Docker 已安装, 跳过"
else
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi
docker --version
echo ">>> Docker 安装完成"

# ── 3. 安装 Nginx ──────────────────────────────────
echo ""
echo ">>> [4/7] 安装 Nginx..."
apt-get install -y -qq nginx
systemctl enable nginx
echo ">>> Nginx 安装完成"

# ── 4. 部署后端代码 ──────────────────────────────────
echo ""
echo ">>> [5/7] 部署后端代码..."
mkdir -p "$APP_DIR"

if [ -f /tmp/wanxiang-backend.tar.gz ]; then
    echo "从上传的压缩包解压..."
    tar xzf /tmp/wanxiang-backend.tar.gz -C "$APP_DIR"
else
    echo "⚠️  未找到 /tmp/wanxiang-backend.tar.gz"
    echo "请先上传代码包: scp wanxiang-backend.tar.gz root@${SERVER_IP}:/tmp/"
    echo "然后重新运行此脚本"
    exit 1
fi

# 创建 .env
cat > "$APP_DIR/.env" <<ENVEOF
NODE_ENV=production
PORT=3000
DB_PATH=/app/data/wanxiang.db
ADMIN_INITIAL_PASSWORD=${ADMIN_PWD}
DEVICE_TOKEN_SECRET=${DEVICE_SECRET}
SECURE_COOKIE=0
BCRYPT_COST=8
LOG_LEVEL=info
BACKUP_RETENTION_DAYS=7
ENVEOF

echo ">>> .env 已生成 (管理员密码: ${ADMIN_PWD})"

# ── 5. Docker 构建 & 启动 ──────────────────────────────
echo ""
echo ">>> [6/7] 构建并启动 Docker 容器..."
cd "$APP_DIR"
mkdir -p data

docker build -t wanxiang-backend:latest .
docker rm -f wanxiang-backend 2>/dev/null || true
docker run -d \
    --name wanxiang-backend \
    --restart unless-stopped \
    -p 127.0.0.1:3000:3000 \
    -v "$APP_DIR/data":/app/data \
    --env-file "$APP_DIR/.env" \
    --memory=512m \
    --log-opt max-size=10m \
    --log-opt max-file=5 \
    wanxiang-backend:latest

sleep 3
if docker ps | grep -q wanxiang-backend; then
    echo ">>> 容器启动成功!"
    docker logs wanxiang-backend --tail 10
else
    echo ">>> ⚠️ 容器启动失败, 查看日志:"
    docker logs wanxiang-backend
    exit 1
fi

# ── 6. 配置 Nginx 反向代理 ──────────────────────────────
echo ""
echo ">>> [7/7] 配置 Nginx..."

# 品牌主页
mkdir -p /opt/wanxiang/web /opt/wanxiang/dl
if [ -f "$APP_DIR/web/index.html" ]; then
    cp "$APP_DIR/web/index.html" /opt/wanxiang/web/
fi

cat > /etc/nginx/sites-available/wanxiang <<'NGINXEOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 25M;
    access_log /var/log/nginx/wanxiang-access.log;
    error_log /var/log/nginx/wanxiang-error.log;

    # 品牌主页
    location = / {
        root /opt/wanxiang/web;
        try_files /index.html =404;
        add_header Cache-Control "public, max-age=300";
    }
    location = /index.html {
        root /opt/wanxiang/web;
        add_header Cache-Control "public, max-age=300";
    }
    location /web/ {
        alias /opt/wanxiang/web/;
        autoindex off;
        expires 1d;
        add_header Cache-Control "public, max-age=86400";
    }

    # APK 下载
    location /dl/ {
        alias /opt/wanxiang/dl/;
        autoindex off;
        types {
            application/vnd.android.package-archive apk;
            text/html html;
        }
        sendfile on;
        sendfile_max_chunk 1m;
        if ($request_uri ~* "\.apk$") {
            add_header Content-Disposition 'attachment';
            add_header Cache-Control 'no-store';
        }
    }

    # API + Admin 反代
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/wanxiang /etc/nginx/sites-enabled/wanxiang
nginx -t && systemctl reload nginx

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║              🎉 部署完成!                        ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  品牌主页:   http://${SERVER_IP}/                ║"
echo "║  管理后台:   http://${SERVER_IP}/admin            ║"
echo "║  API 健康:   http://${SERVER_IP}/api/health       ║"
echo "║  API 文档:   http://${SERVER_IP}/api-docs         ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║  管理员账号: admin                               ║"
echo "║  管理员密码: ${ADMIN_PWD}                        ║"
echo "║  SSH:        ssh root@${SERVER_IP}               ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "后续可选:"
echo "  1. 绑定域名 + HTTPS: 参考 deploy/HTTPS-DEPLOY.md"
echo "  2. 查看容器日志: docker logs -f wanxiang-backend"
echo "  3. 重启服务: docker restart wanxiang-backend"
