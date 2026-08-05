// 万象书屋后端 - Express 入口
//
// 代码结构:
//   middleware/  — 限速、设备认证、admin 认证
//   models/     — 数据库 CRUD (通过 db.js 重导出)
//   jobs/       — 备份、告警、mirror 调度
//   本文件      — 路由注册 + 启动

const express = require('express');
const cookieParser = require('cookie-parser');
const crypto = require('crypto');
const path = require('path');
const db = require('./db');
const logger = require('./logger');

// middleware
const { makeRateLimit, rateLimitSources, rateLimitPing, rateLimitAdConfig,
        rateLimitAdEvent,
        rateLimitFeedback, rateLimitSourceError } = require('./middleware/rateLimit');
const deviceAuth = require('./middleware/deviceAuth');
const adminAuth = require('./middleware/adminAuth');

// jobs
const { scheduleDailyBackup } = require('./jobs/backup');
const { scheduleMirrorJob, getNextRunAt } = require('./jobs/mirrorScheduler');
const bookDownloader = require('./jobs/bookDownloader');
const legadoEngine = require('./jobs/legadoEngine');
const proxySearch = require('./jobs/proxySearch');

// 初始化有状态中间件
deviceAuth.setup(db);
adminAuth.setup(db);

const { blockBlacklistedDevice, verifyDeviceToken, verifyDeviceTokenStrict } = deviceAuth;
const { loginRateLimit, recordLoginResult, requireAdmin, requireRole } = adminAuth;

const PORT = parseInt(process.env.PORT || '3000', 10);
const app = express();
app.set('trust proxy', 1);
app.set('x-powered-by', false);

// ═══════════════════ 全局中间件 ═══════════════════

// traceId + 请求日志
app.use((req, res, next) => {
  req.traceId = crypto.randomBytes(8).toString('hex');
  res.setHeader('X-Request-Id', req.traceId);
  const start = Date.now();
  res.on('finish', () => {
    const d = Date.now() - start;
    const lvl = d > 500 ? 'warn' : (res.statusCode >= 500 ? 'error' :
                res.statusCode >= 400 ? 'warn' : 'info');
    logger[lvl]('http', {
      t: req.traceId, m: req.method, p: req.path, s: res.statusCode,
      d, ip: req.ip, ua: (req.headers['user-agent'] || '').slice(0, 80),
      pf: req.platform,
    });
  });
  next();
});

// 平台识别
const _ALLOWED_PLATFORMS = new Set(['android', 'ios', 'web']);
app.use((req, res, next) => {
  const raw = (req.get('X-Platform') || '').toLowerCase().trim();
  req.platform = _ALLOWED_PLATFORMS.has(raw) ? raw : 'android';
  next();
});

// 全局 piggyback ETag
app.use('/api/', (req, res, next) => {
  try {
    res.set('X-Sources-Etag', db.getEnabledSourcesEtag(req.platform));
    res.append('Vary', 'X-Platform');
  } catch (_e) {}
  next();
});

// 30 分钟清一次老数据 + 自动重试 not_found 书
setInterval(() => {
  try { db.cleanupOldData(); } catch (e) { logger.error('cleanupOldData failed', { msg: e.message }); }
}, 30 * 60 * 1000).unref?.();

// 每 6 小时自动处理 pending 的书 (含自动重试的)
setInterval(async () => {
  const pending = db.nextPendingBook();
  if (!pending) return;
  logger.info('auto-download: found pending books, starting batch');
  try {
    await bookDownloader.processParallel(db, 10, 2, 4);
  } catch (e) {
    logger.error('auto-download failed', {msg: e.message});
  }
}, 6 * 3600 * 1000).unref?.();

// 启动定时任务
const backupCtl = scheduleDailyBackup(db);

// 访问日志
app.use(logger.httpAccess());

// 安全 / 性能中间件
const helmet = require('helmet');
const compression = require('compression');
const cors = require('cors');

app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: false,
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", 'https://cdn.tailwindcss.com', 'https://cdn.jsdelivr.net', "'unsafe-inline'", "'unsafe-eval'"],
      scriptSrcAttr: ["'unsafe-inline'"],
      styleSrc: ["'self'", "'unsafe-inline'", 'https://cdn.jsdelivr.net'],
      imgSrc: ["'self'", 'data:', 'https:'],
      connectSrc: ["'self'", 'https://cdn.jsdelivr.net'],
      fontSrc: ["'self'", 'data:', 'https://cdn.jsdelivr.net'],
      workerSrc: ["'self'", 'blob:'],
      objectSrc: ["'none'"],
      frameAncestors: ["'none'"],
      baseUri: ["'self'"],
      formAction: ["'self'"]
    }
  },
  hsts: { maxAge: 31536000, includeSubDomains: true, preload: false },
  crossOriginEmbedderPolicy: false,
  crossOriginOpenerPolicy: false,
  crossOriginResourcePolicy: false
}));
app.use(compression({ threshold: 1024 }));
app.use('/api/', cors({ origin: false, credentials: false }));

