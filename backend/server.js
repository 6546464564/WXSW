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
const multer = require('multer');
const db = require('./db');
const validator = require('./sourceValidator');
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
const qidianMirror = require('./jobs/qidianMirror');
const bookDownloader = require('./jobs/bookDownloader');
const qimaoUpdater = require('./jobs/qimaoUpdater');

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
setInterval(() => db.cleanupOldData(), 30 * 60 * 1000).unref?.();

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
if (DEVICE_TOKEN_SECRET.startsWith('dev-only-')) {
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
    checks.db = { ok: false, error: e.message };
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
app.get('/metrics', (req, res) => {
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
  if (extra.min_os) resp.min_os = extra.min_os;
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
let breakerCache = { computedAt: 0, broken: [] };
const BREAKER_SUPPRESS_KV_KEY = 'breaker_suppress_until';
let breakerSuppressUntil = (() => {
  const v = parseInt(db.kvGet(BREAKER_SUPPRESS_KV_KEY), 10);
  return Number.isFinite(v) && v > Date.now() ? v : 0;
})();

function refreshBreakerIfStale() {
  const now = Date.now();
  if (now < breakerSuppressUntil) {
    breakerCache = { computedAt: now, broken: [] };
    return;
  }
  if (now - breakerCache.computedAt < 5 * 60_000) return;
  try {
    breakerCache = {
      computedAt: now,
      broken: db.adProvidersToBreak({
        windowHours: 6, minSamples: 10, errorThreshold: 0.6,
        perPlacementMinSamples: { rewardedReadingUnlock: 3, chapterUnlock: 3 }
      }),
    };
    if (breakerCache.broken.length) logger.warn('circuit breaker tripped', { broken: breakerCache.broken });
  } catch (e) {
    logger.error('breaker compute failed', { msg: e.message });
  }
}

function applyBreaker(config) {
  refreshBreakerIfStale();
  if (!breakerCache.broken.length) return config;
  const cloned = JSON.parse(JSON.stringify(config));
  for (const b of breakerCache.broken) {
    const p = cloned.placements && cloned.placements[b.placement];
    if (!p || !Array.isArray(p.providers)) continue;
    for (const slot of p.providers) {
      if (slot.name === b.provider) slot.weight = 0;
    }
  }
  if (cloned.placements) {
    for (const [, p] of Object.entries(cloned.placements)) {
      if (!p || !Array.isArray(p.providers) || !p.enabled) continue;
      const totalWeight = p.providers.reduce((s, x) => s + (x.weight || 0), 0);
      if (totalWeight <= 0) p.enabled = false;
    }
  }
  return cloned;
}

app.get('/api/ad-config', rateLimitAdConfig, (req, res) => {
  const deviceId = req.get('X-Device-Id') || req.query.device_id;
  const row = db.getAdConfig(deviceId, req.platform);
  res.set('Cache-Control', 'public, max-age=300');
  if (row.isStaging) res.set('X-Rollout-Bucket', 'staging');
  refreshBreakerIfStale();
  const breakerKey = breakerCache.broken.length
    ? '-b' + crypto.createHash('md5').update(JSON.stringify(breakerCache.broken)).digest('hex').slice(0, 6)
    : '';
  const effectiveEtag = row.etag + breakerKey;
  res.set('ETag', effectiveEtag);
  if (req.get('If-None-Match') === effectiveEtag) return res.status(304).end();
  if (breakerCache.broken.length) {
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
  const ok = db.recordPromoUsage({ code, agentName: agent_name, deviceId: device_id, deviceModel: device_model, systemVersion: system_version, ip: req.ip });
  res.json({ ok });
});

// ═══════════════════ 管理 API ═══════════════════

// --- 登录/登出 ---
app.post('/api/admin/login', loginRateLimit, async (req, res) => {
  const { username, password, totp } = req.body || {};
  const pwd = password;
  if (username) {
    const lock = db.isAccountLocked(username, { windowMin: 5, threshold: 5, lockMin: 30 });
    if (lock.locked) {
      const left = Math.ceil((lock.unlock_at - Date.now()) / 60_000);
      logger.warn('admin login locked', { t: req.traceId, username, ip: req.ip, unlock_in_min: left });
      return res.status(423).json({ ok: false, msg: `account locked due to too many failures, try again in ${left} minutes`, unlock_at: lock.unlock_at });
    }
    const user = await db.verifyAdminUser(username, pwd);
    if (!user) {
      recordLoginResult(res, false);
      db.recordLoginFailure(username, req.ip);
      return res.status(401).json({ ok: false, msg: 'wrong username or password' });
    }
    if (user.totp_enabled) {
      if (!totp) return res.status(401).json({ ok: false, msg: 'totp required', need_totp: true });
      if (!totpVerify(totp, user.totp_secret)) {
        recordLoginResult(res, false);
        db.recordLoginFailure(username, req.ip);
        return res.status(401).json({ ok: false, msg: 'wrong totp code' });
      }
    }
    recordLoginResult(res, true);
    db.clearLoginFailures(username);
    db.recordAdminLogin(username, req.ip);
    const token = db.createSession(req.ip || '', req.get('User-Agent') || '', { username, role: user.role });
    res.cookie('adm', token, { httpOnly: true, sameSite: 'strict', maxAge: 7 * 86400 * 1000, secure: !!process.env.SECURE_COOKIE });
    return res.json({ ok: true, role: user.role });
  }
  const ok = await db.verifyAdminPassword(pwd);
  if (!ok) { recordLoginResult(res, false); return res.status(401).json({ ok: false, msg: 'wrong password' }); }
  recordLoginResult(res, true);
  const token = db.createSession(req.ip || '', req.get('User-Agent') || '');
  res.cookie('adm', token, { httpOnly: true, sameSite: 'strict', maxAge: 7 * 86400 * 1000, secure: !!process.env.SECURE_COOKIE });
  res.json({ ok: true, role: 'super' });
});

app.post('/api/admin/logout', requireAdmin, (req, res) => {
  db.destroySession(req.cookies.adm);
  res.clearCookie('adm');
  res.json({ ok: true });
});

app.post('/api/admin/password', loginRateLimit, requireAdmin, async (req, res) => {
  const { oldPassword, newPassword } = req.body || {};
  const ok = await db.verifyAdminPassword(oldPassword);
  if (!ok) { recordLoginResult(res, false); return res.status(401).json({ ok: false, msg: 'wrong old password' }); }
  recordLoginResult(res, true);
  if (!newPassword || newPassword.length < 8) return res.status(400).json({ ok: false, msg: 'new password must be >= 8 chars' });
  if (newPassword === oldPassword) return res.status(400).json({ ok: false, msg: 'new password must differ from old' });
  await db.setAdminPassword(newPassword);
  db.destroyAllSessions();
  res.clearCookie('adm');
  res.json({ ok: true });
});

app.get('/api/admin/me', (req, res) => {
  const tok = req.cookies && req.cookies.adm;
  res.json({ ok: db.isValidSession(tok, req.get('User-Agent') || '') });
});

// --- admin 应用配置 ---
app.get('/api/admin/app-extra', requireAdmin, (req, res) => {
  res.json(db.getExtraConfig());
});
app.post('/api/admin/app-extra', requireAdmin, (req, res) => {
  const { min_os } = req.body || {};
  const cur = db.getExtraConfig();
  if (min_os !== undefined) cur.min_os = String(min_os || '');
  db.saveExtraConfig(cur);
  res.json({ ok: true });
});

// --- admin 书源管理 ---
app.get('/api/admin/sources', requireAdmin, (req, res) => res.json(db.listAllSources()));
app.get('/api/admin/sources/raw', requireAdmin, (req, res) => {
  const row = db.getSource(req.query.url);
  if (!row) return res.status(404).json({ ok: false });
  res.set('Content-Type', 'application/json'); res.send(row.json);
});
app.post('/api/admin/sources', largeJson, requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    if (Array.isArray(req.body)) {
      const r = db.bulkUpsert(req.body);
      return res.json({ ok: true, ...r });
    }
    if (req.body && typeof req.body === 'object') {
      const r = db.upsertSource(req.body);
      return res.json({ ok: true, ...r });
    }
    return res.status(400).json({ ok: false, msg: 'JSON object or array expected' });
  } catch (err) {
    return res.status(400).json({ ok: false, msg: err.message || 'invalid book source' });
  }
});
app.delete('/api/admin/sources', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const url = req.query.url;
  if (!url) return res.status(400).json({ ok: false });
  const n = db.deleteSource(url);
  res.json({ ok: true, deleted: n });
});
app.post('/api/admin/sources/check', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    const r = db.runSourceStaticCheck({ platform: req.body?.platform || req.query.platform || 'ios', sampleKeyword: req.body?.sampleKeyword || req.query.sampleKeyword || '斗破苍穹', url: req.body?.url || req.query.url || null });
    const { ok: okCount, error: errorCount, ...rest } = r;
    res.json({ ok: true, okCount, errorCount, ...rest });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message || 'check failed' }); }
});
app.patch('/api/admin/sources/enabled', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { url, enabled } = req.body || {};
  if (!url) return res.status(400).json({ ok: false });
  db.setEnabled(url, !!enabled);
  res.json({ ok: true });
});
app.patch('/api/admin/sources/platforms', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { url, platforms } = req.body || {};
  if (!url) return res.status(400).json({ ok: false, msg: 'url required' });
  if (!Array.isArray(platforms)) return res.status(400).json({ ok: false, msg: 'platforms must be an array' });
  try {
    const n = db.setSourcePlatforms(url, platforms);
    if (n === 0) return res.status(404).json({ ok: false, msg: 'source not found' });
    res.json({ ok: true, changed: n });
  } catch (err) { res.status(400).json({ ok: false, msg: err.message || 'invalid' }); }
});
app.patch('/api/admin/sources/platforms/bulk', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { urls, platform, op } = req.body || {};
  if (!Array.isArray(urls) || urls.length === 0) return res.status(400).json({ ok: false, msg: 'urls required' });
  if (!['android', 'ios', 'web'].includes(platform)) return res.status(400).json({ ok: false, msg: 'platform invalid' });
  if (!['add', 'remove'].includes(op)) return res.status(400).json({ ok: false, msg: 'op must be add|remove' });
  let changed = 0;
  for (const url of urls) {
    const row = db.getSource(url);
    if (!row) continue;
    const cur = String(row.platforms || '').split(',').map(s => s.trim()).filter(Boolean);
    let next;
    if (op === 'add') { if (cur.includes(platform)) continue; next = [...cur, platform]; }
    else { if (!cur.includes(platform)) continue; next = cur.filter(p => p !== platform); }
    db.setSourcePlatforms(url, next);
    changed++;
  }
  res.json({ ok: true, changed });
});
app.patch('/api/admin/sources/group-enabled', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { group, enabled } = req.body || {};
  if (typeof group !== 'string') return res.status(400).json({ ok: false, msg: 'group required' });
  const rows = db.__db.prepare('SELECT url, json FROM book_sources').all();
  let affected = 0;
  const tx = db.__db.transaction(() => {
    for (const r of rows) {
      try {
        const src = JSON.parse(r.json);
        const tokens = String(src.bookSourceGroup || '').split(/[,;，；]/).map(s => s.trim());
        if (!tokens.includes(group)) continue;
        db.__db.prepare('UPDATE book_sources SET enabled=?, updated_at=? WHERE url=?').run(enabled ? 1 : 0, Date.now(), r.url);
        affected++;
      } catch {}
    }
  });
  tx();
  db.invalidateSourcesCache();
  res.json({ ok: true, affected });
});
app.get('/api/admin/sources/groups', requireAdmin, (req, res) => {
  const rows = db.__db.prepare('SELECT json FROM book_sources').all();
  const set = new Set();
  for (const r of rows) {
    try { for (const g of String(JSON.parse(r.json).bookSourceGroup || '').split(/[,;，；]/)) { const t = g.trim(); if (t) set.add(t); } } catch {}
  }
  res.json({ ok: true, groups: [...set].sort() });
});
app.get('/api/admin/sources/export', requireAdmin, (req, res) => {
  const rows = db.__db.prepare('SELECT json FROM book_sources ORDER BY updated_at DESC').all();
  const body = '[' + rows.map(r => r.json).join(',') + ']';
  const fname = `wanxiang-sources-${new Date().toISOString().slice(0,10)}.json`;
  res.set('Content-Type', 'application/json; charset=utf-8');
  res.set('Content-Disposition', `attachment; filename="${fname}"`);
  res.send(body);
});
app.get('/api/admin/sources/validate', requireAdmin, async (req, res) => {
  const url = req.query.url;
  if (!url) return res.status(400).json({ ok: false, msg: 'url required' });
  const row = db.getSource(url);
  if (!row) return res.status(404).json({ ok: false, msg: 'source not found' });
  try {
    const src = JSON.parse(row.json);
    const result = await validator.validateOne(src, { checkReach: true, checkSearch: String(req.query.search || '') === '1', timeoutMs: 6000 });
    res.json({ ok: true, result });
  } catch (e) { res.status(500).json({ ok: false, msg: e.message }); }
});
app.get('/api/admin/sources/validate-all', requireAdmin, async (req, res) => {
  const checkSearch = String(req.query.search || '') === '1';
  const list = db.listAllSources();
  const sources = list.map(meta => { const row = db.getSource(meta.url); try { return JSON.parse(row.json); } catch { return { bookSourceUrl: meta.url, bookSourceName: meta.name }; } });
  try {
    const summary = await validator.validateAll(sources, { concurrency: 8, checkReach: true, checkSearch, timeoutMs: 6000 });
    res.json({ ok: true, ...summary });
  } catch (e) { res.status(500).json({ ok: false, msg: e.message }); }
});

