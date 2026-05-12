// 万象书屋 - SQLite 数据访问层 (入口 / 重导出)
//
// 所有业务逻辑已拆分到 models/ 目录，本文件只做：
//   1. 创建 DB 连接 + 调优
//   2. 建表 + migration
//   3. 初始化各 model
//   4. 重导出所有函数（保持 require('./db') 接口不变）

const path = require('path');
const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'data', 'wanxiang.db');
const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.pragma('busy_timeout = 5000');
db.pragma('synchronous = NORMAL');
db.pragma('foreign_keys = ON');
db.pragma('cache_size = -64000');

const BCRYPT_COST = (() => {
  const v = parseInt(process.env.BCRYPT_COST, 10);
  if (!Number.isFinite(v)) return 10;
  if (v < 4) { console.warn('[db] BCRYPT_COST clamped to 4 (was ' + v + ')'); return 4; }
  if (v > 14) { console.warn('[db] BCRYPT_COST clamped to 14 (was ' + v + ')'); return 14; }
  return v;
})();

// ─── 建表 ───────────────────────────────────────────────────

function init() {
  db.exec(`
    CREATE TABLE IF NOT EXISTS book_sources (
      url TEXT PRIMARY KEY, name TEXT, json TEXT NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS heartbeats (
      device_id TEXT NOT NULL, ts INTEGER NOT NULL,
      PRIMARY KEY (device_id, ts)
    );
    CREATE INDEX IF NOT EXISTS idx_heartbeats_ts ON heartbeats(ts);
    CREATE TABLE IF NOT EXISTS visits (
      device_id TEXT NOT NULL, day TEXT NOT NULL, first_ts INTEGER NOT NULL,
      PRIMARY KEY (device_id, day)
    );
    CREATE INDEX IF NOT EXISTS idx_visits_day ON visits(day);
    CREATE TABLE IF NOT EXISTS admin (
      id INTEGER PRIMARY KEY CHECK (id = 1), pwd_hash TEXT NOT NULL, updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS admin_session (
      token TEXT PRIMARY KEY, created_at INTEGER NOT NULL,
      ip TEXT, ua_hash TEXT, username TEXT, role TEXT
    );
    CREATE TABLE IF NOT EXISTS ad_config (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      version INTEGER NOT NULL, json TEXT NOT NULL, etag TEXT NOT NULL, updated_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ad_config_history (
      version INTEGER PRIMARY KEY, json TEXT NOT NULL, created_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS ad_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
      placement TEXT NOT NULL, provider TEXT NOT NULL, type TEXT NOT NULL,
      err_code INTEGER, err_msg TEXT, device_id TEXT, app_ver TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_ad_events_ts ON ad_events(ts);
    CREATE INDEX IF NOT EXISTS idx_ad_events_pp ON ad_events(placement, provider, ts);
    CREATE TABLE IF NOT EXISTS crashes (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
      device_id TEXT, app_ver TEXT, brand TEXT, model TEXT, sdk_int INTEGER,
      fingerprint TEXT, exception TEXT NOT NULL, stack TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_crashes_ts ON crashes(ts);
    CREATE INDEX IF NOT EXISTS idx_crashes_fp ON crashes(fingerprint, ts);
    CREATE TABLE IF NOT EXISTS audit_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
      ip TEXT, action TEXT NOT NULL, target TEXT, detail TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts);
    CREATE TABLE IF NOT EXISTS app_versions (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      latest_code INTEGER NOT NULL DEFAULT 0, latest_name TEXT NOT NULL DEFAULT '',
      min_required_code INTEGER NOT NULL DEFAULT 0, changelog TEXT,
      apk_url TEXT, market_url TEXT, updated_at INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS announcements (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL, content TEXT NOT NULL,
      style TEXT NOT NULL DEFAULT 'info', dismissable INTEGER NOT NULL DEFAULT 1,
      enabled INTEGER NOT NULL DEFAULT 1,
      start_at INTEGER NOT NULL DEFAULT 0, end_at INTEGER NOT NULL DEFAULT 0,
      version_min INTEGER NOT NULL DEFAULT 0, version_max INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_announcements_enabled ON announcements(enabled, start_at, end_at);
    CREATE TABLE IF NOT EXISTS device_blacklist (
      device_id TEXT PRIMARY KEY, reason TEXT,
      blocked_at INTEGER NOT NULL, operator TEXT
    );
    CREATE TABLE IF NOT EXISTS admin_users (
      username TEXT PRIMARY KEY, pwd_hash TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'operator',
      totp_secret TEXT, totp_enabled INTEGER NOT NULL DEFAULT 0,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      last_login_at INTEGER, last_login_ip TEXT
    );
    CREATE TABLE IF NOT EXISTS redeem_codes (
      code TEXT PRIMARY KEY, reward_type TEXT NOT NULL, reward_value INTEGER NOT NULL,
      batch TEXT, max_uses INTEGER NOT NULL DEFAULT 1, used_count INTEGER NOT NULL DEFAULT 0,
      expires_at INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
      created_by TEXT, revoked INTEGER NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS idx_redeem_batch ON redeem_codes(batch);
    CREATE TABLE IF NOT EXISTS redeem_uses (
      id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL,
      device_id TEXT NOT NULL, used_at INTEGER NOT NULL, ip TEXT,
      UNIQUE(code, device_id)
    );
    CREATE INDEX IF NOT EXISTS idx_redeem_uses_code ON redeem_uses(code);
    CREATE INDEX IF NOT EXISTS idx_redeem_uses_device ON redeem_uses(device_id);
    CREATE TABLE IF NOT EXISTS alert_rules (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL, kind TEXT NOT NULL, threshold REAL NOT NULL,
      window_min INTEGER NOT NULL DEFAULT 5,
      webhook_url TEXT NOT NULL, webhook_kind TEXT NOT NULL DEFAULT 'wecom',
      enabled INTEGER NOT NULL DEFAULT 1, cooldown_min INTEGER NOT NULL DEFAULT 30,
      last_fired_at INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS feedback (
      id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL,
      type TEXT NOT NULL, content TEXT NOT NULL, contact TEXT,
      device_id TEXT, app_ver TEXT, ip TEXT,
      status TEXT NOT NULL DEFAULT 'open', reply TEXT, reply_ts INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_feedback_ts ON feedback(ts);
    CREATE INDEX IF NOT EXISTS idx_feedback_status ON feedback(status, ts);
    CREATE TABLE IF NOT EXISTS promo_codes (
      code TEXT PRIMARY KEY, agent_name TEXT NOT NULL DEFAULT '代理',
      max_uses INTEGER NOT NULL DEFAULT 0, single_device INTEGER NOT NULL DEFAULT 0,
      used_count INTEGER NOT NULL DEFAULT 0, expires_at INTEGER NOT NULL DEFAULT 0,
      enabled INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL, created_by TEXT
    );
    CREATE TABLE IF NOT EXISTS promo_attempts (
      id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL,
      device_id TEXT NOT NULL, device_model TEXT,
      success INTEGER NOT NULL DEFAULT 0, ip TEXT, ts INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_promo_attempts_code ON promo_attempts(code);
    CREATE INDEX IF NOT EXISTS idx_promo_attempts_device ON promo_attempts(device_id);
    CREATE INDEX IF NOT EXISTS idx_promo_attempts_ts ON promo_attempts(ts);
    CREATE TABLE IF NOT EXISTS promo_usage (
      id INTEGER PRIMARY KEY AUTOINCREMENT, code TEXT NOT NULL,
      agent_name TEXT NOT NULL, device_id TEXT NOT NULL,
      device_model TEXT, system_version TEXT, ip TEXT, ts INTEGER NOT NULL,
      UNIQUE(code, device_id)
    );
    CREATE INDEX IF NOT EXISTS idx_promo_usage_code ON promo_usage(code);
    CREATE INDEX IF NOT EXISTS idx_promo_usage_device ON promo_usage(device_id);
  `);

  migrateAddColumnIfMissing('admin_session', 'ip', 'TEXT');
  migrateAddColumnIfMissing('admin_session', 'ua_hash', 'TEXT');
  migrateAddColumnIfMissing('admin_session', 'username', 'TEXT');
  migrateAddColumnIfMissing('admin_session', 'role', 'TEXT');

  const row = db.prepare('SELECT 1 FROM admin WHERE id = 1').get();
  if (!row) {
    const initPwd = process.env.ADMIN_INITIAL_PASSWORD;
    if (!initPwd || initPwd.length < 8) {
      if (process.env.NODE_ENV === 'production' || process.env.REQUIRE_ADMIN_PWD === '1') {
        throw new Error('ADMIN_INITIAL_PASSWORD env must be set (>=8 chars) before first start');
      }
      const fallback = 'wanxiang2026';
      console.warn('[init] ADMIN_INITIAL_PASSWORD not set, using dev default (NON-PRODUCTION ONLY)');
      const hash = bcrypt.hashSync(fallback, BCRYPT_COST);
      db.prepare('INSERT INTO admin(id, pwd_hash, updated_at) VALUES (1, ?, ?)').run(hash, Date.now());
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

function runMigrations() {
  const fs = require('fs');
  const pathMod = require('path');
  const migDir = pathMod.join(__dirname, 'migrations');
  if (!fs.existsSync(migDir)) return;
  db.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
    filename TEXT PRIMARY KEY, applied_at INTEGER NOT NULL, duration_ms INTEGER
  )`);
  const files = fs.readdirSync(migDir).filter(f => f.endsWith('.sql')).sort();
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
      throw e;
    }
  }
}

// 定时清理过期数据
function cleanupOldData() {
  const heartbeatCutoff = Date.now() - 30 * 86400 * 1000;
  db.prepare('DELETE FROM heartbeats WHERE ts < ?').run(heartbeatCutoff);
  const visitCutoffDay = new Date(Date.now() + 8 * 3600 * 1000 - 90 * 86400 * 1000)
    .toISOString().slice(0, 10);
  db.prepare('DELETE FROM visits WHERE day < ?').run(visitCutoffDay);
  const sessionCutoff = Date.now() - 7 * 86400 * 1000;
  db.prepare('DELETE FROM admin_session WHERE created_at < ?').run(sessionCutoff);
  db.prepare('DELETE FROM ad_events WHERE ts < ?').run(Date.now() - 30 * 86400 * 1000);
  db.prepare('DELETE FROM crashes WHERE ts < ?').run(Date.now() - 90 * 86400 * 1000);
  db.prepare('DELETE FROM audit_log WHERE ts < ?').run(Date.now() - 180 * 86400 * 1000);
  db.prepare("DELETE FROM feedback WHERE status IN ('done','spam') AND ts < ?")
    .run(Date.now() - 90 * 86400 * 1000);
  db.prepare('DELETE FROM device_tokens WHERE last_seen_at < ?')
    .run(Date.now() - 365 * 86400 * 1000);
  db.prepare('DELETE FROM admin_login_failures WHERE ts < ?')
    .run(Date.now() - 30 * 86400 * 1000);
  db.prepare('DELETE FROM source_error_events WHERE ts < ?')
    .run(Date.now() - 30 * 86400 * 1000);
  db.prepare('DELETE FROM events WHERE ts < ?')
    .run(Date.now() - 90 * 86400 * 1000);
}

// ─── 初始化 ─────────────────────────────────────────────────

init();
runMigrations();

// 加载所有 models 并注入 db
const sourcesModel       = require('./models/sources');
const sourceHealthModel  = require('./models/sourceHealth');
const bookstoreFeedModel = require('./models/bookstoreFeed');
const heartbeatModel     = require('./models/heartbeat');
const adminModel         = require('./models/admin');
const adConfigModel      = require('./models/adConfig');
const adEventsModel      = require('./models/adEvents');
const deviceTokenModel   = require('./models/deviceToken');
const iapModel           = require('./models/iap');
const eventsModel        = require('./models/events');
const promoModel         = require('./models/promo');
const redeemModel        = require('./models/redeem');
const alertsModel        = require('./models/alerts');
const appVersionModel    = require('./models/appVersion');

sourcesModel.init(db);
sourceHealthModel.init(db, sourcesModel);
bookstoreFeedModel.init(db);
heartbeatModel.init(db);
adminModel.init(db, BCRYPT_COST);
adConfigModel.init(db);
adEventsModel.init(db);
deviceTokenModel.init(db);
iapModel.init(db);
eventsModel.init(db);
promoModel.init(db);
redeemModel.init(db);
alertsModel.init(db);
appVersionModel.init(db);

// ─── 重导出（保持 require('./db') 接口完全兼容）──────────────

module.exports = {
  init,
  // book sources
  listEnabledSourcesJson: sourcesModel.listEnabledSourcesJson,
  getEnabledSourcesEtag: sourcesModel.getEnabledSourcesEtag,
  listAllSources: sourcesModel.listAllSources,
  getSource: sourcesModel.getSource,
  upsertSource: sourcesModel.upsertSource,
  bulkUpsert: sourcesModel.bulkUpsert,
  deleteSource: sourcesModel.deleteSource,
  setEnabled: sourcesModel.setEnabled,
  setSourcePlatforms: sourcesModel.setSourcePlatforms,
  invalidateSourcesCache: sourcesModel.invalidateSourcesCache,
  _invalidateSourcesCacheForTest: sourcesModel._invalidateSourcesCacheForTest,
  // source health
  recordSourceHealth: sourceHealthModel.recordSourceHealth,
  recordSourceErrorEvent: sourceHealthModel.recordSourceErrorEvent,
  listSourceHealth: sourceHealthModel.listSourceHealth,
  sourceHealthSummary: sourceHealthModel.sourceHealthSummary,
  runSourceStaticCheck: sourceHealthModel.runSourceStaticCheck,
  // bookstore feed + mirror
  listBookstoreFeed: bookstoreFeedModel.listBookstoreFeed,
  getBookstoreFeedEtag: bookstoreFeedModel.getBookstoreFeedEtag,
  listAllBookstoreFeed: bookstoreFeedModel.listAllBookstoreFeed,
  upsertBookstoreFeed: bookstoreFeedModel.upsertBookstoreFeed,
  setBookstoreFeedEnabled: bookstoreFeedModel.setBookstoreFeedEnabled,
  deleteBookstoreFeed: bookstoreFeedModel.deleteBookstoreFeed,
  invalidateFeedCache: bookstoreFeedModel.invalidateFeedCache,
  insertBookstoreMirror: bookstoreFeedModel.insertBookstoreMirror,
  getLatestBookstoreMirror: bookstoreFeedModel.getLatestBookstoreMirror,
  listRecentBookstoreMirror: bookstoreFeedModel.listRecentBookstoreMirror,
  cleanupOldBookstoreMirror: bookstoreFeedModel.cleanupOldBookstoreMirror,
  setBookstoreMirrorOverrides: bookstoreFeedModel.setBookstoreMirrorOverrides,
  // heartbeat / stats
  recordPing: heartbeatModel.recordPing,
  statsOnline: heartbeatModel.statsOnline,
  statsToday: heartbeatModel.statsToday,
  statsWeek: heartbeatModel.statsWeek,
  statsMonth: heartbeatModel.statsMonth,
  statsDailyCurve: heartbeatModel.statsDailyCurve,
  // admin
  verifyAdminPassword: adminModel.verifyAdminPassword,
  verifyAdminPasswordSync: adminModel.verifyAdminPasswordSync,
  setAdminPassword: adminModel.setAdminPassword,
  createSession: adminModel.createSession,
  isValidSession: adminModel.isValidSession,
  destroySession: adminModel.destroySession,
  destroyAllSessions: adminModel.destroyAllSessions,
  createAdminUser: adminModel.createAdminUser,
  verifyAdminUser: adminModel.verifyAdminUser,
  listAdminUsers: adminModel.listAdminUsers,
  updateAdminPassword: adminModel.updateAdminPassword,
  deleteAdminUser: adminModel.deleteAdminUser,
  setAdminTotpSecret: adminModel.setAdminTotpSecret,
  recordAdminLogin: adminModel.recordAdminLogin,
  recordLoginFailure: adminModel.recordLoginFailure,
  clearLoginFailures: adminModel.clearLoginFailures,
  isAccountLocked: adminModel.isAccountLocked,
  // ad config
  getAdConfig: adConfigModel.getAdConfig,
  getAdConfigRaw: adConfigModel.getAdConfigRaw,
  saveAdConfig: adConfigModel.saveAdConfig,
  listAdConfigHistory: adConfigModel.listAdConfigHistory,
  getAdConfigByVersion: adConfigModel.getAdConfigByVersion,
  DEFAULT_AD_CONFIG: adConfigModel.DEFAULT_AD_CONFIG,
  setAdConfigStaging: adConfigModel.setAdConfigStaging,
  commitAdConfigStaging: adConfigModel.commitAdConfigStaging,
  abortAdConfigStaging: adConfigModel.abortAdConfigStaging,
  // ad events / crashes / audit / feedback
  recordAdEvent: adEventsModel.recordAdEvent,
  adEventFunnel: adEventsModel.adEventFunnel,
  adProvidersToBreak: adEventsModel.adProvidersToBreak,
  recordCrash: adEventsModel.recordCrash,
  listCrashSummary: adEventsModel.listCrashSummary,
  listCrashesByFingerprint: adEventsModel.listCrashesByFingerprint,
  recordAudit: adEventsModel.recordAudit,
  listAuditLog: adEventsModel.listAuditLog,
  recordFeedback: adEventsModel.recordFeedback,
  listFeedback: adEventsModel.listFeedback,
  updateFeedbackStatus: adEventsModel.updateFeedbackStatus,
  feedbackStats: adEventsModel.feedbackStats,
  // device token / blacklist / KV / wipe
  upsertDeviceToken: deviceTokenModel.upsertDeviceToken,
  getDeviceTokenHash: deviceTokenModel.getDeviceTokenHash,
  touchDeviceSeen: deviceTokenModel.touchDeviceSeen,
  deleteDeviceToken: deviceTokenModel.deleteDeviceToken,
  isDeviceBlocked: deviceTokenModel.isDeviceBlocked,
  blockDevice: deviceTokenModel.blockDevice,
  unblockDevice: deviceTokenModel.unblockDevice,
  listBlockedDevices: deviceTokenModel.listBlockedDevices,
  kvGet: deviceTokenModel.kvGet,
  kvSet: deviceTokenModel.kvSet,
  wipeUserData: deviceTokenModel.wipeUserData,
  // IAP
  saveIapReceipt: iapModel.saveIapReceipt,
  listActiveIapForDevice: iapModel.listActiveIapForDevice,
  setIapStatus: iapModel.setIapStatus,
  // events
  recordEvent: eventsModel.recordEvent,
  recordEventsBulk: eventsModel.recordEventsBulk,
  listEvents: eventsModel.listEvents,
  eventTopList: eventsModel.eventTopList,
  eventDailyDau: eventsModel.eventDailyDau,
  eventFunnel: eventsModel.eventFunnel,
  eventOverview: eventsModel.eventOverview,
  eventRetentionMatrix: eventsModel.eventRetentionMatrix,
  // promo
  listPromoCodes: promoModel.listPromoCodes,
  createPromoCode: promoModel.createPromoCode,
  updatePromoCode: promoModel.updatePromoCode,
  deletePromoCode: promoModel.deletePromoCode,
  recordPromoAttempt: promoModel.recordPromoAttempt,
  recordPromoUsage: promoModel.recordPromoUsage,
  promoCodeStats: promoModel.promoCodeStats,
  promoOverview: promoModel.promoOverview,
  promoFraudDetection: promoModel.promoFraudDetection,
  // redeem
  createRedeemCodes: redeemModel.createRedeemCodes,
  redeemCode: redeemModel.redeemCode,
  listRedeemCodes: redeemModel.listRedeemCodes,
  revokeRedeemBatch: redeemModel.revokeRedeemBatch,
  // alerts
  listAlertRules: alertsModel.listAlertRules,
  upsertAlertRule: alertsModel.upsertAlertRule,
  deleteAlertRule: alertsModel.deleteAlertRule,
  markAlertFired: alertsModel.markAlertFired,
  // app version / announcements
  getAppVersion: appVersionModel.getAppVersion,
  saveAppVersion: appVersionModel.saveAppVersion,
  listActiveAnnouncements: appVersionModel.listActiveAnnouncements,
  listAllAnnouncements: appVersionModel.listAllAnnouncements,
  upsertAnnouncement: appVersionModel.upsertAnnouncement,
  deleteAnnouncement: appVersionModel.deleteAnnouncement,
  // cleanup
  cleanupOldData,
  // raw db instance
  __db: db,
};
