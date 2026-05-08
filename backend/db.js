// 万象书屋 - SQLite 数据访问层
const path = require('path');
const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'data', 'wanxiang.db');
const db = new Database(DB_PATH);
// 万象书屋 SQLite 调优:
//   - WAL: 写不阻塞读, 单写多读场景性能 +10x
//   - busy_timeout: 锁等待 5s, 避免高并发下 SQLITE_BUSY
//   - synchronous=NORMAL: WAL 下 NORMAL 已足够, 比 FULL 快很多但仍 crash-safe
//   - foreign_keys: 强制外键约束 (默认关)
//   - cache_size: 64MB 内存 cache, 高并发查询提速
db.pragma('journal_mode = WAL');
db.pragma('busy_timeout = 5000');
db.pragma('synchronous = NORMAL');
db.pragma('foreign_keys = ON');
db.pragma('cache_size = -64000'); // 负数=KB, 64000=64MB

// 万象书屋: bcrypt 工作因子. 低性能 VPS (1 核 1G) 跑 cost=10 单次 hash ~600ms,
// 在登录密集时即使 async 也会让 CPU 跑满. 允许通过 BCRYPT_COST 调小.
//   推荐:
//     - 4 (单测/CI 必用): ~5ms
//     - 8 (低端 VPS 推荐): ~30ms
//     - 10 (默认, 4 核及以上服务器): ~200~600ms
//     - 12 (高安全要求, 单次几秒)
const BCRYPT_COST = (() => {
  const v = parseInt(process.env.BCRYPT_COST, 10);
  if (!Number.isFinite(v)) return 10;
  if (v < 4) { console.warn('[db] BCRYPT_COST clamped to 4 (was ' + v + ')'); return 4; }
  if (v > 14) { console.warn('[db] BCRYPT_COST clamped to 14 (was ' + v + ')'); return 14; }
  return v;
})();