// --- admin 统计 ---
app.get('/api/admin/stats', requireAdmin, (req, res) => {
  const days = parseInt(req.query.days, 10) || 7;
  res.json({ online: db.statsOnline(), today: db.statsToday(), week: db.statsWeek(), month: db.statsMonth(), daily: db.statsDailyCurve(days) });
});

// --- admin 书城 mirror ---
app.get('/api/admin/bookstore-mirror/status', requireAdmin, (req, res) => {
  const latest = db.getLatestBookstoreMirror();
  const recent = db.listRecentBookstoreMirror(3);
  res.json({
    latest: latest ? { version: latest.version, fetched_at: latest.fetched_at, etag: latest.etag, source: latest.source, payload_size: latest.payload?.length || 0 } : null,
    nextScheduledAt: getNextRunAt() || null,
    recent: recent.map(r => ({ id: r.id, version: r.version, fetched_at: r.fetched_at, ok: r.ok === 1, err_msg: r.err_msg, payload_size: r.payload_size, source: r.source })),
  });
});
app.post('/api/admin/bookstore-mirror/refresh', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
  try { const result = await qidianMirror.fetchAndCache(db); logger.info('mirror manual refresh ok', result); res.json({ ok: true, ...result }); }
  catch (e) { qidianMirror.recordFailure(db, e); logger.warn('mirror manual refresh failed', { msg: e.message }); res.status(500).json({ ok: false, msg: e.message }); }
});
/** 万象书屋: 从可信 admin 客户端上传完整 mirror JSON (含 ranksFemale). SSH 不可达时的备用发布路径. */
app.post('/api/admin/bookstore-mirror/publish', requireAdmin, requireRole(['super', 'operator']), largeJson, (req, res) => {
  const payload = req.body;
  if (!payload || typeof payload !== 'object' || !payload.ranks) {
    return res.status(400).json({ ok: false, msg: 'body must be mirror payload with ranks' });
  }
  const validation = qidianMirror.validateMirrorPayload(payload);
  if (!validation.ok) {
    return res.status(400).json({ ok: false, msg: 'mirror validation failed', errors: validation.errors });
  }
  const payloadStr = JSON.stringify(payload);
  const etag = crypto.createHash('md5').update(payloadStr).digest('hex');
  const totalBooks = Object.values(payload.ranks).reduce((s, l) => s + (l?.length || 0), 0)
    + (payload.yuepiaoTop50?.length || 0)
    + Object.values(payload.finish || {}).reduce((s, l) => s + (l?.length || 0), 0)
    + (payload.ranksFemale
      ? Object.values(payload.ranksFemale).reduce((s, l) => s + (l?.length || 0), 0)
      : 0)
    + (payload.yuepiaoTop50Female?.length || 0)
    + (payload.ranksPublish
      ? Object.values(payload.ranksPublish).reduce((s, l) => s + (l?.length || 0), 0)
      : 0)
    + (payload.yuepiaoTop50Publish?.length || 0);
  db.insertBookstoreMirror({
    version: payload.version || Date.now(),
    payload: payloadStr,
    etag,
    fetched_at: Date.now(),
    source: payload.source || 'admin-publish',
    ok: 1,
    err_msg: null,
  });
  db.cleanupOldBookstoreMirror(3);
  logger.info('mirror admin publish ok', { totalBooks, etag, hasFemale: !!payload.ranksFemale });
  res.json({ ok: true, totalBooks, etag, version: payload.version || Date.now(), hasFemale: !!payload.ranksFemale });
});
app.get('/api/admin/bookstore-mirror/preview', requireAdmin, (req, res) => {
  const row = db.getLatestBookstoreMirror();
  res.set('Content-Type', 'application/json; charset=utf-8'); res.send(row?.payload || '{}');
});

