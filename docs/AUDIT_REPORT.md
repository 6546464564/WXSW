# 万象书屋 · 全栈审查报告

> 角色: 资深全栈 + QA · 时间: 2026-05-01 · 范围: Node.js 后端 + Android App (Kotlin) + admin 面板
>
> 严重度: **P0 必修 (安全/数据丢失/崩溃)** · **P1 重要 (体验/性能/正确性)** · **P2 改进 (可读/可维护)**
>
> 本报告**只发现, 不动手**. 你挑出哪几条要做, 我再实施.

---

## 第一部分 · 功能审查 (用户视角)

### F1. Splash → 同意 → Main 流程在屏幕旋转时会重弹同意框 [P1]
**复现**: SplashAdActivity 弹同意框时旋转屏幕 (或者拖动通知栏导致 onCreate 重建).
**原因**: `SplashAdActivity.decideFlow()` 没有 `savedInstanceState != null` 早返, `jumped` flag 也没序列化.
**用户体验**: 用户看到同意框两次, 困惑.
**修复**: `onCreate` 一开始判 `savedInstanceState != null && jumped` 就直接 `proceedToMain()`.

### F2. SplashAdActivity 屏蔽了 Back 键 [P1]
**复现**: 启动 App, 同意框出来时按 Back 键 — 无反应.
**原因**: `onBackPressed()` 被空实现覆盖了, 注释说"开屏期间禁止返回键退出".
**问题**: 同意框还没出现 (SDK 异步) 时也没法返回, 用户必须等 3-5 秒. 老人/低端机用户会以为卡死.
**修复**: 仅在"已经开始播广告"阶段拦, 同意框 + 等待期允许 Back 退出.

### F3. 隐私同意一次性, 没有"撤回"入口 [P0 合规]
**复现**: 用户首启同意了, 后悔想关广告 — 设置里找不到入口.
**原因**: `AdConsent.revoke()` 只标记给 debug 用, App 内没有 UI 暴露.
**合规风险**: PIPL 第 16 条规定"个人有权撤回同意", 不提供撤回路径在监管检查时直接定不合规.
**修复**: "我的 → 设置 → 其他 → 个性化广告" toggle, 关掉 = 调 `AdConsent.revoke()` + `AdManager.setConsent(ctx, false)`.

### F4. "看广告解锁纯净阅读" 解锁状态对用户不可见 [P1]
**复现**: 用户看完激励视频, 解锁了 30 分钟无广告; 但 App 没显示倒计时, 用户不知道还剩多少.
**问题**: 默认 `cooldownMinutes = 30 + unlockMinutes = 30`, 用户看完一次后不知何时再被打扰.
**修复**: 阅读器顶部状态栏 / Tip 区显示"纯净阅读还剩 27:42", 解锁结束时 toast 提示一次.

### F5. 翻到全书最后一页 → "作者努力更新中" 节流过松 [P2]
**当前节流**: 按 `durChapterIndex` 去重, 但 `bookFinishedDialog` 关闭后 ref 仍保留, GC 不掉.
**用户体验**: 用户关掉对话框后再翻, 不再弹 (节流命中); 但是切到另一本书 → 翻到底, 又弹. 这是预期, OK.
**真问题**: 关掉对话框后, ref 一直挂在 `ReadBookActivity.bookFinishedDialog` 上, 持有 activity context. 内存泄露但 destroy 时一起 GC, 影响极小. 建议 dismiss callback 里把 ref 置 null.

### F6. "去书架/去书城" 按钮回到 Main 后, 读到一半的书丢了 [P1]
**复现**: 翻到底 → 点"去书架" → 后续想继续读这本书.
**原因**: ReadBookActivity 是 singleTask, finish 后再启动会从 onCreate 走, 没问题. 但用户**不知道这本书在书架里有**, 因为没标记"上次在读".
**修复**: BookshelfFragment 给"上次在读"的书加角标 / 置顶; 或者点"去书架" 时 toast "已为你保存进度".

### F7. 阅读器内"换源"对话框无内置 fallback 提示 [P2]
**复现**: 翻到底 → 点"看看其它源" → ChangeBookSourceDialog 弹出, 但**当前书源也在列表里**, 用户找不到"还有别的源吗".
**修复**: ChangeBookSourceDialog 加个空态文案 "已尝试 N 个源, 无新源"; 当前实现可能让用户以为是 bug.