// body parser (路径级分流)
const largeBodyRoutes = new Set([
  'POST /api/admin/sources',
]);
app.use((req, res, next) => {
  const key = req.method + ' ' + req.path;
  const limit = largeBodyRoutes.has(key) ? '20mb' : '1mb';
  return express.json({ limit })(req, res, next);
});
const largeJson = (req, res, next) => next();
app.use(cookieParser());

// OpenAPI 文档
try {
  const swaggerUi = require('swagger-ui-express');
  const swaggerSpec = require('./swagger');
  app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(swaggerSpec, {
    customSiteTitle: '万象书屋 API',
    swaggerOptions: { docExpansion: 'list' }
  }));
  app.get('/api/docs.json', (req, res) => res.json(swaggerSpec));
} catch (e) {
  console.warn('[swagger] not loaded:', e.message);
}

// TOTP (otplib v13 requires --experimental-require-module on Node 22+)
let _otplib = null;
try { _otplib = require('otplib'); } catch (e) {
  console.error('[TOTP] otplib load failed (likely ESM issue):', e.code || e.message);
  console.error('[TOTP] 2FA will be disabled. Start with: node --experimental-require-module server.js');
}
function totpVerify(token, secret) {
  if (!token || !secret || !_otplib) return false;
  return _otplib.verifySync({ token: String(token), secret, options: { window: 1 } });
}
function totpGenerateSecret() {
  if (!_otplib) throw new Error('otplib not loaded, 2FA unavailable');
  return _otplib.generateSecret();
}
function totpGenerateUri(label, issuer, secret) {
  if (!_otplib) throw new Error('otplib not loaded, 2FA unavailable');
  return _otplib.generateURI({ label, issuer, secret });
}

// 设备 token HMAC
const DEVICE_TOKEN_SECRET = process.env.DEVICE_TOKEN_SECRET ||
  'dev-only-CHANGE-IN-PRODUCTION-please-' + (require('os').hostname());
if (process.env.NODE_ENV === 'production' && DEVICE_TOKEN_SECRET.startsWith('dev-only-')) {
  console.error('[security] FATAL: DEVICE_TOKEN_SECRET must be set in production, refusing to start');
  process.exit(1);
} else if (DEVICE_TOKEN_SECRET.startsWith('dev-only-')) {
  console.warn('[security] DEVICE_TOKEN_SECRET not set, using insecure dev fallback');
}
function computeDeviceTokenHash(deviceId, installTs) {
  return crypto.createHmac('sha256', DEVICE_TOKEN_SECRET)
    .update(`${deviceId}|${installTs}`)
    .digest('hex');
}

// ═══════════════════ 公开 API ═══════════════════

// --- 设备注册 ---
app.post('/api/device/register', makeRateLimit({ windowMs: 60_000, max: 3, keyPrefix: 'reg:' }),
  blockBlacklistedDevice, (req, res) => {
  const did = (req.body && (req.body.device_id || req.body.deviceId));
  if (!did || typeof did !== 'string' || did.length < 8 || did.length > 128) {
    return res.status(400).json({ ok: false, msg: 'invalid device_id' });
  }
  const existing = db.getDeviceTokenHash(did);
  const reissue = req.query.reissue === '1';
  if (existing && !reissue) return res.status(409).json({ ok: false, msg: 'already registered' });
  const installTs = Date.now();
  const tokenHash = computeDeviceTokenHash(did, installTs);
  db.upsertDeviceToken({
    deviceId: did, tokenHash, installTs,
    ua: (req.headers['user-agent'] || '').slice(0, 200), ip: req.ip,
    platform: req.platform,
  });
  res.json({ ok: true, token: tokenHash, install_ts: installTs, platform: req.platform });
});

// --- 健康检查 ---
app.get('/api/health', (req, res) => {
  const checks = {};
  let allOk = true;
  const t0 = Date.now();
  try {
    db.__db.prepare('SELECT 1').get();
    checks.db = { ok: true, latency_ms: Date.now() - t0 };
  } catch (e) {
    checks.db = { ok: false, error: 'db check failed' };
    logger.error('health db check failed', { msg: e.message });
    allOk = false;
  }
  const mem = process.memoryUsage();
  const rssMb = Math.round(mem.rss / 1024 / 1024);
  checks.mem = { ok: rssMb < 500, rss_mb: rssMb, heap_used_mb: Math.round(mem.heapUsed / 1024 / 1024) };
  if (!checks.mem.ok) allOk = false;
  try {
    const fs = require('fs');
    const dataDir = process.env.DB_PATH ? path.dirname(process.env.DB_PATH) : path.join(__dirname, 'data');
    const stat = fs.statfsSync ? fs.statfsSync(dataDir) : null;
    if (stat) {
      const freeMb = Math.round(stat.bsize * stat.bavail / 1024 / 1024);
      checks.disk = { ok: freeMb > 100, free_mb: freeMb };
      if (!checks.disk.ok) allOk = false;
    }
  } catch (_) {}
  checks.uptime_s = Math.round(process.uptime());
  res.status(allOk ? 200 : 503).json({ ok: allOk, checks, now: Date.now() });
});