// --- admin 广告配置 ---
app.get('/api/admin/ad-config', requireAdmin, (req, res) => {
  const row = db.getAdConfigRaw();
  res.json({ version: row.version, etag: row.etag, config: JSON.parse(row.json) });
});
app.post('/api/admin/ad-config', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    if (!req.body || typeof req.body !== 'object') return res.status(400).json({ ok: false, msg: 'JSON object expected' });
    const r = db.saveAdConfig(req.body);
    res.json({ ok: true, ...r });
  } catch (err) { res.status(400).json({ ok: false, msg: err.message || 'invalid ad config' }); }
});
app.get('/api/admin/ad-config/history', requireAdmin, (req, res) => res.json(db.listAdConfigHistory(30)));
app.get('/api/admin/ad-config/version/:v', requireAdmin, (req, res) => {
  const v = parseInt(req.params.v, 10);
  if (!Number.isFinite(v)) return res.status(400).json({ ok: false });
  const row = db.getAdConfigByVersion(v);
  if (!row) return res.status(404).json({ ok: false });
  res.json({ version: row.version, createdAt: row.created_at, config: JSON.parse(row.json) });
});
app.put('/api/admin/ad-config/staging', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try { const { config, rolloutPct } = req.body || {}; db.setAdConfigStaging(config, rolloutPct); res.json({ ok: true }); }
  catch (e) { res.status(400).json({ ok: false, error: e.message }); }
});
app.post('/api/admin/ad-config/staging/commit', requireAdmin, requireRole(['super']), (req, res) => {
  try { db.commitAdConfigStaging(); res.json({ ok: true }); }
  catch (e) { res.status(400).json({ ok: false, error: e.message }); }
});
app.post('/api/admin/ad-config/staging/abort', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  db.abortAdConfigStaging(); res.json({ ok: true });
});
app.get('/api/admin/ad-funnel', requireAdmin, (req, res) => {
  const hours = Math.max(1, Math.min(24 * 30, parseInt(req.query.hours, 10) || 24));
  res.json({ ok: true, hours, funnel: db.adEventFunnel({ hours }), breaker: breakerCache });
});
app.post('/api/admin/breaker/reset', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const minutes = Math.max(1, Math.min(360, parseInt(req.query.minutes, 10) || 30));
  const before = breakerCache.broken.slice();
  breakerSuppressUntil = Date.now() + minutes * 60_000;
  db.kvSet(BREAKER_SUPPRESS_KV_KEY, breakerSuppressUntil);
  breakerCache = { computedAt: Date.now(), broken: [] };
  res.json({ ok: true, previouslyBroken: before, suppressMinutes: minutes, suppressUntil: breakerSuppressUntil, msg: `breaker suppressed for ${minutes} minutes` });
});
app.post('/api/admin/backup/now', requireAdmin, requireRole(['super']), async (req, res) => {
  try { await backupCtl.runBackupOnce(); res.json({ ok: true, msg: 'backup triggered' }); }
  catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});


