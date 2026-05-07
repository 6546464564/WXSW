# 万象书屋后端优化建议

> 当前后端 (Node.js + Express + better-sqlite3 + 单实例 SQLite WAL) 已经支撑书源管理 / 访问统计 / 广告配置 + 书源体检 4 个模块. 下面是按优先级排序的优化清单, 每条都给「价值 / 工作量 / 实施提示」, 你按需挑.

---

## 一、书源管理模块

### 已有
- CRUD (单条 / 批量 upsert / 删除 / 启停)
- raw JSON 查看
- **新增: 准确性体检 (字段 + 主域可达 + 可选搜索探活)** ←本次实现

### 推荐改进 (按价值排序)

| # | 名称 | 价值 | 工作量 | 提示 |
|---|---|---|---|---|
| 1 | **导入/导出整包** | 高 | 0.5h | 加 `GET /api/admin/sources/export` 直接下载 `book_sources.json`, App 端可用同一个 endpoint backup; admin 加"上传文件" 输入 |
| 2 | **分组过滤 + 一键启停整组** | 中 | 1h | `bookSourceGroup` 字段已存在但 admin 没用. 列表上方加 group dropdown, 加"启用本组 / 禁用本组" 按钮 |
| 3 | **失效自动停用** | 高 | 1h | 体检功能跑完后, 给 error 行加 `[一键禁用全部异常]` 按钮; 调 `setEnabled(url, false)` 批量, 不删, 留作 archived |
| 4 | **使用统计** | 中 | 2h | App 端命中某个源时上报 `POST /api/source-hit {url, action: search/info/toc/content}`; 后端 group by 按周聚合, admin 列"过去 7 天命中数", 让用户砍掉一直不用的 |
| 5 | **定时体检 + 邮件通知** | 中 | 2h | crontab/setInterval 每天 03:00 自动跑全量体检, 失败超 5 条时给管理员邮箱发提醒 (用 `nodemailer`) |
| 6 | **搜索框** | 低 | 0.5h | 现在 38 条还能用列表, 上百条就要客户端 filter (按 name/url 模糊匹配) |
| 7 | **站点级缓存** (慎用) | 低 | 1h | `/api/sources` 加 5 分钟 ETag 内存缓存, 减少多端拉取时的 SQLite 反复读 (实测当前不是瓶颈) |
| 8 | **去重智能 merge** | 低 | 1h | bulk upsert 时, 如果传入的 source 与现有同 url 但 ruleSearch 不同, 弹 confirm 让用户决定是否覆盖 (现在静默 update) |

---

## 二、访问统计模块

### 已有
- 实时在线 (5 分钟窗口) / 今日 / 本周 / 本月 (独立设备)
- 7 天 / 自定义天数曲线

### 推荐改进

| # | 名称 | 价值 | 工作量 | 提示 |
|---|---|---|---|---|
| 1 | **App 版本分布** | 高 | 1.5h | 心跳 body 加 `app_ver` (App 端早就有 BuildConfig.VERSION_NAME); 后端加 `versions` 表 `(device_id, ver, day)`; admin 显示饼图 "用户分版本占比", 决定何时下线兼容代码 |
| 2 | **时段分布** | 中 | 1h | heartbeats 已有精确 ts, 新接口 `/api/admin/stats/hourly?days=7` 按小时 bucket, 显示一天 24 小时活跃曲线 |
| 3 | **留存/流失** | 中 | 2h | 用 visits 表算 D1/D7/D30 留存率: 当日新增设备里, 第 7 天还活跃的占比; 给 admin 一个"群组留存"模块 |
| 4 | **崩溃/错误上报** | 高 | 3h | App 端 `CrashHandler` 已存在但只本地存. 加 `POST /api/crash-log` (rate-limited), 后端落 `crashes` 表; admin 看错误堆栈聚合 + 出现频率 (类似 mini Sentry, 不上 Sentry SDK 即可) |
| 5 | **地理粗分布** | 低 | 1h + ip 库 | 不准备引第三方就用 `geoip-lite`, 按 ip CIDR 段算省份, 仅展示到省级别避免隐私问题 |
| 6 | **图表更细** | 低 | 0.5h | 已经用 ECharts, 加多曲线 (DAU + WAU + MAU 同图叠加) |

---

## 三、广告配置模块

### 已有
- 全局 disabled 总开关
- CSJ + YLH 双 SDK appId
- splash + rewardedReadingUnlock 两个 placement, 每个 placement 多 provider 权重路由
- 历史版本回滚, ETag 缓存, 客户端可调 pollIntervalSec
- 客户端隐私同意 + Lifecycle 安全 + 失败 fallback

### 推荐改进