// --- Prometheus metrics ---
// 保护: 配置 METRICS_TOKEN 则需 Bearer token; 否则仅允许本机访问
app.get('/metrics', (req, res) => {
  const token = process.env.METRICS_TOKEN;
  if (token) {
    const auth = req.get('Authorization') || '';
    if (auth !== `Bearer ${token}`) return res.status(401).json({ ok: false, msg: 'unauthorized' });
  } else {
    const ip = req.ip || '';
    if (!/^127\.|^::1$|^::ffff:127\./.test(ip)) {
      return res.status(403).json({ ok: false, msg: 'metrics only accessible from localhost (set METRICS_TOKEN to allow remote)' });
    }
  }
  const lines = [];
  const mem = process.memoryUsage();
  function metric(name, help, type, value, labels = '') {
    lines.push(`# HELP ${name} ${help}`);
    lines.push(`# TYPE ${name} ${type}`);
    lines.push(`${name}${labels} ${value}`);
  }
  metric('wanxiang_uptime_seconds', 'Process uptime seconds', 'counter', Math.round(process.uptime()));
  metric('wanxiang_memory_rss_bytes', 'Resident set size in bytes', 'gauge', mem.rss);
  metric('wanxiang_memory_heap_used_bytes', 'V8 heap used in bytes', 'gauge', mem.heapUsed);
  try {
    metric('wanxiang_active_devices_today', 'Distinct devices visited today (UTC+8)', 'gauge', Number(db.statsToday()) || 0);
    const hb = db.__db.prepare('SELECT COUNT(*) AS n FROM heartbeats WHERE ts > ?').get(Date.now() - 86400_000).n;
    metric('wanxiang_heartbeats_24h', 'Heartbeats received in last 24h', 'gauge', Number(hb) || 0);
    metric('wanxiang_online_5m', 'Distinct devices with heartbeat in last 5 minutes', 'gauge', Number(db.statsOnline()) || 0);
  } catch (_) {}
  try {
    const sourceCount = db.__db.prepare('SELECT COUNT(*) AS n FROM book_sources WHERE enabled = 1').get();
    metric('wanxiang_book_sources_active', 'Active book sources count', 'gauge', sourceCount.n);
  } catch (_) {}
  try {
    const r = db.__db.prepare("SELECT COUNT(*) AS n FROM feedback WHERE status = 'pending'").get();
    metric('wanxiang_feedback_pending', 'Pending feedback count', 'gauge', r.n);
  } catch (_) {}
  res.set('Content-Type', 'text/plain; version=0.0.4');
  res.send(lines.join('\n') + '\n');
});

// --- 版本检查 + 公告 ---
app.get('/api/version-check', (req, res) => {
  const code = parseInt(req.query.code, 10) || 0;
  const v = db.getAppVersion();
  const extra = db.getExtraConfig();
  const resp = {
    latestCode: v.latest_code, latestName: v.latest_name,
    minRequiredCode: v.min_required_code,
    forceUpgrade: code > 0 && v.min_required_code > 0 && code < v.min_required_code,
    needUpgrade: code > 0 && v.latest_code > 0 && code < v.latest_code,
    changelog: v.changelog || '', apkUrl: v.apk_url || '', marketUrl: v.market_url || ''
  };
  if (extra.min_os && db.kvGet('review_mode') !== '1') resp.min_os = extra.min_os;
  res.json(resp);
});

app.get('/api/announcement', (req, res) => {
  const versionCode = parseInt(req.query.versionCode, 10) || 0;
  const list = db.listActiveAnnouncements(versionCode);
  const etag = '"' + crypto.createHash('md5').update(JSON.stringify(list)).digest('hex').slice(0, 16) + '"';
  res.set('Cache-Control', 'public, max-age=60');
  res.set('ETag', etag);
  if (req.get('If-None-Match') === etag) return res.status(304).end();
  res.json({ ok: true, list });
});

// --- 书源 ---
app.get('/api/sources', rateLimitSources, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const healthyOnly = req.query.healthy === '1' || req.query.healthy === 'true' || req.query.hideBroken === '1';
  const etag = db.getEnabledSourcesEtag(req.platform, { healthyOnly });
  res.set('Cache-Control', 'public, max-age=300');
  res.set('ETag', etag);
  res.vary('X-Platform');
  res.vary('X-Source-Health');
  if (req.get('If-None-Match') === etag) return res.status(304).end();
  res.json(db.listEnabledSourcesJson(req.platform, { healthyOnly }));
});

app.post('/api/source-error', rateLimitSourceError, blockBlacklistedDevice, verifyDeviceTokenStrict, (req, res) => {
  try {
    const r = db.recordSourceErrorEvent({
      ...(req.body || {}),
      deviceId: (req.body && req.body.deviceId) || (req.body && req.body.device_id) || req.get('X-Device-Id'),
      platform: (req.body && req.body.platform) || req.platform
    }, req.ip);
    res.json(r);
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message || 'invalid source error' });
  }
});