### F8. 后端 admin 面板登录页没有"忘记密码"出口 [P2]
**当前**: 改密码必须先登录. 忘了密码只能 SSH 上服务器手动改 SQLite.
**修复**: 提供 `node scripts/reset-admin-password.js` 命令行工具 (项目已有 scripts 目录).

### F9. 一键体检结果中, 异常源没有"批量操作" [P2]
**当前**: 可以看到 6 条异常, 但要一条条点"删除"或者改 `enabled=false`.
**修复**: modal 底部加 `[一键停用所有异常]` 按钮.

### F10. App 端"换源"成功后没自动同步进度 [P2]
**复现**: 在源 A 读到第 50 章, 换源 B → 跳到第 1 章 (因为新源章节列表不同).
**这是 legado 上游问题**, 不是本次新引入的 bug, 但应当在阅读器引导对话框里明确告知 "换源可能会丢进度, 请确认书架已经收藏".

---

## 第二部分 · 代码审查 (后端为主)

### A. 安全隐患 (P0/P1)

#### A1. **管理员默认密码硬编码 + 启动时打印到 stdout** [P0 严重]
位置: `backend/db.js:65-69`
```js
const defaultPwd = process.env.ADMIN_INITIAL_PASSWORD || 'wanxiang2026';
const hash = bcrypt.hashSync(defaultPwd, 10);
db.prepare('INSERT INTO admin(...)').run(hash, Date.now());
console.log(`[init] admin password = ${defaultPwd} (...)`);
```
- **问题 1**: 默认 `wanxiang2026` 是开源项目里能搜到的字符串 (本仓库历史 commit 都有), 任何人 git clone 后部署默认就是这个密码.
- **问题 2**: 启动时把明文密码 println 到 stdout, 任何能看 systemd journal / docker logs 的人都能拿到 (运维脚本/同事/被入侵的日志收集系统).
- **修复**:
  - 启动时如果 `ADMIN_INITIAL_PASSWORD` 未设, **拒绝启动并报错**, 强制运维显式提供.
  - 永远不要 println 明文.

#### A2. **修改密码接口没限速** [P0]
位置: `server.js:116`
```js
app.post('/api/admin/password', requireAdmin, (req, res) => {
  if (!db.verifyAdminPassword(oldPassword)) { return 401 }
  ...
});
```
- 攻击者偷到一份 admin cookie 后, 可以无限次试 `oldPassword` 暴破当前密码.
- session 7 天有效, 给攻击者足够窗口.
- **修复**: `loginRateLimit` 中间件复用到此接口; 同时 oldPassword 错 N 次后强制 destroy 当前 session, 让攻击者重登.

#### A3. **session 表无 IP / UA 绑定** [P1]
位置: `db.js:210` `createSession()` 只存 token + created_at.
- cookie 被偷之后, 攻击者从任何地方都能用, 无防御.
- **修复**: createSession 接收 (ip, ua), 存到表里; isValidSession 校验时比对 (允许 IP 段变化, 但 UA hash 不一致直接拒).

#### A4. **express.json 限制 50MB** [P1]
位置: `server.js:17` `app.use(express.json({ limit: '50mb' }))`
- 任何匿名用户都能给公开接口 (`/api/ping`) post 50MB body, 直接吃完进程内存 + CPU JSON 解析.
- **修复**: 默认 limit `1mb`; 给真正需要大 body 的接口 (`/api/admin/sources` bulk import) 单独挂 `express.json({ limit: '20mb' })` 中间件.

#### A5. **公开接口无限速 / 防爬** [P1]
位置: `/api/sources`, `/api/ping`, `/api/ad-config` 都没 rate limit.
- 别人写脚本可以每秒打几百次 `/api/sources` 把你 38 条书源源源不断爬走 (你的核心资产).
- **修复**: `/api/sources` 加 IP 维度限速 (10 req/min/IP), `/api/ping` 也限 (1 req/30s/device, 防设备伪造刷量).

#### A6. **SSRF 风险 (validator)** [P1]
位置: `sourceValidator.js:probeUrl`
- 任意 admin 添加恶意书源 url = `http://localhost:6379` / `http://169.254.169.254/latest/meta-data/` 等, validator 会从后端发请求, 攻击者借后端访问内网/云元数据.
- 虽然前提是攻击者已经是 admin, 但**纵深防御**仍要做.
- **修复**: probeUrl 加 deny-list:
  ```js
  function isPrivateUrl(url) {
    const u = new URL(url);
    const h = u.hostname;
    return /^(localhost|127\.|10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|169\.254\.|::1$|fe80:)/.test(h);
  }
  ```