// --- admin 反馈 ---
app.get('/api/admin/feedback', requireAdmin, (req, res) => {
  const status = req.query.status || null;
  const limit = Math.max(10, Math.min(500, parseInt(req.query.limit, 10) || 200));
  res.json({ ok: true, list: db.listFeedback({ status, limit }), stats: db.feedbackStats() });
});
app.patch('/api/admin/feedback/:id', requireAdmin, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const { status, reply } = req.body || {};
  if (!id) return res.status(400).json({ ok: false, msg: 'invalid id' });
  try { db.updateFeedbackStatus(id, status, reply); res.json({ ok: true }); }
  catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});

// --- admin 公告 ---
app.get('/api/admin/announcements', requireAdmin, (req, res) => res.json({ ok: true, list: db.listAllAnnouncements() }));
app.post('/api/admin/announcement', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try { const id = db.upsertAnnouncement(req.body || {}); res.json({ ok: true, id }); }
  catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});
app.delete('/api/admin/announcement/:id', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  db.deleteAnnouncement(req.params.id); res.json({ ok: true });
});

// --- admin 推广代理码 ---
app.get('/api/admin/promo/codes', requireAdmin, (req, res) => res.json({ ok: true, list: db.listPromoCodes() }));
app.post('/api/admin/promo/codes', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    const { code, agentName, maxUses, singleDevice, expiresAt } = req.body || {};
    const result = db.createPromoCode({ code, agentName, maxUses, singleDevice, expiresAt, creator: req.admin.username });
    res.json({ ok: true, ...result });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});