// --- 书城 mirror ---
app.get('/api/bookstore/mirror', rateLimitSources, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const row = db.getLatestBookstoreMirror();
  if (!row) return res.status(503).json({ ok: false, msg: 'mirror not ready, fallback to direct fetch' });
  res.set('ETag', row.etag);
  res.set('Cache-Control', 'public, max-age=600');
  res.set('Content-Type', 'application/json; charset=utf-8');
  if (req.get('If-None-Match') === row.etag) return res.status(304).end();
  res.send(row.payload);
});

// --- 心跳 ---
app.post('/api/ping', rateLimitPing, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const deviceId = (req.body && typeof req.body.device_id === 'string' && req.body.device_id) ||
    req.get('X-Device-Id') || null;
  if (!deviceId) return res.status(400).json({ ok: false, msg: 'device_id required' });
  if (deviceId.length > 128) return res.status(400).json({ ok: false, msg: 'device_id too long' });
  db.recordPing(deviceId);
  res.json({ ok: true });
});

// --- 广告配置 + 熔断 ---
const breaker = require('./middleware/breaker');
breaker.setup(db);

function refreshBreakerIfStale() { return breaker.refreshBreakerIfStale(); }
function applyBreaker(config) { return breaker.applyBreaker(config); }

app.get('/api/ad-config', rateLimitAdConfig, (req, res) => {
  const deviceId = req.get('X-Device-Id') || req.query.device_id;
  const row = db.getAdConfig(deviceId, req.platform);
  res.set('Cache-Control', 'public, max-age=300');
  if (row.isStaging) res.set('X-Rollout-Bucket', 'staging');
  refreshBreakerIfStale();
  const breakerKey = breaker.broken.length
    ? '-b' + crypto.createHash('md5').update(JSON.stringify(breaker.broken)).digest('hex').slice(0, 6)
    : '';
  const effectiveEtag = row.etag + breakerKey;
  res.set('ETag', effectiveEtag);
  if (req.get('If-None-Match') === effectiveEtag) return res.status(304).end();
  if (breaker.broken.length) {
    const cfg = applyBreaker(JSON.parse(row.json));
    res.set('Content-Type', 'application/json; charset=utf-8');
    res.send(JSON.stringify({ version: row.version, etag: effectiveEtag, config: cfg }));
  } else {
    res.set('Content-Type', 'application/json; charset=utf-8');
    res.send(`{"version":${row.version},"etag":${JSON.stringify(effectiveEtag)},"config":${row.json}}`);
  }
});