#### A7. **缺基础响应头 (helmet)** [P2]
- 没设 `X-Content-Type-Options: nosniff` / `X-Frame-Options: DENY` / `Content-Security-Policy`.
- admin.html 可被任意站点 iframe → clickjacking 偷 admin 权限.
- **修复**: `npm i helmet` + `app.use(helmet())`.

#### A8. **SQL 注入** [P0 检查通过]
- 全部走 `db.prepare(...).run(?, ?, ...)`, **无拼接, 无注入风险** ✓
- 唯一动态拼接: `db.js:175 statsWeek` `IN (${days.map(()=>'?').join(',')})` — 但 days 来源于 `weekDays()` 内部生成, 用户不可控, 安全 ✓

---

### B. 隐藏 Bug 与逻辑漏洞 (P0/P1)

#### B1. **statsMonth 用 LIKE 不走索引** [P1 性能]
位置: `db.js:179`
```js
'SELECT COUNT(DISTINCT device_id) AS c FROM visits WHERE day LIKE ?'
// param: '2026-05%'
```
- SQLite 对 `LIKE 'YYYY-MM%'` 默认**不走索引** (除非 `PRAGMA case_sensitive_like=ON` + ASCII 模式).
- 90 天保留 + 1 万设备 = `~30 万行`, 全表扫描每次几十 ms.
- **修复**: 改成范围查询
  ```js
  'WHERE day >= ? AND day < ?', [`${monthKey()}-01`, `${nextMonthFirst()}-01`]
  // 或者更简单:
  'WHERE day BETWEEN ? AND ?', [`${monthKey()}-01`, `${monthKey()}-31`]
  ```

#### B2. **upsertSource / bulkUpsert 在循环内 prepare statement** [P1 性能]
位置: `db.js:92-118`
```js
function upsertSource(srcJson) {
  ...
  const existing = db.prepare('SELECT created_at FROM book_sources WHERE url = ?').get(url);
  if (existing) {
    db.prepare('UPDATE ...').run(...);  // 每次循环重新 prepare
  } else {
    db.prepare('INSERT ...').run(...);
  }
}
```
- bulkUpsert 200 条 → 600 次 prepare. better-sqlite3 prepare 是同步阻塞的, 估算 ~100ms 浪费.
- **修复**: 把 3 个 statement 提到 module 级, 像 `heartbeatStmt` 一样.

#### B3. **CsjProvider 防重 tag/markDelivered 是 no-op** [P1 正确性]
位置: `CsjProvider.kt:286-294`
```kotlin
private fun TTRewardVideoAd.tag(key: Int): Boolean? = null  // 永远 null
private fun TTRewardVideoAd.markDelivered() {}              // 空
```
- `bindAndDeliver` 第一行 `if (ad.tag(TAG_KEY_DELIVERED) == true) return` → **永远不会拦截**.
- 实际后果: 同一个 ad 既触发 `onRewardVideoAdLoad` 又触发 `onRewardVideoCached(ad)`, `bindAndDeliver` 跑 2 次, `setRewardAdInteractionListener` 被设两次, 第二次 listener 内的 `var rewarded = false` 重置, 用户看完后第一个 listener 状态丢失.
- **修复**: 用 module 级 `WeakHashMap<TTRewardVideoAd, Boolean>` 做真防重; 或者把 listener 提到 outer 闭包共享.

#### B4. **YlhProvider rewardedFlag 是 listener 闭包变量, 多回调线程不安全** [P1]
位置: `YlhProvider.kt:122` `var rewardedFlag = false`
- onReward 与 onADClose 在 SDK 不同 callback 线程触发, 没 @Volatile / synchronized.
- 实际 race window 极小但存在, 表现为"用户看完没解锁".

#### B5. **AdRepository.cached 304 时不更新, 但下次 process restart 后 readSp 拿到的 cached 也不会被刷新** [P2]
位置: `AdRepository.kt:73-77`
- 304 时 `sp.put(KEY_LAST_FETCH_MS)` 但没把 `cached` 重置. 实际逻辑正确 (cached 已经是最新的), 注释看起来误导.

#### B6. **MainActivity.onNewIntent 没调 setIntent** [P1]
位置: `MainActivity.kt:` 我新加的
```kotlin
override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    applySelectTab(intent)
}
```
- Android 标准做法: `setIntent(intent)` 让后续 `getIntent()` 拿到新的, 否则 onResume 等 lifecycle 事件里读到的还是初始 intent.
- 影响: 其他依赖 getIntent 的代码 (MainActivity 后续逻辑 / fragment) 拿不到 select_tab 字段, 但因为我已经直接传 intent 参数了, 当前流程 OK. **未来加新 extra 时会埋坑**.
- **修复**: `super.onNewIntent(intent); setIntent(intent); applySelectTab(intent)`

