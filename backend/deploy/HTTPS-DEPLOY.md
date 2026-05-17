# 万象书屋 HTTPS 部署 (备案下来后, 30 分钟搞定)

iOS App Store 强制 ATS, 不能走 HTTP. 必须配 HTTPS.

## 前置 (业务层)

- 已买域名 (例 `wanxiangbook.com`) 实名认证
- ICP 备案号下来 (大陆上架硬性, 7-14 天)
- DNS A 记录: `api.wanxiangbook.com` → `wxsw.app`
  - 验证: `dig api.wanxiangbook.com` 应返 `wxsw.app`

## 第 1 步: 装 certbot (1 分钟)

```bash
ssh root@wxsw.app
apt update && apt install -y certbot python3-certbot-nginx
mkdir -p /var/www/letsencrypt
```

## 第 2 步: 签证书 (5 分钟)

⚠️ 先不要换 nginx 配置 — 用现有 HTTP 配置, 让 certbot 验证域名能用 80 端口.

```bash
certbot certonly --webroot -w /var/www/letsencrypt \
    -d api.wanxiangbook.com \
    -d wanxiangbook.com \
    --email your-email@example.com --agree-tos --no-eff-email
```

成功后看到:
```
Certificate is saved at: /etc/letsencrypt/live/api.wanxiangbook.com/fullchain.pem
Key is saved at:         /etc/letsencrypt/live/api.wanxiangbook.com/privkey.pem
```

## 第 3 步: 改 nginx 用 HTTPS 模板 (5 分钟)

⚠️ 先把 `nginx-wanxiang-https.conf` 里的 `api.wanxiangbook.com` 全部替换成你的真实域名.

```bash
# 本地 (Windows)
scp backend/deploy/nginx-wanxiang-https.conf root@wxsw.app:/etc/nginx/sites-available/wanxiang

# 服务器
nginx -t                 # 语法检查
systemctl reload nginx   # 0 停机 reload
```

测试:
```bash
curl -I https://api.wanxiangbook.com/api/health
# 应返 200 OK + Strict-Transport-Security header
curl -I http://api.wanxiangbook.com/api/health
# 应返 301 → https://...
```

## 第 4 步: 自动续期 (验证一次)

```bash
systemctl status certbot.timer
# 应该是 active (waiting), 每天 2 次自动检查并续期
certbot renew --dry-run
# 验证续期流程能跑通
```

## 第 5 步: 更新 App 后端 URL

```properties
# Android: gradle.properties
WANXIANG_BACKEND_URL=https://api.wanxiangbook.com
```

```swift
// iOS: WanxiangAPI.swift
static let base = "https://api.wanxiangbook.com"
```

## 第 6 步: 验证 iOS ATS 通过

```bash
# Mac 上 (装了 nscurl 的 Xcode 命令行工具)
nscurl --ats-diagnostics https://api.wanxiangbook.com/api/health
# 应该 16 个测试全部 PASS
```

## 回滚

如果出问题想立刻回到 HTTP:

```bash
# 服务器上有旧配置自动备份
ls /etc/nginx/sites-available/wanxiang.bak.*
cp /etc/nginx/sites-available/wanxiang.bak.<时间戳> /etc/nginx/sites-available/wanxiang
nginx -t && systemctl reload nginx
```

## 常见坑

| 现象 | 原因 | 解决 |
|---|---|---|
| `cannot load certificate` | certbot 还没签 | 先跑第 2 步 |
| iOS 模拟器请求 NSURLErrorDomain Code=-1202 | 证书链不全 / 未信任 | 换 fullchain.pem 不要 cert.pem |
| 中国大陆访问 80/443 被运营商干 | 没备案 | 备案完成才能开 80/443 |
| Let's Encrypt 限频 | 1 周 5 次 | 先用 `--dry-run` 调试 |
| App 请求 502 | Node 后端没起 | `systemctl status wanxiang-backend.service` |