app.put('/api/admin/promo/codes/:code', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const ok = db.updatePromoCode(req.params.code, req.body || {});
  if (ok)
  res.json({ ok });
});
app.delete('/api/admin/promo/codes/:code', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const ok = db.deletePromoCode(req.params.code);
  if (ok)
  res.json({ ok });
});
app.get('/api/admin/promo/stats', requireAdmin, (req, res) => res.json({ ok: true, ...db.promoOverview() }));
app.get('/api/admin/promo/stats/:code', requireAdmin, (req, res) => res.json({ ok: true, ...db.promoCodeStats(req.params.code) }));
app.get('/api/admin/promo/fraud', requireAdmin, (req, res) => res.json({ ok: true, alerts: db.promoFraudDetection() }));

// --- 审核模式 ---
app.get('/api/admin/review-mode', requireAdmin, (req, res) => {
  res.json({ ok: true, enabled: db.kvGet('review_mode') === '1' });
});
app.post('/api/admin/review-mode', requireAdmin, requireRole(['super']), (req, res) => {
  const enabled = !!req.body.enabled;
  db.kvSet('review_mode', enabled ? '1' : '0');
  logger.warn({ m: 'review_mode_toggled', enabled, by: req.adminUser });
  res.json({ ok: true, enabled });
});