| # | 名称 | 价值 | 工作量 | 提示 |
|---|---|---|---|---|
| 1 | **广告效果回传** | 高 | 3h | App 端 SplashAdListener / RewardAdInteractionListener 已有所有事件钩子, 加 `POST /api/ad-event {placement, provider, type: load/show/click/reward, errCode}`, 后端按天聚合, admin 看「曝光 → 点击 → 完播」漏斗, 决定哪个 SDK 该提权重 |
| 2 | **熔断/降级** | 高 | 2h | 后端定时算"过去 1h CSJ splash 错误率 > 30%" 时, 自动 push 一个版本把 csj weight 降到 0; 配合 #1 用. 防止账号被封时一边用户全 fallback 一边自己没察觉 |
| 3 | **A/B 测试分桶** | 中 | 3h | 配置加字段 `experiments: [{ id, weight, override: {placements: ...} }]`; 客户端用 `device_id` 哈希取模分桶, 各桶用不同 weight; 后端按桶聚合 #1 数据看哪个桶 eCPM 高 |
| 4 | **按版本灰度** | 中 | 1.5h | `/api/ad-config?ver=1.2.3` 时后端按 `versionRange` 决定下发哪一份配置; 新 posId 先发给 50% 老版本观察一周再全量, 风险低 |
| 5 | **CSJ「新插屏」显式建模** | 中 | 1.5h | 当前 CsjProvider 在 splash API 失败 (40019) 才 fallback 到 fullScreenVideo, 不优雅. 加 `ProviderSlot.type: "splash" / "interstitial"` 字段, admin 可显式选, 流程更可控 |
| 6 | **广告位扩展** | 中 | 2h/位 | 现在只 splash + rewarded. 加: 章末插屏 / 书架信息流 / 搜索结果原生; 不需要新 placement 类型, 数据模型已通用, 主要是 App 端找注入点 |
| 7 | **VIP / 兑换码免广告** | 中 | 3h | 加 `redeem_codes` 表 (code, expires_at, used_by_device, granted_days); App 端「我的→兑换码」输入后写到本地 SP, AdManager 检测到 SP 有有效期不弹广告 |
| 8 | **广告白名单设备** | 低 | 0.5h | 加 `dev_devices: [device_id...]` 数组; 列表中的设备永远 disabled, 你自己测试时不被广告打扰 |

---

## 四、横向 / 工程化建议 (跨模块)

| # | 名称 | 价值 | 工作量 | 提示 |
|---|---|---|---|---|
| 1 | **HTTPS 强制** (上线必备) | 必须 | 0.5h + nginx | 套 nginx + Let's Encrypt; `app.set('trust proxy', 1)` 已经写了, 直接生效 |
| 2 | **SQLite 自动备份** | 高 | 1h | 每天 02:00 用 `sqlite3.backup()` 复制 `wanxiang.db` 到 `data/backup/wanxiang-YYYYMMDD.db`, 保留最近 14 份; 单点故障时能找回最近 24h 数据 |
| 3 | **结构化日志** | 中 | 1h | 当前都是 `console.log`. 引 `pino` 输出 JSON 行, 支持级别 + 滚动文件; 出问题时 `grep` 能找到 |
| 4 | **API 限流扩展** | 中 | 1h | 当前只 admin/login 有限速. 公开 `/api/sources` `/api/ad-config` 也加按 IP 1 QPS, 防爬 |
| 5 | **多管理员 / RBAC** | 中 | 4h | 单密码 admin 模型适合个人项目. 多人协作时加 `users (id, name, pwd_hash, role)` + `role: 'admin' | 'viewer'`, viewer 只能看不能改 |
| 6 | **审计日志** | 中 | 1.5h | 所有写操作 (upsertSource, deleteSource, setEnabled, setAdminPassword, saveAdConfig) 都落 `audit_log` 表; admin 加"操作历史" tab |
| 7 | **健康检查端点** | 低 | 0.2h | `GET /api/health` 返 `{db: ok, uptime, mem}`; 配合 uptime monitor (Uptime Kuma 等) |
| 8 | **环境配置抽离** | 低 | 0.5h | 当前密码默认 `wanxiang2026` 写死在 db.js. 加 `.env` + `dotenv`, 部署时用环境变量覆盖 |

---

## 五、近期最优 ROI 三件套 (我的私货推荐)

如果只能挑 3 件做, 我会按这个顺序:

1. **广告效果回传 (#3.1) + 熔断 (#3.2)** — 你刚接好广告, 这俩是变现规模化的前置, 没数据无从优化
2. **HTTPS + SQLite 自动备份 (#4.1, #4.2)** — 上线最低门槛, 出事不会无米下锅
3. **失效书源自动停用 (#1.3) + 分组管理 (#1.2)** — 体检功能我刚上线, 加这俩才形成"发现 → 处置" 闭环

剩下的等你看到对应数据/痛点再选。