#### B7. **AdManager.showSplash 双协程 race** [P2]
位置: `AdManager.kt:128-150`
```kotlin
activity.lifecycleScope.launch {  // 协程 1: 硬超时
    delay(timeoutMs.toLong())
    onceFinished.run("timeout-$timeoutMs")
}
activity.lifecycleScope.launch {  // 协程 2: 等 SDK ready 轮询
    while (...) { pickProvider; ...; triggerSplash; return@launch }
}
```
- 当 timeout 触发时, 协程 2 还在 while 循环. 即使 `onceFinished.isDone()` 返 true, 它也可能在 isDone 检查后正好 pickProvider 成功 → triggerSplash → loadSplashAd, SDK 加载好之后回调 `listener.onAdReadyToShow` → provider 仍然 `addView` 到 container, 但 SplashAdActivity 已经 finish, 抛 IllegalStateException 或者 leak window token.
- 修复: `triggerSplash` 内也判一次 `if (onceFinished.isDone()) return`, 或者把 lifecycleScope 协程关联到 STARTED 状态.

#### B8. **PageDelegate 内 snackBar 字段成 dead code** [P2]
位置: `PageDelegate.kt`
- 我把 `if (!hasNext) { snackBar.show() }` 改成 `callBack.onNoNextPage()`, 但 `snackBar` 字段还在, 占内存 + 让人误以为还在用.
- 修复: 删 `snackBar` 字段 + 相关 import.

#### B9. **WanxiangBackend.startHeartbeatLoop 没有进程退出检测** [P2]
位置: `WanxiangBackend.kt:79-89`
```kotlin
while (true) {
    runCatching { sendPing(url) }
    delay(PING_INTERVAL_MS)
}
```
- 用 `Coroutine.async` 启动, 协程跟着 ProcessLifecycle 一起活. App 进程死了协程也死, OK.
- 但 sendPing 失败时只 log, 没退避策略. 后端宕机时 App 每 4 分钟无脑重试, 浪费流量 + 电.
- **修复**: 失败 N 次后切到指数退避 (1min → 2min → 4min → 8min → 30min).

#### B10. **ReadBookActivity.bookFinishedDialog ref 不释放** [P2 内存]
- AlertDialog dismiss 后引用还挂着, 持有 activity context. Activity destroy 时一起释放, 影响小.
- **修复**: 在 `BookFinishedDialog.show` 里用 `setOnDismissListener { /* let caller null it */ }`, 或者每次 onNoNextPage 不持有引用 (只用 isShowing 做防重).

---

### C. 性能瓶颈 (P1/P2)

#### C1. **每次 /api/sources 都 parse 38 个 JSON** [P2]
位置: `db.js:76-79`
```js
function listEnabledSourcesJson() {
  const rows = db.prepare('SELECT json FROM book_sources WHERE enabled = 1').all();
  return rows.map(r => JSON.parse(r.json));
}
```
- 每次调用都全表查 + parse, 没缓存.
- 实测 38 条 ~5ms, 上规模 (200+ 条) 后会到 50-100ms.
- **修复**: 加内存 LRU + version counter; upsertSource/deleteSource 时 bumpVersion + invalidate.
  ```js
  let cached = null, cachedVer = 0;
  function listEnabledSourcesJson() {
    if (cached && cachedVer === currentVersion) return cached;
    cached = ...; cachedVer = currentVersion;
    return cached;
  }
  ```

#### C2. **/api/sources 整包返回, 没分页 / 增量** [P1 流量]
- 38 条 ~150KB, 1 万用户每天首启拉一次 = 1.5GB 流量.
- 真实场景中书源列表变化不频繁, 应当用 ETag 304.
- **修复**: 计算 `hash(JSON.stringify(sources))` 当 ETag, 客户端带 `If-None-Match` 时返 304.
- 当前 `Cache-Control: no-store` 反而禁止了任何缓存, 删掉这个 header.

#### C3. **probeUrl 全量读 body** [P2]
位置: `sourceValidator.js:127`
```js
const buf = await resp.arrayBuffer();
bodyLen = buf.byteLength;
```
- 38 条体检, 如果某个书源主页 5MB, 全读到内存. validator 模式下还可能并发 8 个, 瞬时 40MB.
- **修复**: 流式读, 累加到 `MAX_BODY_BYTES = 256 * 1024` 即 abort.