// --- admin 代搜配置 ---
const legadoEngine = require('./jobs/legadoEngine');

function initProxyFromDb() {
  const saved = db.kvGet('proxy_url');
  if (saved) {
    legadoEngine.setProxyUrl(saved);
    logger.info('proxy loaded from db', { url: saved.replace(/:([^@:]+)@/, ':***@') });
  }
}
initProxyFromDb();

app.get('/api/admin/proxy-search/config', requireAdmin, (req, res) => {
  const raw = db.kvGet('proxy_url') || '';
  const masked = raw ? raw.replace(/:([^@:]+)@/, ':***@') : '';
  const cacheStats = require('./jobs/proxySearch').searchCache;
  res.json({
    ok: true,
    proxyUrl: masked,
    hasProxy: !!raw,
    cacheSize: cacheStats.size,
    envProxy: process.env.PROXY_URL ? process.env.PROXY_URL.replace(/:([^@:]+)@/, ':***@') : null,
  });
});

app.post('/api/admin/proxy-search/config', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { host, port, username, password } = req.body || {};
  if (!host || !port) {
    db.kvSet('proxy_url', '');
    legadoEngine.setProxyUrl(null);
    return res.json({ ok: true, msg: '代理已清除' });
  }
  const proxyUrl = username && password
    ? `http://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${host}:${port}`
    : `http://${host}:${port}`;
  db.kvSet('proxy_url', proxyUrl);
  legadoEngine.setProxyUrl(proxyUrl);
  logger.info('proxy config updated', { url: proxyUrl.replace(/:([^@:]+)@/, ':***@') });
  res.json({ ok: true, msg: '代理已配置' });
});

app.post('/api/admin/proxy-search/test', requireAdmin, async (req, res) => {
  try {
    const resp = await legadoEngine.httpGet('https://httpbin.org/ip', { timeout: 10000 });
    const ip = JSON.parse(resp);
    res.json({ ok: true, ip: ip.origin || 'unknown', raw: resp.slice(0, 200) });
  } catch (e) {
    res.json({ ok: false, msg: e.message });
  }
});

app.post('/api/admin/proxy-search/test-search', requireAdmin, async (req, res) => {
  const keyword = (req.body.keyword || '斗破苍穹').trim();
  try {
    const proxySearchModule = require('./jobs/proxySearch');
    const sources = db.listEnabledSourcesJson('ios')
      .filter(s => s.searchUrl && s.bookSourceUrl !== (process.env.PUBLIC_URL || 'https://www.wxsw.app'));
    const result = await proxySearchModule.proxySearch(sources, keyword);
    res.json({ ok: true, count: result.books.length, fromCache: result.fromCache, sourceCount: result.sourceCount, books: result.books.slice(0, 20) });
  } catch (e) {
    res.json({ ok: false, msg: e.message });
  }
});

app.post('/api/admin/proxy-search/clear-cache', requireAdmin, (req, res) => {
  const proxySearchModule = require('./jobs/proxySearch');
  const size = proxySearchModule.searchCache.size;
  proxySearchModule.searchCache.clear();
  res.json({ ok: true, msg: `已清除 ${size} 条缓存` });
});

// ═══════════════════ 服务端代搜 API ═══════════════════