// --- 广告事件上报 ---
app.post('/api/ad-event', rateLimitAdEvent, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const b = req.body || {};
  try {
    db.recordAdEvent({
      placement: b.placement, provider: b.provider, type: b.type,
      errCode: b.errCode, errMsg: b.errMsg, deviceId: b.deviceId,
      appVer: b.appVer, platform: req.platform,
    });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

app.post('/api/ad-events', rateLimitAdEvent, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const arr = Array.isArray(req.body) ? req.body : req.body?.events;
  if (!Array.isArray(arr)) return res.status(400).json({ ok: false, msg: 'array expected' });
  if (arr.length > 50) return res.status(400).json({ ok: false, msg: 'too many events' });
  let ok = 0, bad = 0, firstError = null, firstBadEvent = null;
  for (const e of arr) {
    try {
      db.recordAdEvent({ ...e, platform: req.platform });
      ok++;
    } catch (err) {
      bad++;
      if (!firstError) { firstError = err.message; firstBadEvent = e; }
    }
  }
  if (bad > 0) {
    logger.warn('ad-events batch had rejected items', {
      t: req.traceId, accepted: ok, rejected: bad, total: arr.length,
      firstError, sampleEvent: firstBadEvent ? JSON.stringify(firstBadEvent).slice(0, 200) : null
    });
  }
  res.json({ ok: true, accepted: ok, rejected: bad, total: arr.length });
});


// --- 反馈 ---
app.post('/api/feedback', rateLimitFeedback, blockBlacklistedDevice, verifyDeviceTokenStrict, (req, res) => {
  const b = req.body || {};
  try {
    const r = db.recordFeedback({
      type: b.type, content: b.content, contact: b.contact,
      deviceId: b.deviceId, appVer: b.appVer, ip: req.ip, platform: req.platform,
    });
    res.json({ ok: true, id: r.id });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

// --- IAP ---
const _IAP_PROD_URL = 'https://buy.itunes.apple.com/verifyReceipt';
const _IAP_SANDBOX_URL = 'https://sandbox.itunes.apple.com/verifyReceipt';
const _IAP_RATE = makeRateLimit({ windowMs: 60_000, max: 10, keyPrefix: 'iap:' });

function _mapProductIdToEntitlement(productId) {
  if (!productId) return null;
  if (productId.endsWith('.lifetime') || productId === 'com.wanxiang.adfree.lifetime') return 'lifetime';
  if (productId.includes('adfree') || productId.includes('vip')) return 'vip';
  return null;
}

async function _verifyAppleReceipt(receiptData, sandboxFirst = false) {
  const body = JSON.stringify({
    'receipt-data': receiptData,
    'password': process.env.APPLE_SHARED_SECRET || '',
    'exclude-old-transactions': true,
  });
  const tryUrl = async (url) => {
    const r = await fetch(url, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body, signal: AbortSignal.timeout(10_000),
    });
    return r.json();
  };
  let firstUrl = sandboxFirst ? _IAP_SANDBOX_URL : _IAP_PROD_URL;
  let resp = await tryUrl(firstUrl);
  if (resp.status === 21007 && firstUrl === _IAP_PROD_URL) {
    resp = await tryUrl(_IAP_SANDBOX_URL); resp.__sandbox = true;
  } else if (resp.status === 21008 && firstUrl === _IAP_SANDBOX_URL) {
    resp = await tryUrl(_IAP_PROD_URL);
  } else if (firstUrl === _IAP_SANDBOX_URL) {
    resp.__sandbox = true;
  }
  return resp;
}

// IAP verify 暂未上线, 保留路由占位避免 404 噪音
app.post('/api/iap/verify', _IAP_RATE, blockBlacklistedDevice, verifyDeviceToken, async (req, res) => {
  return res.status(503).json({ ok: false, msg: 'IAP verification not yet enabled' });
});

app.get('/api/iap/entitlements', blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const did = req.get('X-Device-Id') || req.query.device_id;
  if (!did) return res.status(400).json({ ok: false, msg: 'device_id required' });
  const list = db.listActiveIapForDevice(String(did));
  const entitlements = Array.from(new Set(
    list.map(r => _mapProductIdToEntitlement(r.product_id)).filter(Boolean)
  ));
  res.json({
    ok: true, entitlements,
    receipts: list.map(r => ({
      product_id: r.product_id, expires_at: r.expires_at,
      verified_at: r.verified_at, sandbox: !!r.sandbox,
    }))
  });
});

// --- 推广代理码 (客户端) ---
app.get('/api/promo/codes', blockBlacklistedDevice, (req, res) => {
  if (db.kvGet('review_mode') === '1') {
    return res.json({ ok: true, codes: [] });
  }
  const codes = db.listPromoCodes({ enabledOnly: true }).map(c => ({
    code: c.code, agent_name: c.agent_name, max_uses: c.max_uses,
    single_device: c.single_device === 1,
    expires_at: c.expires_at ? new Date(c.expires_at).toISOString() : null,
  }));
  res.json({ ok: true, codes });
});

app.get('/api/promo/agent-stats', (req, res) => {
  const code = (req.query.code || '').trim();
  if (!code) return res.status(400).json({ ok: false, msg: '请输入推广码' });
  const codeRow = db.listPromoCodes().find(c => c.code.toLowerCase() === code.toLowerCase());
  if (!codeRow) return res.json({ ok: false, msg: '推广码不存在' });
  if (!codeRow.enabled) return res.json({ ok: false, msg: '该推广码已停用' });
  const stats = db.promoCodeStats(code);
  const usages = (stats.usages || []).map(u => ({
    device_model: u.device_model || '未知设备', system_version: u.system_version || '', ts: u.ts,
  }));
  res.json({
    ok: true, code: codeRow.code, agentName: codeRow.agent_name,
    totalUses: stats.totalUses, uniqueDevices: stats.uniqueDevices,
    totalAttempts: stats.totalAttempts, usages,
  });
});

app.post('/api/promo/attempt', blockBlacklistedDevice, (req, res) => {
  const { code, success, device_id, device_model } = req.body || {};
  if (!code || !device_id) return res.status(400).json({ ok: false, msg: 'code & device_id required' });
  db.recordPromoAttempt({ code, deviceId: device_id, deviceModel: device_model, success: !!success, ip: req.ip });
  res.json({ ok: true });
});

app.post('/api/promo/usage', blockBlacklistedDevice, (req, res) => {
  const { code, agent_name, device_id, device_model, system_version } = req.body || {};
  if (!code || !device_id) return res.status(400).json({ ok: false, msg: 'code & device_id required' });
  const result = db.recordPromoUsage({ code, agentName: agent_name, deviceId: device_id, deviceModel: device_model, systemVersion: system_version, ip: req.ip });
  if (!result.ok) return res.status(400).json(result);
  res.json({ ok: true });
});

// ═══════════════════ 管理 API (routes/admin.js) ═══════════════════
const createAdminRouter = require('./routes/admin');
app.use('/api/admin', createAdminRouter({
  db, logger, requireAdmin, requireRole, loginRateLimit, recordLoginResult,
  totpVerify, largeJson, backupCtl, getNextRunAt, breaker,
}));

// ═══════════════════ 服务端代搜 API ═══════════════════

app.get('/api/search/proxy', rateLimitSources, async (req, res) => {
  const keyword = (req.query.keyword || req.query.key || '').trim();
  if (!keyword) return res.status(400).json({ ok: false, msg: 'keyword required' });
  if (keyword.length > 100) return res.status(400).json({ ok: false, msg: 'keyword too long' });

  const cacheKey = 'search:' + crypto.createHash('md5').update(keyword).digest('hex');
  const cached = db.proxyCacheGet(cacheKey);
  if (cached) {
    res.set('Cache-Control', 'public, max-age=60');
    res.set('X-Cache', 'HIT');
    return res.type('json').send(cached);
  }

  try {
    const platform = req.platform || 'ios';
    const sources = db.listEnabledSourcesJson(platform)
      .filter(s => s.searchUrl && s.bookSourceUrl !== (process.env.PUBLIC_URL || 'https://www.wxsw.app'));
    const result = await proxySearch.proxySearch(sources, keyword);
    const body = JSON.stringify({
      ok: true,
      count: result.books.length,
      fromCache: result.fromCache,
      sourceCount: result.sourceCount,
      books: result.books,
    });
    db.proxyCacheSet(cacheKey, 'search', body, 3600 * 1000);
    res.set('Cache-Control', 'public, max-age=60');
    res.set('X-Cache', 'MISS');
    res.type('json').send(body);
  } catch (e) {
    logger.error('proxy search failed', { keyword, msg: e.message });
    res.status(500).json({ ok: false, msg: 'search failed' });
  }
});

app.get('/api/search/changesource', rateLimitSources, async (req, res) => {
  const name = (req.query.name || '').trim();
  const author = (req.query.author || '').trim();
  if (!name) return res.status(400).json({ ok: false, msg: 'name required' });
  try {
    const platform = req.platform || 'ios';
    const sources = db.listEnabledSourcesJson(platform)
      .filter(s => s.searchUrl && s.bookSourceUrl !== (process.env.PUBLIC_URL || 'https://www.wxsw.app'));
    const limitParam = parseInt(req.query.limit, 10);
    const opts = limitParam > 0 ? { limit: limitParam } : {};
    const result = await proxySearch.changeSourceSearch(sources, name, author, opts);
    res.set('Cache-Control', 'public, max-age=60');
    res.json({
      ok: true,
      count: result.candidates.length,
      fromCache: result.fromCache,
      sourceCount: result.sourceCount,
      candidates: result.candidates,
    });
  } catch (e) {
    logger.error('changesource search failed', { name, author, msg: e.message });
    res.status(500).json({ ok: false, msg: 'search failed' });
  }
});

// 起点封面查询 (对齐 iOS QidianBook.lookupQidianCover)
app.get('/api/cover', async (req, res) => {
  const name = (req.query.name || '').trim();
  const author = (req.query.author || '').trim();
  if (!name) return res.status(400).json({ ok: false, msg: 'name required' });

  const cacheKey = 'cover:' + crypto.createHash('md5').update(name + '|' + author).digest('hex');
  const cached = db.proxyCacheGet(cacheKey);
  if (cached) {
    res.set('Cache-Control', 'public, max-age=86400');
    return res.type('json').send(cached);
  }

  try {
    const searchTerm = author ? `${name} ${author}` : name;
    const encoded = encodeURIComponent(searchTerm);
    const resp = await fetch(`https://m.qidian.com/soushu/${encoded}`, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
      },
      signal: AbortSignal.timeout(6000),
    });
    if (!resp.ok) throw new Error('qidian ' + resp.status);
    const html = await resp.text();
    const bidMatch = html.match(/"bid"\s*:\s*(\d+)/);
    if (bidMatch) {
      const coverUrl = `https://bookcover.yuewen.com/qdbimg/349573/${bidMatch[1]}/300`;
      const body = JSON.stringify({ ok: true, coverUrl });
      db.proxyCacheSet(cacheKey, 'cover', body, 7 * 86400 * 1000);
      res.set('Cache-Control', 'public, max-age=86400');
      return res.type('json').send(body);
    }
    const body = JSON.stringify({ ok: true, coverUrl: null });
    db.proxyCacheSet(cacheKey, 'cover', body, 86400 * 1000);
    res.json({ ok: true, coverUrl: null });
  } catch (e) {
    res.json({ ok: true, coverUrl: null });
  }
});

