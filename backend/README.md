# 万象书屋后端

Node.js + Express + SQLite，单文件启动，附带网页版管理面板。

```
backend/
├── server.js          Express 入口
├── db.js              SQLite 数据访问层
├── package.json
├── public/
│   └── admin.html     管理面板（vanilla JS + Tailwind CDN + ECharts）
├── scripts/
│   └── seed-default-sources.js  从 App 内置 JSON 导入书源（npm run seed）
├── data/              SQLite 数据库存放目录（运行时自动创建）
├── Caddyfile          Caddy 反代示例
├── wanxiang.service   systemd 启动单元
├── run-local.ps1      Windows 本地一键启动（需 Node LTS）
└── README.md
```

## App 端填入后端地址

在 Legado 工程根目录 `gradle.properties` 里配置（或 `-PWANXIANG_BACKEND_URL=...` 命令行传入）：

```properties
WANXIANG_BACKEND_URL=https://www.wxsw.app
```

重新编译安装后，`BuildConfig.BACKEND_BASE_URL` 生效，`WanxiangBackend` 会拉取 `/api/sources` 并定期 POST `/api/ping`。

## 提供给 App 的接口

| Method | Path | 用途 |
|---|---|---|
| `GET` | `/api/sources` | App 启动时拉取所有启用的书源（JSON 数组） |
| `POST` | `/api/ping` | 心跳上报，body `{device_id: "..."}`；用于实时在线 + DAU 统计 |

## 管理面板

- URL：`https://www.wxsw.app/admin`
- 默认密码：`wanxiang2026`（首次启动后**立即在面板里改密码**）
- 功能：
  - 实时在线人数（5 分钟窗）
  - 今日 / 本周 / 本月独立设备访问数 + 7 天折线图
  - 书源列表（增删改 / 启用禁用 / 查看 JSON / 批量导入 JSON 数组）

### 为什么刚装好后台「看不到书源」？

后端 SQLite **默认为空**。App 里的书源在 **设备本地 / 安装包 assets**，**不会自动同步到服务器**。要看到后端的列表：

1. **从本仓库一键灌入（与客户端默认一致）**：在 `backend` 目录执行 **`npm run seed`**（会从 `app/src/main/assets/defaultData/bookSources.json` 导入）。服务器/VPS 上若没有附带 Android 工程，可复制该 JSON 到任意路径后：`BOOK_SOURCES_JSON=/path/to/bookSources.json npm run seed`
2. **在管理页「批量导入」**：粘贴书源 JSON 数组。

导入成功后刷新 `/admin`；公开接口 **`GET /api/sources`** 会返回启用中的书源供 App 拉取。

## 一键部署到 Linux VPS

> 假设系统是 Ubuntu / Debian / CentOS，已有 root，已有指向 VPS 的域名。

```bash
# 1. 安装运行时
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt install -y nodejs build-essential
# Caddy 自动 HTTPS（也可以用 nginx + certbot）
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy

# 2. 部署后端
sudo useradd -r -s /bin/false wanxiang || true
sudo mkdir -p /opt/wanxiang
sudo rsync -av --exclude node_modules --exclude data ./ /opt/wanxiang/
cd /opt/wanxiang
sudo -u wanxiang npm install --production

# 3. 配 systemd
sudo cp wanxiang.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now wanxiang
sudo systemctl status wanxiang     # 应该是 active (running)

# 4. 配 Caddy（仓库内 `Caddyfile` 已为 www.wxsw.app；域名不同时请改站点块）
sudo cp Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy

# 5. 导入默认书源（否则后台为空）
# 若 VPS 上是完整仓库（含 app/src/main/assets/defaultData/bookSources.json）：
cd /opt/wanxiang && sudo -u wanxiang npm run seed
# 若只拷了 backend 目录：先把 bookSources.json 上传到服务器，再执行：
# sudo -u wanxiang env BOOK_SOURCES_JSON=/opt/wanxiang/bookSources.json npm run seed

# 6. 检查
curl https://www.wxsw.app/api/sources    # 应返回 JSON 数组（导入后有数据）
```

## 本地开发

```bash
cd backend
npm install
node server.js
# 浏览器访问 http://localhost:3000/admin
# 默认密码 wanxiang2026
```

**Windows**：先安装 [Node.js LTS](https://nodejs.org/)（安装程序会带上 `npm`）。然后在 `backend` 目录执行：

```powershell
.\run-local.ps1
```

若提示无法加载脚本：`powershell -ExecutionPolicy Bypass -File .\run-local.ps1`

## 修改默认密码

首次启动后，请用浏览器进入 `https://www.wxsw.app/admin`，登录后点右上角「修改密码」按钮。
设了之后 systemd 单元里的 `ADMIN_INITIAL_PASSWORD` 就没用了，可以从 `wanxiang.service` 删掉。

## 数据库结构

| 表 | 字段 | 说明 |
|---|---|---|
| `book_sources` | url(PK), name, json, enabled, created_at, updated_at | 书源主表，json 字段存完整 Legado v3 书源 JSON |
| `heartbeats` | device_id, ts | 实时心跳，30 天后自动清理 |
| `visits` | device_id, day, first_ts | 每天每设备一条，用于 DAU 统计，90 天后清理 |
| `admin` | id=1, pwd_hash | 单管理员，bcrypt |
| `admin_session` | token, created_at | 7 天过期 |

## 安全建议

- 默认密码 `wanxiang2026` **必须改**
- VPS 防火墙：只开 80 / 443，不暴露 3000
- 定期备份 `/opt/wanxiang/data/wanxiang.db` 文件即可恢复全部数据