const proxySearch = require('./jobs/proxySearch');

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

// --- Admin: 缓存统计 ---
app.get('/api/admin/cache/stats', requireAdmin, (req, res) => {
  const stats = db.getCacheStats();
  res.json({ ok: true, stats });
});

// --- Admin: 列出所有缓存书籍 ---
app.get('/api/admin/cache/books', requireAdmin, (req, res) => {
  const status = req.query.status || null;
  const list = db.listCachedBooks(status);
  res.json({ ok: true, count: list.length, books: list });
});

// --- Admin: 触发下载任务 ---
let _downloadRunning = false;
app.post('/api/admin/cache/download', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
  if (_downloadRunning) return res.status(409).json({ ok: false, msg: 'download already running' });
  const count = parseInt(req.body?.count, 10) || 1;
  _downloadRunning = true;
  res.json({ ok: true, msg: `download started for ${count} book(s)` });
  try {
    await bookDownloader.processLoop(db, count);
  } catch (e) {
    logger.error('cache download failed', { msg: e.message });
  } finally {
    _downloadRunning = false;
  }
});

// --- Admin: 七猫章节更新 ---
let _qimaoUpdateRunning = false;
let _qimaoUpdateProgress = null;

app.post('/api/admin/cache/qimao-update', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
  if (_qimaoUpdateRunning) return res.status(409).json({ ok: false, msg: '更新任务正在运行中', progress: _qimaoUpdateProgress });
  _qimaoUpdateRunning = true;
  _qimaoUpdateProgress = { done: 0, total: 0, updated: 0, upToDate: 0, newChapters: 0, status: 'running' };
  res.json({ ok: true, msg: '七猫章节更新已启动' });
  try {
    const summary = await qimaoUpdater.updateAll(db, logger, p => { _qimaoUpdateProgress = { ...p, status: 'running' }; });
    _qimaoUpdateProgress = { ...summary, status: 'done' };
    logger.info('qimao update complete', summary);
  } catch (e) {
    _qimaoUpdateProgress = { ..._qimaoUpdateProgress, status: 'error', error: e.message };
    logger.error('qimao update failed', { msg: e.message });
  } finally {
    _qimaoUpdateRunning = false;
  }
});

app.get('/api/admin/cache/qimao-update/status', requireAdmin, (req, res) => {
  res.json({ ok: true, running: _qimaoUpdateRunning, progress: _qimaoUpdateProgress });
});

app.post('/api/admin/cache/qimao-import', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
  const { qimaoId, category } = req.body || {};
  if (!qimaoId) return res.status(400).json({ ok: false, msg: 'qimaoId required' });
  try {
    const result = await qimaoUpdater.importBook(db, String(qimaoId), category, logger);
    res.json({ ok: true, ...result });
  } catch (e) {
    res.status(500).json({ ok: false, msg: e.message });
  }
});

// --- Admin: 删除某本书 ---
app.delete('/api/admin/cache/books/:id', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const bookId = parseInt(req.params.id, 10);
  if (!bookId) return res.status(400).json({ ok: false, msg: 'invalid id' });
  const book = db.getCachedBook(bookId);
  if (!book) return res.status(404).json({ ok: false, msg: 'book not found' });
  db.__db.prepare('DELETE FROM cached_chapters WHERE book_id = ?').run(bookId);
  db.__db.prepare('DELETE FROM cached_books WHERE id = ?').run(bookId);
  logger.info('library book deleted', { bookId, title: book.title });
  res.json({ ok: true, msg: `《${book.title}》已删除` });
});

// --- Admin: 重置某本书状态 ---
app.post('/api/admin/cache/books/:id/reset', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const bookId = parseInt(req.params.id, 10);
  if (!bookId) return res.status(400).json({ ok: false, msg: 'invalid id' });
  const book = db.getCachedBook(bookId);
  if (!book) return res.status(404).json({ ok: false, msg: 'book not found' });
  db.updateCachedBookStatus(bookId, 'pending');
  res.json({ ok: true, msg: `book ${bookId} reset to pending` });
});

// --- Admin: 上传 TXT 书籍到书库 ---
const uploadTxt = multer({ storage: multer.memoryStorage(), limits: { fileSize: 50 * 1024 * 1024 } });