app.get('/api/search/toc', rateLimitSources, async (req, res) => {
  const origin = (req.query.origin || '').trim();
  const bookUrl = (req.query.bookUrl || '').trim();
  if (!origin || !bookUrl) return res.status(400).json({ ok: false, msg: 'origin and bookUrl required' });

  const cacheKey = 'toc:' + crypto.createHash('md5').update(origin + '|' + bookUrl).digest('hex');
  const cached = db.proxyCacheGet(cacheKey);
  if (cached) {
    res.set('Cache-Control', 'public, max-age=120');
    res.set('X-Cache', 'HIT');
    return res.type('json').send(cached);
  }

  try {
    const platform = req.platform || 'ios';
    const source = db.listEnabledSourcesJson(platform).find(s => s.bookSourceUrl === origin);
    if (!source) return res.status(404).json({ ok: false, msg: 'source not found' });
    const chapters = await legadoEngine.fetchToc(source, bookUrl);
    const body = JSON.stringify({ ok: true, count: chapters.length, chapters });
    db.proxyCacheSet(cacheKey, 'toc', body, 2 * 3600 * 1000);
    res.set('Cache-Control', 'public, max-age=120');
    res.set('X-Cache', 'MISS');
    res.type('json').send(body);
  } catch (e) {
    logger.error('proxy toc failed', { origin, bookUrl, msg: e.message });
    res.status(500).json({ ok: false, msg: 'toc fetch failed' });
  }
});