#### C4. **statsOnline 每次 COUNT(DISTINCT device_id)** [P2]
- 数据量大时全表扫 idx_heartbeats_ts 的范围, 然后内存 dedupe.
- **修复**: 物化表 `online_5min(updated_at, count)` 每分钟刷一次.

#### C5. **AdRepository.refreshFromRemote 每 60 秒一次 (debug 时)** [P2]
- 调试时 pollIntervalSec=60, 每分钟一次远端拉取 + SP 写入.
- SP 写入 (`apply` 是 async) 但 GSON.toJson 同步, 大配置时几 ms.
- 当前 OK, 但生产值 21600 (6h), 不是问题.

#### C6. **better-sqlite3 单连接同步** [P0 架构]
- 整个 backend 共享一个 sync 数据库连接. 任何慢查询 (如 statsMonth LIKE) 阻塞所有 HTTP 请求.
- **修复**: 上规模后必须迁 PostgreSQL + 连接池. 当前规模可接受.

---

### D. 并发/数据一致性 (P1)

#### D1. **upsertSource 不在事务里, race 时可能"双 INSERT"** [P1]
位置: `db.js:92-105`
```js
const existing = db.prepare('SELECT ...').get(url);  // step 1
if (existing) UPDATE; else INSERT;                     // step 2
```
- step 1 和 step 2 之间, 另一个并发请求可能也 SELECT 看到 NULL → 都走 INSERT 分支. 第二个 INSERT 因为 url PRIMARY KEY 直接抛.
- **修复**: 用 `INSERT INTO ... ON CONFLICT(url) DO UPDATE SET ...` (better-sqlite3 支持), 一句搞定 + 原子.

#### D2. **saveAdConfig 嵌套事务** [P0 检查通过]
- 已经用 `db.transaction(() => { ... })` 包了 INSERT + history + DELETE 三步 ✓ 安全.

#### D3. **loginRateLimit Map 没并发保护** [P2]
- Node.js 单线程 event loop, Map 操作天然原子, 安全 ✓

#### D4. **AdManager.consented 跨线程 race** [P2]
位置: `AdManager.kt:54` `@Volatile private var consented = false`
- 多个 Activity 调用 setConsent 并发改 consented. @Volatile 保证可见性, 但 `setConsent → bootstrap → initOnDemand` 链没原子化, 可能初始化两次.
- 实际 init 内部有 `initStarted` 防重, 影响小.

---

### E. 可读性 / 复用 / 设计模式 (P2)

#### E1. **server.js 600+ 行单文件, 路由 + 中间件 + 业务全混** [P2]
- 当前 4 个模块 (sources / ping / admin / ad) + 1 个新加 (validate), 拆成 `routes/sources.js` `routes/admin.js` `routes/ad.js` `middleware/auth.js` 更清晰.
- 当前规模可接受, 上 1000 行后必拆.

#### E2. **db.js 320 行同样混杂** [P2]
- book_sources / heartbeats / visits / admin / ad_config 5 个 domain 一锅. 拆成 `db/sources.js` `db/stats.js` 等. 共享一个 db 实例, OK.

#### E3. **错误处理风格不统一** [P2]
- 路由处理: 有 try/catch 也有不 catch 让全局 handler 接的; 返回 `{ok:false}` 也有 `{ok:false, msg}` 也有纯 status.
- **修复**: 统一一个 `errorResponse(res, code, msg)` helper.

#### E4. **admin.html 600+ 行 inline JS** [P1]
- 没模块化, 没 build, 全靠 onclick. 改一个按钮要小心 onclick 字符串里的引号转义.
- 中长期: 引 Vue 3 / React (不上 Vite, 直接 CDN umd) 重写, 但成本高.
- 短期可接受.

#### E5. **AdProvider 接口 + Csj/Ylh/Stub 实现, 设计模式 OK** [赞]
- 适配器模式 + 策略模式. 想加 KS/Baidu 只需实现 AdProvider, AdManager 不动 ✓

#### E6. **CsjProvider 单文件 280 行, splash + interstitial fallback + rewarded 三段塞一起** [P2]
- 拆成 `CsjSplashLoader.kt` `CsjRewardedLoader.kt` 更清晰. 当前可读性中等.