function splitChapters(text) {
  const PATTERNS = [
    /^第[零一二三四五六七八九十百千万〇\d]+[章节回卷]/,
    /^[序终]章/,
    /^楔子/,
    /^番外/,
    /^\d{1,4}[、.:：]\s*.+/,
    /^\d{1,4}\s{2,}\S.+/,
    /^【\d+】/,
    /^Chapter\s+\d+/i,
  ];

  const lines = text.split(/\r?\n/);
  let headerEnd = 0;
  for (let i = 0; i < Math.min(5, lines.length); i++) {
    if (/^书名[：:]/.test(lines[i]) || /^作者[：:]/.test(lines[i]) || lines[i].trim() === '') headerEnd = i + 1;
    else break;
  }

  const chapters = [];
  let current = null;

  for (let i = headerEnd; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    const isTitle = trimmed.length > 0 && PATTERNS.some(p => p.test(trimmed));
    if (isTitle) {
      if (current) chapters.push(current);
      current = { title: trimmed, content: '' };
    } else if (current) {
      current.content += line + '\n';
    } else {
      // 第一章之前的内容暂存，后面作为"前言"
      if (!chapters._preface) chapters._preface = '';
      chapters._preface += line + '\n';
    }
  }
  if (current) chapters.push(current);

  // 第一章前有实质内容时，作为"前言"章节插入开头
  if (chapters._preface) {
    const pre = chapters._preface.trim();
    if (pre.length > 10) {
      chapters.unshift({ title: '前言', content: pre });
    }
  }
  delete chapters._preface;

  for (const ch of chapters) ch.content = ch.content.trim();

  // 合并连续空内容章节（七猫格式：标题出现两次，第一次带副标题但无内容）
  const merged = [];
  for (let i = 0; i < chapters.length; i++) {
    if (chapters[i].content === '' && i + 1 < chapters.length) {
      const longer = chapters[i].title.length >= chapters[i + 1].title.length
        ? chapters[i].title : chapters[i + 1].title;
      chapters[i + 1].title = longer;
    } else {
      merged.push(chapters[i]);
    }
  }
  return merged;
}

function detectEncoding(buffer) {
  if (buffer.length >= 3 && buffer[0] === 0xEF && buffer[1] === 0xBB && buffer[2] === 0xBF) return 'utf-8';
  if (buffer.length >= 2 && buffer[0] === 0xFF && buffer[1] === 0xFE) return 'utf-16le';
  if (buffer.length >= 2 && buffer[0] === 0xFE && buffer[1] === 0xFF) return 'utf-16be';
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(buffer);
    return 'utf-8';
  } catch {
    return 'gbk';
  }
}

app.post('/api/admin/library/upload', requireAdmin, requireRole(['super', 'operator']),
  uploadTxt.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ ok: false, msg: 'missing file' });

  const title = (req.body.title || '').trim();
  const author = (req.body.author || '').trim();
  const category = (req.body.category || '').trim();
  if (!title) return res.status(400).json({ ok: false, msg: 'missing title' });

  const enc = detectEncoding(req.file.buffer);
  let text = new TextDecoder(enc).decode(req.file.buffer);
  if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);

  let chapters = splitChapters(text);
  if (!chapters.length) {
    chapters = [{ title: '全文', content: text.trim() }];
  }

  const now = Date.now();
  const insertBook = db.__db.prepare(`
    INSERT INTO cached_books (title, author, category, total_chapters, cached_chapters, status, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, 'done', ?, ?)
  `);
  const insertChapter = db.__db.prepare(`
    INSERT INTO cached_chapters (book_id, chapter_idx, title, content, word_count, status, created_at)
    VALUES (?, ?, ?, ?, ?, 'done', ?)
  `);

  const tx = db.__db.transaction(() => {
    const r = insertBook.run(title, author, category, chapters.length, chapters.length, now, now);
    const bookId = r.lastInsertRowid;
    for (let i = 0; i < chapters.length; i++) {
      const wc = chapters[i].content.replace(/\s/g, '').length;
      insertChapter.run(bookId, i, chapters[i].title, chapters[i].content, wc, now);
    }
    return { bookId: Number(bookId), chapters: chapters.length };
  });

  try {
    const result = tx();
    logger.info('library upload', { title, author, ...result });
    res.json({ ok: true, msg: `《${title}》已入库`, ...result });
  } catch (e) {
    if (e.message.includes('UNIQUE')) {
      return res.status(409).json({ ok: false, msg: '同名书籍已存在' });
    }
    logger.error('library upload failed', { msg: e.message });
    res.status(500).json({ ok: false, msg: e.message });
  }
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
  res.status(status).json({ ok: false, msg: err.message || 'server error' });
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