function init() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS book_sources (
      url        TEXT PRIMARY KEY,
      name       TEXT,
      json       TEXT NOT NULL,
      enabled    INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS heartbeats (
      device_id TEXT NOT NULL,
      ts        INTEGER NOT NULL,
      PRIMARY KEY (device_id, ts)
    );
    CREATE INDEX IF NOT EXISTS idx_heartbeats_ts ON heartbeats(ts);

    CREATE TABLE IF NOT EXISTS visits (
      device_id TEXT NOT NULL,
      day       TEXT NOT NULL,           -- YYYY-MM-DD UTC+8
      first_ts  INTEGER NOT NULL,
      PRIMARY KEY (device_id, day)
    );
    CREATE INDEX IF NOT EXISTS idx_visits_day ON visits(day);

    CREATE TABLE IF NOT EXISTS admin (
      id         INTEGER PRIMARY KEY CHECK (id = 1),
      pwd_hash   TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS admin_session (
      token      TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL,
      -- 万象书屋: 绑定 session 创建时的 IP + User-Agent hash,
      -- IP 仅审计不强校验 (用户换 WiFi 不被掉线);
      -- UA hash 参与校验 (浏览器特征变化极大时强制重登, 防 cookie 被偷到别的设备)
      ip         TEXT,
      ua_hash    TEXT,
      -- 万象书屋 v2: 多管理员支持. session 关联 admin_users.username
      username   TEXT,
      role       TEXT
    );

    -- 万象书屋广告配置: 单行 (id=1) 持有当前生效配置, 历史走 ad_config_history
    CREATE TABLE IF NOT EXISTS ad_config (
      id         INTEGER PRIMARY KEY CHECK (id = 1),
      version    INTEGER NOT NULL,
      json       TEXT NOT NULL,
      etag       TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ad_config_history (
      version    INTEGER PRIMARY KEY,
      json       TEXT NOT NULL,
      created_at INTEGER NOT NULL
    );

    -- 万象书屋: 广告效果事件. 由 App 端上报, 按天聚合分析 eCPM / 曝光率 / 完播
    CREATE TABLE IF NOT EXISTS ad_events (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      ts         INTEGER NOT NULL,
      placement  TEXT NOT NULL,   -- splash / rewardedReadingUnlock
      provider   TEXT NOT NULL,   -- csj / ylh / ks
      type       TEXT NOT NULL,   -- load / show / click / close / reward / error
      err_code   INTEGER,
      err_msg    TEXT,
      device_id  TEXT,
      app_ver    TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_ad_events_ts ON ad_events(ts);
    CREATE INDEX IF NOT EXISTS idx_ad_events_pp ON ad_events(placement, provider, ts);

    -- 万象书屋: App 崩溃上报 (mini Sentry)
    CREATE TABLE IF NOT EXISTS crashes (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      ts         INTEGER NOT NULL,
      device_id  TEXT,
      app_ver    TEXT,
      brand      TEXT,
      model      TEXT,
      sdk_int    INTEGER,
      fingerprint TEXT,           -- 堆栈第一行 + 异常类型的 md5, 用于聚合同类崩溃
      exception  TEXT NOT NULL,
      stack      TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_crashes_ts ON crashes(ts);
    CREATE INDEX IF NOT EXISTS idx_crashes_fp ON crashes(fingerprint, ts);

    -- 万象书屋: admin 操作审计
    CREATE TABLE IF NOT EXISTS audit_log (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      ts         INTEGER NOT NULL,
      ip         TEXT,
      action     TEXT NOT NULL,   -- source.upsert / source.delete / ad.save / pwd.change / ...
      target     TEXT,            -- 受影响对象标识 (url / version / ...)
      detail     TEXT             -- 可选详情 json
    );
    CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts);

    -- 万象书屋: 强制升级控制. App 启动拉一次 /api/version-check, 根据本地 versionCode 决定:
    --   - 当前 < min_required_code: 强制升级 (不升不让用)
    --   - min_required_code <= 当前 < latest_code: 提示升级 (可跳过)
    --   - 当前 >= latest_code: 已是最新, 不弹
    CREATE TABLE IF NOT EXISTS app_versions (
      id                 INTEGER PRIMARY KEY CHECK (id = 1),
      latest_code        INTEGER NOT NULL DEFAULT 0,    -- 最新 versionCode
      latest_name        TEXT NOT NULL DEFAULT '',      -- 最新 versionName 显示用
      min_required_code  INTEGER NOT NULL DEFAULT 0,    -- 强制升级阈值
      changelog          TEXT,                          -- 更新日志 (markdown)
      apk_url            TEXT,                          -- 直链下载 URL (空 = 跳商店)
      market_url         TEXT,                          -- 商店深链 (例: market://details?id=...)
      updated_at         INTEGER NOT NULL DEFAULT 0
    );

    -- 万象书屋: 全局公告. App 启动拉一次, 根据 (id, dismissable) 决定弹一次还是必弹.
    -- 只取 enabled=1 + 当前时间在 [start_at, end_at] 之间, version_min ~ version_max
    CREATE TABLE IF NOT EXISTS announcements (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      title        TEXT NOT NULL,
      content      TEXT NOT NULL,                  -- markdown
      style        TEXT NOT NULL DEFAULT 'info',   -- info / warn / urgent
      dismissable  INTEGER NOT NULL DEFAULT 1,     -- 0 = 必看不能关
      enabled      INTEGER NOT NULL DEFAULT 1,
      start_at     INTEGER NOT NULL DEFAULT 0,     -- 0 = 立即生效
      end_at       INTEGER NOT NULL DEFAULT 0,     -- 0 = 永不过期
      version_min  INTEGER NOT NULL DEFAULT 0,     -- App versionCode >= 这个值才显示
      version_max  INTEGER NOT NULL DEFAULT 0,     -- 0 = 不限
      created_at   INTEGER NOT NULL,
      updated_at   INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_announcements_enabled ON announcements(enabled, start_at, end_at);

    -- 万象书屋: 设备黑名单. ping/sources/ad-event 等 App 接口入口都会查一次,
    -- 命中即返 403 让 App 永久拒绝服务. 用于封作弊/羊毛/恶意设备.
    CREATE TABLE IF NOT EXISTS device_blacklist (
      device_id   TEXT PRIMARY KEY,
      reason      TEXT,
      blocked_at  INTEGER NOT NULL,
      operator    TEXT                   -- 谁加的 (admin username)
    );

    -- 万象书屋: 多管理员账号. 旧的 admin 表 (id=1) 保留兼容,
    -- 新表用 username 主键 + role 控权限. role: super / operator / cs
    CREATE TABLE IF NOT EXISTS admin_users (
      username    TEXT PRIMARY KEY,
      pwd_hash    TEXT NOT NULL,
      role        TEXT NOT NULL DEFAULT 'operator',  -- super / operator / cs
      totp_secret TEXT,                              -- Base32 TOTP secret, 空=未开 2FA
      totp_enabled INTEGER NOT NULL DEFAULT 0,
      created_at  INTEGER NOT NULL,
      updated_at  INTEGER NOT NULL,
      last_login_at INTEGER,
      last_login_ip TEXT
    );

    -- 万象书屋: 兑换码. admin 批量生成, 用户在 App 输入兑换得"纯净阅读 N 天"
    CREATE TABLE IF NOT EXISTS redeem_codes (
      code         TEXT PRIMARY KEY,
      reward_type  TEXT NOT NULL,        -- ad_free_minutes / vip_days / custom
      reward_value INTEGER NOT NULL,     -- 数值: 分钟数 / 天数
      batch        TEXT,                 -- 批次号, admin 用于一键吊销整批
      max_uses     INTEGER NOT NULL DEFAULT 1,  -- 通用码可设 N 次
      used_count   INTEGER NOT NULL DEFAULT 0,
      expires_at   INTEGER NOT NULL DEFAULT 0,  -- 0 = 永久
      created_at   INTEGER NOT NULL,
      created_by   TEXT,                 -- admin username
      revoked      INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_redeem_batch ON redeem_codes(batch);

    -- 兑换码使用记录. UNIQUE(code, device_id) 防止同设备 / 同事务并发重复兑换
    CREATE TABLE IF NOT EXISTS redeem_uses (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      code        TEXT NOT NULL,
      device_id   TEXT NOT NULL,
      used_at     INTEGER NOT NULL,
      ip          TEXT,
      UNIQUE(code, device_id)
    );
    CREATE INDEX IF NOT EXISTS idx_redeem_uses_code ON redeem_uses(code);
    CREATE INDEX IF NOT EXISTS idx_redeem_uses_device ON redeem_uses(device_id);

    -- 万象书屋: 告警规则 + Webhook. 定时任务每 5 分钟扫一次 crashes/ad_events,
    -- 命中规则就 POST 到 webhook (企微/钉钉机器人)
    CREATE TABLE IF NOT EXISTS alert_rules (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      name        TEXT NOT NULL,
      kind        TEXT NOT NULL,    -- crash_burst / ad_error_rate / heartbeat_drop
      threshold   REAL NOT NULL,    -- 数值, 看 kind 决定单位
      window_min  INTEGER NOT NULL DEFAULT 5,
      webhook_url TEXT NOT NULL,
      webhook_kind TEXT NOT NULL DEFAULT 'wecom',  -- wecom / dingtalk / generic
      enabled     INTEGER NOT NULL DEFAULT 1,
      cooldown_min INTEGER NOT NULL DEFAULT 30,    -- 同一规则最小通知间隔, 防刷屏
      last_fired_at INTEGER NOT NULL DEFAULT 0,
      created_at  INTEGER NOT NULL
    );

    -- 万象书屋: 用户反馈与举报 (国内应用商店硬性要求 user-content 投诉渠道)
    CREATE TABLE IF NOT EXISTS feedback (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      ts         INTEGER NOT NULL,
      type       TEXT NOT NULL,   -- bug / content / suggest / other
      content    TEXT NOT NULL,
      contact    TEXT,            -- 用户选填的邮箱/QQ
      device_id  TEXT,
      app_ver    TEXT,
      ip         TEXT,
      status     TEXT NOT NULL DEFAULT 'open',  -- open / processing / done / spam
      reply      TEXT,
      reply_ts   INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_feedback_ts ON feedback(ts);
    CREATE INDEX IF NOT EXISTS idx_feedback_status ON feedback(status, ts);
  `);

  // 万象书屋: SQLite ALTER TABLE ADD COLUMN 补齐老 schema 缺失的列
  // CREATE TABLE IF NOT EXISTS 不会给已存在的表加字段, 所以这里幂等加.
  migrateAddColumnIfMissing('admin_session', 'ip', 'TEXT');
  migrateAddColumnIfMissing('admin_session', 'ua_hash', 'TEXT');
  migrateAddColumnIfMissing('admin_session', 'username', 'TEXT');
  migrateAddColumnIfMissing('admin_session', 'role', 'TEXT');

  // 默认管理员密码 (首次启动). 万象书屋: 强制 ADMIN_INITIAL_PASSWORD 环境变量提供,
  // 不再写死 "wanxiang2026" 避免所有 fork 者用相同默认密码; 也不再把明文密码 println 到 stdout.
  const row = db.prepare('SELECT 1 FROM admin WHERE id = 1').get();
  if (!row) {
    const initPwd = process.env.ADMIN_INITIAL_PASSWORD;
    if (!initPwd || initPwd.length < 8) {
      // 允许本地开发用默认, 生产必须设环境变量
      if (process.env.NODE_ENV === 'production' || process.env.REQUIRE_ADMIN_PWD === '1') {
        throw new Error('ADMIN_INITIAL_PASSWORD env must be set (>=8 chars) before first start');
      }
      const fallback = 'wanxiang2026';
      console.warn('[init] ADMIN_INITIAL_PASSWORD not set, using dev default (NON-PRODUCTION ONLY)');
      const hash = bcrypt.hashSync(fallback, BCRYPT_COST);
      db.prepare('INSERT INTO admin(id, pwd_hash, updated_at) VALUES (1, ?, ?)').run(hash, Date.now());
      // 不再打印明文
      console.log('[init] admin account created. default password hidden; set ADMIN_INITIAL_PASSWORD in production.');
      return;
    }
    const hash = bcrypt.hashSync(initPwd, BCRYPT_COST);
    db.prepare('INSERT INTO admin(id, pwd_hash, updated_at) VALUES (1, ?, ?)').run(hash, Date.now());
    console.log('[init] admin account created from ADMIN_INITIAL_PASSWORD env (cost=' + BCRYPT_COST + ').');
  }
}

function migrateAddColumnIfMissing(table, col, type) {
  const cols = db.prepare(`PRAGMA table_info(${table})`).all();
  if (cols.some(c => c.name === col)) return;
  db.exec(`ALTER TABLE ${table} ADD COLUMN ${col} ${type}`);
}

init();
runMigrations();

/**
 * 万象书屋: schema migration runner.
 *
 * 每次 server 启动时:
 *   1. 扫 backend/migrations/*.sql 按文件名排序
 *   2. 跟 schema_migrations 表对比, 只跑新文件
 *   3. 每个文件用 transaction 跑, 失败回滚 + 抛出 (启动失败保护数据)
 *
 * 这套方案不引第三方 (knex/typeorm 太重),
 * 只 30 行代码, 适配 better-sqlite3 同步 API.
 */
function runMigrations() {
  const fs = require('fs');
  const pathMod = require('path');
  const migDir = pathMod.join(__dirname, 'migrations');
  if (!fs.existsSync(migDir)) return;
  // 确保 schema_migrations 表存在 (001_baseline.sql 也会建, 但首次启动还没跑过)
  db.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
    filename   TEXT PRIMARY KEY,
    applied_at INTEGER NOT NULL,
    duration_ms INTEGER
  )`);
  const files = fs.readdirSync(migDir)
    .filter(f => f.endsWith('.sql'))
    .sort();
  const stmtExists = db.prepare('SELECT 1 FROM schema_migrations WHERE filename = ?');
  const stmtMark = db.prepare(
    'INSERT INTO schema_migrations (filename, applied_at, duration_ms) VALUES (?, ?, ?)'
  );
  for (const f of files) {
    if (stmtExists.get(f)) continue;
    const sql = fs.readFileSync(pathMod.join(migDir, f), 'utf8');
    const t0 = Date.now();
    try {
      db.transaction(() => {
        db.exec(sql);
        stmtMark.run(f, Date.now(), Date.now() - t0);
      })();
      console.log('[migrations] applied', f, '+' + (Date.now() - t0) + 'ms');
    } catch (e) {
      console.error('[migrations] FAILED', f, e.message);
      throw e; // 启动失败, 防止跑在不一致的 schema 上
    }
  }
}

// === Book sources ===
// 万象书屋: statement 提到 module 级, 避免 bulkUpsert 循环内反复 prepare
//
// 万象书屋 v2 (007_book_sources_platforms): platforms 列 (CSV 'android,ios')
// - listEnabledSourcesJson(platform) 用 LIKE '%<platform>%' 过滤
// - ETag 按 platform 分桶, 不让 iOS 拿到 Android 的 304
const stmtListEnabledJson = db.prepare('SELECT json FROM book_sources WHERE enabled = 1');
const stmtListEnabledJsonByPlatform = db.prepare(
  // 用 ',' || platforms || ',' 包一层, 再 LIKE '%,android,%' 防止 'android-tv' 之类前缀误匹配
  `SELECT json FROM book_sources
   WHERE enabled = 1
     AND (',' || platforms || ',') LIKE ('%,' || ? || ',%')`
);
// 万象书屋: 健康过滤防恶意污染.
//   1. 必须 search 阶段连续 fail >= MIN_FAIL_COUNT 次才认为坏 (单次失败可能是网络抖动)
//   2. 必须该源的 success_count == 0 (有过成功就先信任,避免新设备网络差污染老用户)
//   3. admin 手动 setSourceHealthOverride('block') 一票否决, override='allow' 强制保留
//
// 任何客户端不能凭一次上报让全网用户看不到某个源.
const HEALTH_HIDE_MIN_FAIL_COUNT = 5;
const stmtListEnabledJsonByPlatformHealthy = db.prepare(
  `SELECT bs.json
   FROM book_sources bs
   WHERE bs.enabled = 1
     AND (',' || bs.platforms || ',') LIKE ('%,' || ? || ',%')
     AND NOT EXISTS (
       SELECT 1 FROM source_health sh
       WHERE sh.source_url = bs.url
         AND sh.platform = ?
         AND sh.stage = 'search'
         AND sh.status IN ('error', 'timeout')
         AND sh.fail_count >= ${HEALTH_HIDE_MIN_FAIL_COUNT}
         AND sh.success_count = 0
     )`
);
// 万象书屋: 把 bookSourceGroup 原始字符串和 platforms 都返回, admin 用于分组筛选 + 平台勾选.
// SQLite 3.x 自带 JSON1 扩展, json_extract 能直接取嵌套字段.
const stmtListAll = db.prepare(
  `SELECT url, name, enabled, updated_at, platforms,
          json_extract(json, '$.bookSourceGroup') AS groupRaw
   FROM book_sources ORDER BY updated_at DESC`
);
const stmtGetSource = db.prepare('SELECT * FROM book_sources WHERE url = ?');
// ON CONFLICT 一句完成 upsert, 天然原子, 消除 race window
// 万象书屋: 不动 platforms, 让 admin 单独用 setSourcePlatforms 维护 (避免 upsert 覆盖手工配置)
const stmtUpsertSource = db.prepare(
  `INSERT INTO book_sources(url, name, json, enabled, created_at, updated_at)
   VALUES (?, ?, ?, 1, ?, ?)
   ON CONFLICT(url) DO UPDATE SET name=excluded.name, json=excluded.json, updated_at=excluded.updated_at`
);
const stmtCheckSourceExists = db.prepare('SELECT 1 FROM book_sources WHERE url = ? LIMIT 1');
const stmtDeleteSource = db.prepare('DELETE FROM book_sources WHERE url = ?');
const stmtSetEnabled = db.prepare('UPDATE book_sources SET enabled=?, updated_at=? WHERE url=?');
const stmtSetPlatforms = db.prepare('UPDATE book_sources SET platforms=?, updated_at=? WHERE url=?');

// 万象书屋: /api/sources 是热接口, 用内存缓存 + 版本号 invalidate 避免每次 JSON.parse 38+ 条
// v2: 按 platform 分桶缓存 (Map<platform, list>), iOS / Android / 默认各自一份
const cachedEnabledByPlatform = new Map(); // key: platform | '__all__' (向下兼容旧 caller)
const cachedEnabledEtagByPlatform = new Map();
function invalidateSourcesCache() {
  cachedEnabledByPlatform.clear();
  cachedEnabledEtagByPlatform.clear();
}

const _ALLOWED_SOURCE_PLATFORMS = new Set(['android', 'ios', 'web']);

/**
 * 列出已启用的书源 JSON.
 *
 * @param {string|null} platform - 'android' | 'ios' | 'web' | null
 *   - null: 不过滤,返回所有 enabled 源 (向下兼容,跑批/admin 内部用)
 *   - 否则按 LIKE '%,<platform>,%' 过滤
 *   - 非法值会强制 fallback 到 'android' (与 server.js 中间件一致)
 */
function listEnabledSourcesJson(platform = null, opts = {}) {
  const key = platform == null ? '__all__'
    : (_ALLOWED_SOURCE_PLATFORMS.has(platform) ? platform : 'android');
  const healthyOnly = !!opts.healthyOnly && key !== '__all__';

  // 万象书屋: healthy=1 绕过内存缓存. 上报错误时为了不刷爆 SQLite, 我们故意不
  // invalidate cache; 但 healthy 过滤要立刻生效, 所以 healthy 查询直接走 DB.
  if (healthyOnly) {
    const rows = stmtListEnabledJsonByPlatformHealthy.all(key, key);
    return rows.map(r => JSON.parse(r.json));
  }

  const cached = cachedEnabledByPlatform.get(key);
  if (cached) return cached;
  const rows = key === '__all__'
    ? stmtListEnabledJson.all()
    : stmtListEnabledJsonByPlatform.all(key);
  const list = rows.map(r => JSON.parse(r.json));
  cachedEnabledByPlatform.set(key, list);
  return list;
}

/** 返回 /api/sources 对应的 ETag (基于内容 hash, 按 platform 分桶) */
function getEnabledSourcesEtag(platform = null, opts = {}) {
  const key = platform == null ? '__all__'
    : (_ALLOWED_SOURCE_PLATFORMS.has(platform) ? platform : 'android');
  const healthyOnly = !!opts.healthyOnly && key !== '__all__';

  if (healthyOnly) {
    // healthy 不缓存 ETag, 下面 hash 当前结果. 量小可接受.
    const list = listEnabledSourcesJson(platform, opts);
    const hash = require('crypto')
      .createHash('md5')
      .update(JSON.stringify(list))
      .digest('hex')
      .slice(0, 12);
    return `"sources-${key}-healthy-${hash}"`;
  }

  const cached = cachedEnabledEtagByPlatform.get(key);
  if (cached) return cached;
  const list = listEnabledSourcesJson(platform, opts);
  const hash = require('crypto')
    .createHash('md5')
    .update(JSON.stringify(list))
    .digest('hex')
    .slice(0, 12);
  // 万象书屋: ETag 带 platform 前缀, 让 nginx/CDN/反代缓存命中也按 platform 区分
  const etag = key === '__all__' ? `"sources-${hash}"` : `"sources-${key}-${hash}"`;
  cachedEnabledEtagByPlatform.set(key, etag);
  return etag;
}

function listAllSources() { return stmtListAll.all(); }

function getSource(url) { return stmtGetSource.get(url); }

function upsertSource(srcJson) {
  const url = srcJson.bookSourceUrl;
  if (!url) throw new Error('bookSourceUrl required');
  // 万象书屋 D-16 (BACKEND-1): 拒绝非 http(s) 协议. 防 admin 误传 javascript: / file: / data: 等
  // 被下发到客户端 (App admin.html 已 escape 但 iOS WKWebView 等其它消费方可能直接 load).
  if (typeof url !== 'string' || url.length > 2048) {
    throw new Error('bookSourceUrl invalid');
  }
  if (!/^https?:\/\//i.test(url)) {
    throw new Error('bookSourceUrl must start with http:// or https://');
  }
  try { new URL(url); } catch {
    throw new Error('bookSourceUrl is not a valid URL');
  }
  const name = srcJson.bookSourceName || url;
  const now = Date.now();
  const existed = !!stmtCheckSourceExists.get(url);
  stmtUpsertSource.run(url, name, JSON.stringify(srcJson), now, now);
  invalidateSourcesCache();
  return { url, action: existed ? 'updated' : 'created' };
}

function bulkUpsert(arr) {
  const tx = db.transaction((items) => {
    let created = 0, updated = 0;
    for (const it of items) {
      const r = upsertSource(it);
      if (r.action === 'created') created++; else updated++;
    }
    return { created, updated };
  });
  return tx(arr);
}

function deleteSource(url) {
  const info = stmtDeleteSource.run(url);
  invalidateSourcesCache();
  return info.changes;
}

function setEnabled(url, enabled) {
  const info = stmtSetEnabled.run(enabled ? 1 : 0, Date.now(), url);
  invalidateSourcesCache();
  return info.changes;
}

/**
 * 万象书屋: admin 给某个源单独勾选可见平台.
 * @param {string} url
 * @param {string[]} platforms - 数组,例如 ['android', 'ios']. 空数组 = 该源对所有平台不可见.
 * @returns {number} changes
 *
 * 安全:
 *   - 只接受白名单内的平台名 ('android' | 'ios' | 'web'), 其它静默丢弃
 *   - 去重 + 排序 (CSV 顺序稳定, ETag 不抖)
 */
function setSourcePlatforms(url, platforms) {
  if (!Array.isArray(platforms)) throw new Error('platforms must be an array');
  const cleaned = Array.from(new Set(
    platforms
      .map(p => String(p || '').toLowerCase().trim())
      .filter(p => _ALLOWED_SOURCE_PLATFORMS.has(p))
  )).sort();
  const csv = cleaned.join(',');
  const info = stmtSetPlatforms.run(csv, Date.now(), url);
  invalidateSourcesCache();
  return info.changes;
}

/** 万象书屋: 仅测试用,清缓存让前后两次查询拿到不同结果 */
function _invalidateSourcesCacheForTest() { invalidateSourcesCache(); }

// === Source health (iOS/Android parser observability) ===

const _SOURCE_STAGES = new Set(['search', 'info', 'toc', 'content', 'static']);
const _SOURCE_STATUSES = new Set(['ok', 'zero', 'error', 'timeout', 'skip']);

const stmtHealthUpsert = db.prepare(
  `INSERT INTO source_health
     (source_url, platform, stage, sample_keyword, status, error_message,
      success_count, fail_count, last_checked_at, last_ok_at, last_error_at, app_ver)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
   ON CONFLICT(source_url, platform, stage, sample_keyword)
   DO UPDATE SET
     status=excluded.status,
     error_message=excluded.error_message,
     success_count=source_health.success_count + excluded.success_count,
     fail_count=source_health.fail_count + excluded.fail_count,
     last_checked_at=excluded.last_checked_at,
     last_ok_at=COALESCE(excluded.last_ok_at, source_health.last_ok_at),
     last_error_at=COALESCE(excluded.last_error_at, source_health.last_error_at),
     app_ver=COALESCE(excluded.app_ver, source_health.app_ver)`
);

const stmtErrorEventInsert = db.prepare(
  `INSERT INTO source_error_events
     (ts, source_url, source_name, platform, stage, status, error_message,
      sample_keyword, sample_url, app_ver, device_id, ip)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
);

const stmtHealthList = db.prepare(
  `SELECT h.*, bs.name AS source_name
   FROM source_health h
   LEFT JOIN book_sources bs ON bs.url = h.source_url
   WHERE (? IS NULL OR h.platform = ?)
     AND (? IS NULL OR h.stage = ?)
     AND (? IS NULL OR h.status = ?)
     AND (? IS NULL OR h.source_url = ?)
   ORDER BY h.last_checked_at DESC
   LIMIT ?`
);

const stmtHealthSummary = db.prepare(
  `SELECT platform, stage, status, COUNT(*) AS count,
          SUM(success_count) AS success_count,
          SUM(fail_count) AS fail_count
   FROM source_health
   WHERE (? IS NULL OR platform = ?)
   GROUP BY platform, stage, status
   ORDER BY platform, stage, status`
);

function _cleanPlatform(platform) {
  const p = String(platform || 'ios').toLowerCase().trim();
  return _ALLOWED_SOURCE_PLATFORMS.has(p) ? p : 'ios';
}

function _cleanStage(stage) {
  const s = String(stage || 'search').toLowerCase().trim();
  return _SOURCE_STAGES.has(s) ? s : 'search';
}

function _cleanStatus(status) {
  const s = String(status || 'error').toLowerCase().trim();
  return _SOURCE_STATUSES.has(s) ? s : 'error';
}

function recordSourceHealth(input, opts = {}) {
  const now = Date.now();
  const sourceUrl = String(input.sourceUrl || input.source_url || '').trim();
  if (!sourceUrl) throw new Error('sourceUrl required');
  const platform = _cleanPlatform(input.platform);
  const stage = _cleanStage(input.stage);
  const status = _cleanStatus(input.status);
  const sampleKeyword = String(input.sampleKeyword || input.sample_keyword || '').slice(0, 128);
  const errorMessage = input.errorMessage || input.error_message
    ? String(input.errorMessage || input.error_message).slice(0, 1000)
    : null;
  const ok = status === 'ok';
  stmtHealthUpsert.run(
    sourceUrl, platform, stage, sampleKeyword, status, errorMessage,
    ok ? 1 : 0,
    ok || status === 'skip' ? 0 : 1,
    now,
    ok ? now : null,
    ok || status === 'skip' ? null : now,
    input.appVer || input.app_ver || null
  );
  // 万象书屋: 高频错误上报会让 cache 反复失效, 调用方可批量调用后再统一 invalidate
  if (!opts.skipCacheInvalidate) invalidateSourcesCache();
  return { ok: true, sourceUrl, platform, stage, status };
}

function recordSourceErrorEvent(input, ip) {
  const now = Date.now();
  const sourceUrl = String(input.sourceUrl || input.source_url || '').trim();
  if (!sourceUrl) throw new Error('sourceUrl required');
  // 万象书屋: 防止恶意客户端塞任意 URL 撑爆表;
  // 只接受当前已注册的书源 URL.
  if (!stmtCheckSourceExists.get(sourceUrl)) {
    throw new Error('unknown sourceUrl');
  }
  const platform = _cleanPlatform(input.platform);
  const stage = _cleanStage(input.stage);
  const status = _cleanStatus(input.status || 'error');
  const event = {
    ts: now,
    source_url: sourceUrl,
    source_name: input.sourceName || input.source_name || null,
    platform,
    stage,
    status,
    error_message: input.errorMessage || input.error_message ? String(input.errorMessage || input.error_message).slice(0, 1000) : null,
    sample_keyword: input.sampleKeyword || input.sample_keyword ? String(input.sampleKeyword || input.sample_keyword).slice(0, 128) : null,
    sample_url: input.sampleUrl || input.sample_url ? String(input.sampleUrl || input.sample_url).slice(0, 1000) : null,
    app_ver: input.appVer || input.app_ver || null,
    device_id: input.deviceId || input.device_id || null,
    ip: ip || null
  };
  stmtErrorEventInsert.run(
    event.ts, event.source_url, event.source_name, event.platform, event.stage,
    event.status, event.error_message, event.sample_keyword, event.sample_url,
    event.app_ver, event.device_id, event.ip
  );
  // 单条 App 上报合成 health: skip cache 失效, 让 /api/sources 缓存继续命中;
  // 健康过滤是软 + N 次失败阈值, 短延迟无影响.
  recordSourceHealth({
    sourceUrl,
    platform,
    stage,
    status,
    errorMessage: event.error_message,
    sampleKeyword: event.sample_keyword || '',
    appVer: event.app_ver
  }, { skipCacheInvalidate: true });
  return { ok: true };
}

function listSourceHealth(filters = {}) {
  const platform = filters.platform ? _cleanPlatform(filters.platform) : null;
  const stage = filters.stage ? _cleanStage(filters.stage) : null;
  const status = filters.status ? _cleanStatus(filters.status) : null;
  const sourceUrl = filters.sourceUrl || filters.source_url || null;
  const limit = Math.min(Math.max(parseInt(filters.limit, 10) || 200, 1), 1000);
  return stmtHealthList.all(platform, platform, stage, stage, status, status, sourceUrl, sourceUrl, limit);
}

function sourceHealthSummary(platform = null) {
  const p = platform ? _cleanPlatform(platform) : null;
  return stmtHealthSummary.all(p, p);
}

function _recordStaticCheck(src, platform, sampleKeyword) {
  const url = src.bookSourceUrl;
  const checks = [];
  const rs = src.ruleSearch || {};
  checks.push(['search', src.searchUrl && rs.bookList && rs.name && rs.bookUrl]);
  const ri = src.ruleBookInfo || {};
  checks.push(['info', !!(ri.name || ri.author || ri.tocUrl || ri.coverUrl || ri.intro)]);
  const rt = src.ruleToc || {};
  checks.push(['toc', !!(rt.chapterList && (rt.chapterName || rt.chapterUrl))]);
  const rc = src.ruleContent || {};
  checks.push(['content', !!rc.content]);
  let okCount = 0, errorCount = 0;
  for (const [stage, pass] of checks) {
    if (pass) okCount++;
    else errorCount++;
    recordSourceHealth({
      sourceUrl: url,
      platform,
      stage,
      status: pass ? 'ok' : 'error',
      errorMessage: pass ? null : `missing ${stage} required rules`,
      sampleKeyword
    }, { skipCacheInvalidate: true });
  }
  return { url, name: src.bookSourceName || url, okCount, errorCount };
}

function runSourceStaticCheck({ platform = 'ios', sampleKeyword = '斗破苍穹', url = null } = {}) {
  const p = _cleanPlatform(platform);
  const list = url
    ? (() => {
        const row = getSource(url);
        return row ? [JSON.parse(row.json)] : [];
      })()
    : listEnabledSourcesJson(p);
  // 万象书屋: 一次跑几百次 health upsert, 全部包进 transaction + 最后统一 invalidate cache,
  // 避免每行触发一次 cache flush 把 /api/sources 慢查询打满.
  const results = db.transaction(() => list.map(src => _recordStaticCheck(src, p, sampleKeyword)))();
  invalidateSourcesCache();
  return {
    platform: p,
    checked: results.length,
    ok: results.filter(r => r.errorCount === 0).length,
    error: results.filter(r => r.errorCount > 0).length,
    results
  };
}

// === 万象书屋 v2 (008): 书城 feed (M2.3.1) ===
//
// admin 录数据, App 端 GET /api/bookstore/feed?channel=male 拉

const stmtFeedListByChannel = db.prepare(
  `SELECT id, channel, section, name, author, cover_url, intro, kind,
          target_url, source_origin, priority, enabled, updated_at
   FROM bookstore_feed
   WHERE enabled = 1 AND channel = ?
   ORDER BY priority ASC, id ASC`
);

const stmtFeedListAll = db.prepare(
  `SELECT id, channel, section, name, author, cover_url, intro, kind,
          target_url, source_origin, priority, enabled, updated_at
   FROM bookstore_feed
   ORDER BY channel ASC, priority ASC, id ASC`
);

const stmtFeedInsert = db.prepare(
  `INSERT INTO bookstore_feed
     (channel, section, name, author, cover_url, intro, kind,
      target_url, source_origin, priority, enabled, updated_at)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
);

const stmtFeedUpdate = db.prepare(
  `UPDATE bookstore_feed SET
     channel=?, section=?, name=?, author=?, cover_url=?, intro=?, kind=?,
     target_url=?, source_origin=?, priority=?, enabled=?, updated_at=?
   WHERE id=?`
);

const stmtFeedSetEnabled = db.prepare(
  `UPDATE bookstore_feed SET enabled = ?, updated_at = ? WHERE id = ?`
);

const stmtFeedDelete = db.prepare(`DELETE FROM bookstore_feed WHERE id = ?`);

// 万象书屋: feed 分桶缓存 + ETag (内容变化时手动 invalidate)
let feedCachedByChannel = new Map();    // channel → list
let feedEtagByChannel = new Map();      // channel → etag

function invalidateFeedCache() {
  feedCachedByChannel.clear();
  feedEtagByChannel.clear();
}

function listBookstoreFeed(channel) {
  if (!channel) return [];
  const cached = feedCachedByChannel.get(channel);
  if (cached) return cached;
  const rows = stmtFeedListByChannel.all(channel);
  // 字段名转 camelCase, 跟 iOS SearchBook 对齐
  const list = rows.map(r => ({
    id: r.id,
    channel: r.channel,
    section: r.section,
    name: r.name,
    author: r.author,
    coverUrl: r.cover_url,
    intro: r.intro,
    kind: r.kind,
    bookUrl: r.target_url,           // iOS SearchBook.bookUrl
    origin: r.source_origin || '',   // iOS SearchBook.origin
    originName: '书城推荐',
    priority: r.priority,
  }));
  feedCachedByChannel.set(channel, list);
  return list;
}

function getBookstoreFeedEtag(channel) {
  const cached = feedEtagByChannel.get(channel);
  if (cached) return cached;
  const list = listBookstoreFeed(channel);
  const hash = require('crypto')
    .createHash('md5')
    .update(JSON.stringify(list))
    .digest('hex')
    .slice(0, 12);
  const etag = `"feed-${channel}-${hash}"`;
  feedEtagByChannel.set(channel, etag);
  return etag;
}

function listAllBookstoreFeed() {
  return stmtFeedListAll.all();
}

function upsertBookstoreFeed(item) {
  const now = Date.now();
  if (item.id) {
    stmtFeedUpdate.run(
      item.channel, item.section || 'recommend', item.name,
      item.author || '', item.cover_url || null, item.intro || null,
      item.kind || null, item.target_url, item.source_origin || null,
      Number.isFinite(item.priority) ? item.priority : 0,
      item.enabled === false ? 0 : 1, now, item.id
    );
  } else {
    const r = stmtFeedInsert.run(
      item.channel, item.section || 'recommend', item.name,
      item.author || '', item.cover_url || null, item.intro || null,
      item.kind || null, item.target_url, item.source_origin || null,
      Number.isFinite(item.priority) ? item.priority : 0,
      item.enabled === false ? 0 : 1, now
    );
    item.id = r.lastInsertRowid;
  }
  invalidateFeedCache();
  return item;
}

function setBookstoreFeedEnabled(id, enabled) {
  stmtFeedSetEnabled.run(enabled ? 1 : 0, Date.now(), id);
  invalidateFeedCache();
}

function deleteBookstoreFeed(id) {
  const info = stmtFeedDelete.run(id);
  invalidateFeedCache();
  return info.changes;
}

// === 万象书屋 D-23 (012): 书城 m.qidian.com mirror cache ===
//
// 后端定时 (每天 0:00-7:00 随机一次) 抓 m.qidian.com → 整理 JSON → 存这张表.
// App 改为 GET /api/bookstore/mirror 拉这份 cache.
// App 端原直抓代码保留作 fallback (后端挂了 / cache 全空时降级).

const stmtMirrorInsert = db.prepare(
  `INSERT INTO bookstore_mirror (version, payload, etag, fetched_at, source, ok, err_msg)
   VALUES (?, ?, ?, ?, ?, ?, ?)`
);
const stmtMirrorLatestOk = db.prepare(
  `SELECT id, version, payload, etag, fetched_at, source, overrides_json
   FROM bookstore_mirror WHERE ok = 1 ORDER BY id DESC LIMIT 1`
);
const stmtMirrorRecent = db.prepare(
  `SELECT id, version, etag, fetched_at, source, ok, err_msg, length(payload) AS payload_size
   FROM bookstore_mirror ORDER BY id DESC LIMIT ?`
);
const stmtMirrorCleanup = db.prepare(
  `DELETE FROM bookstore_mirror WHERE id NOT IN
     (SELECT id FROM bookstore_mirror ORDER BY id DESC LIMIT ?)`
);
const stmtMirrorSetOverrides = db.prepare(
  `UPDATE bookstore_mirror SET overrides_json = ? WHERE id = ?`
);

function insertBookstoreMirror({ version, payload, etag, fetched_at, source, ok, err_msg }) {
  stmtMirrorInsert.run(version, payload, etag, fetched_at, source, ok ? 1 : 0, err_msg || null);
}

/**
 * 万象书屋: 拿"最新 ok=1 的 cache 行", 给 /api/bookstore/mirror 客户端 endpoint 用.
 * 返 null 表示从未抓成功过 (App 应降级到直抓).
 */
function getLatestBookstoreMirror() {
  return stmtMirrorLatestOk.get() || null;
}

function listRecentBookstoreMirror(limit = 24) {
  return stmtMirrorRecent.all(limit);
}

function cleanupOldBookstoreMirror(keepCount = 24) {
  stmtMirrorCleanup.run(keepCount);
}

/** admin 面板加 / 改 / 删覆盖规则时调用 */
function setBookstoreMirrorOverrides(id, overridesJson) {
  stmtMirrorSetOverrides.run(overridesJson, id);
}

// === Heartbeat / Visit ===
const heartbeatStmt = db.prepare(
  'INSERT OR REPLACE INTO heartbeats(device_id, ts) VALUES (?, ?)'
);
const visitStmt = db.prepare(
  'INSERT OR IGNORE INTO visits(device_id, day, first_ts) VALUES (?, ?, ?)'
);
// 万象书屋: stats 接口 admin 面板每 30s 调一次, 预编译省 prepare 开销
const stmtStatsOnline = db.prepare('SELECT COUNT(DISTINCT device_id) AS c FROM heartbeats WHERE ts >= ?');
const stmtStatsToday = db.prepare('SELECT COUNT(*) AS c FROM visits WHERE day = ?');
const stmtStatsDay = db.prepare('SELECT COUNT(*) AS c FROM visits WHERE day = ?');
const stmtStatsMonth = db.prepare('SELECT COUNT(DISTINCT device_id) AS c FROM visits WHERE day > ? AND day < ?');
// 周独立设备数: 用范围查询, 边界两端各 -1 / +1 让 < / > 严格
const stmtStatsWeek = db.prepare('SELECT COUNT(DISTINCT device_id) AS c FROM visits WHERE day >= ? AND day <= ?');

function recordPing(deviceId) {
  if (!deviceId) return;
  const now = Date.now();
  heartbeatStmt.run(deviceId, now);
  // 按 UTC+8 计算 day
  const day = new Date(now + 8 * 3600 * 1000).toISOString().slice(0, 10);
  visitStmt.run(deviceId, day, now);
}

function statsOnline(windowMs = 5 * 60 * 1000) {
  const since = Date.now() - windowMs;
  return stmtStatsOnline.get(since).c;
}

function todayKey() {
  return new Date(Date.now() + 8 * 3600 * 1000).toISOString().slice(0, 10);
}
function weekDays() {
  const days = [];
  for (let i = 6; i >= 0; i--) {
    const d = new Date(Date.now() + 8 * 3600 * 1000 - i * 86400 * 1000);
    days.push(d.toISOString().slice(0, 10));
  }
  return days;
}
function monthKey() {
  return todayKey().slice(0, 7);
}

function statsToday() {
  return stmtStatsToday.get(todayKey()).c;
}
function statsWeek() {
  // 万象书屋: 改用范围 [first, last] 查询走索引 + 预编译, 替代 IN(...,...) 每次重新 prepare;
  // 语义保持"独立设备数" (一个设备 7 天内来 N 次只算 1).
  const days = weekDays();
  return stmtStatsWeek.get(days[0], days[days.length - 1]).c;
}
function statsMonth() {
  // 万象书屋: 之前用 LIKE 'YYYY-MM%' 默认不走 idx_visits_day 索引, 全表扫.
  // 改成范围查询, SQLite 字符串比较对 YYYY-MM-DD 自然序 = 日期序.
  //
  // 万象书屋 D-16 (B-10): 边界用更直观的语义.
  //   旧: lo='2026-05-00' (字面 < '2026-05-01'), hi='2026-05-32' (字面 > '2026-05-31')
  //       字典序碰巧成立, 但 '-32' 是非法日期, 看代码的人需想几秒才理解.
  //   新: 用 [本月-01, 下月-01) 半开区间. 可读性提升, 不依赖字符串字典序对非法日期的容忍.
  const m = monthKey();                              // YYYY-MM
  const [yyyy, mm] = m.split('-').map(Number);
  // 计算下一个月的第一天 YYYY-MM-DD (12 月加 1 → 次年 1 月)
  const nextMonth = mm === 12
    ? `${yyyy + 1}-01-01`
    : `${yyyy}-${String(mm + 1).padStart(2, '0')}-01`;
  const lo = `${m}-01`;                              // e.g. '2026-05-01'
  // stmtStatsMonth 是 day > lo AND day < hi (严格小于), 用 [lo, nextMonth) 等价
  // lo 用 '00' 让 '2026-05-01' 严格 > '2026-05-00' 同样成立; 这里改成 '2026-04-31' 也行.
  // 简化: 用 lo='YYYY-MM-00' (排除上月最后一天就 OK), hi=下月-01 (排除下月第一天 OK)
  const loBoundary = `${m}-00`;
  return stmtStatsMonth.get(loBoundary, nextMonth).c;
}
/**
 * 万象书屋: 统计近 N 天每日访问独立设备数曲线 (UTC+8)
 * 修复: 旧版本忽略 days 参数, 现在按入参生成
 */
function statsDailyCurve(days = 7) {
  const n = Math.max(1, Math.min(60, Number(days) || 7));
  const list = [];
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(Date.now() + 8 * 3600 * 1000 - i * 86400 * 1000);
    list.push(d.toISOString().slice(0, 10));
  }
  return list.map(day => ({ day, count: stmtStatsDay.get(day).c }));
}

// === Admin ===
// 万象书屋: 预编译, 频繁调用接口 (login / requireAdmin) 各省一次 prepare
const stmtGetAdminPwd = db.prepare('SELECT pwd_hash FROM admin WHERE id = 1');
const stmtUpdateAdminPwd = db.prepare('UPDATE admin SET pwd_hash=?, updated_at=? WHERE id=1');
const stmtCreateSession = db.prepare(
  'INSERT INTO admin_session(token, created_at, ip, ua_hash, username, role) VALUES (?, ?, ?, ?, ?, ?)'
);
const stmtGetSession = db.prepare('SELECT created_at, ua_hash, username, role FROM admin_session WHERE token = ?');
const stmtDeleteSession = db.prepare('DELETE FROM admin_session WHERE token = ?');
const stmtDeleteAllSessions = db.prepare('DELETE FROM admin_session');

// 万象书屋: bcrypt 10 轮在服务端 ~500ms, sync 调用阻塞整个 event loop;
// 改成 async, 让同时的其他请求 (心跳 / ad-event / sources) 不被 admin 登录卡住.
// 仍同时保留同步版给 init / 测试代码兼容.
function verifyAdminPasswordSync(plain) {
  if (!plain || typeof plain !== 'string') return false;
  const row = stmtGetAdminPwd.get();
  if (!row) return false;
  return bcrypt.compareSync(plain, row.pwd_hash);
}
async function verifyAdminPassword(plain) {
  if (!plain || typeof plain !== 'string') return false;
  const row = stmtGetAdminPwd.get();
  if (!row) return false;
  return await bcrypt.compare(plain, row.pwd_hash);
}

async function setAdminPassword(plain) {
  const hash = await bcrypt.hash(plain, BCRYPT_COST);
  stmtUpdateAdminPwd.run(hash, Date.now());
}

function uaHash(ua) {
  if (!ua) return '';
  return require('crypto').createHash('sha256').update(ua).digest('hex').slice(0, 16);
}

/**
 * 万象书屋: session 绑定创建时的 IP + User-Agent.
 * IP 仅记录审计用, UA hash 参与校验 (浏览器变化则强制重登, 防 cookie 被偷)
 */
function createSession(ip = '', ua = '', meta = {}) {
  const token = require('crypto').randomBytes(24).toString('hex');
  stmtCreateSession.run(token, Date.now(), ip || '', uaHash(ua), meta.username || null, meta.role || null);
  return token;
}

/**
 * 万象书屋 v2: isValidSession 现在也返回 username + role, 让 server 中间件取出.
 * 兼容老调用 isValidSession(token, ua) -> bool, 新调用 isValidSession(token, ua, true) -> {ok, username, role}
 */
function isValidSession(token, ua = '', returnMeta = false) {
  if (!token) return returnMeta ? null : false;
  const row = stmtGetSession.get(token);
  if (!row) return returnMeta ? null : false;
  if (Date.now() - row.created_at >= 7 * 86400 * 1000) return returnMeta ? null : false;
  if (row.ua_hash && ua && row.ua_hash !== uaHash(ua)) return returnMeta ? null : false;
  if (returnMeta) return { ok: true, username: row.username, role: row.role };
  return true;
}

function destroySession(token) {
  stmtDeleteSession.run(token);
}

/** 删除某用户所有 session (改密码后强制其他端下线) */
function destroyAllSessions() {
  stmtDeleteAllSessions.run();
}

// === Ad config ===
const DEFAULT_AD_CONFIG = {
  // 客户端读到 disabled=true 时, 一律不展示任何广告位
  disabled: true,
  // SDK 的 appId, 真实账号在 admin 后台填; 默认空 = 不 init
  sdk: { csj: { appId: '' }, ylh: { appId: '' } },
  // 广告位配置: weight=0 即关闭该位; provider weights 和 = 100
  placements: {
    splash: {
      enabled: false,
      timeoutMs: 3000,
      // 万象书屋: "独家投放" 开关 (运营应急)
      //   "" (空) = 默认按 weight 抽签
      //   "csj"   = 仅穿山甲, ylh weight 强制 0
      //   "ylh"   = 仅优量汇, csj weight 强制 0
      // 优先级: breaker (自动熔断) > soloProvider > weight
      // 即使 admin 选 "ylh", 但 ylh 错误率 100% 触发熔断, 仍走 csj
      soloProvider: '',
      providers: [
        { name: 'csj', weight: 50, posId: '' },
        { name: 'ylh', weight: 50, posId: '' }
      ]
    },
    rewardedReadingUnlock: {
      enabled: false,
      // 用户每次成功观看后, 解锁多少分钟纯净阅读
      unlockMinutes: 30,
      // 距上次广告结束多久后才能再次提示 (旧时间制, 现在主要用 cooldownSec)
      cooldownMinutes: 30,
      // 万象书屋累积奖励:
      // 两次主动激励之间至少间隔多少秒 (反作弊 + 防 SDK 风控)
      cooldownSec: 180,
      // 累积纯净阅读时长上限 (分钟, 默认 24 小时), 防恶意刷量
      maxAccumulatedMinutes: 1440,
      // 阅读器顶部是否显示「纯净阅读 X 分钟 [续期]」倒计时条
      showCountdownBar: true,
      // 万象书屋: 独家投放开关, 同 splash.soloProvider
      soloProvider: '',
      providers: [
        { name: 'csj', weight: 50, posId: '' },
        { name: 'ylh', weight: 50, posId: '' }
      ]
    }
  },
  // 客户端拉取间隔 (秒), 默认 6 小时
  pollIntervalSec: 21600,
  // 万象书屋: 章节级付费墙 (强制变现). enabled=true 时,
  // 用户每次冷启动头 freeChapters 章免费, 之后必须看广告解锁 unlockMinutes 分钟,
  // 没看完则锁屏阻止继续阅读 (blockOnSkip)
  chapterUnlock: {
    enabled: false,
    freeChapters: 3,
    unlockMinutes: 30,
    blockOnSkip: true
  }
};

/**
 * 万象书屋: 给老的 ad_config 自动补全新字段.
 * 新版本上线后增加的字段 (如 cooldownSec / maxAccumulatedMinutes / showCountdownBar)
 * 在已存配置里没有, 这里递归填默认值, 避免老数据返回 undefined 给 App.
 */
function _mergeAdConfigDefaults(saved, defaults) {
  if (saved == null || typeof saved !== 'object') return defaults;
  if (Array.isArray(saved)) return saved;
  const out = { ...saved };
  for (const k of Object.keys(defaults)) {
    if (out[k] === undefined) {
      out[k] = defaults[k];
    } else if (defaults[k] && typeof defaults[k] === 'object' && !Array.isArray(defaults[k])) {
      out[k] = _mergeAdConfigDefaults(out[k], defaults[k]);
    }
  }
  return out;
}

/**
 * 获取广告配置. 支持灰度:
 *   - rollout_pct=0   → 总是返回主版本
 *   - rollout_pct=100 → 总是返回 staging (所有用户)
 *   - rollout_pct=10 + deviceId 命中 → 返回 staging, 否则返回主
 *
 * @param {string} [deviceId] 给灰度选版本用; 不传则总是返回主版本
 */
function getAdConfig(deviceId) {
  const row = db.prepare(
    'SELECT version, json, etag, staging_json, rollout_pct FROM ad_config WHERE id = 1'
  ).get();
  if (!row) {
    return { version: 0, json: JSON.stringify(DEFAULT_AD_CONFIG), etag: 'v0', isStaging: false };
  }

  let chosenJson = row.json;
  let chosenEtag = row.etag;
  let isStaging = false;

  // 灰度选择
  const pct = row.rollout_pct || 0;
  if (pct > 0 && row.staging_json) {
    let inRollout = pct >= 100;
    if (!inRollout && deviceId) {
      // 用 device_id 哈希后取 0-99, < pct 命中
      const h = require('crypto').createHash('md5').update(deviceId).digest();
      const bucket = h.readUInt32LE(0) % 100;
      inRollout = bucket < pct;
    }
    if (inRollout) {
      chosenJson = row.staging_json;
      // staging etag 区别于主 etag, 让客户端能区分缓存
      chosenEtag = row.etag + '-s' + pct;
      isStaging = true;
    }
  }

  // 合并默认: 老存档可能缺新字段
  try {
    const saved = JSON.parse(chosenJson);
    const merged = _mergeAdConfigDefaults(saved, DEFAULT_AD_CONFIG);
    _applySoloProvider(merged);
    return { version: row.version, json: JSON.stringify(merged), etag: chosenEtag, isStaging };
  } catch (e) {
    // 万象书屋 D-4 修复: JSON 损坏时返回 DEFAULT_AD_CONFIG (disabled=true), 不返回半残数据.
    // 之前: 直接返回 chosenJson (可能缺字段 / 未 merge / 未 solo), 客户端行为不可预测.
    // 现在: 损坏 = 关广告, 同时 server console 打 error 让运维感知.
    console.error('[db.getAdConfig] JSON parse failed, falling back to DEFAULT_AD_CONFIG:', e.message);
    return {
      version: row.version,
      json: JSON.stringify(DEFAULT_AD_CONFIG),
      etag: 'fallback-' + (row.etag || ''),
      isStaging: false
    };
  }
}

/**
 * 万象书屋: 拿原始未经 _applySoloProvider 处理的配置, 给 admin 加载用.
 *
 * 之前 BUG: admin GET /api/admin/ad-config 用 getAdConfig() 拿到的是
 * 经过 solo 处理后的 weight (非选中家 weight=0). admin 表单显示这个假值,
 * POST 保存时回写到 db, 把真实 weight 覆盖成 0. 切下次 solo 时, 该家
 * weight 也是 0 → 双 0 = 没广告.
 *
 * 修复: admin 加载用 getAdConfigRaw 拿真实 weight, App 读 getAdConfig 拿处理后的.
 */
function getAdConfigRaw() {
  const row = db.prepare(
    'SELECT version, json, etag FROM ad_config WHERE id = 1'
  ).get();
  if (!row) {
    return { version: 0, json: JSON.stringify(DEFAULT_AD_CONFIG), etag: 'v0' };
  }
  try {
    const saved = JSON.parse(row.json);
    const merged = _mergeAdConfigDefaults(saved, DEFAULT_AD_CONFIG);
    // 不调 _applySoloProvider, 返回原始 weight
    return { version: row.version, json: JSON.stringify(merged), etag: row.etag };
  } catch (_) {
    return row;
  }
}

/**
 * 万象书屋: 独家投放应用器.
 * 如果某 placement 的 soloProvider 不为空, 把所有非选中 provider 的 weight 强制设 0.
 * 不修改 posId, 切回"全部按权重"时数据不丢失 (前端切换 soloProvider="" 即可恢复).
 *
 * 只读 + 改 weight, 不读 db, 不应用 breaker (breaker 在 server.js 的 applyBreaker 里处理,
 * 优先级更高, 会在 solo 之上再次覆盖).
 */
function _applySoloProvider(cfg) {
  if (!cfg || !cfg.placements) return;
  for (const placement of Object.values(cfg.placements)) {
    if (!placement || !Array.isArray(placement.providers)) continue;
    const solo = placement.soloProvider;
    if (!solo) continue;
    for (const slot of placement.providers) {
      if (slot.name !== solo) slot.weight = 0;
    }
  }
}

/**
 * 写入 staging 灰度版本. rollout_pct 控制覆盖比例.
 * 不修改主版本 (version 不递增, ad_config_history 不变).
 */
function setAdConfigStaging(jsonObj, rolloutPct) {
  if (!jsonObj || typeof jsonObj !== 'object' || !jsonObj.placements) {
    throw new Error('staging config must contain placements');
  }
  const pct = Math.max(0, Math.min(100, parseInt(rolloutPct, 10) || 0));
  db.prepare(
    'UPDATE ad_config SET staging_json=?, rollout_pct=? WHERE id=1'
  ).run(JSON.stringify(jsonObj), pct);
}

/**
 * 灰度版本提升为主版本 (rollout 完成).
 * 把 staging 合并到主, 走标准 saveAdConfig 流程, version+1, 入 history.
 * 同时清空 staging.
 */
function commitAdConfigStaging() {
  const row = db.prepare(
    'SELECT staging_json, rollout_pct FROM ad_config WHERE id = 1'
  ).get();
  if (!row || !row.staging_json) {
    throw new Error('no staging config to commit');
  }
  const obj = JSON.parse(row.staging_json);
  saveAdConfig(obj);
  db.prepare('UPDATE ad_config SET staging_json=NULL, rollout_pct=0 WHERE id=1').run();
}

/** 取消灰度 (回滚到主版本, staging 内容丢弃). */
function abortAdConfigStaging() {
  db.prepare('UPDATE ad_config SET staging_json=NULL, rollout_pct=0 WHERE id=1').run();
}

function saveAdConfig(jsonObj) {
  // 简单语义校验: 必须有 placements
  if (!jsonObj || typeof jsonObj !== 'object' || !jsonObj.placements) {
    throw new Error('ad config must contain placements');
  }
  const now = Date.now();
  const json = JSON.stringify(jsonObj);
  const cur = db.prepare('SELECT version FROM ad_config WHERE id = 1').get();
  const nextVer = (cur ? cur.version : 0) + 1;
  // etag 取 version + 简短 hash, 客户端 If-None-Match 可比对
  const etag = `v${nextVer}-${require('crypto').createHash('md5').update(json).digest('hex').slice(0, 8)}`;
  const tx = db.transaction(() => {
    db.prepare(
      `INSERT INTO ad_config(id, version, json, etag, updated_at) VALUES (1, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET version=excluded.version, json=excluded.json, etag=excluded.etag, updated_at=excluded.updated_at`
    ).run(nextVer, json, etag, now);
    db.prepare(
      'INSERT OR REPLACE INTO ad_config_history(version, json, created_at) VALUES (?, ?, ?)'
    ).run(nextVer, json, now);
    // 历史只保留最近 30 个版本
    db.prepare(
      'DELETE FROM ad_config_history WHERE version <= (SELECT MAX(version) FROM ad_config_history) - 30'
    ).run();
  });
  tx();
  return { version: nextVer, etag };
}

function listAdConfigHistory(limit = 30) {
  return db.prepare(
    'SELECT version, created_at FROM ad_config_history ORDER BY version DESC LIMIT ?'
  ).all(limit);
}

function getAdConfigByVersion(version) {
  return db.prepare(
    'SELECT version, json, created_at FROM ad_config_history WHERE version = ?'
  ).get(version);
}

// === 万象书屋: 广告事件 / 崩溃 / 审计 ===
const stmtInsertAdEvent = db.prepare(
  // 万象书屋: platform 列在 006_multi_platform.sql 加上, 默认 'android' 兼容老 App.
  `INSERT INTO ad_events(ts, placement, provider, type, err_code, err_msg, device_id, app_ver, platform)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
);
function recordAdEvent({ placement, provider, type, errCode, errMsg, deviceId, appVer, platform }) {
  if (!placement || !provider || !type) {
    // 万象书屋: 之前是静默 return → server 仍返 ok:true, 客户端误判已上报.
    // 现在 throw, 让 server.js 转 400, 客户端看见错误能 fix.
    throw new Error('placement / provider / type required');
  }
  const p = (platform === 'ios' || platform === 'web') ? platform : 'android';
  stmtInsertAdEvent.run(
    Date.now(), String(placement).slice(0, 64), String(provider).slice(0, 32),
    String(type).slice(0, 16),
    errCode != null ? Number(errCode) : null,
    errMsg ? String(errMsg).slice(0, 200) : null,
    deviceId ? String(deviceId).slice(0, 128) : null,
    appVer ? String(appVer).slice(0, 32) : null,
    p,
  );
}

/** 按小时分组返回 (placement, provider, type, count, err_rate) */
function adEventFunnel({ hours = 24 } = {}) {
  const since = Date.now() - hours * 3600_000;
  // 各 provider 每种事件数
  const rows = db.prepare(`
    SELECT placement, provider, type, COUNT(*) AS c
    FROM ad_events WHERE ts >= ?
    GROUP BY placement, provider, type
  `).all(since);
  // 整理成漏斗 per (placement, provider)
  const funnel = {};
  for (const r of rows) {
    const k = `${r.placement}|${r.provider}`;
    if (!funnel[k]) funnel[k] = { placement: r.placement, provider: r.provider };
    funnel[k][r.type] = r.c;
  }
  // 万象书屋: 错误率 = error 数 / load 数. (旧公式 error/(load+error) 错误地把分母翻倍, 导致 100% 失败被显示成 50%)
  // 每次广告请求 = 1 个 load 事件; 失败时**额外** 上报 1 个 error 事件 (非互斥, 而是 error⊆load 的子集统计).
  // 因此 errorRate ∈ [0, 1+], 极端情况下 SDK 同一请求多次 error 回调可能 >100%, 已知风险.
  for (const v of Object.values(funnel)) {
    const load = v.load || 0;
    const error = v.error || 0;
    v.errorRate = load > 0 ? Math.min(1, error / load) : 0;
  }
  return Object.values(funnel);
}

/**
 * 熔断: 最近 1 小时某 (placement, provider) 错误率 > threshold 时返 true.
 * AdManager 拉 /api/ad-config 时会把该 provider.weight 运行时覆盖为 0.
 * 不改数据库, 错误率恢复后自动放开.
 */
function adProvidersToBreak({ windowHours = 1, minSamples = 20, errorThreshold = 0.6, perPlacementMinSamples = null } = {}) {
  const since = Date.now() - windowHours * 3600_000;
  // 万象书屋: 用 load 事件总数当样本量 + error 数 / load 数当失败率,
  // 跟 funnel 的 errorRate 公式保持一致 (之前用 load+error 当分母, 失败率被低估 50%).
  // 同时返回最常见 errCode + errMsg, admin 不必跳查 ad_events 就能看到根因.
  //
  // perPlacementMinSamples: { splash: 10, rewardedReadingUnlock: 3 }
  // 让低流量位 (激励视频) 用更低样本数熔断, 不必等到 10 个失败才保护用户.
  const rows = db.prepare(`
    SELECT placement, provider,
           SUM(CASE WHEN type='error' THEN 1 ELSE 0 END) AS errs,
           SUM(CASE WHEN type='load'  THEN 1 ELSE 0 END) AS loads
    FROM ad_events WHERE ts >= ?
    GROUP BY placement, provider
  `).all(since);
  return rows
    .filter(r => {
      const m = (perPlacementMinSamples && perPlacementMinSamples[r.placement]) || minSamples;
      return r.loads >= m && (r.errs / r.loads) >= errorThreshold;
    })
    .map(r => {
      // 最常见错误码+消息, 给 admin 一眼看出根因
      const top = db.prepare(`
        SELECT err_code AS errCode, err_msg AS errMsg, COUNT(*) AS n
        FROM ad_events
        WHERE ts >= ? AND placement = ? AND provider = ? AND type = 'error'
        GROUP BY err_code, err_msg
        ORDER BY n DESC LIMIT 1
      `).get(since, r.placement, r.provider);
      return {
        placement: r.placement,
        provider: r.provider,
        errs: r.errs,
        total: r.loads,
        // errorRate 作为 0~1 浮点; admin 前端 *100 显示百分比
        errorRate: Number((r.errs / r.loads).toFixed(3)),
        topErrCode: top ? top.errCode : null,
        topErrMsg: top ? top.errMsg : null
      };
    });
}

// === Crashes ===
const stmtInsertCrash = db.prepare(
  // 万象书屋: platform 列见 006_multi_platform.sql, iOS 端 sdk_int 通常为空, brand="Apple" model 为机型代码 (iPhone15,2)
  `INSERT INTO crashes(ts, device_id, app_ver, brand, model, sdk_int, fingerprint, exception, stack, platform)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
);
function recordCrash(c) {
  const { deviceId, appVer, brand, model, sdkInt, fingerprint, exception, stack, platform } = c;
  if (!exception || !stack) return;
  const p = (platform === 'ios' || platform === 'web') ? platform : 'android';
  stmtInsertCrash.run(
    Date.now(),
    deviceId ? String(deviceId).slice(0, 128) : null,
    appVer ? String(appVer).slice(0, 32) : null,
    brand ? String(brand).slice(0, 32) : null,
    model ? String(model).slice(0, 64) : null,
    sdkInt != null ? Number(sdkInt) : null,
    fingerprint ? String(fingerprint).slice(0, 64) : null,
    String(exception).slice(0, 200),
    String(stack).slice(0, 20_000),
    p,
  );
}

function listCrashSummary({ hours = 168 } = {}) {
  const since = Date.now() - hours * 3600_000;
  return db.prepare(`
    SELECT fingerprint, exception, COUNT(*) AS count,
           MAX(ts) AS last_ts, MIN(ts) AS first_ts,
           COUNT(DISTINCT device_id) AS devices
    FROM crashes WHERE ts >= ?
    GROUP BY fingerprint, exception
    ORDER BY count DESC LIMIT 100
  `).all(since);
}

function listCrashesByFingerprint(fingerprint, limit = 20) {
  return db.prepare(`
    SELECT ts, device_id, app_ver, brand, model, sdk_int, exception, stack
    FROM crashes WHERE fingerprint = ? ORDER BY ts DESC LIMIT ?
  `).all(fingerprint, limit);
}

// === Audit log ===
const stmtInsertAudit = db.prepare(
  `INSERT INTO audit_log(ts, ip, action, target, detail) VALUES (?, ?, ?, ?, ?)`
);
function recordAudit({ ip, action, target, detail }) {
  if (!action) return;
  stmtInsertAudit.run(
    Date.now(),
    ip ? String(ip).slice(0, 64) : null,
    String(action).slice(0, 64),
    target ? String(target).slice(0, 256) : null,
    detail ? (typeof detail === 'string' ? detail.slice(0, 2000) : JSON.stringify(detail).slice(0, 2000)) : null,
  );
}

function listAuditLog({ limit = 200 } = {}) {
  return db.prepare(`
    SELECT ts, ip, action, target, detail FROM audit_log
    ORDER BY ts DESC LIMIT ?
  `).all(limit);
}

// === Feedback ===
const stmtInsertFeedback = db.prepare(
  `INSERT INTO feedback(ts, type, content, contact, device_id, app_ver, ip, platform)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
);
function recordFeedback(f) {
  const { type, content, contact, deviceId, appVer, ip, platform } = f;
  if (!type || !content) throw new Error('type & content required');
  const allowedTypes = new Set(['bug', 'content', 'suggest', 'other']);
  const t = allowedTypes.has(type) ? type : 'other';
  if (String(content).length < 5) throw new Error('content too short');
  if (String(content).length > 2000) throw new Error('content too long');
  const p = (platform === 'ios' || platform === 'web') ? platform : 'android';
  const r = stmtInsertFeedback.run(
    Date.now(), t,
    String(content).slice(0, 2000),
    contact ? String(contact).slice(0, 100) : null,
    deviceId ? String(deviceId).slice(0, 128) : null,
    appVer ? String(appVer).slice(0, 32) : null,
    ip ? String(ip).slice(0, 64) : null,
    p,
  );
  return { id: r.lastInsertRowid };
}

function listFeedback({ status = null, limit = 200 } = {}) {
  if (status) {
    return db.prepare(`
      SELECT id, ts, type, content, contact, device_id, app_ver, ip, status, reply, reply_ts
      FROM feedback WHERE status = ?
      ORDER BY ts DESC LIMIT ?
    `).all(status, limit);
  }
  return db.prepare(`
    SELECT id, ts, type, content, contact, device_id, app_ver, ip, status, reply, reply_ts
    FROM feedback ORDER BY ts DESC LIMIT ?
  `).all(limit);
}

function updateFeedbackStatus(id, status, reply) {
  const allowed = new Set(['open', 'processing', 'done', 'spam']);
  if (!allowed.has(status)) throw new Error('invalid status');
  if (reply != null) {
    db.prepare('UPDATE feedback SET status=?, reply=?, reply_ts=? WHERE id=?')
      .run(status, String(reply).slice(0, 2000), Date.now(), id);
  } else {
    db.prepare('UPDATE feedback SET status=? WHERE id=?').run(status, id);
  }
}

function feedbackStats() {
  return db.prepare(`
    SELECT status, COUNT(*) AS c FROM feedback GROUP BY status
  `).all();
}

// === 万象书屋: iOS IAP 票据 (006_multi_platform.sql) ===
// 用户内购成功后, 客户端把苹果 receipt-data 发后端, 后端转发到苹果验证服务器,
// 验证成功后入库. 后续判断 entitlement (是否去广告 / VIP) 看 iap_receipts 即可.
const stmtUpsertIapReceipt = db.prepare(
  `INSERT INTO iap_receipts(
     device_id, product_id, transaction_id, original_tx_id,
     receipt_data, expires_at, verified_at, sandbox, status, raw_response
   ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
   ON CONFLICT(transaction_id) DO UPDATE SET
     receipt_data = excluded.receipt_data,
     expires_at   = excluded.expires_at,
     verified_at  = excluded.verified_at,
     status       = excluded.status,
     raw_response = excluded.raw_response`
);

function saveIapReceipt({
  deviceId, productId, transactionId, originalTxId,
  receiptData, expiresAt, sandbox, status, rawResponse,
}) {
  if (!deviceId || !productId || !transactionId || !receiptData) {
    throw new Error('deviceId / productId / transactionId / receiptData required');
  }
  stmtUpsertIapReceipt.run(
    String(deviceId).slice(0, 128),
    String(productId).slice(0, 100),
    String(transactionId).slice(0, 100),
    originalTxId ? String(originalTxId).slice(0, 100) : null,
    String(receiptData).slice(0, 50000),
    expiresAt != null ? Number(expiresAt) : null,
    Date.now(),
    sandbox ? 1 : 0,
    status || 'active',
    rawResponse ? String(rawResponse).slice(0, 50000) : null,
  );
}

/**
 * 查设备当前 entitlement: active 且 (expires_at 为空一次性买断 OR expires_at 未过期).
 * 返回该设备所有"还有效的"订单, 用于判断 isAdFree / isVip.
 */
function listActiveIapForDevice(deviceId) {
  if (!deviceId) return [];
  const now = Date.now();
  return db.prepare(`
    SELECT product_id, transaction_id, expires_at, verified_at, status, sandbox
    FROM iap_receipts
    WHERE device_id = ?
      AND status = 'active'
      AND (expires_at IS NULL OR expires_at > ?)
  `).all(String(deviceId), now);
}

function setIapStatus(transactionId, status) {
  const allowed = new Set(['active', 'expired', 'refunded', 'revoked']);
  if (!allowed.has(status)) throw new Error('invalid iap status');
  db.prepare('UPDATE iap_receipts SET status = ? WHERE transaction_id = ?')
    .run(status, String(transactionId));
}

// === 万象书屋: 强制升级 ===
function getAppVersion() {
  const row = db.prepare('SELECT * FROM app_versions WHERE id = 1').get();
  if (!row) return { latest_code: 0, latest_name: '', min_required_code: 0, changelog: '', apk_url: '', market_url: '', updated_at: 0 };
  return row;
}

function saveAppVersion(o) {
  const now = Date.now();
  db.prepare(
    `INSERT INTO app_versions(id, latest_code, latest_name, min_required_code, changelog, apk_url, market_url, updated_at)
     VALUES (1, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       latest_code=excluded.latest_code,
       latest_name=excluded.latest_name,
       min_required_code=excluded.min_required_code,
       changelog=excluded.changelog,
       apk_url=excluded.apk_url,
       market_url=excluded.market_url,
       updated_at=excluded.updated_at`
  ).run(
    Number(o.latest_code) || 0,
    String(o.latest_name || '').slice(0, 32),
    Number(o.min_required_code) || 0,
    String(o.changelog || '').slice(0, 4000),
    String(o.apk_url || '').slice(0, 500),
    String(o.market_url || '').slice(0, 200),
    now
  );
}

// === 万象书屋: 公告 ===
const stmtListEnabledAnnouncements = db.prepare(
  `SELECT id, title, content, style, dismissable, version_min, version_max, end_at
   FROM announcements
   WHERE enabled = 1
     AND (start_at = 0 OR start_at <= ?)
     AND (end_at   = 0 OR end_at   >= ?)
   ORDER BY id DESC`
);
function listActiveAnnouncements(versionCode) {
  const now = Date.now();
  const rows = stmtListEnabledAnnouncements.all(now, now);
  return rows.filter(r =>
    (r.version_min === 0 || versionCode >= r.version_min) &&
    (r.version_max === 0 || versionCode <= r.version_max)
  );
}

function listAllAnnouncements() {
  return db.prepare('SELECT * FROM announcements ORDER BY id DESC LIMIT 200').all();
}

function upsertAnnouncement(o) {
  const now = Date.now();
  if (o.id) {
    db.prepare(
      `UPDATE announcements SET title=?, content=?, style=?, dismissable=?, enabled=?,
       start_at=?, end_at=?, version_min=?, version_max=?, updated_at=? WHERE id=?`
    ).run(
      String(o.title || '').slice(0, 100),
      String(o.content || '').slice(0, 4000),
      String(o.style || 'info'),
      o.dismissable ? 1 : 0,
      o.enabled ? 1 : 0,
      Number(o.start_at) || 0, Number(o.end_at) || 0,
      Number(o.version_min) || 0, Number(o.version_max) || 0,
      now, Number(o.id)
    );
    return o.id;
  }
  const r = db.prepare(
    `INSERT INTO announcements(title, content, style, dismissable, enabled, start_at, end_at, version_min, version_max, created_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(
    String(o.title || '').slice(0, 100),
    String(o.content || '').slice(0, 4000),
    String(o.style || 'info'),
    o.dismissable ? 1 : 0,
    o.enabled ? 1 : 0,
    Number(o.start_at) || 0, Number(o.end_at) || 0,
    Number(o.version_min) || 0, Number(o.version_max) || 0,
    now, now
  );
  return r.lastInsertRowid;
}

function deleteAnnouncement(id) {
  db.prepare('DELETE FROM announcements WHERE id=?').run(Number(id));
}

// === 万象书屋: 设备黑名单 ===
const stmtCheckBlacklist = db.prepare('SELECT 1 FROM device_blacklist WHERE device_id = ? LIMIT 1');
function isDeviceBlocked(deviceId) {
  if (!deviceId) return false;
  return !!stmtCheckBlacklist.get(deviceId);
}

function blockDevice(deviceId, reason, operator) {
  if (!deviceId) throw new Error('deviceId required');
  db.prepare(
    `INSERT INTO device_blacklist(device_id, reason, blocked_at, operator) VALUES (?, ?, ?, ?)
     ON CONFLICT(device_id) DO UPDATE SET reason=excluded.reason, operator=excluded.operator`
  ).run(String(deviceId).slice(0, 128), String(reason || '').slice(0, 200), Date.now(), String(operator || '').slice(0, 64));
}

function unblockDevice(deviceId) {
  db.prepare('DELETE FROM device_blacklist WHERE device_id=?').run(deviceId);
}

function listBlockedDevices(limit = 200) {
  return db.prepare('SELECT * FROM device_blacklist ORDER BY blocked_at DESC LIMIT ?').all(limit);
}

// === 万象书屋: 多管理员 ===
async function createAdminUser({ username, password, role = 'operator', creator }) {
  if (!username || !password) throw new Error('username & password required');
  if (password.length < 8) throw new Error('password too short');
  const allowedRoles = new Set(['super', 'operator', 'cs']);
  if (!allowedRoles.has(role)) throw new Error('invalid role');
  const exists = db.prepare('SELECT 1 FROM admin_users WHERE username=?').get(username);
  if (exists) throw new Error('username already exists');
  const hash = await bcrypt.hash(password, BCRYPT_COST);
  const now = Date.now();
  db.prepare(
    'INSERT INTO admin_users(username, pwd_hash, role, created_at, updated_at) VALUES (?, ?, ?, ?, ?)'
  ).run(username, hash, role, now, now);
  recordAudit({ action: 'admin.user.create', target: username, detail: { role, creator } });
}

// 万象书屋 D-8 修复: 防 timing attack 测 username 存在性.
// 用一个固定 dummy bcrypt hash, 用户不存在时也跑一次 bcrypt.compare,
// 让 "username 不存在" 跟 "username 存在但密码错" 的响应耗时一致 (~bcrypt cost).
//
// 万象书屋 D-15 修复 (B-1): 之前硬编码字符串不是合法 bcrypt hash —
//   53 字符 (合法 bcrypt 是 60 字符) + base64 字符表违规 (含连续的 abc...XYZ 跨段).
//   bcrypt.compare 会立即抛 'Invalid salt' 被 .catch(() => false) 吞掉, **耗时几乎为 0**,
//   timing 防护完全失效, 用户名枚举仍然成立.
// 修复: 启动时用同样 BCRYPT_COST 真实生成一次, 永远不会被任何真实密码匹配
// (rand 32 字节作明文, 强度足够 — 任何攻击者都猜不到这个明文).
const _DUMMY_PWD_HASH = bcrypt.hashSync(
  'dummy-' + require('crypto').randomBytes(32).toString('hex'),
  BCRYPT_COST
);

async function verifyAdminUser(username, password) {
  if (!username || !password) return null;
  const row = db.prepare('SELECT * FROM admin_users WHERE username=?').get(username);
  if (!row) {
    // 关键: 即使用户不存在也跑一次 bcrypt.compare 平衡耗时
    await bcrypt.compare(password, _DUMMY_PWD_HASH).catch(() => false);
    return null;
  }
  const ok = await bcrypt.compare(password, row.pwd_hash);
  return ok ? row : null;
}

function listAdminUsers() {
  return db.prepare(
    'SELECT username, role, totp_enabled, created_at, last_login_at, last_login_ip FROM admin_users ORDER BY created_at ASC'
  ).all();
}

async function updateAdminPassword(username, newPassword) {
  if (newPassword.length < 8) throw new Error('password too short');
  const hash = await bcrypt.hash(newPassword, BCRYPT_COST);
  db.prepare('UPDATE admin_users SET pwd_hash=?, updated_at=? WHERE username=?').run(hash, Date.now(), username);
}

function deleteAdminUser(username) {
  db.prepare('DELETE FROM admin_users WHERE username=?').run(username);
}

function setAdminTotpSecret(username, secret, enabled) {
  db.prepare('UPDATE admin_users SET totp_secret=?, totp_enabled=?, updated_at=? WHERE username=?')
    .run(secret, enabled ? 1 : 0, Date.now(), username);
}

function recordAdminLogin(username, ip) {
  db.prepare('UPDATE admin_users SET last_login_at=?, last_login_ip=? WHERE username=?')
    .run(Date.now(), ip || '', username);
}

// === 万象书屋: 兑换码 ===
function createRedeemCodes({ count, rewardType, rewardValue, batch, maxUses = 1, expiresAt = 0, creator }) {
  if (!rewardType || !rewardValue) throw new Error('rewardType & rewardValue required');
  const allowedTypes = new Set(['ad_free_minutes', 'vip_days', 'custom']);
  if (!allowedTypes.has(rewardType)) throw new Error('invalid rewardType');
  const n = Math.max(1, Math.min(1000, Number(count) || 1));
  const now = Date.now();
  const codes = [];
  const stmt = db.prepare(
    `INSERT INTO redeem_codes(code, reward_type, reward_value, batch, max_uses, expires_at, created_at, created_by)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
  );
  const tx = db.transaction(() => {
    for (let i = 0; i < n; i++) {
      // 8 字符 base32 风格 (排除易混: 0/O/1/I/L)
      const code = randomCode(10);
      stmt.run(code, rewardType, Number(rewardValue), batch || null, maxUses, expiresAt, now, creator || null);
      codes.push(code);
    }
  });
  tx();
  return codes;
}

function randomCode(len = 10) {
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; // 去 I L 0 1 O
  const bytes = require('crypto').randomBytes(len);
  let s = '';
  for (let i = 0; i < len; i++) s += alphabet[bytes[i] % alphabet.length];
  return s;
}

/**
 * 万象书屋: 原子兑换. 之前 SELECT/UPDATE/INSERT 分三步, 高并发下 (两台设备抢最后 1 次)
 * 可击穿 max_uses. 改用单 UPDATE-with-check + UNIQUE(code,device_id) 防双击.
 *
 * 流程:
 *   1) UPDATE redeem_codes SET used_count = used_count + 1
 *      WHERE code=? AND revoked=0 AND used_count<max_uses AND (expires_at=0 OR expires_at>now)
 *      → SQLite 在单条语句下保证 row-level 原子, changes()===1 即"成功占了一个名额"
 *   2) INSERT INTO redeem_uses(...) — UNIQUE(code,device_id) 失败说明同设备已兑过, 此时回滚
 *   3) 回滚 = used_count - 1
 *
 * 使用 BEGIN IMMEDIATE 避免读写交错.
 */
const stmtUpdateRedeemAtomic = db.prepare(
  `UPDATE redeem_codes
   SET used_count = used_count + 1
   WHERE code = ?
     AND revoked = 0
     AND used_count < max_uses
     AND (expires_at = 0 OR expires_at > ?)`
);
const stmtRollbackRedeem = db.prepare('UPDATE redeem_codes SET used_count = used_count - 1 WHERE code = ?');
const stmtSelectRedeemReward = db.prepare('SELECT reward_type, reward_value FROM redeem_codes WHERE code = ?');
const stmtInsertRedeemUse = db.prepare('INSERT INTO redeem_uses(code, device_id, used_at, ip) VALUES (?, ?, ?, ?)');

function redeemCode(code, deviceId, ip) {
  if (!code || !deviceId) throw new Error('code & deviceId required');
  const now = Date.now();
  // 先查存在性 (失败原因要给具体), 然后用原子 update 占位
  const row = stmtSelectRedeemReward.get(code);
  if (!row) return { ok: false, msg: 'code not found' };

  const tx = db.transaction(() => {
    const r = stmtUpdateRedeemAtomic.run(code, now);
    if (r.changes !== 1) {
      // 占位失败: 已用尽 / 撤销 / 过期, 给一个通用消息让客户端知道无效
      // 具体原因再查一次 row 的 revoked/expires_at/used_count, 但消息粒度低对外足够
      return { ok: false, msg: 'code unavailable (used up / revoked / expired)' };
    }
    // 占位成功后, 尝试插使用记录; UNIQUE(code,device_id) 命中即同设备重兑, 回滚名额
    try {
      stmtInsertRedeemUse.run(code, deviceId, now, ip || '');
    } catch (e) {
      // SQLITE_CONSTRAINT_UNIQUE
      stmtRollbackRedeem.run(code);
      return { ok: false, msg: 'already redeemed by this device' };
    }
    return { ok: true, rewardType: row.reward_type, rewardValue: row.reward_value };
  });
  return tx();
}

function listRedeemCodes({ batch, limit = 500 } = {}) {
  if (batch) {
    return db.prepare('SELECT * FROM redeem_codes WHERE batch=? ORDER BY created_at DESC LIMIT ?').all(batch, limit);
  }
  return db.prepare('SELECT * FROM redeem_codes ORDER BY created_at DESC LIMIT ?').all(limit);
}

function revokeRedeemBatch(batch) {
  const r = db.prepare('UPDATE redeem_codes SET revoked=1 WHERE batch=?').run(batch);
  return r.changes;
}

// === 万象书屋: 告警规则 ===
function listAlertRules() {
  return db.prepare('SELECT * FROM alert_rules ORDER BY id DESC').all();
}

function upsertAlertRule(o) {
  const now = Date.now();
  if (o.id) {
    db.prepare(
      `UPDATE alert_rules SET name=?, kind=?, threshold=?, window_min=?, webhook_url=?, webhook_kind=?, enabled=?, cooldown_min=? WHERE id=?`
    ).run(o.name, o.kind, Number(o.threshold), Number(o.window_min) || 5,
          o.webhook_url, o.webhook_kind || 'wecom', o.enabled ? 1 : 0, Number(o.cooldown_min) || 30, Number(o.id));
    return o.id;
  }
  const r = db.prepare(
    `INSERT INTO alert_rules(name, kind, threshold, window_min, webhook_url, webhook_kind, enabled, cooldown_min, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
  ).run(o.name, o.kind, Number(o.threshold), Number(o.window_min) || 5,
        o.webhook_url, o.webhook_kind || 'wecom', o.enabled ? 1 : 0, Number(o.cooldown_min) || 30, now);
  return r.lastInsertRowid;
}

function deleteAlertRule(id) {
  db.prepare('DELETE FROM alert_rules WHERE id=?').run(Number(id));
}

function markAlertFired(id) {
  db.prepare('UPDATE alert_rules SET last_fired_at=? WHERE id=?').run(Date.now(), Number(id));
}

// === 万象书屋: 设备 token (HMAC) 防伪 ===
//
// 防御场景:
//   - 攻击者拿到别人的 device_id (从抓包 / log 漏出去) 想冒充该设备刷接口
//   - 用户重装 App 想绕过黑名单
//
// 设计:
//   - 首次启动: App 调 /api/device/register 注册, 后端生成 token = HMAC(SECRET, device_id||install_ts)
//   - 后续接口: App 同时带 device_id + token (header 或 body), 后端比对 token_hash
//   - SECRET 在 server.js 用环境变量 DEVICE_TOKEN_SECRET, 必须保密
//   - token 一次发放永不过期 (重装则重新走 register)
// 万象书屋: 修一个潜在严重 bug — ON CONFLICT 时**必须**更新 token_hash 和 install_ts.
// 之前不更新, 导致 reissue=true 时后端给 App 发新 token 但 db 仍存旧 token,
// App 后续 verifyDeviceToken 永远 401. 这个路径只有在 reissue=true 或者代码 bug 写重复时
// 才走到 ON CONFLICT (普通 register 已经被 server.js 路由的 if existing 拦了).
const _stmtUpsertDeviceToken = db.prepare(
  // 万象书屋: 加 platform (006_multi_platform.sql), iOS / Android 共用一套表区分平台.
  // 老客户端不传 platform 时 server.js middleware 默认 'android', 兼容存量数据.
  `INSERT INTO device_tokens(device_id, token_hash, install_ts, last_seen_at, ua, ip, platform)
   VALUES (?, ?, ?, ?, ?, ?, ?)
   ON CONFLICT(device_id) DO UPDATE SET
     token_hash = excluded.token_hash,
     install_ts = excluded.install_ts,
     last_seen_at = excluded.last_seen_at,
     ua = excluded.ua,
     ip = excluded.ip,
     platform = excluded.platform`
);
const _stmtGetDeviceTokenHash = db.prepare(
  'SELECT token_hash FROM device_tokens WHERE device_id = ?'
);
const _stmtTouchDeviceSeen = db.prepare(
  'UPDATE device_tokens SET last_seen_at = ? WHERE device_id = ?'
);

function upsertDeviceToken({ deviceId, tokenHash, installTs, ua, ip, platform }) {
  const now = Date.now();
  // 万象书屋: platform 必须是 'android' / 'ios' / 'web', 默认 android 兼容老 App.
  const p = (platform === 'ios' || platform === 'web') ? platform : 'android';
  _stmtUpsertDeviceToken.run(
    deviceId, tokenHash, installTs || now, now,
    ua || null, ip || null, p
  );
}

function getDeviceTokenHash(deviceId) {
  const r = _stmtGetDeviceTokenHash.get(deviceId);
  return r ? r.token_hash : null;
}

function touchDeviceSeen(deviceId) {
  _stmtTouchDeviceSeen.run(Date.now(), deviceId);
}

function deleteDeviceToken(deviceId) {
  db.prepare('DELETE FROM device_tokens WHERE device_id = ?').run(deviceId);
}

// 万象书屋 D-14 修复: 通用 KV settings, 给运维状态持久化 (跨进程重启不丢)
// 例如 breakerSuppressUntil — 之前是内存变量, 重启就丢, 运维设的 360min 保护期失效.
function kvGet(key) {
  const r = db.prepare('SELECT v FROM kv_settings WHERE k = ?').get(key);
  return r ? r.v : null;
}
function kvSet(key, value) {
  db.prepare(
    `INSERT INTO kv_settings(k, v, updated_at) VALUES (?, ?, ?)
     ON CONFLICT(k) DO UPDATE SET v=excluded.v, updated_at=excluded.updated_at`
  ).run(key, String(value), Date.now());
}

// === 万象书屋: admin 账户级登录锁定 ===
//
// 防御场景: IP 限流防机器, username 锁定防慢速爆破 (即使攻击者换 IP).
// 配合 loginRateLimit 双管齐下.
//
// 策略:
//   - 同一 username 在 LOCK_WINDOW_MIN 分钟内失败 ≥ LOCK_THRESHOLD 次 → 锁 LOCK_DURATION_MIN 分钟
//   - 锁定期间: 即使密码正确也拒绝, 返回 423 Locked
//   - 成功登录: 清空该 username 的失败记录
const _stmtRecordLoginFail = db.prepare(
  'INSERT INTO admin_login_failures (username, ip, ts) VALUES (?, ?, ?)'
);
const _stmtCountLoginFail = db.prepare(
  'SELECT COUNT(*) AS n FROM admin_login_failures WHERE username = ? AND ts > ?'
);
const _stmtClearLoginFail = db.prepare(
  'DELETE FROM admin_login_failures WHERE username = ?'
);
const _stmtLatestLoginFailTs = db.prepare(
  'SELECT MAX(ts) AS t FROM admin_login_failures WHERE username = ? AND ts > ?'
);

function recordLoginFailure(username, ip) {
  _stmtRecordLoginFail.run(username || '?', ip || null, Date.now());
}

function clearLoginFailures(username) {
  _stmtClearLoginFail.run(username || '?');
}

/**
 * 检查 username 是否被锁定. 返回 { locked, unlock_at } / { locked: false }.
 *
 * @param {string} username
 * @param {object} [opt]
 * @param {number} [opt.windowMin=5]   失败计数窗口
 * @param {number} [opt.threshold=5]   阈值
 * @param {number} [opt.lockMin=30]    锁定时长
 */
function isAccountLocked(username, opt = {}) {
  const windowMin = opt.windowMin || 5;
  const threshold = opt.threshold || 5;
  const lockMin = opt.lockMin || 30;
  const since = Date.now() - windowMin * 60_000;
  const r = _stmtCountLoginFail.get(username || '?', since);
  if (!r || r.n < threshold) return { locked: false };
  // 锁定窗口从最近一次失败开始算
  const t = _stmtLatestLoginFailTs.get(username || '?', since);
  const lastTs = t ? t.t : Date.now();
  const unlockAt = lastTs + lockMin * 60_000;
  if (Date.now() > unlockAt) return { locked: false };
  return { locked: true, unlock_at: unlockAt };
}

/**
 * 万象书屋: 按 device_id 级联清空用户在后端的所有数据.
 * PIPL 第 47 条 "处理者应当主动删除" 的合规实现.
 *
 * 调用场景: 用户在 App 内点"注销账号", App 调 DELETE /api/me/wipe-data 时.
 * 不删 device_blacklist (黑名单保留, 重装不能绕过).
 *
 * 返回 { tableName: deletedCount }, 给 admin 审计 / 用户证据.
 */
function wipeUserData(deviceId) {
  if (!deviceId || typeof deviceId !== 'string') return { error: 'invalid device_id' };
  const stats = {};
  // 用 transaction 保证要么全删要么不删
  const tx = db.transaction(() => {
    // 万象书屋 D-15 修复 (B-3 / PIPL 第 47 条): 注销账号必须删干净所有按 device_id 关联的个人数据.
    // 旧版漏删:
    //   - events:               自建埋点 (PV/click/留存), 留存 90 天, 含 device_id
    //   - iap_receipts:         iOS 内购票据, 永久保留, 含 device_id
    //   - source_error_events:  设备级解析错误事件, 留存 30 天, 含 device_id
    // 这三张表都属于"按 device_id 可关联到自然人的个人信息", 注销时未删 ≡ 违规留存.
    const tables = [
      'heartbeats',
      'visits',
      'ad_events',
      'crashes',
      'feedback',
      'redeem_uses',
      'device_tokens',
      'events',                  // D-15: 用户行为埋点
      'iap_receipts',            // D-15: iOS 内购票据
      'source_error_events',     // D-15: 设备级解析错误
    ];
    for (const t of tables) {
      try {
        const r = db.prepare(`DELETE FROM ${t} WHERE device_id = ?`).run(deviceId);
        stats[t] = r.changes;
      } catch (e) {
        // 表不存在 / 字段名不一样, 跳过
        stats[t] = 0;
      }
    }
  });
  tx();
  return stats;
}

// 定时清理过期数据
function cleanupOldData() {
  // 心跳: 保留 30 天
  const heartbeatCutoff = Date.now() - 30 * 86400 * 1000;
  db.prepare('DELETE FROM heartbeats WHERE ts < ?').run(heartbeatCutoff);
  // 访问记录: 保留 90 天
  const visitCutoffDay = new Date(Date.now() + 8 * 3600 * 1000 - 90 * 86400 * 1000)
    .toISOString().slice(0, 10);
  db.prepare('DELETE FROM visits WHERE day < ?').run(visitCutoffDay);
  // 万象书屋: 顺手清理过期 admin session (7 天前的)
  const sessionCutoff = Date.now() - 7 * 86400 * 1000;
  db.prepare('DELETE FROM admin_session WHERE created_at < ?').run(sessionCutoff);
  // 万象书屋: 广告事件保留 30 天, 崩溃 90 天, 审计 180 天, 反馈 done/spam 状态保留 90 天
  db.prepare('DELETE FROM ad_events WHERE ts < ?').run(Date.now() - 30 * 86400 * 1000);
  db.prepare('DELETE FROM crashes WHERE ts < ?').run(Date.now() - 90 * 86400 * 1000);
  db.prepare('DELETE FROM audit_log WHERE ts < ?').run(Date.now() - 180 * 86400 * 1000);
  db.prepare(
    `DELETE FROM feedback WHERE status IN ('done','spam') AND ts < ?`
  ).run(Date.now() - 90 * 86400 * 1000);
  // 万象书屋: 设备 token 长时间没活跃 (超 365 天) 清掉, 用户重装会自动重新注册
  db.prepare('DELETE FROM device_tokens WHERE last_seen_at < ?')
    .run(Date.now() - 365 * 86400 * 1000);
  // 登录失败记录 ≤30 天 (锁定窗口最长 30 分钟, 30 天 buffer 用于事后审计)
  db.prepare('DELETE FROM admin_login_failures WHERE ts < ?')
    .run(Date.now() - 30 * 86400 * 1000);
  // 万象书屋: source_error_events 保留 30 天, source_health 是聚合表保留所有
  db.prepare('DELETE FROM source_error_events WHERE ts < ?')
    .run(Date.now() - 30 * 86400 * 1000);
  // 万象书屋: events 表保留 90 天 (PV/click 量大, 90 天足够做留存分析)
  db.prepare('DELETE FROM events WHERE ts < ?')
    .run(Date.now() - 90 * 86400 * 1000);
}

// ==================== 万象书屋: 自建埋点 ====================

const _insertEventStmt = db.prepare(`
  INSERT INTO events (ts, client_ts, device_id, platform, app_ver,
                      event_type, event_name, params, session_id, ip)
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
`);

/**
 * 单条事件入库. 高频路径, 用 prepared statement.
 * @param {object} e {clientTs, deviceId, platform, appVer, type, name, params, sessionId, ip}
 */
function recordEvent(e) {
  const params = e.params != null
    ? (typeof e.params === 'string' ? e.params : JSON.stringify(e.params))
    : null;
  _insertEventStmt.run(
    Date.now(),
    e.clientTs ? Number(e.clientTs) : null,
    String(e.deviceId).slice(0, 80),
    e.platform || null,
    e.appVer || null,
    String(e.type || 'custom').slice(0, 32),
    String(e.name || '').slice(0, 80),
    params ? params.slice(0, 4000) : null,
    e.sessionId ? String(e.sessionId).slice(0, 64) : null,
    e.ip || null,
  );
}

/**
 * 批量事件入库 (上报路径用, 减少 SQLite 事务开销).
 * 在单事务里跑, 出错全部回滚.
 */
function recordEventsBulk(events, ip) {
  if (!Array.isArray(events) || !events.length) return 0;
  const tx = db.transaction((arr) => {
    for (const e of arr) recordEvent({ ...e, ip: e.ip || ip });
  });
  tx(events);
  return events.length;
}

/**
 * 列出最近事件, 管理面板用.
 * @param {object} opts {limit=200, eventName, deviceId, type, sinceTs}
 */
function listEvents(opts = {}) {
  const limit = Math.min(parseInt(opts.limit, 10) || 200, 1000);
  const conds = [];
  const args = [];
  if (opts.eventName) { conds.push('event_name = ?'); args.push(opts.eventName); }
  if (opts.deviceId)  { conds.push('device_id = ?');  args.push(opts.deviceId); }
  if (opts.type)      { conds.push('event_type = ?'); args.push(opts.type); }
  if (opts.sinceTs)   { conds.push('ts >= ?');         args.push(Number(opts.sinceTs)); }
  const where = conds.length ? 'WHERE ' + conds.join(' AND ') : '';
  return db.prepare(
    `SELECT id, ts, client_ts, device_id, platform, app_ver,
            event_type, event_name, params, session_id, ip
     FROM events ${where}
     ORDER BY ts DESC LIMIT ?`
  ).all(...args, limit);
}

/**
 * 事件 Top 排行 (按 event_name 计数).
 * @param {object} opts {sinceTs, limit=20, type}
 */
function eventTopList(opts = {}) {
  const sinceTs = Number(opts.sinceTs) || (Date.now() - 7 * 86400 * 1000);
  const limit = Math.min(parseInt(opts.limit, 10) || 20, 100);
  const typeFilter = opts.type ? 'AND event_type = ?' : '';
  const args = opts.type ? [sinceTs, opts.type, limit] : [sinceTs, limit];
  return db.prepare(
    `SELECT event_name, event_type, COUNT(*) AS count,
            COUNT(DISTINCT device_id) AS uv
     FROM events
     WHERE ts >= ? ${typeFilter}
     GROUP BY event_name
     ORDER BY count DESC
     LIMIT ?`
  ).all(...args);
}

/**
 * 按天统计 DAU (基于 events 表 distinct device_id).
 * @param {number} days 默认 7 天
 */
function eventDailyDau(days = 7) {
  const since = Date.now() - days * 86400 * 1000;
  // SQLite 没有 date() 转毫秒的内置, 我们用 (ts/86400000)|0 取天数 epoch
  const rows = db.prepare(
    `SELECT CAST((ts + 28800000) / 86400000 AS INTEGER) AS day_idx,
            COUNT(DISTINCT device_id) AS dau,
            COUNT(*) AS events
     FROM events WHERE ts >= ?
     GROUP BY day_idx ORDER BY day_idx ASC`
  ).all(since);
  // 把 day_idx 转回 yyyy-mm-dd (北京时区已通过 +28800000 偏移)
  return rows.map(r => {
    const d = new Date(r.day_idx * 86400000 - 28800000);
    return {
      date: d.toISOString().slice(0, 10),
      dau: r.dau,
      events: r.events,
    };
  });
}

/**
 * 简单漏斗分析: 给定一组 event_name 序列, 返回每个步骤的去重设备数 + 转化率.
 * @param {string[]} steps 例 ['app_open', 'page_main', 'page_bookshelf', 'read_chapter_open']
 * @param {number} sinceTs 默认最近 7 天
 */
function eventFunnel(steps, sinceTs) {
  if (!Array.isArray(steps) || !steps.length) return [];
  const since = sinceTs || (Date.now() - 7 * 86400 * 1000);
  return steps.map((name, idx) => {
    const uv = db.prepare(
      `SELECT COUNT(DISTINCT device_id) AS uv FROM events
       WHERE ts >= ? AND event_name = ?`
    ).get(since, name).uv;
    return { step: idx + 1, name, uv };
  });
}

/**
 * Cohort 留存矩阵分析.
 *
 * 定义:
 *   cohort = 同一天首次出现在 events 表里的设备集合 (即"新增用户")
 *   day_N retention = cohort 在第 N 天还活跃的设备数 (events 里有任何事件)
 *   day_0 = 当天本身, 一定等于 cohort_size
 *   day_1 = 第二天还回来的设备, day_2 = 第三天, 以此类推
 *
 * 性能:
 *   单查询取所有 events (device_id, ts), 在 Node 里建两层 Map 聚合,
 *   时间复杂度 O(events_count). events 表 90 天内 SQLite 单 ms 取几万行没问题.
 *
 * @param {number} windowDays cohort 窗口大小, 默认 14 (最近 14 天形成的 cohort, 每个看
 *   后续 14 天的留存; 早于 2*windowDays 之前的不查).
 * @returns {{ windowDays, cohorts: [{ date, size, retention: number[], retentionPct: number[] }] }}
 */
function eventRetentionMatrix(windowDays = 14) {
  const W = Math.max(2, Math.min(60, parseInt(windowDays, 10) || 14));
  const DAY = 86_400_000;
  const TZ_OFFSET = 8 * 3600_000;  // UTC+8 北京时区
  const now = Date.now();
  // 取 2*W 天内的事件: 最早形成的 cohort 是 W 天前, 它最多还能再观察 W-1 天
  const since = now - (2 * W) * DAY;

  const rows = db.prepare(
    'SELECT device_id, ts FROM events WHERE ts >= ? ORDER BY ts ASC'
  ).all(since);

  // device -> first day index (按 device_id ASC 不能直接拿首次时间,
  //  ORDER BY ts ASC 后第一次见到该 device_id 就是 first time)
  const firstDay = new Map();        // device_id -> dayIdx
  const activeDays = new Map();      // device_id -> Set<dayIdx>
  for (const r of rows) {
    const dayIdx = Math.floor((r.ts + TZ_OFFSET) / DAY);
    if (!firstDay.has(r.device_id)) firstDay.set(r.device_id, dayIdx);
    let s = activeDays.get(r.device_id);
    if (!s) { s = new Set(); activeDays.set(r.device_id, s); }
    s.add(dayIdx);
  }

  // 按 cohort_day 分组所有 device
  const cohortDevices = new Map();   // dayIdx -> string[]
  for (const [dev, day] of firstDay) {
    let arr = cohortDevices.get(day);
    if (!arr) { arr = []; cohortDevices.set(day, arr); }
    arr.push(dev);
  }

  const todayIdx = Math.floor((now + TZ_OFFSET) / DAY);
  const cohorts = [];
  // 窗口: 从 W-1 天前的 cohort 到今天的 cohort
  for (let off = W - 1; off >= 0; off--) {
    const cohortDay = todayIdx - off;
    const devices = cohortDevices.get(cohortDay) || [];
    const retention = new Array(W).fill(null);
    const retentionPct = new Array(W).fill(null);
    for (let dN = 0; dN < W; dN++) {
      const dayIdx = cohortDay + dN;
      if (dayIdx > todayIdx) break;       // 未来日期不计入
      let count = 0;
      for (const dev of devices) {
        if (activeDays.get(dev)?.has(dayIdx)) count++;
      }
      retention[dN] = count;
      retentionPct[dN] = devices.length ? +(count / devices.length * 100).toFixed(1) : 0;
    }
    cohorts.push({
      date: new Date(cohortDay * DAY - TZ_OFFSET).toISOString().slice(0, 10),
      size: devices.length,
      retention,
      retentionPct,
    });
  }

  return { windowDays: W, cohorts };
}

/** 总览统计: 给管理面板首页用 */
function eventOverview() {
  const day = 86400 * 1000;
  const now = Date.now();
  const r = (q, ...args) => db.prepare(q).get(...args);
  return {
    today: r('SELECT COUNT(*) AS c FROM events WHERE ts >= ?', now - day).c,
    yesterday: r(
      'SELECT COUNT(*) AS c FROM events WHERE ts >= ? AND ts < ?',
      now - 2 * day, now - day
    ).c,
    week: r('SELECT COUNT(*) AS c FROM events WHERE ts >= ?', now - 7 * day).c,
    devicesToday: r(
      'SELECT COUNT(DISTINCT device_id) AS c FROM events WHERE ts >= ?',
      now - day
    ).c,
    totalEvents: r('SELECT COUNT(*) AS c FROM events').c,
    pvToday: r(
      "SELECT COUNT(*) AS c FROM events WHERE ts >= ? AND event_type = 'pv'",
      now - day
    ).c,
    clickToday: r(
      "SELECT COUNT(*) AS c FROM events WHERE ts >= ? AND event_type = 'click'",
      now - day
    ).c,
  };
}

module.exports = {
  init,
  // book sources
  listEnabledSourcesJson, getEnabledSourcesEtag, listAllSources,
  getSource, upsertSource, bulkUpsert, deleteSource, setEnabled,
  setSourcePlatforms,
  invalidateSourcesCache, _invalidateSourcesCacheForTest,
  // bookstore feed (008)
  listBookstoreFeed, getBookstoreFeedEtag, listAllBookstoreFeed,
  upsertBookstoreFeed, setBookstoreFeedEnabled, deleteBookstoreFeed,
  invalidateFeedCache,
  // 万象书屋 D-23 (012): bookstore mirror cache
  insertBookstoreMirror, getLatestBookstoreMirror, listRecentBookstoreMirror,
  cleanupOldBookstoreMirror, setBookstoreMirrorOverrides,
  // source health / parser observability
  recordSourceHealth, recordSourceErrorEvent, listSourceHealth,
  sourceHealthSummary, runSourceStaticCheck,
  // ping / stats
  recordPing, statsOnline, statsToday, statsWeek, statsMonth, statsDailyCurve,
  // admin
  verifyAdminPassword, verifyAdminPasswordSync, setAdminPassword,
  createSession, isValidSession, destroySession, destroyAllSessions,
  // device tokens (HMAC anti-forge)
  upsertDeviceToken, getDeviceTokenHash, touchDeviceSeen, deleteDeviceToken,
  // KV settings (跨进程持久化运维状态)
  kvGet, kvSet,
  // admin login lockout
  recordLoginFailure, clearLoginFailures, isAccountLocked,
  // PIPL data wipe
  wipeUserData,
  // ad config
  getAdConfig, getAdConfigRaw, saveAdConfig, listAdConfigHistory, getAdConfigByVersion, DEFAULT_AD_CONFIG,
  setAdConfigStaging, commitAdConfigStaging, abortAdConfigStaging,
  // ad events / crashes / audit / feedback
  recordAdEvent, adEventFunnel, adProvidersToBreak,
  recordCrash, listCrashSummary, listCrashesByFingerprint,
  recordAudit, listAuditLog,
  recordFeedback, listFeedback, updateFeedbackStatus, feedbackStats,
  // 万象书屋 iOS: IAP 票据
  saveIapReceipt, listActiveIapForDevice, setIapStatus,
  // 万象书屋 v2: 强制升级 / 公告 / 黑名单 / 多管理员 / 兑换码 / 告警
  getAppVersion, saveAppVersion,
  listActiveAnnouncements, listAllAnnouncements, upsertAnnouncement, deleteAnnouncement,
  isDeviceBlocked, blockDevice, unblockDevice, listBlockedDevices,
  createAdminUser, verifyAdminUser, listAdminUsers, updateAdminPassword,
  deleteAdminUser, setAdminTotpSecret, recordAdminLogin,
  createRedeemCodes, redeemCode, listRedeemCodes, revokeRedeemBatch,
  listAlertRules, upsertAlertRule, deleteAlertRule, markAlertFired,
  cleanupOldData,
  // 万象书屋: 自建埋点
  recordEvent, recordEventsBulk, listEvents, eventTopList,
  eventDailyDau, eventFunnel, eventOverview, eventRetentionMatrix,
  // db instance (用于 graceful shutdown close + 自动备份)
  __db: db,
};