app.get('/api/search/content', rateLimitSources, async (req, res) => {
  const origin = (req.query.origin || '').trim();
  const chapterUrl = (req.query.chapterUrl || '').trim();
  if (!origin || !chapterUrl) return res.status(400).json({ ok: false, msg: 'origin and chapterUrl required' });

  const cacheKey = 'cnt:' + crypto.createHash('md5').update(origin + '|' + chapterUrl).digest('hex');
  const cached = db.proxyCacheGet(cacheKey);
  if (cached) {
    res.set('Cache-Control', 'public, max-age=300');
    res.set('X-Cache', 'HIT');
    return res.type('json').send(cached);
  }

  try {
    const platform = req.platform || 'ios';
    const source = db.listEnabledSourcesJson(platform).find(s => s.bookSourceUrl === origin);
    if (!source) return res.status(404).json({ ok: false, msg: 'source not found' });
    const content = await legadoEngine.fetchContent(source, chapterUrl);
    const body = JSON.stringify({ ok: true, content });
    db.proxyCacheSet(cacheKey, 'content', body, 24 * 3600 * 1000);
    res.set('Cache-Control', 'public, max-age=300');
    res.set('X-Cache', 'MISS');
    res.type('json').send(body);
  } catch (e) {
    logger.error('proxy content failed', { origin, chapterUrl, msg: e.message });
    res.status(500).json({ ok: false, msg: 'content fetch failed' });
  }
});

// ═══════════════════ 书籍缓存 API ═══════════════════

// --- 公开: App 搜索书库 ---
app.get('/api/cache/search', rateLimitSources, (req, res) => {
  const keyword = (req.query.keyword || req.query.key || '').trim();
  if (!keyword) return res.status(400).json({ ok: false, msg: 'keyword required' });
  const limit = Math.min(parseInt(req.query.limit, 10) || 20, 50);
  const results = db.searchCachedBooks(keyword, limit).map(b => ({
    id: b.id, qidianId: b.qidian_id, title: b.title, author: b.author,
    category: b.category, coverUrl: b.cover_url, intro: b.intro,
    totalChapters: b.total_chapters, cachedChapters: b.cached_chapters,
  }));
  res.set('Cache-Control', 'public, max-age=60');
  res.json({ ok: true, count: results.length, books: results });
});

// --- 公开: App 获取缓存书籍列表 ---
app.get('/api/cache/books', rateLimitSources, (req, res) => {
  const status = req.query.status || 'done';
  const list = db.listCachedBooks(status).map(b => ({
    id: b.id, qidianId: b.qidian_id, title: b.title, author: b.author,
    category: b.category, coverUrl: b.cover_url, sourceUrl: b.source_url,
    totalChapters: b.total_chapters, cachedChapters: b.cached_chapters,
    status: b.status,
  }));
  res.set('Cache-Control', 'public, max-age=300');
  res.json({ ok: true, count: list.length, books: list });
});

// --- 公开: App 获取某本书的章节列表 ---
app.get('/api/cache/books/:id/chapters', rateLimitSources, (req, res) => {
  const bookId = parseInt(req.params.id, 10);
  if (!bookId) return res.status(400).json({ ok: false, msg: 'invalid id' });
  const book = db.getCachedBook(bookId);
  if (!book) return res.status(404).json({ ok: false, msg: 'book not found' });
  const chapters = db.listCachedChapters(bookId).map(ch => ({
    idx: ch.chapter_idx, title: ch.title, wordCount: ch.word_count, status: ch.status,
  }));
  res.json({ ok: true, bookId, title: book.title, chapters });
});

// --- 公开: App 获取章节内容 ---
app.get('/api/cache/books/:id/chapters/:idx', rateLimitSources, (req, res) => {
  const bookId = parseInt(req.params.id, 10);
  const idx = parseInt(req.params.idx, 10);
  if (!Number.isFinite(bookId) || !Number.isFinite(idx)) {
    return res.status(400).json({ ok: false, msg: 'invalid params' });
  }
  const ch = db.getCachedChapter(bookId, idx);
  if (!ch) return res.status(404).json({ ok: false, msg: 'chapter not found' });
  if (ch.status !== 'done' || !ch.content) {
    return res.status(404).json({ ok: false, msg: 'chapter not cached yet' });
  }
  res.set('Cache-Control', 'public, max-age=86400');
  res.json({ ok: true, bookId, idx, title: ch.title, wordCount: ch.word_count, content: ch.content });
});