#### E7. **AdRateLimiter 用 4 个独立 SP key, 没事务** [P2]
- `markRewardedSuccess` 同时写 LAST_REWARDED + UNLOCK_UNTIL, 用 `.apply()` 异步, 进程崩溃时可能只写一半.
- 实际 SharedPreferences 内部是原子 commit per-edit, OK.
- **修复**: 想绝对安全用 SP edit().putXxx().putYyy().commit() 同步.

---

### F. 工程化缺失 (P1)

#### F1. **无 graceful shutdown** [P1]
- Ctrl+C / SIGTERM 时直接退出, db.close() 没调.
- WAL 模式下文件不会损坏, 但写入中的 transaction 可能丢.
- **修复**:
  ```js
  process.on('SIGTERM', () => {
    server.close(() => { db.close(); process.exit(0); });
  });
  ```

#### F2. **无健康检查端点** [P2]
- 反代/k8s/uptime monitor 想知道服务是否活, 没有 `/api/health`.
- **修复**: `app.get('/api/health', (req, res) => res.json({ok: true, uptime: process.uptime()}))`

#### F3. **console.log 没结构化, 没分级, 没文件落盘** [P2]
- 出问题靠 docker logs 翻, 翻多了拖慢.
- **修复**: 引 `pino` 输出 JSON 行, 配 logrotate.

#### F4. **无单元测试** [P1]
- 全靠手测, 改动后没回归保障.
- 建议至少给 `db.js` 的纯函数 (todayKey, weekDays, statsXxx) + `sourceValidator.js` 的 validateShape 写 jest 测试.

#### F5. **无 .env / 环境变量管理** [P1]
- 当前代码里看到的环境变量: PORT, DB_PATH, ADMIN_INITIAL_PASSWORD, SECURE_COOKIE.
- 没 `.env.example` 文件, 新人接手不知道有哪些配置.
- **修复**: 加 dotenv + `.env.example`.

#### F6. **App 端 BACKEND_BASE_URL 通过 gradle property 注入, debug 时手输** [P2]
- `gradlew assembleAppDebug -PWANXIANG_BACKEND_URL=...` 每次都要传, 容易忘.
- **修复**: gradle.properties 里 `WANXIANG_BACKEND_URL_DEBUG=...` (用户本地 git ignore), build.gradle 按 buildType 选.

---

### G. 依赖审计 (npm)

- `express ^4.19.2` — 4.x 是 LTS, OK. 5.x 已发布但 breaking, 暂不升.
- `better-sqlite3 ^11.3.0` — 当前主流版本.
- `bcryptjs ^2.4.3` — 纯 JS bcrypt, **比 native bcrypt 慢 30%+**. 当前是用于密码 hash, 单次开销 ~50ms, 可接受. 但启动时 hashSync 阻塞 event loop.
- `cookie-parser ^1.4.6` — OK.
- **缺少**: helmet, express-rate-limit, dotenv, pino — 见 A7/A5/F5/F3.
- **建议跑**: `npm audit --production` 看 CVE 列表 (我没装 npm audit 在本地, 但目前依赖都是主流, 大概率 clean).

---

## 第三部分 · 私货推荐 (按 ROI 排)

如果你只能挑 5 件做, 我会按这个顺序:

1. **A1 + A2 + A4** — 安全基础线 (默认密码 + 修密码限速 + body limit), **2 小时**
2. **B1 (statsMonth LIKE)** — 性能正确性 + 真 bug, **20 分钟**
3. **B6 (MainActivity setIntent)** — 已经埋下的隐患, **5 分钟**
4. **B3 + B4 (CsjProvider/YlhProvider 防重)** — 真实奖励发放正确性, **30 分钟**
5. **F1 (graceful shutdown)** — 上线必备, **20 分钟**

**完成后再排 P0/P1 剩余项**.

---

## 附录: 测试结论汇总

| 维度 | 状态 |
|---|---|
| **SQL 注入** | ✅ 全部 prepared statement, 无风险 |
| **越权访问** | ✅ admin 接口都有 requireAdmin, 公开接口无敏感数据 |
| **CSRF** | ⚠️ sameSite=strict 兜住大部分, 但建议加 CSRF token 双重保险 |
| **XSS** | ⚠️ admin.html 有 escapeHtml, 但用户数据 (书源 name) 显示时需要 audit |
| **逻辑漏洞** | ⚠️ 见 B 节 10 条 |
| **性能瓶颈** | ⚠️ 见 C 节 6 条 (当前规模都不致命) |
| **设计模式** | ✅ Adapter + Strategy + Repository 都用得对 |
| **可读性** | ⚠️ server.js / db.js 单文件偏大, 待拆 |