// ═══════════════════ 本地书库 API (Legado 书源兼容) ═══════════════════

app.get('/api/library/search', rateLimitSources, (req, res) => {
  const keyword = (req.query.keyword || '').trim();
  if (!keyword) return res.json({ books: [] });
  const rows = db.searchCachedBooks(keyword);
  const books = rows.map(b => ({
    id: b.id,
    title: b.title,
    author: b.author,
    category: b.category,
    coverUrl: b.cover_url || '',
    intro: (b.intro || '').slice(0, 200),
    totalChapters: b.total_chapters,
    bookUrl: `/api/library/toc/${b.id}`,
  }));
  res.json({ books });
});

app.get('/api/library/toc/:id', rateLimitSources, (req, res) => {
  const bookId = parseInt(req.params.id, 10);
  if (!bookId) return res.status(400).json({ chapters: [] });
  const book = db.getCachedBook(bookId);
  if (!book) return res.status(404).json({ chapters: [] });
  const chapters = db.listCachedChapters(bookId)
    .filter(ch => ch.status === 'done')
    .map(ch => ({
      title: ch.title,
      url: `/api/library/content/${bookId}/${ch.chapter_idx}`,
    }));
  res.json({ title: book.title, author: book.author, coverUrl: book.cover_url, chapters });
});

app.get('/api/library/content/:bookId/:idx', rateLimitSources, (req, res) => {
  const bookId = parseInt(req.params.bookId, 10);
  const idx = parseInt(req.params.idx, 10);
  if (!Number.isFinite(bookId) || !Number.isFinite(idx)) {
    return res.status(400).json({ content: '' });
  }
  const row = db.getCachedChapterContent(bookId, idx);
  if (!row || !row.content) return res.status(404).json({ content: '' });
  res.set('Cache-Control', 'public, max-age=86400');
  res.json({ content: row.content });
});

// ═══════════════════ 静态文件 + 兜底 ═══════════════════

app.use(express.static(path.join(__dirname, 'public')));
app.get(['/admin', '/admin/*'], (req, res) => res.sendFile(path.join(__dirname, 'public', 'admin.html')));
app.get('/', (req, res) => res.redirect('/admin'));

// 全局错误处理
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const status = err.status || (err.type === 'entity.parse.failed' ? 400 : 500);
  logger.error('request error', { method: req.method, url: req.url, status, msg: err.message });
  // 对外不泄露内部错误细节（SQL 报错/堆栈等）
  res.status(status).json({ ok: false, msg: status >= 500 ? 'server error' : err.message });
});

// ═══════════════════ 启动 ═══════════════════

let server = null;

function ensureLibrarySource() {
  const LIBRARY_SOURCE_URL = process.env.PUBLIC_URL || 'https://www.wxsw.app';
  const sourceJson = {
    bookSourceUrl: LIBRARY_SOURCE_URL,
    bookSourceName: '万象书库',
    bookSourceGroup: '本地',
    bookSourceType: 0,
    bookSourceComment: '服务端本地书库，收录已缓存的完整书籍，加载速度最快',
    enabled: true,
    enabledExplore: false,
    searchUrl: '/api/library/search?keyword={{key}}',
    ruleSearch: {
      bookList: '$.books',
      name: '$.title',
      author: '$.author',
      coverUrl: '$.coverUrl',
      intro: '$.intro',
      kind: '$.category',
      bookUrl: '$.bookUrl',
    },
    ruleToc: {
      chapterList: '$.chapters',
      chapterName: '$.title',
      chapterUrl: '$.url',
    },
    ruleContent: {
      content: '$.content',
    },
    weight: 100,
  };
  if (!db.getSource(LIBRARY_SOURCE_URL)) {
    db.upsertSource(sourceJson);
    logger.info('library source registered', { url: LIBRARY_SOURCE_URL });
  }
}

function start() {
  ensureLibrarySource();
  server = app.listen(PORT, () => {
    logger.info('backend listening', { port: PORT, admin: `http://0.0.0.0:${PORT}/admin` });
  });
  scheduleMirrorJob(db);
  process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
  process.on('SIGINT', () => gracefulShutdown('SIGINT'));
  return server;
}

function gracefulShutdown(signal) {
  logger.info('shutting down', { signal });
  const forceExitTimer = setTimeout(() => { logger.error('force exit after 10s'); process.exit(1); }, 10_000);
  forceExitTimer.unref();
  if (!server) { try { db.__db.close(); } catch {} return process.exit(0); }
  server.close(err => {
    if (err) { logger.error('http close error', { msg: err.message }); process.exit(1); }
    try { db.__db.close(); } catch (e) { logger.error('db close error', { msg: e.message }); }
    logger.info('shutdown complete');
    process.exit(0);
  });
}

if (require.main === module) { start(); }

module.exports = { app, start, gracefulShutdown };
