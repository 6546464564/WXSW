// 万象书屋后端 - Express 入口
const express = require('express');
const cookieParser = require('cookie-parser');
const crypto = require('crypto');
const path = require('path');
const db = require('./db');
const validator = require('./sourceValidator');
const logger = require('./logger');

const PORT = parseInt(process.env.PORT || '3000', 10);
const app = express();
// nginx/反向代理后面要让 req.ip 拿到真实 IP, 才能给 admin login 限速
app.set('trust proxy', 1);
// JSON 失败提示太详细会泄露内部结构, 只返简短消息
app.set('x-powered-by', false);

// 万象书屋: access log + traceId 中间件 (放最前, 覆盖所有路由).
// 对每个请求:
//   - 生成 8-byte hex traceId, 写到 res.setHeader('X-Request-Id'),
//     log 里所有这次请求的业务日志都带这个 id, 排障可串联
//   - 记录 method/path/status/duration_ms, 出 bug 时一句 grep 就能定位
//   - 不记 body (可能含密码/token), 只记元数据
app.use((req, res, next) => {
  req.traceId = crypto.randomBytes(8).toString('hex');
  res.setHeader('X-Request-Id', req.traceId);
  const start = Date.now();
  res.on('finish', () => {
    const d = Date.now() - start;
    // 慢请求 (>500ms) 用 warn 级别, 方便监控筛
    const lvl = d > 500 ? 'warn' : (res.statusCode >= 500 ? 'error' :
                res.statusCode >= 400 ? 'warn' : 'info');
    logger[lvl]('http', {
      t: req.traceId,
      m: req.method,
      p: req.path,
      s: res.statusCode,
      d,
      ip: req.ip,
      ua: (req.headers['user-agent'] || '').slice(0, 80),
      pf: req.platform,                              // 平台维度 (android/ios/web)
    });
  });
  next();
});

// 万象书屋: 平台识别 (006_multi_platform). 客户端必须发 X-Platform: android / ios / web,
// 老 Android 客户端不发的话默认 android, 完全兼容. 平台值会被各路由透传给 db.recordXxx,
// 入库时可按平台分组统计 / 出 admin 漏斗 / 下发不同 SDK 配置.
const _ALLOWED_PLATFORMS = new Set(['android', 'ios', 'web']);
app.use((req, res, next) => {
  const raw = (req.get('X-Platform') || '').toLowerCase().trim();
  req.platform = _ALLOWED_PLATFORMS.has(raw) ? raw : 'android';
  next();
});

// db.init() 已在 db.js 加载时执行（须在 prepare 语句之前建表）
// 30 分钟清一次老数据 — unref 让单元测试能正常退出
setInterval(() => db.cleanupOldData(), 30 * 60 * 1000).unref?.();

// 万象书屋: 每天 03:00 自动备份 SQLite, 保留 7 天本地 + 可选异地备份 hook.
// better-sqlite3 的 db.backup() 是 SQLite 的 Online Backup API, 不阻塞读写.
//
// 异地备份: 设置 BACKUP_WEBHOOK_URL 环境变量后, 备份完成会 POST 通知该 URL,
// 用户可在自己的脚本里 (如 ops/backup-uploader) 拉取 file 上传到云对象存储 (七牛/COS/S3).
//   POST 请求体: { ok, target, sha256, size, ts }
//   设计动机: 不引第三方 SDK, 解耦云提供商, 灵活给运维.
function scheduleDailyBackup() {
  const fs = require('fs');
  const crypto = require('crypto');
  const pathMod = require('path');
  const dataDir = process.env.DB_PATH
    ? pathMod.dirname(process.env.DB_PATH)
    : pathMod.join(__dirname, 'data');
  const backupDir = pathMod.join(dataDir, 'backup');
  try { fs.mkdirSync(backupDir, { recursive: true }); } catch {}

  const RETENTION_DAYS = parseInt(process.env.BACKUP_RETENTION_DAYS || '7', 10);
  const WEBHOOK = process.env.BACKUP_WEBHOOK_URL || '';

  function msUntilNextRun() {
    const now = new Date();
    const next = new Date(now);
    next.setHours(3, 0, 0, 0);
    if (next <= now) next.setDate(next.getDate() + 1);
    return next - now;
  }

  /** 计算文件 sha256 (流式, 大文件不会爆内存) */
  function fileSha256(filePath) {
    return new Promise((resolve, reject) => {
      const h = crypto.createHash('sha256');
      const s = fs.createReadStream(filePath);
      s.on('data', c => h.update(c));
      s.on('end', () => resolve(h.digest('hex')));
      s.on('error', reject);
    });
  }

  async function runBackupOnce() {
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    const target = pathMod.join(backupDir, `wanxiang-${stamp}.db`);
    const checksumFile = target + '.sha256';
    try {
      await db.__db.backup(target);
      const sha256 = await fileSha256(target);
      const size = fs.statSync(target).size;
      // 写 .sha256 sidecar 用于事后校验完整性
      fs.writeFileSync(checksumFile, `${sha256}  ${pathMod.basename(target)}\n`);
      logger.info('backup ok', { target, sha256: sha256.slice(0, 12), size });

      // 异地备份 webhook 通知
      if (WEBHOOK) {
        try {
          const r = await fetch(WEBHOOK, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ok: true, target, sha256, size, ts: Date.now() }),
            signal: AbortSignal.timeout(10_000)
          });
          logger.info('backup webhook notified', { status: r.status });
        } catch (e) {
          logger.warn('backup webhook failed', { msg: e.message });
        }
      }

      // 清理: 保留最近 RETENTION_DAYS 份 (含 .sha256 sidecar)
      const allFiles = fs.readdirSync(backupDir)
        .filter(f => f.startsWith('wanxiang-') && (f.endsWith('.db') || f.endsWith('.db.sha256')))
        .sort()
        .reverse();
      // 文件名带时间戳, 按时间序倒序后, 保留 RETENTION_DAYS*2 份 (db + sha256 各一)
      for (const f of allFiles.slice(RETENTION_DAYS * 2)) {
        try { fs.unlinkSync(pathMod.join(backupDir, f)); } catch {}
      }
    } catch (e) {
      logger.error('backup failed', { msg: e.message });
    }
  }

  function scheduleNext() {
    const ms = msUntilNextRun();
    setTimeout(async () => {
      await runBackupOnce();
      scheduleNext();
    }, ms).unref?.();
  }
  scheduleNext();
  return { runBackupOnce }; // 暴露给 admin "立刻备份" 接口
}
const backupCtl = scheduleDailyBackup();

// === 万象书屋: 告警检查器, 每 5 分钟扫一次规则 ===
function startAlertScanner() {
  async function scan() {
    let rules = [];
    try { rules = db.listAlertRules(); } catch { return; }
    const now = Date.now();
    for (const r of rules) {
      if (!r.enabled) continue;
      if (r.last_fired_at && now - r.last_fired_at < r.cooldown_min * 60_000) continue;
      try {
        const triggered = await evaluateAlertRule(r);
        if (triggered) {
          await sendAlert(r, triggered);
          db.markAlertFired(r.id);
        }
      } catch (e) {
        logger.warn('alert scan failed', { id: r.id, msg: e.message });
      }
    }
  }
  setInterval(scan, 5 * 60_000).unref?.();
  // 启动 30s 后跑第一次, 让 backend 完全 ready
  setTimeout(scan, 30_000).unref?.();
}

async function evaluateAlertRule(rule) {
  const since = Date.now() - rule.window_min * 60_000;
  switch (rule.kind) {
    case 'crash_burst': {
      // 窗口内崩溃总条数 > threshold
      const c = db.__db.prepare('SELECT COUNT(*) AS c FROM crashes WHERE ts >= ?').get(since).c;
      return c >= rule.threshold ? { metric: 'crashes', value: c } : null;
    }
    case 'ad_error_rate': {
      // 窗口内 (load+error 总数 >= 20) AND (error/(load+error) >= threshold)
      const r = db.__db.prepare(
        `SELECT
            SUM(CASE WHEN type='error' THEN 1 ELSE 0 END) AS errs,
            SUM(CASE WHEN type IN ('load','error') THEN 1 ELSE 0 END) AS total
         FROM ad_events WHERE ts >= ?`
      ).get(since);
      if ((r.total || 0) < 20) return null;
      const rate = r.errs / r.total;
      return rate >= rule.threshold ? { metric: 'errorRate', value: rate, errs: r.errs, total: r.total } : null;
    }
    case 'heartbeat_drop': {
      // 与上一窗口比, 心跳量下降 > threshold (例 0.5 = 跌了 50%)
      const cur = db.__db.prepare('SELECT COUNT(*) AS c FROM heartbeats WHERE ts >= ?').get(since).c;
      const prevSince = since - rule.window_min * 60_000;
      const prev = db.__db.prepare('SELECT COUNT(*) AS c FROM heartbeats WHERE ts >= ? AND ts < ?').get(prevSince, since).c;
      if (prev < 50) return null; // 样本太小不告警
      const drop = (prev - cur) / prev;
      return drop >= rule.threshold ? { metric: 'heartbeatDrop', value: drop, prev, cur } : null;
    }
    default:
      return null;
  }
}

async function sendAlert(rule, info) {
  const msg = `🚨 [万象书屋] ${rule.name}\n` +
    `规则: ${rule.kind} · 阈值 ${rule.threshold} · ${rule.window_min}min 窗口\n` +
    `命中: ${JSON.stringify(info)}\n` +
    `时间: ${new Date().toISOString()}`;
  let body;
  if (rule.webhook_kind === 'wecom') {
    body = JSON.stringify({ msgtype: 'text', text: { content: msg } });
  } else if (rule.webhook_kind === 'dingtalk') {
    body = JSON.stringify({ msgtype: 'text', text: { content: msg } });
  } else {
    body = JSON.stringify({ name: rule.name, kind: rule.kind, info, msg });
  }
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 5000);
    const resp = await fetch(rule.webhook_url, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body, signal: ctrl.signal,
    });
    clearTimeout(timer);
    logger.info('alert fired', { id: rule.id, name: rule.name, status: resp.status });
  } catch (e) {
    logger.warn('alert send failed', { id: rule.id, msg: e.message });
  }
}

startAlertScanner();

// 万象书屋: 访问日志 (排除健康检查避免刷屏)
app.use(logger.httpAccess());

// === 万象书屋: 安全 / 性能中间件 (顺序敏感) ===
const helmet = require('helmet');
const compression = require('compression');
const cors = require('cors');

// helmet: 设置一组安全 HTTP header.
//
// 兼容性注意:
//   admin.html 是手写的 70+ 处 onclick/oninput inline event handlers + 内联 style,
//   还有 cdn.tailwindcss.com (JIT 用 eval) + cdn.jsdelivr.net (echarts).
//   helmet 默认 CSP 太严, 会全部挡掉, 导致后台按钮失效, 图表空白.
//
// 这里手动 useDefaults:false, 只放 directives, 显式放行所需:
//   - scriptSrcAttr 'unsafe-inline': 放行 onclick=... 这类 (admin 大量使用)
//   - upgrade-insecure-requests 显式去掉, 否则本地 HTTP 测试时浏览器会强升 HTTPS 失败
//   - 'unsafe-eval': tailwindcss CDN 的 JIT 编译器要 eval
//
// 生产 (admin 走 HTTPS) 时, 把 admin.html 改用预编译资源, CSP 可以再收紧.
app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: false,
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: [
        "'self'",
        'https://cdn.tailwindcss.com',
        'https://cdn.jsdelivr.net',
        "'unsafe-inline'",
        "'unsafe-eval'"
      ],
      // onclick / oninput / onerror 等 inline handlers (admin.html 70+ 处用到)
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
      // 故意不加 upgrade-insecure-requests: 本地 HTTP 开发会被强升 HTTPS 失败.
      // 生产部署 HTTPS 后, 由 nginx 头来管 HSTS 即可.
    }
  },
  // HSTS: 浏览器记住"必须 HTTPS", 1 年; 部署到 HTTPS 后才生效, HTTP 下浏览器忽略
  hsts: { maxAge: 31536000, includeSubDomains: true, preload: false },
  crossOriginEmbedderPolicy: false,
  crossOriginOpenerPolicy: false,
  crossOriginResourcePolicy: false  // admin tailwindcss CDN 跨域加载
}));

// gzip 压缩响应, 降低带宽 (sources/announcements 大列表节流明显)
// threshold: 1KB 以下不压, 不值得 CPU
app.use(compression({ threshold: 1024 }));

// CORS: 公开 API 默认拒绝跨域 (App 不走浏览器, 不需 CORS)
// admin API 也只能从 admin.html 同源访问. 想要跨域调用的人请自己在 nginx 加 origin allowlist.
app.use('/api/', cors({ origin: false, credentials: false }));

// 万象书屋: 默认 1mb 防匿名刷内存; 个别需要大 body 的 admin 接口走 20mb.
// 注: Express body-parser 是"先到先得", 一旦全局 1mb 这个 middleware 把 body 解析失败
// 就 next(err) 给错误处理器, 后挂的路由级 largeJson 永远不会被触发. 因此必须在
// 同一个 use 钩子里按路径分流, 而不是全局 1mb + 路由级 20mb 的顺序叠放.
const largeBodyRoutes = new Set([
  'POST /api/admin/sources',          // 导入/批量更新书源 (整包可能几 MB)
  'POST /api/admin/bookstore-feed',   // 书城板块批量配置
]);
app.use((req, res, next) => {
  const key = req.method + ' ' + req.path;
  const limit = largeBodyRoutes.has(key) ? '20mb' : '1mb';
  return express.json({ limit })(req, res, next);
});
// 兼容老代码: 仍导出 largeJson 给路由声明用 (空实现, 路径已在上面分流)
const largeJson = (req, res, next) => next();
app.use(cookieParser());

// 万象书屋: OpenAPI 文档 /api/docs (开发/排障辅助, 不收录到搜索引擎)
try {
  const swaggerUi = require('swagger-ui-express');
  const swaggerSpec = require('./swagger');
  app.use('/api/docs', swaggerUi.serve, swaggerUi.setup(swaggerSpec, {
    customSiteTitle: '万象书屋 API',
    swaggerOptions: { docExpansion: 'list' }
  }));
  app.get('/api/docs.json', (req, res) => res.json(swaggerSpec));
} catch (e) {
  // swagger-ui-express 没装也不阻塞启动
  console.warn('[swagger] not loaded:', e.message);
}

// 万象书屋: TOTP (Google Authenticator) 二步验证库
// 注: otplib 新版本顶层 API, 不再用 authenticator.options 这种老形式
const otplib = require('otplib');
function totpVerify(token, secret) {
  if (!token || !secret) return false;
  // 容忍前后 30s 的时间漂移 (window=1)
  return otplib.verifySync({ token: String(token), secret, options: { window: 1 } });
}
function totpGenerateSecret() {
  return otplib.generateSecret();
}
function totpGenerateUri(label, issuer, secret) {
  return otplib.generateURI({ label, issuer, secret });
}

// 万象书屋: 简易内存级限速 (按 IP). 不依赖 redis, 适合单实例部署.
// 用于阻挡 admin/login 暴力破解.
const loginAttempts = new Map(); // ip -> { count, firstTs, lockedUntil }
function loginRateLimit(req, res, next) {
  const ip = req.ip || req.connection?.remoteAddress || 'unknown';
  const now = Date.now();
  const WINDOW_MS = 60 * 1000;          // 1 分钟内最多 5 次失败
  const MAX_FAILS = 5;
  const LOCK_MS = 5 * 60 * 1000;        // 触发后冷却 5 分钟
  const slot = loginAttempts.get(ip);
  if (slot && slot.lockedUntil && slot.lockedUntil > now) {
    return res.status(429).json({ ok: false, msg: 'too many attempts, try later' });
  }
  // 过期窗口重置
  if (slot && now - slot.firstTs > WINDOW_MS) {
    loginAttempts.delete(ip);
  }
  res.locals._loginIp = ip;
  res.locals._loginNow = now;
  res.locals._loginCfg = { WINDOW_MS, MAX_FAILS, LOCK_MS };
  next();
}
function recordLoginResult(res, ok) {
  const ip = res.locals._loginIp;
  if (!ip) return;
  if (ok) {
    loginAttempts.delete(ip);
    return;
  }
  const now = res.locals._loginNow || Date.now();
  const cfg = res.locals._loginCfg || { WINDOW_MS: 60_000, MAX_FAILS: 5, LOCK_MS: 5 * 60_000 };
  const slot = loginAttempts.get(ip) || { count: 0, firstTs: now, lockedUntil: 0 };
  slot.count += 1;
  if (slot.count === 1) slot.firstTs = now;
  if (slot.count >= cfg.MAX_FAILS) slot.lockedUntil = now + cfg.LOCK_MS;
  loginAttempts.set(ip, slot);
}
// 顺手定时清理 1 小时前的过期 lock 记录, 防止 map 无限增长
setInterval(() => {
  const cutoff = Date.now() - 60 * 60 * 1000;
  for (const [ip, slot] of loginAttempts.entries()) {
    if ((slot.lockedUntil || 0) < cutoff && (slot.firstTs || 0) < cutoff) {
      loginAttempts.delete(ip);
    }
  }
}, 30 * 60 * 1000).unref?.();

// 万象书屋: 通用 IP 维度滑动窗口限速, 给公开接口防爬防刷
// 简单令牌桶: 每个 IP 在 windowMs 内最多 max 次. 超出返 429.
// NODE_ENV=test 时跳过限速 (集成测试同 IP 高频调用), 生产环境绝不能跳.
//
// 万象书屋 D-12 修复: DISABLE_RATE_LIMIT=1 在生产是危险开关, 启动时打 warn 让运维感知.
const RATE_LIMIT_DISABLED = process.env.NODE_ENV === 'test' || process.env.DISABLE_RATE_LIMIT === '1';
if (process.env.DISABLE_RATE_LIMIT === '1' && process.env.NODE_ENV === 'production') {
  console.warn('[security] WARNING: DISABLE_RATE_LIMIT=1 in production, all rate limits OFF!');
}

// 万象书屋 D-10 修复: 多 makeRateLimit 实例共享一个 sweeper, 避免 N 条 setInterval.
// 每加一个限速器只是 push 到 _allBuckets, 单次 sweeper 跑一遍清理.
const _allBuckets = []; // [{ bucket, windowMs }, ...]
let _sweeperStarted = false;
function _startGlobalSweeper() {
  if (_sweeperStarted) return;
  _sweeperStarted = true;
  setInterval(() => {
    const now = Date.now();
    for (const { bucket, windowMs } of _allBuckets) {
      const cutoff = now - windowMs;
      for (const [k, v] of bucket.entries()) {
        if (v.firstTs < cutoff) bucket.delete(k);
      }
    }
  }, 60_000).unref?.();
}

function makeRateLimit({ windowMs, max, keyPrefix = '' }) {
  if (RATE_LIMIT_DISABLED) return (req, res, next) => next();
  const bucket = new Map(); // ip -> { count, firstTs }
  _allBuckets.push({ bucket, windowMs });
  _startGlobalSweeper();
  return (req, res, next) => {
    const ip = req.ip || 'unknown';
    const key = keyPrefix + ip;
    const now = Date.now();
    const slot = bucket.get(key);
    if (!slot || now - slot.firstTs > windowMs) {
      bucket.set(key, { count: 1, firstTs: now });
      return next();
    }
    slot.count += 1;
    if (slot.count > max) {
      res.set('Retry-After', Math.ceil((slot.firstTs + windowMs - now) / 1000));
      return res.status(429).json({ ok: false, msg: 'rate limited' });
    }
    next();
  };
}

// /api/sources 是爬虫重点目标 (你的核心书源资产), 限制每 IP 每分钟 10 次
const rateLimitSources = makeRateLimit({ windowMs: 60_000, max: 10, keyPrefix: 's:' });
// /api/ping 限制每 IP 每 10 秒 1 次 (正常 device 4 分钟一次, 超频即作弊)
const rateLimitPing = makeRateLimit({ windowMs: 10_000, max: 3, keyPrefix: 'p:' });
// /api/ad-config 每 IP 每 5 秒 1 次 (客户端默认 6h 一次, 超频即异常)
const rateLimitAdConfig = makeRateLimit({ windowMs: 5_000, max: 3, keyPrefix: 'a:' });
// 广告事件 / 崩溃上报: 每设备每 3 秒最多 5 条, 防止 App 端 bug 刷爆
const rateLimitAdEvent = makeRateLimit({ windowMs: 3_000, max: 5, keyPrefix: 'e:' });
const rateLimitCrash = makeRateLimit({ windowMs: 60_000, max: 3, keyPrefix: 'c:' });
// 万象书屋: 自建埋点 /api/events 上报. 客户端会内存队列 5s 或 50 条触发, 单设备每 5s 1 次窗.
// 留 3 次 burst 容忍 App 切后台一次性 flush + 5s 后下个窗又上报.
const rateLimitEvents = makeRateLimit({ windowMs: 5_000, max: 3, keyPrefix: 'ev:' });
// 用户反馈: 每 IP 每 5 分钟 5 条, 防恶意提交骚扰
const rateLimitFeedback = makeRateLimit({ windowMs: 5 * 60_000, max: 5, keyPrefix: 'f:' });
// 万象书屋: 解析失败上报频率本质比 feedback 高得多 (一次搜索 79 源都可能 fail).
// 用 30 秒 100 次的窗, 防刷又不挡正常使用; sourceUrl 必须已注册, 进一步防爆表.
const rateLimitSourceError = makeRateLimit({ windowMs: 30_000, max: 100, keyPrefix: 'se:' });
// 兑换码: 每设备每分钟 5 次, 防爆破
const rateLimitRedeem = makeRateLimit({ windowMs: 60_000, max: 5, keyPrefix: 'r:' });

/**
 * 万象书屋: 设备黑名单中间件. 命中即 403, App 收到永久拒绝.
 * 用于挂在 /api/ping / /api/sources / /api/ad-event / /api/feedback 入口.
 */
function blockBlacklistedDevice(req, res, next) {
  const did = (req.body && req.body.device_id) ||
              (req.body && req.body.deviceId) ||
              req.get('X-Device-Id');
  // 万象书屋 D-9 修复: 强制 did 为 string. 客户端误发数组/对象会让下游 SQL/cache 出 type 错.
  if (did != null && typeof did !== 'string') {
    return res.status(400).json({ ok: false, msg: 'device_id must be string' });
  }
  if (did && did.length > 128) {
    return res.status(400).json({ ok: false, msg: 'device_id too long' });
  }
  if (did && db.isDeviceBlocked(did)) {
    return res.status(403).json({ ok: false, msg: 'device blocked' });
  }
  next();
}

// === 万象书屋: 设备 token (HMAC) 防伪 ===
//
// SECRET 必须保密, 部署时通过环境变量 DEVICE_TOKEN_SECRET 注入.
// 本地开发用兜底值, 生产 .env 里**必须**改成 32+ 字节随机串.
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

/**
 * 万象书屋 安全加固: 未注册 device_id 的 IP 级配额.
 *
 * 旧设计: verifyDeviceToken 对"db 里查不到 token"的设备直接放行(兼容老 App),
 *   导致攻击者只要伪造任意新 X-Device-Id 即可绕开 token 校验, token 校验形同虚设.
 *
 * 新设计 (双层):
 *   1. 已注册设备: 必须带正确 token, 否则 401 (跟旧版一致).
 *   2. 未注册设备 (兼容老 App): 放行, 但每 IP 每分钟最多见 N 个 unique device_id.
 *      超过 N 一律 429, 阻止"伪造 device_id 横扫"攻击; 真实老 App 一台设备只
 *      贡献 1 个 device_id, 完全不受影响.
 *
 * UNREG_PER_IP_LIMIT 默认 8 (家庭/办公网 NAT 后通常 < 8 台 App), 可通过环境变量调.
 */
// 万象书屋: 阈值取 60 — NAT 后大型办公网 1 分钟内同时新装 60 个全新设备很罕见,
// 但能拦下"伪造 device_id 横扫"的暴力攻击 (千级以上). 生产可通过 env 调小给关键 IP 收紧.
const UNREG_PER_IP_LIMIT = parseInt(process.env.UNREG_PER_IP_LIMIT, 10) || 60;
const UNREG_WINDOW_MS = 60_000;
const _unregByIp = new Map(); // ip -> { ts: number, dids: Set<string> }
function _checkUnregisteredQuota(ip, did) {
  const now = Date.now();
  let bucket = _unregByIp.get(ip);
  if (!bucket || now - bucket.ts > UNREG_WINDOW_MS) {
    bucket = { ts: now, dids: new Set() };
    _unregByIp.set(ip, bucket);
  }
  bucket.dids.add(did);
  // 顺手清旧桶, 防止 Map 无限膨胀 (每 1000 次清一次过期)
  if (_unregByIp.size > 5000) {
    for (const [k, v] of _unregByIp) {
      if (now - v.ts > UNREG_WINDOW_MS) _unregByIp.delete(k);
    }
  }
  return bucket.dids.size <= UNREG_PER_IP_LIMIT;
}

/**
 * 校验设备 token 中间件 (默认: 兼容模式).
 * - 已注册设备: 必须带 token, 否则 401.
 * - 未注册设备: 放行 (兼容老 App), 但走 IP 级 quota 防伪造扫.
 *
 * 用 [verifyDeviceTokenStrict] 替换以拒绝未注册访问 (写操作端点推荐).
 */
function verifyDeviceToken(req, res, next) {
  const did = (req.body && (req.body.device_id || req.body.deviceId)) ||
              req.get('X-Device-Id');
  if (!did) return next(); // 无 device_id 的接口 (如 health) 不校验
  // 万象书屋 D-9 修复: did 必须是 string. 误发数组/对象时 db 查询会出错或行为异常.
  if (typeof did !== 'string' || did.length === 0 || did.length > 128) {
    return res.status(400).json({ ok: false, msg: 'invalid device_id' });
  }
  const expected = db.getDeviceTokenHash(did);
  if (!expected) {
    // 未注册: IP 级配额防伪造横扫
    if (!_checkUnregisteredQuota(req.ip, did)) {
      logger.warn('unregistered device flood', { t: req.traceId, ip: req.ip, did: did.slice(0, 12) });
      return res.status(429).json({ ok: false, msg: 'too many unregistered devices, please register' });
    }
    req.deviceUnregistered = true;
    return next();
  }
  const provided = req.get('X-Device-Token') || (req.body && req.body.device_token);
  if (!provided) {
    return res.status(401).json({ ok: false, msg: 'device token required' });
  }
  // 防 timing attack
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  const ok = a.length === b.length && crypto.timingSafeEqual(a, b);
  if (!ok) {
    logger.warn('device token mismatch', { t: req.traceId, did: did.slice(0, 12) });
    return res.status(401).json({ ok: false, msg: 'device token invalid' });
  }
  // 顺手更新 last_seen_at, 用于活跃统计
  db.touchDeviceSeen(did);
  next();
}

/**
 * 严格模式: 未注册 device_id 一律 401, 让客户端先调 /api/device/register.
 * 用于敏感写操作 (crash-log / feedback / source-error / wipe-data) 防匿名滥发.
 */
function verifyDeviceTokenStrict(req, res, next) {
  const did = (req.body && (req.body.device_id || req.body.deviceId)) ||
              req.get('X-Device-Id');
  if (!did) {
    return res.status(401).json({ ok: false, msg: 'device id required' });
  }
  if (typeof did !== 'string' || did.length === 0 || did.length > 128) {
    return res.status(400).json({ ok: false, msg: 'invalid device_id' });
  }
  const expected = db.getDeviceTokenHash(did);
  if (!expected) {
    return res.status(401).json({ ok: false, msg: 'device not registered, call /api/device/register first' });
  }
  const provided = req.get('X-Device-Token') || (req.body && req.body.device_token);
  if (!provided) {
    return res.status(401).json({ ok: false, msg: 'device token required' });
  }
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  const ok = a.length === b.length && crypto.timingSafeEqual(a, b);
  if (!ok) {
    logger.warn('device token mismatch (strict)', { t: req.traceId, did: did.slice(0, 12) });
    return res.status(401).json({ ok: false, msg: 'device token invalid' });
  }
  db.touchDeviceSeen(did);
  next();
}

// 公开接口: 设备首次注册 / 重新注册
// App 端: 启动时如果本地没 token, 调一次, 把返回的 token 持久化, 后续请求都带.
//   POST /api/device/register
//   body: { device_id, ua? }
//   resp: { ok, token, install_ts }
// 万象书屋: PIPL 用户数据清空入口. App 注销账号时调用.
//   DELETE /api/me/wipe-data
//   header: X-Device-Id, X-Device-Token (token 必须有效)
//   resp: { ok, deleted: { tableName: count } }
//
// 设计: 必须先注册 device_token, 否则任何人都能用别人的 device_id 把数据擦掉.
// 没注册的设备 (老 App) 暂不允许走 wipe, 让用户先升级.
app.delete('/api/me/wipe-data', makeRateLimit({ windowMs: 60_000, max: 1, keyPrefix: 'wipe:' }),
  (req, res) => {
  const did = req.get('X-Device-Id') || (req.body && req.body.deviceId);
  const tok = req.get('X-Device-Token') || (req.body && req.body.deviceToken);
  if (!did || !tok) {
    return res.status(400).json({ ok: false, msg: 'device id & token required' });
  }
  const expected = db.getDeviceTokenHash(did);
  if (!expected) {
    return res.status(400).json({ ok: false, msg: 'device not registered, cannot wipe' });
  }
  const a = Buffer.from(tok), b = Buffer.from(expected);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    logger.warn('wipe-data token invalid', { t: req.traceId, did: did.slice(0, 12) });
    return res.status(401).json({ ok: false, msg: 'invalid token' });
  }
  const deleted = db.wipeUserData(did);
  db.recordAudit({
    ip: req.ip, action: 'pipl.wipe_user_data', target: did.slice(0, 16) + '...',
    detail: deleted
  });
  logger.info('user data wiped', { t: req.traceId, did: did.slice(0, 12), deleted });
  res.json({ ok: true, deleted });
});

app.post('/api/device/register', makeRateLimit({ windowMs: 60_000, max: 3, keyPrefix: 'reg:' }),
  blockBlacklistedDevice, (req, res) => {
  const did = (req.body && (req.body.device_id || req.body.deviceId));
  if (!did || typeof did !== 'string' || did.length < 8 || did.length > 128) {
    return res.status(400).json({ ok: false, msg: 'invalid device_id' });
  }
  // 已注册过的不允许重复 register (除非显式 ?reissue=1, 给运营复位用)
  const existing = db.getDeviceTokenHash(did);
  const reissue = req.query.reissue === '1';
  if (existing && !reissue) {
    return res.status(409).json({ ok: false, msg: 'already registered' });
  }
  const installTs = Date.now();
  const tokenHash = computeDeviceTokenHash(did, installTs);
  db.upsertDeviceToken({
    deviceId: did, tokenHash, installTs,
    ua: (req.headers['user-agent'] || '').slice(0, 200), ip: req.ip,
    platform: req.platform,                          // 'android' / 'ios' / 'web'
  });
  res.json({ ok: true, token: tokenHash, install_ts: installTs, platform: req.platform });
});

// === 公共 API（App 端调用，无需登录） ===

// 健康检查: 反代/uptime monitor 用, 不走限速
// 万象书屋: 分级健康检查. 监控用 GET /api/health, 5xx = 应该重启;
// 200 但 checks.x.ok=false = 部分依赖异常, 该报警但不该重启.
app.get('/api/health', (req, res) => {
  const checks = {};
  let allOk = true;

  // DB 检查 (轻量 SELECT 1, 不影响业务)
  const t0 = Date.now();
  try {
    db.__db.prepare('SELECT 1').get();
    checks.db = { ok: true, latency_ms: Date.now() - t0 };
  } catch (e) {
    checks.db = { ok: false, error: e.message };
    allOk = false;
  }

  // 内存使用 (单位: MB), 若 RSS 超过 500MB 视为异常 (low-end VPS 会被 OOM)
  const mem = process.memoryUsage();
  const rssMb = Math.round(mem.rss / 1024 / 1024);
  checks.mem = { ok: rssMb < 500, rss_mb: rssMb, heap_used_mb: Math.round(mem.heapUsed / 1024 / 1024) };
  if (!checks.mem.ok) allOk = false;

  // 磁盘剩余空间 (data 目录所在分区)
  try {
    const fs = require('fs');
    const dataDir = process.env.DB_PATH ? path.dirname(process.env.DB_PATH) : path.join(__dirname, 'data');
    const stat = fs.statfsSync ? fs.statfsSync(dataDir) : null;
    if (stat) {
      const freeMb = Math.round(stat.bsize * stat.bavail / 1024 / 1024);
      checks.disk = { ok: freeMb > 100, free_mb: freeMb };
      if (!checks.disk.ok) allOk = false;
    }
  } catch (_) { /* statfs 在某些版本/系统上没有, 跳过 */ }

  checks.uptime_s = Math.round(process.uptime());

  res.status(allOk ? 200 : 503).json({ ok: allOk, checks, now: Date.now() });
});

// 万象书屋: Prometheus 文本格式指标. 即使没 Prometheus, 别的监控工具也能 scrape.
// 设计参考 https://prometheus.io/docs/instrumenting/exposition_formats/
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

  // 业务指标 (从 db 拉取, 已被 prepared statement 优化)
  // 万象书屋 D-15 修复 (B-2): db.statsToday() 返回 number (今日访问 device 去重数), 不是
  //   { activeDevices, heartbeats } 对象. 之前 stats.activeDevices 永远 undefined → metric 永远输出 0,
  //   监控告警全部失灵. 改成直接消费 number, 心跳数另起一条 SELECT.
  try {
    metric('wanxiang_active_devices_today', 'Distinct devices visited today (UTC+8)', 'gauge',
      Number(db.statsToday()) || 0);
    const hb = db.__db.prepare('SELECT COUNT(*) AS n FROM heartbeats WHERE ts > ?')
      .get(Date.now() - 86400_000).n;
    metric('wanxiang_heartbeats_24h', 'Heartbeats received in last 24h', 'gauge', Number(hb) || 0);
    metric('wanxiang_online_5m', 'Distinct devices with heartbeat in last 5 minutes', 'gauge',
      Number(db.statsOnline()) || 0);
  } catch (_) { /* 业务指标允许失败 */ }

  try {
    const sourceCount = db.__db.prepare('SELECT COUNT(*) AS n FROM book_sources WHERE enabled = 1').get();
    metric('wanxiang_book_sources_active', 'Active book sources count', 'gauge', sourceCount.n);
  } catch (_) {}

  try {
    const r = db.__db.prepare(
      `SELECT COUNT(*) AS n FROM crashes WHERE ts > ?`
    ).get(Date.now() - 24 * 3600 * 1000);
    metric('wanxiang_crashes_24h', 'Crashes in last 24h', 'gauge', r.n);
  } catch (_) {}

  try {
    const r = db.__db.prepare(
      `SELECT COUNT(*) AS n FROM feedback WHERE status = 'pending'`
    ).get();
    metric('wanxiang_feedback_pending', 'Pending feedback count', 'gauge', r.n);
  } catch (_) {}

  res.set('Content-Type', 'text/plain; version=0.0.4');
  res.send(lines.join('\n') + '\n');
});

// 万象书屋: App 启动版本检查. App 传 ?code=10001, 后端返"是否要升级"
app.get('/api/version-check', (req, res) => {
  const code = parseInt(req.query.code, 10) || 0;
  const v = db.getAppVersion();
  res.json({
    latestCode: v.latest_code,
    latestName: v.latest_name,
    minRequiredCode: v.min_required_code,
    forceUpgrade: code > 0 && v.min_required_code > 0 && code < v.min_required_code,
    needUpgrade: code > 0 && v.latest_code > 0 && code < v.latest_code,
    changelog: v.changelog || '',
    apkUrl: v.apk_url || '',
    marketUrl: v.market_url || ''
  });
});

// 万象书屋: 公告. App 启动拉一次. ?versionCode=N 用于按版本范围过滤
app.get('/api/announcement', (req, res) => {
  const versionCode = parseInt(req.query.versionCode, 10) || 0;
  const list = db.listActiveAnnouncements(versionCode);
  // ETag 用 list 的 hash, 内容不变就 304, 节省带宽 (公告数据量虽小但被频繁拉取)
  const etag = '"' + crypto.createHash('md5')
    .update(JSON.stringify(list))
    .digest('hex').slice(0, 16) + '"';
  res.set('Cache-Control', 'public, max-age=60');
  res.set('ETag', etag);
  if (req.get('If-None-Match') === etag) return res.status(304).end();
  res.json({ ok: true, list });
});

// 万象书屋: 兑换码兑换
app.post('/api/redeem', rateLimitRedeem, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const { code, deviceId } = req.body || {};
  if (!code || !deviceId) return res.status(400).json({ ok: false, msg: 'code & deviceId required' });
  if (typeof code !== 'string' || code.length > 32) return res.status(400).json({ ok: false, msg: 'invalid code' });
  try {
    const r = db.redeemCode(String(code).toUpperCase().trim(), String(deviceId).slice(0, 128), req.ip);
    if (r.ok) {
      db.recordAudit({ ip: req.ip, action: 'redeem.use', target: code, detail: { deviceId, rewardType: r.rewardType, rewardValue: r.rewardValue } });
    }
    res.json(r);
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

// App 拉取书源列表. 支持 ETag 304 避免重复下载 (省流量)
//
// 万象书屋 v2 (007): 按 X-Platform 过滤 (req.platform 由前面的中间件解析).
//   - Android 老客户端没 X-Platform → 中间件默认 'android' → 命中 platforms LIKE '%android%'
//   - iOS 客户端 X-Platform: ios → 命中 platforms LIKE '%ios%'
//   - admin 通过 PATCH /api/admin/sources/:url/platforms 控制每个源对哪些平台可见
//
// ETag 按 platform 分桶: iOS 拿 Android 的 If-None-Match 会自动 mismatch → 200, 不会拿到错误的 304
app.get('/api/sources', rateLimitSources, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const healthyOnly = req.query.healthy === '1' || req.query.healthy === 'true' || req.query.hideBroken === '1';
  const etag = db.getEnabledSourcesEtag(req.platform, { healthyOnly });
  // public, 允许反代/CDN 缓存 5 分钟; ETag 变化时客户端自动重拉
  res.set('Cache-Control', 'public, max-age=300');
  res.set('ETag', etag);
  // Vary: X-Platform 让 CDN 区分平台缓存, 避免互相串
  res.vary('X-Platform');
  res.vary('X-Source-Health');
  if (req.get('If-None-Match') === etag) return res.status(304).end();
  res.json(db.listEnabledSourcesJson(req.platform, { healthyOnly }));
});

// 万象书屋 iOS/Android: 解析失败/超时上报.
// App 可在 search/info/toc/content 任意阶段上报, 后台聚合为 source_health.
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

// 万象书屋 v2 (008): 书城 feed (M2.3.1)
//
// iOS App 用: GET /api/bookstore/feed?channel=male
//   - channel: male / female / publish / manga / audio
//   - 返回: [{id, channel, section, name, author, coverUrl, intro, kind, bookUrl, origin, ...}]
//   - 含 ETag 304 缓存
const _ALLOWED_CHANNELS = new Set(['male', 'female', 'publish', 'manga', 'audio']);
app.get('/api/bookstore/feed', rateLimitSources, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const channel = String(req.query.channel || '').toLowerCase().trim();
  if (!_ALLOWED_CHANNELS.has(channel)) {
    return res.status(400).json({ ok: false, msg: 'channel must be male/female/publish/manga/audio' });
  }
  const etag = db.getBookstoreFeedEtag(channel);
  res.set('Cache-Control', 'public, max-age=600');
  res.set('ETag', etag);
  res.vary('X-Platform');
  if (req.get('If-None-Match') === etag) return res.status(304).end();
  res.json({ ok: true, channel, items: db.listBookstoreFeed(channel) });
});

// App 心跳 + 访问统计上报
app.post('/api/ping', rateLimitPing, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const deviceId =
    (req.body && typeof req.body.device_id === 'string' && req.body.device_id) ||
    req.get('X-Device-Id') ||
    null;
  if (!deviceId) return res.status(400).json({ ok: false, msg: 'device_id required' });
  // 防 device_id 过长刷表
  if (deviceId.length > 128) return res.status(400).json({ ok: false, msg: 'device_id too long' });
  db.recordPing(deviceId);
  res.json({ ok: true });
});

// === 管理 API ===

function requireAdmin(req, res, next) {
  const tok = req.cookies && req.cookies.adm;
  const meta = db.isValidSession(tok, req.get('User-Agent') || '', true);
  if (meta && meta.ok) {
    // 万象书屋 v2: 把当前 admin 用户名 / 角色挂到 req, 给 RBAC 用
    // 没绑用户的老 session (legacy 单密码登录) 默认 super
    req.admin = { username: meta.username || 'legacy', role: meta.role || 'super' };
    return next();
  }
  return res.status(401).json({ ok: false, msg: 'unauthorized' });
}

/**
 * 万象书屋: 角色权限. 用法 requireRole('super') / requireRole(['super','operator']).
 * 必须在 requireAdmin 之后使用.
 *   super    — 所有权限
 *   operator — 书源/广告配置/兑换码 (运营)
 *   cs       — 仅看反馈/崩溃日志 (客服)
 */
function requireRole(roles) {
  const allowed = Array.isArray(roles) ? new Set(roles) : new Set([roles]);
  return (req, res, next) => {
    const role = req.admin?.role || 'super'; // 老 session 默认 super 兼容
    if (allowed.has(role)) return next();
    return res.status(403).json({ ok: false, msg: 'role denied: need ' + [...allowed].join('/') });
  };
}

app.post('/api/admin/login', loginRateLimit, async (req, res) => {
  const { username, password, totp } = req.body || {};
  const pwd = password;

  // 万象书屋 v2: 优先走多用户体系 (admin_users); 老的 admin 表 (id=1) 仅作 fallback
  if (username) {
    // 账户级锁定检查 (跟 IP 限流并行, 防爆破换 IP 绕过)
    const lock = db.isAccountLocked(username, { windowMin: 5, threshold: 5, lockMin: 30 });
    if (lock.locked) {
      const left = Math.ceil((lock.unlock_at - Date.now()) / 60_000);
      logger.warn('admin login locked', { t: req.traceId, username, ip: req.ip, unlock_in_min: left });
      return res.status(423).json({
        ok: false,
        msg: `account locked due to too many failures, try again in ${left} minutes`,
        unlock_at: lock.unlock_at
      });
    }

    const user = await db.verifyAdminUser(username, pwd);
    if (!user) {
      recordLoginResult(res, false);
      db.recordLoginFailure(username, req.ip);
      return res.status(401).json({ ok: false, msg: 'wrong username or password' });
    }
    // 2FA 校验
    if (user.totp_enabled) {
      if (!totp) {
        return res.status(401).json({ ok: false, msg: 'totp required', need_totp: true });
      }
      const valid = totpVerify(totp, user.totp_secret);
      if (!valid) {
        recordLoginResult(res, false);
        db.recordLoginFailure(username, req.ip);
        return res.status(401).json({ ok: false, msg: 'wrong totp code' });
      }
    }
    recordLoginResult(res, true);
    db.clearLoginFailures(username);
    db.recordAdminLogin(username, req.ip);
    db.recordAudit({ ip: req.ip, action: 'admin.login', target: username });
    const token = db.createSession(req.ip || '', req.get('User-Agent') || '', { username, role: user.role });
    res.cookie('adm', token, {
      httpOnly: true, sameSite: 'strict',
      maxAge: 7 * 86400 * 1000,
      secure: !!process.env.SECURE_COOKIE
    });
    return res.json({ ok: true, role: user.role });
  }

  // 兼容老路径: 单密码登录 (上线前建议关掉, 走 username)
  const ok = await db.verifyAdminPassword(pwd);
  if (!ok) {
    recordLoginResult(res, false);
    return res.status(401).json({ ok: false, msg: 'wrong password' });
  }
  recordLoginResult(res, true);
  const token = db.createSession(req.ip || '', req.get('User-Agent') || '');
  res.cookie('adm', token, {
    httpOnly: true, sameSite: 'strict',
    maxAge: 7 * 86400 * 1000,
    secure: !!process.env.SECURE_COOKIE
  });
  res.json({ ok: true, role: 'super' });
});

app.post('/api/admin/logout', requireAdmin, (req, res) => {
  db.destroySession(req.cookies.adm);
  res.clearCookie('adm');
  res.json({ ok: true });
});

// 万象书屋: 改密码也套 login 限速 + 成功后踢掉所有 session 强制全部端重登
app.post('/api/admin/password', loginRateLimit, requireAdmin, async (req, res) => {
  const { oldPassword, newPassword } = req.body || {};
  const ok = await db.verifyAdminPassword(oldPassword);
  if (!ok) {
    recordLoginResult(res, false);
    return res.status(401).json({ ok: false, msg: 'wrong old password' });
  }
  recordLoginResult(res, true);
  if (!newPassword || newPassword.length < 8) {
    return res.status(400).json({ ok: false, msg: 'new password must be >= 8 chars' });
  }
  if (newPassword === oldPassword) {
    return res.status(400).json({ ok: false, msg: 'new password must differ from old' });
  }
  await db.setAdminPassword(newPassword);
  db.destroyAllSessions();
  db.recordAudit({ ip: req.ip, action: 'pwd.change', target: 'admin' });
  res.clearCookie('adm');
  res.json({ ok: true });
});

// 检查登录态（前端用来判断要不要跳登录页）
app.get('/api/admin/me', (req, res) => {
  const tok = req.cookies && req.cookies.adm;
  res.json({ ok: db.isValidSession(tok, req.get('User-Agent') || '') });
});

// 书源管理
app.get('/api/admin/sources', requireAdmin, (req, res) => {
  res.json(db.listAllSources());
});

app.get('/api/admin/sources/raw', requireAdmin, (req, res) => {
  const url = req.query.url;
  const row = db.getSource(url);
  if (!row) return res.status(404).json({ ok: false });
  res.set('Content-Type', 'application/json');
  res.send(row.json);
});

// 导入书源可能整包传几 MB, 单独挂 largeJson 中间件 (20mb)
// 万象书屋 D-16 (B-4 RBAC): 写接口加角色限制, cs 客服角色不能改书源, 仅 super/operator 可
app.post('/api/admin/sources', largeJson, requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const body = req.body;
  try {
    if (Array.isArray(body)) {
      const r = db.bulkUpsert(body);
      db.recordAudit({ ip: req.ip, action: 'source.bulkUpsert', target: `count=${body.length}`, detail: r });
      return res.json({ ok: true, ...r });
    }
    if (body && typeof body === 'object') {
      const r = db.upsertSource(body);
      db.recordAudit({ ip: req.ip, action: 'source.upsert', target: body.bookSourceUrl, detail: { action: r.action } });
      return res.json({ ok: true, ...r });
    }
    return res.status(400).json({ ok: false, msg: 'JSON object or array expected' });
  } catch (err) {
    return res.status(400).json({ ok: false, msg: err.message || 'invalid book source' });
  }
});

// 万象书屋 D-16 (B-4): 删源是高危操作, 仅 super/operator
app.delete('/api/admin/sources', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const url = req.query.url;
  if (!url) return res.status(400).json({ ok: false });
  const n = db.deleteSource(url);
  db.recordAudit({ ip: req.ip, action: 'source.delete', target: url, detail: { deleted: n } });
  res.json({ ok: true, deleted: n });
});

// 万象书屋 iOS: 书源健康度 / 解析器质量面板
app.get('/api/admin/source-health', requireAdmin, (req, res) => {
  res.json({
    ok: true,
    items: db.listSourceHealth({
      platform: req.query.platform,
      stage: req.query.stage,
      status: req.query.status,
      sourceUrl: req.query.sourceUrl || req.query.url,
      limit: req.query.limit
    })
  });
});

app.get('/api/admin/source-health/summary', requireAdmin, (req, res) => {
  res.json({ ok: true, summary: db.sourceHealthSummary(req.query.platform) });
});

// 一键静态检查: 不做网络抓取, 只验证各阶段必要规则是否存在.
// 真正的动态 search/info/toc/content 结果由 iOS CLI 或 App 上报 /api/source-error 聚合.
app.post('/api/admin/sources/check', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    const r = db.runSourceStaticCheck({
      platform: req.body?.platform || req.query.platform || 'ios',
      sampleKeyword: req.body?.sampleKeyword || req.query.sampleKeyword || '斗破苍穹',
      url: req.body?.url || req.query.url || null
    });
    // 万象书屋 D-16 (B-7): audit detail 的 'error' 字段是数字 (失败源数), 不是错误对象,
    // 在 audit 面板里看到 'error: 3' 容易误读为 "出了 3 个错误". 改名 errorCount 消歧义.
    db.recordAudit({
      ip: req.ip, action: 'source.staticCheck', target: r.platform,
      detail: { checked: r.checked, okCount: r.ok, errorCount: r.error }
    });
    // 万象书屋: r 自带 { platform, checked, ok, error, results } — 把数字 ok 改名 okCount,
    // 否则 spread 后 `ok: true` 会被覆盖. 同步把 error 改名 errorCount.
    const { ok: okCount, error: errorCount, ...rest } = r;
    res.json({ ok: true, okCount, errorCount, ...rest });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message || 'check failed' });
  }
});

// 万象书屋 D-16 (B-4): 切换 enabled 只 super/operator
app.patch('/api/admin/sources/enabled', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { url, enabled } = req.body || {};
  if (!url) return res.status(400).json({ ok: false });
  db.setEnabled(url, !!enabled);
  db.recordAudit({ ip: req.ip, action: 'source.enabled', target: url, detail: { enabled: !!enabled } });
  res.json({ ok: true });
});

// 万象书屋 v2 (007): admin 改某个源对哪些平台可见
// body: { url, platforms: ['android', 'ios'] }   (空数组 = 该源对所有平台不可见, 实质禁用)
// 万象书屋 D-16 (B-4): 平台过滤是 admin 运营操作, 限 super/operator
app.patch('/api/admin/sources/platforms', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { url, platforms } = req.body || {};
  if (!url) return res.status(400).json({ ok: false, msg: 'url required' });
  if (!Array.isArray(platforms)) return res.status(400).json({ ok: false, msg: 'platforms must be an array' });
  try {
    const n = db.setSourcePlatforms(url, platforms);
    db.recordAudit({
      ip: req.ip,
      action: 'source.platforms',
      target: url,
      detail: { platforms, changed: n }
    });
    if (n === 0) return res.status(404).json({ ok: false, msg: 'source not found' });
    res.json({ ok: true, changed: n });
  } catch (err) {
    res.status(400).json({ ok: false, msg: err.message || 'invalid' });
  }
});

// 万象书屋 v2 (008): admin 书城 feed 管理 (M2.3.1)
app.get('/api/admin/bookstore-feed', requireAdmin, (req, res) => {
  res.json(db.listAllBookstoreFeed());
});

// 万象书屋 D-16 (B-4): 书城 feed 也属于运营修改
app.post('/api/admin/bookstore-feed', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const b = req.body || {};
  if (!b.channel || !_ALLOWED_CHANNELS.has(b.channel)) {
    return res.status(400).json({ ok: false, msg: 'channel invalid' });
  }
  if (!b.name || typeof b.name !== 'string') return res.status(400).json({ ok: false, msg: 'name required' });
  if (!b.target_url || typeof b.target_url !== 'string') return res.status(400).json({ ok: false, msg: 'target_url required' });
  try {
    const item = db.upsertBookstoreFeed(b);
    db.recordAudit({ ip: req.ip, action: 'feed.upsert', target: String(item.id), detail: { channel: b.channel, name: b.name } });
    res.json({ ok: true, item });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

app.patch('/api/admin/bookstore-feed/:id/enabled', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (!id) return res.status(400).json({ ok: false });
  db.setBookstoreFeedEnabled(id, !!req.body?.enabled);
  res.json({ ok: true });
});

// =============================================================================
// 万象书屋 D-23 (2026-05-08): 书城 m.qidian.com mirror endpoints
// =============================================================================

const qidianMirror = require('./jobs/qidianMirror');

/**
 * 客户端拉 mirror cache. ETag 304 节流, 命中 cache 时只发 etag header 不发 body.
 * App 端原直抓 m.qidian 的代码保留为 fallback (本接口 503 / 304 异常时降级).
 */
app.get('/api/bookstore/mirror', rateLimitSources, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const row = db.getLatestBookstoreMirror();
  if (!row) {
    return res.status(503).json({ ok: false, msg: 'mirror not ready, fallback to direct fetch' });
  }
  // 万象书屋: payload 已经是序列化好的 JSON 字符串, 直接 send 不再 JSON.stringify
  res.set('ETag', row.etag);
  res.set('Cache-Control', 'public, max-age=600');
  res.set('Content-Type', 'application/json; charset=utf-8');
  if (req.get('If-None-Match') === row.etag) return res.status(304).end();
  // overrides_json 是 admin 配的覆盖规则 (置顶/屏蔽/改字段). 没规则时直接 send 原 payload.
  // 有规则时 merge 后 send (overrides 处理放在客户端方便也省服务端 CPU; 后期可挪到这里).
  res.send(row.payload);
});

/** admin 监控: 当前 cache 状态 + 最近 24 次抓取记录 */
app.get('/api/admin/bookstore-mirror/status', requireAdmin, (req, res) => {
  const latest = db.getLatestBookstoreMirror();
  const recent = db.listRecentBookstoreMirror(24);
  res.json({
    latest: latest ? {
      version: latest.version,
      fetched_at: latest.fetched_at,
      etag: latest.etag,
      source: latest.source,
      payload_size: latest.payload?.length || 0,
    } : null,
    nextScheduledAt: _nextMirrorRunAt || null,
    recent: recent.map(r => ({
      id: r.id,
      version: r.version,
      fetched_at: r.fetched_at,
      ok: r.ok === 1,
      err_msg: r.err_msg,
      payload_size: r.payload_size,
      source: r.source,
    })),
  });
});

/** admin 手动触发抓取 (不替换 cron, 只是临时刷新). */
app.post('/api/admin/bookstore-mirror/refresh', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
  try {
    const result = await qidianMirror.fetchAndCache(db);
    logger.info('mirror manual refresh ok', result);
    res.json({ ok: true, ...result });
  } catch (e) {
    qidianMirror.recordFailure(db, e);
    logger.warn('mirror manual refresh failed', { msg: e.message });
    res.status(500).json({ ok: false, msg: e.message });
  }
});

/** admin 预览当前 cache 完整 JSON */
app.get('/api/admin/bookstore-mirror/preview', requireAdmin, (req, res) => {
  const row = db.getLatestBookstoreMirror();
  res.set('Content-Type', 'application/json; charset=utf-8');
  res.send(row?.payload || '{}');
});

app.delete('/api/admin/bookstore-feed/:id', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const id = parseInt(req.params.id, 10);
  if (!id) return res.status(400).json({ ok: false });
  const n = db.deleteBookstoreFeed(id);
  db.recordAudit({ ip: req.ip, action: 'feed.delete', target: String(id), detail: { changed: n } });
  res.json({ ok: true, deleted: n });
});

// 万象书屋 v2 (007): 批量给一组源加/去某个平台标 (admin "全选 iOS" 用)
// body: { urls: ['url1','url2'], platform: 'ios', op: 'add'|'remove' }
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
    if (op === 'add') {
      if (cur.includes(platform)) continue;
      next = [...cur, platform];
    } else {
      if (!cur.includes(platform)) continue;
      next = cur.filter(p => p !== platform);
    }
    db.setSourcePlatforms(url, next);
    changed++;
  }
  db.recordAudit({
    ip: req.ip,
    action: 'source.platforms.bulk',
    target: `count=${urls.length}`,
    detail: { platform, op, changed }
  });
  res.json({ ok: true, changed });
});

// 万象书屋: 批量启停整组 (admin O6)
app.patch('/api/admin/sources/group-enabled', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { group, enabled } = req.body || {};
  if (typeof group !== 'string') return res.status(400).json({ ok: false, msg: 'group required' });
  const now = Date.now();
  // bookSourceGroup 字段是逗号分隔的多个 group, 用 LIKE '%group%' 命中
  // 为安全起见用 JSON 字段直接扫描, 命中即切 enabled
  const rows = db.__db.prepare('SELECT url, json FROM book_sources').all();
  let affected = 0;
  const tx = db.__db.transaction(() => {
    for (const r of rows) {
      try {
        const src = JSON.parse(r.json);
        const grp = String(src.bookSourceGroup || '');
        // 分组是逗号/分号分隔, 按 token 精确匹配
        const tokens = grp.split(/[,;，；]/).map(s => s.trim());
        if (!tokens.includes(group)) continue;
        db.__db.prepare('UPDATE book_sources SET enabled=?, updated_at=? WHERE url=?')
          .run(enabled ? 1 : 0, now, r.url);
        affected++;
      } catch { /* skip bad json */ }
    }
  });
  tx();
  db.invalidateSourcesCache();
  db.recordAudit({ ip: req.ip, action: 'source.group.enabled', target: group, detail: { enabled: !!enabled, affected } });
  res.json({ ok: true, affected });
});

// 万象书屋: 列出所有分组 (admin UI 下拉用)
app.get('/api/admin/sources/groups', requireAdmin, (req, res) => {
  const rows = db.__db.prepare('SELECT json FROM book_sources').all();
  const set = new Set();
  for (const r of rows) {
    try {
      const src = JSON.parse(r.json);
      for (const g of String(src.bookSourceGroup || '').split(/[,;，；]/)) {
        const t = g.trim();
        if (t) set.add(t);
      }
    } catch { /* */ }
  }
  res.json({ ok: true, groups: [...set].sort() });
});

app.get('/api/admin/stats', requireAdmin, (req, res) => {
  // 万象书屋: 支持 ?days=N 自定义曲线长度 (1~60), 默认 7
  const days = parseInt(req.query.days, 10) || 7;
  res.json({
    online: db.statsOnline(),
    today: db.statsToday(),
    week: db.statsWeek(),
    month: db.statsMonth(),
    daily: db.statsDailyCurve(days),
  });
});

// === 万象书屋: 书源准确性校验 ===

// 单条校验: ?url=... 必填; ?search=1 时一并探活 searchUrl
app.get('/api/admin/sources/validate', requireAdmin, async (req, res) => {
  const url = req.query.url;
  if (!url) return res.status(400).json({ ok: false, msg: 'url required' });
  const row = db.getSource(url);
  if (!row) return res.status(404).json({ ok: false, msg: 'source not found' });
  const checkSearch = String(req.query.search || '') === '1';
  try {
    const src = JSON.parse(row.json);
    const result = await validator.validateOne(src, { checkReach: true, checkSearch, timeoutMs: 6000 });
    res.json({ ok: true, result });
  } catch (e) {
    res.status(500).json({ ok: false, msg: e.message });
  }
});

// 批量体检: ?search=1 时同时跑搜索探活 (慢, 默认只 ping 主域)
app.get('/api/admin/sources/validate-all', requireAdmin, async (req, res) => {
  const checkSearch = String(req.query.search || '') === '1';
  // 用 listAllSources 拿到 url 再到 raw json 重组完整源对象
  const list = db.listAllSources();
  const sources = list.map(meta => {
    const row = db.getSource(meta.url);
    try { return JSON.parse(row.json); } catch { return { bookSourceUrl: meta.url, bookSourceName: meta.name }; }
  });
  try {
    const summary = await validator.validateAll(sources, {
      concurrency: 8,
      checkReach: true,
      checkSearch,
      timeoutMs: 6000,
    });
    res.json({ ok: true, ...summary });
  } catch (e) {
    res.status(500).json({ ok: false, msg: e.message });
  }
});

// === 万象书屋广告配置 ===

// 万象书屋: 熔断器. 5 分钟计算一次最近 6 小时高错误率的 provider, 动态把 weight 置 0
// 不改 DB, 只在 /api/ad-config 响应里运行时覆盖; 错误率恢复后下一次刷新自动放开.
let breakerCache = { computedAt: 0, broken: [] }; // broken: [{placement, provider}]
// 万象书屋 D-14 修复: breakerSuppressUntil 持久化到 SQLite (kv_settings 表), 进程重启不丢.
// 之前是纯内存变量, 运维 reset?minutes=360 设的 6 小时保护期, server 一重启就清零, 熔断又触发.
const BREAKER_SUPPRESS_KV_KEY = 'breaker_suppress_until';
let breakerSuppressUntil = (() => {
  const v = parseInt(db.kvGet(BREAKER_SUPPRESS_KV_KEY), 10);
  return Number.isFinite(v) && v > Date.now() ? v : 0;
})();
function refreshBreakerIfStale() {
  const now = Date.now();
  // 保护期内: 强制空 broken, 让被熔断的 provider 重新上场 (admin 手动 reset 用)
  if (now < breakerSuppressUntil) {
    breakerCache = { computedAt: now, broken: [] };
    return;
  }
  if (now - breakerCache.computedAt < 5 * 60_000) return;
  try {
    // 万象书屋: 之前 windowHours=1 + minSamples=20 太严, 实战中流量不密集时永不触发熔断.
    // 改 6 小时窗口 + 默认 10 样本, 让 ylh 包名错误这种"大面积失败"能在半天内被识别;
    // 误判风险: 公网偶发抖动, 但 errorThreshold=0.6 + 10 样本仍要求"60% 持续失败", 不会误熔断.
    //
    // perPlacementMinSamples: 激励视频流量 ~10x 低于开屏, 用 3 样本熔断
    // (10 次错误才保护用户, 用户体验掉得太厉害)
    breakerCache = {
      computedAt: now,
      broken: db.adProvidersToBreak({
        windowHours: 6,
        minSamples: 10,
        errorThreshold: 0.6,
        perPlacementMinSamples: { rewardedReadingUnlock: 3, chapterUnlock: 3 }
      }),
    };
    if (breakerCache.broken.length) {
      logger.warn('circuit breaker tripped', { broken: breakerCache.broken });
    }
  } catch (e) {
    logger.error('breaker compute failed', { msg: e.message });
  }
}

/** 对 config 对象做熔断: 命中的 provider.weight 置 0. 返回新对象, 不改原对象. */
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
  // 万象书屋 D-3 修复: 熔断后某 placement 所有 provider weight 都为 0 时,
  // 把该 placement.enabled 置 false, 避免 App 端持续走"等 SDK ready 5-8s 然后 fail"
  // 的硬超时路径, 浪费白屏时间. App 看到 enabled=false 直接 skip 这个广告位.
  if (cloned.placements) {
    for (const [name, p] of Object.entries(cloned.placements)) {
      if (!p || !Array.isArray(p.providers) || !p.enabled) continue;
      const totalWeight = p.providers.reduce((s, x) => s + (x.weight || 0), 0);
      if (totalWeight <= 0) {
        p.enabled = false;
      }
    }
  }
  return cloned;
}

// 公开: App 启动 / 定时拉取. 支持 If-None-Match -> 304 + 熔断运行时覆盖
app.get('/api/ad-config', rateLimitAdConfig, (req, res) => {
  // 万象书屋: 把 device_id 透传到 getAdConfig 实现灰度选版本
  const deviceId = req.get('X-Device-Id') || req.query.device_id;
  const row = db.getAdConfig(deviceId);
  res.set('Cache-Control', 'public, max-age=300');
  // 灰度: staging 命中的设备每次响应都有 X-Rollout-Bucket 标头方便排障
  if (row.isStaging) res.set('X-Rollout-Bucket', 'staging');
  // 熔断后 etag 要变, 否则客户端拿 304 还用旧 (未熔断) 配置
  refreshBreakerIfStale();
  const breakerKey = breakerCache.broken.length
    ? '-b' + require('crypto').createHash('md5')
        .update(JSON.stringify(breakerCache.broken)).digest('hex').slice(0, 6)
    : '';
  const effectiveEtag = row.etag + breakerKey;
  res.set('ETag', effectiveEtag);
  if (req.get('If-None-Match') === effectiveEtag) return res.status(304).end();
  // 熔断生效时 clone + 改 weight; 未熔断直接原串返回
  if (breakerCache.broken.length) {
    const cfg = applyBreaker(JSON.parse(row.json));
    res.set('Content-Type', 'application/json; charset=utf-8');
    res.send(JSON.stringify({ version: row.version, etag: effectiveEtag, config: cfg }));
  } else {
    res.set('Content-Type', 'application/json; charset=utf-8');
    res.send(`{"version":${row.version},"etag":${JSON.stringify(effectiveEtag)},"config":${row.json}}`);
  }
});

// 万象书屋灰度发布 admin 接口
//   PUT  /api/admin/ad-config/staging  body: {config: {...}, rolloutPct: 10}
//   POST /api/admin/ad-config/staging/commit  → 灰度完成, 主版本切到 staging
//   POST /api/admin/ad-config/staging/abort   → 取消灰度, 丢弃 staging
app.put('/api/admin/ad-config/staging', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    const { config, rolloutPct } = req.body || {};
    db.setAdConfigStaging(config, rolloutPct);
    db.recordAudit({
      ip: req.ip, action: 'ad_config.staging.set', target: req.admin.username,
      detail: { rolloutPct }
    });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ ok: false, error: e.message });
  }
});
app.post('/api/admin/ad-config/staging/commit', requireAdmin, requireRole(['super']), (req, res) => {
  try {
    db.commitAdConfigStaging();
    db.recordAudit({ ip: req.ip, action: 'ad_config.staging.commit', target: req.admin.username });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ ok: false, error: e.message });
  }
});
app.post('/api/admin/ad-config/staging/abort', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  db.abortAdConfigStaging();
  db.recordAudit({ ip: req.ip, action: 'ad_config.staging.abort', target: req.admin.username });
  res.json({ ok: true });
});

// === 万象书屋: 广告事件上报 (App 端埋点) ===
app.post('/api/ad-event', rateLimitAdEvent, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const b = req.body || {};
  try {
    db.recordAdEvent({
      placement: b.placement,
      provider: b.provider,
      type: b.type,
      errCode: b.errCode,
      errMsg: b.errMsg,
      deviceId: b.deviceId,
      appVer: b.appVer,
      platform: req.platform,                        // header 自动注入, 客户端不必每条都填
    });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

// 允许 App 一次 POST 多条 (节流后批量上报); 最多 50 条
app.post('/api/ad-events', rateLimitAdEvent, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const arr = Array.isArray(req.body) ? req.body : req.body?.events;
  if (!Array.isArray(arr)) return res.status(400).json({ ok: false, msg: 'array expected' });
  if (arr.length > 50) return res.status(400).json({ ok: false, msg: 'too many events' });
  // 万象书屋 D-11 修复: 批量失败时记一条 warn (含首条 reject 详情), 排障客户端 schema 漂移用.
  // 不打每条 reject (50 条都失败时不该刷屏 warn).
  let ok = 0, bad = 0;
  let firstError = null;
  let firstBadEvent = null;
  for (const e of arr) {
    try {
      // 给每条事件统一打上 req.platform; 防客户端 schema 漂移 (即使 e.platform 自带也以 header 为准)
      db.recordAdEvent({ ...e, platform: req.platform });
      ok++;
    } catch (err) {
      bad++;
      if (!firstError) {
        firstError = err.message;
        firstBadEvent = e;
      }
    }
  }
  if (bad > 0) {
    logger.warn('ad-events batch had rejected items', {
      t: req.traceId, accepted: ok, rejected: bad, total: arr.length,
      firstError,
      // 截短 sample, 不要把整个 event 都写进日志
      sampleEvent: firstBadEvent ? JSON.stringify(firstBadEvent).slice(0, 200) : null
    });
  }
  res.json({ ok: true, accepted: ok, rejected: bad, total: arr.length });
});

// ==================== 万象书屋: 自建埋点 ====================
// 设计:
//   客户端内存队列, 5 秒 / 50 条 / 切后台 触发批量 POST /api/events.
//   单条事件 schema: {ts, type, name, params, sessionId} - deviceId 走 X-Device-Id header.
//   后端只校验 schema 不校验业务语义 (event_name 可任意), 接受所有事件入库.
//   长期数据用 /api/admin/events/* 系列查询.
app.post('/api/events', rateLimitEvents, blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const arr = Array.isArray(req.body) ? req.body : req.body?.events;
  if (!Array.isArray(arr)) return res.status(400).json({ ok: false, msg: 'array expected' });
  if (arr.length === 0) return res.json({ ok: true, accepted: 0 });
  if (arr.length > 100) return res.status(400).json({ ok: false, msg: 'too many events (max 100)' });

  const did = req.get('X-Device-Id') || '';
  if (!did) return res.status(400).json({ ok: false, msg: 'X-Device-Id required' });

  let ok = 0, bad = 0;
  const valid = [];
  for (const e of arr) {
    if (!e || typeof e !== 'object') { bad++; continue; }
    if (!e.name || typeof e.name !== 'string') { bad++; continue; }
    valid.push({
      clientTs: e.ts,
      deviceId: did,
      platform: req.platform,
      // 万象书屋 D-16 (API-3): appVer/sessionId 优先取 envelope (req.body), 单条 fallback 仅历史兼容.
      // 当前 WanxiangAnalytics SDK 只在 envelope 顶层放, 不在每条 event 里放. 早期 schema 漂移
      // 的客户端可能在每条事件里也带 — 二选一不阻塞解析.
      appVer: req.body?.appVer || e.appVer,
      type: e.type || 'custom',
      name: e.name,
      params: e.params,
      sessionId: req.body?.sessionId || e.sessionId,
    });
  }
  try {
    ok = db.recordEventsBulk(valid, req.ip);
  } catch (err) {
    logger.error('event insert fail', { t: req.traceId, err: err.message });
    return res.status(500).json({ ok: false, msg: 'db insert failed' });
  }
  res.json({ ok: true, accepted: ok, rejected: bad });
});

// === 万象书屋: 埋点管理面板查询接口 ===

app.get('/api/admin/events/overview', requireAdmin, (req, res) => {
  res.json({ ok: true, ...db.eventOverview() });
});

app.get('/api/admin/events/top', requireAdmin, (req, res) => {
  const days = Math.max(1, Math.min(90, parseInt(req.query.days, 10) || 7));
  const limit = Math.max(1, Math.min(100, parseInt(req.query.limit, 10) || 20));
  const sinceTs = Date.now() - days * 86400 * 1000;
  res.json({
    ok: true, days, limit,
    items: db.eventTopList({ sinceTs, limit, type: req.query.type }),
  });
});

app.get('/api/admin/events/dau', requireAdmin, (req, res) => {
  const days = Math.max(1, Math.min(60, parseInt(req.query.days, 10) || 14));
  res.json({ ok: true, days, daily: db.eventDailyDau(days) });
});

app.get('/api/admin/events/recent', requireAdmin, (req, res) => {
  res.json({
    ok: true,
    items: db.listEvents({
      limit: req.query.limit,
      eventName: req.query.name,
      deviceId: req.query.deviceId,
      type: req.query.type,
    }),
  });
});

app.get('/api/admin/events/retention', requireAdmin, (req, res) => {
  // 万象书屋 D-16 (B-5): db.eventRetentionMatrix 内部 SELECT device_id,ts FROM events WHERE ts >= now-2*days,
  //   实测 90 天 events 表 (~50 万行) 单查询会阻塞 event loop ~1-2 秒.
  //   admin 看留存通常只关心最近 14-30 天, 把上限收到 30 (原来 60), 同时给运维指引文档.
  //   长期方案见 011_book_sources_idx.sql 的 events_cohort_daily 物化表 (D-17 计划).
  const days = Math.max(2, Math.min(30, parseInt(req.query.days, 10) || 14));
  res.json({ ok: true, ...db.eventRetentionMatrix(days) });
});

app.get('/api/admin/events/funnel', requireAdmin, (req, res) => {
  // 接受 ?steps=app_open,page_main,page_bookshelf,read_chapter_open
  const steps = (req.query.steps || '').split(',').map(s => s.trim()).filter(Boolean);
  if (!steps.length) return res.status(400).json({ ok: false, msg: 'steps required' });
  const days = Math.max(1, Math.min(60, parseInt(req.query.days, 10) || 7));
  const sinceTs = Date.now() - days * 86400 * 1000;
  const items = db.eventFunnel(steps, sinceTs);
  // 加转化率
  const enriched = items.map((s, i) => {
    const prev = items[0]?.uv || 0;
    const last = i > 0 ? items[i - 1].uv : prev;
    return {
      ...s,
      conversionFromFirst: prev ? +(s.uv / prev * 100).toFixed(1) : 0,
      conversionFromPrev:  last ? +(s.uv / last * 100).toFixed(1) : 0,
    };
  });
  res.json({ ok: true, days, steps: enriched });
});

// 万象书屋: 手动清除熔断 + 设保护期 (运维介入用).
// 适合场景: 业务侧已修复 (例如改了 ylh 平台包名), 想立刻让被熔断的 provider 重新上场.
// 接受 ?minutes=N (默认 30, 最大 360) 设保护期, 期间 breaker 强制为空, 让真实新流量产生数据;
// 保护期结束后熔断恢复正常计算, 如果错误率仍 >60% 会再次熔断.
// 万象书屋: admin 一键立即备份 (出 bug 前/部署前手动调一次, 拿到时间点最新的备份)
app.post('/api/admin/backup/now', requireAdmin, requireRole(['super']), async (req, res) => {
  try {
    await backupCtl.runBackupOnce();
    db.recordAudit({ ip: req.ip, action: 'backup.manual', target: req.admin.username, detail: {} });
    res.json({ ok: true, msg: 'backup triggered, see logs / data/backup folder' });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.post('/api/admin/breaker/reset', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const minutes = Math.max(1, Math.min(360, parseInt(req.query.minutes, 10) || 30));
  const before = breakerCache.broken.slice();
  breakerSuppressUntil = Date.now() + minutes * 60_000;
  db.kvSet(BREAKER_SUPPRESS_KV_KEY, breakerSuppressUntil);  // D-14: 持久化, 重启不丢
  breakerCache = { computedAt: Date.now(), broken: [] };
  db.recordAudit({
    ip: req.ip, action: 'breaker.reset', target: req.admin.username,
    detail: { previouslyBroken: before, suppressMinutes: minutes }
  });
  res.json({
    ok: true,
    previouslyBroken: before,
    suppressMinutes: minutes,
    suppressUntil: breakerSuppressUntil,
    msg: `breaker suppressed for ${minutes} minutes — all providers eligible during this window`
  });
});

// admin 看广告效果漏斗
app.get('/api/admin/ad-funnel', requireAdmin, (req, res) => {
  const hours = Math.max(1, Math.min(24 * 30, parseInt(req.query.hours, 10) || 24));
  res.json({
    ok: true,
    hours,
    funnel: db.adEventFunnel({ hours }),
    breaker: breakerCache,
  });
});

// === 万象书屋: 崩溃上报 (mini Sentry) ===
app.post('/api/crash-log', rateLimitCrash, blockBlacklistedDevice, verifyDeviceTokenStrict, (req, res) => {
  const b = req.body || {};
  if (!b.exception || !b.stack) return res.status(400).json({ ok: false, msg: 'exception & stack required' });
  // fingerprint: stack 第一行 + exception, md5, 用于聚合同类
  const firstFrame = String(b.stack).split('\n').slice(0, 3).join('\n');
  const fp = require('crypto').createHash('md5')
    .update(String(b.exception) + '|' + firstFrame).digest('hex').slice(0, 16);
  db.recordCrash({ ...b, fingerprint: fp, platform: req.platform });
  res.json({ ok: true });
});

app.get('/api/admin/crashes', requireAdmin, (req, res) => {
  const hours = Math.max(1, Math.min(24 * 90, parseInt(req.query.hours, 10) || 168));
  res.json({ ok: true, hours, list: db.listCrashSummary({ hours }) });
});

app.get('/api/admin/crashes/:fp', requireAdmin, (req, res) => {
  const list = db.listCrashesByFingerprint(req.params.fp, 20);
  res.json({ ok: true, list });
});

// === 万象书屋: 书源一键导出 ===
app.get('/api/admin/sources/export', requireAdmin, (req, res) => {
  // 返回所有书源的完整 JSON 数组, 下载成文件
  const rows = db.__db.prepare('SELECT json FROM book_sources ORDER BY updated_at DESC').all();
  const body = '[' + rows.map(r => r.json).join(',') + ']';
  const fname = `wanxiang-sources-${new Date().toISOString().slice(0,10)}.json`;
  res.set('Content-Type', 'application/json; charset=utf-8');
  res.set('Content-Disposition', `attachment; filename="${fname}"`);
  res.send(body);
  db.recordAudit({ ip: req.ip, action: 'source.export', target: `count=${rows.length}` });
});

// === 万象书屋: admin 审计日志 ===
app.get('/api/admin/audit-log', requireAdmin, (req, res) => {
  const limit = Math.max(10, Math.min(500, parseInt(req.query.limit, 10) || 200));
  res.json({ ok: true, list: db.listAuditLog({ limit }) });
});

// === 万象书屋: 用户反馈与举报 (公开 + admin) ===
app.post('/api/feedback', rateLimitFeedback, blockBlacklistedDevice, verifyDeviceTokenStrict, (req, res) => {
  const b = req.body || {};
  try {
    const r = db.recordFeedback({
      type: b.type,
      content: b.content,
      contact: b.contact,
      deviceId: b.deviceId,
      appVer: b.appVer,
      ip: req.ip,
      platform: req.platform,
    });
    res.json({ ok: true, id: r.id });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

app.get('/api/admin/feedback', requireAdmin, (req, res) => {
  const status = req.query.status || null;
  const limit = Math.max(10, Math.min(500, parseInt(req.query.limit, 10) || 200));
  res.json({
    ok: true,
    list: db.listFeedback({ status, limit }),
    stats: db.feedbackStats(),
  });
});

// === 万象书屋: iOS IAP 票据验证 (006_multi_platform) ===
// iOS 端在 StoreKit 完成购买后, 把 receipt-data 发后端, 后端转发苹果服务器验证.
// 前端不要自己信任 receipt — 必须服务端验, 苹果服务器返回的 status=0 才算有效.
//
// 苹果验证 URL:
//   生产: https://buy.itunes.apple.com/verifyReceipt
//   沙盒: https://sandbox.itunes.apple.com/verifyReceipt
//   苹果建议先打生产, 收到 status=21007 (sandbox receipt) 再打沙盒, 测试环境也能跑.
//
// 环境变量: APPLE_SHARED_SECRET — auto-renewable subscription 必填,
//   一次性 IAP 可不填. App Store Connect → 此 App → 应用专用共享密钥拿.
//
// 请求体 (App 发):
//   { product_id, transaction_id, receipt_data, original_tx_id?, sandbox? }
// 响应:
//   { ok, expires_at?, entitlement: 'adfree' | 'vip' | 'lifetime' | null }
const _IAP_PROD_URL = 'https://buy.itunes.apple.com/verifyReceipt';
const _IAP_SANDBOX_URL = 'https://sandbox.itunes.apple.com/verifyReceipt';
const _IAP_RATE = makeRateLimit({ windowMs: 60_000, max: 10, keyPrefix: 'iap:' });

// 万象书屋: 把 product_id 映射到业务 entitlement 名. iOS 内购 SKU 配:
//   com.wanxiang.adfree.lifetime  -> 'lifetime' 永久去广告
//   com.wanxiang.adfree.year      -> 'vip' 订阅 1 年去广告
//   com.wanxiang.adfree.month     -> 'vip' 订阅 1 月去广告
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
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body,
      signal: AbortSignal.timeout(10_000),  // 10s 超时, 苹果偶尔慢
    });
    return r.json();
  };

  // 流程: 默认打生产; 苹果返 21007 时改打沙盒. (App 端 build 是 sandbox 测试时反过来一样)
  let firstUrl = sandboxFirst ? _IAP_SANDBOX_URL : _IAP_PROD_URL;
  let resp = await tryUrl(firstUrl);
  if (resp.status === 21007 && firstUrl === _IAP_PROD_URL) {
    resp = await tryUrl(_IAP_SANDBOX_URL);
    resp.__sandbox = true;
  } else if (resp.status === 21008 && firstUrl === _IAP_SANDBOX_URL) {
    // 沙盒收据发到生产 — 反向兜底
    resp = await tryUrl(_IAP_PROD_URL);
  } else if (firstUrl === _IAP_SANDBOX_URL) {
    resp.__sandbox = true;
  }
  return resp;
}

// 万象书屋: /api/iap/verify (iOS 内购验证) 已默认禁用.
// 当前业务无内购需求, 路由暴露在外只增加攻击面 (Apple receipt 解析涉及外部 HTTPS 调用,
// 大流量伪造请求可能造成 SSRF/慢请求问题). 实现保留在文件下方 _verifyAppleReceipt() 等
// 私有函数里, 想启用只需把下面 if (true) return 404; 那一行删除.
app.post('/api/iap/verify', _IAP_RATE, blockBlacklistedDevice, verifyDeviceToken, async (req, res) => {
  if (true) return res.status(404).json({ ok: false, msg: 'not found' });
  // eslint-disable-next-line no-unreachable
  if (req.platform !== 'ios') {
    return res.status(400).json({ ok: false, msg: 'iap is iOS-only' });
  }
  const b = req.body || {};
  const did = b.device_id || b.deviceId || req.get('X-Device-Id');
  const productId = b.product_id || b.productId;
  const transactionId = b.transaction_id || b.transactionId;
  const originalTxId = b.original_tx_id || b.originalTxId || null;
  const receiptData = b.receipt_data || b.receiptData;
  const sandbox = !!(b.sandbox);

  if (!did || !productId || !transactionId || !receiptData) {
    return res.status(400).json({
      ok: false,
      msg: 'device_id / product_id / transaction_id / receipt_data required'
    });
  }
  if (typeof receiptData !== 'string' || receiptData.length > 100_000) {
    return res.status(400).json({ ok: false, msg: 'invalid receipt_data' });
  }

  try {
    const apple = await _verifyAppleReceipt(receiptData, sandbox);
    if (apple.status !== 0) {
      logger.warn('iap apple reject', {
        t: req.traceId, did: String(did).slice(0, 12),
        productId, status: apple.status,
      });
      return res.status(402).json({ ok: false, msg: 'apple status=' + apple.status });
    }

    // 解析 latest_receipt_info / receipt.in_app — 找匹配 transaction_id 的那条
    const allTx = [
      ...(apple.latest_receipt_info || []),
      ...((apple.receipt && apple.receipt.in_app) || []),
    ];
    const tx = allTx.find(t => t.transaction_id === transactionId);
    if (!tx) {
      return res.status(400).json({ ok: false, msg: 'transaction_id not in apple response' });
    }

    // 订阅: expires_date_ms; 一次性: 没有 expires_date_ms (永久买断)
    const expiresAt = tx.expires_date_ms ? Number(tx.expires_date_ms) : null;
    const isExpired = expiresAt != null && expiresAt < Date.now();

    db.saveIapReceipt({
      deviceId: did,
      productId,
      transactionId,
      originalTxId: originalTxId || tx.original_transaction_id || null,
      receiptData,
      expiresAt,
      sandbox: !!apple.__sandbox,
      status: isExpired ? 'expired' : 'active',
      rawResponse: JSON.stringify(apple).slice(0, 50_000),
    });
    db.recordAudit({
      ip: req.ip,
      action: 'iap.verify',
      target: productId + ':' + transactionId,
      detail: { sandbox: !!apple.__sandbox, expiresAt, did: String(did).slice(0, 12) }
    });

    const entitlement = _mapProductIdToEntitlement(productId);
    res.json({
      ok: true,
      product_id: productId,
      transaction_id: transactionId,
      expires_at: expiresAt,
      entitlement,
      sandbox: !!apple.__sandbox,
    });
  } catch (e) {
    logger.error('iap verify error', { t: req.traceId, e: e.message });
    res.status(502).json({ ok: false, msg: 'apple verify failed: ' + e.message });
  }
});

// 设备 entitlement 查询: 客户端拉本设备当前所有有效内购 (启动 + 进入"我的"时调一次)
// 不需要 X-Platform 限制 (Android 设备不会有 IAP, 自动返空数组, 无害)
app.get('/api/iap/entitlements', blockBlacklistedDevice, verifyDeviceToken, (req, res) => {
  const did = req.get('X-Device-Id') || req.query.device_id;
  if (!did) return res.status(400).json({ ok: false, msg: 'device_id required' });
  const list = db.listActiveIapForDevice(String(did));
  const entitlements = Array.from(new Set(
    list.map(r => _mapProductIdToEntitlement(r.product_id)).filter(Boolean)
  ));
  res.json({
    ok: true,
    entitlements,
    receipts: list.map(r => ({
      product_id: r.product_id,
      expires_at: r.expires_at,
      verified_at: r.verified_at,
      sandbox: !!r.sandbox,
    }))
  });
});

app.patch('/api/admin/feedback/:id', requireAdmin, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const { status, reply } = req.body || {};
  if (!id) return res.status(400).json({ ok: false, msg: 'invalid id' });
  try {
    db.updateFeedbackStatus(id, status, reply);
    db.recordAudit({ ip: req.ip, action: 'feedback.update', target: `id=${id}`, detail: { status } });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ ok: false, msg: e.message });
  }
});

app.get('/api/admin/ad-config', requireAdmin, (req, res) => {
  // 万象书屋: 用 getAdConfigRaw, 返回未经 _applySoloProvider 处理的原始 weight,
  // 否则 admin 表单加载 → 保存会把 weight 永久污染成 0.
  const row = db.getAdConfigRaw();
  res.json({
    version: row.version,
    etag: row.etag,
    config: JSON.parse(row.json)
  });
});

// 万象书屋 D-16 (B-4): 广告配置改写仅 super/operator (灰度 + commit 已限 super)
app.post('/api/admin/ad-config', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    const body = req.body;
    if (!body || typeof body !== 'object') {
      return res.status(400).json({ ok: false, msg: 'JSON object expected' });
    }
    const r = db.saveAdConfig(body);
    db.recordAudit({ ip: req.ip, action: 'ad.save', target: `v${r.version}` });
    res.json({ ok: true, ...r });
  } catch (err) {
    res.status(400).json({ ok: false, msg: err.message || 'invalid ad config' });
  }
});

app.get('/api/admin/ad-config/history', requireAdmin, (req, res) => {
  res.json(db.listAdConfigHistory(30));
});

app.get('/api/admin/ad-config/version/:v', requireAdmin, (req, res) => {
  const v = parseInt(req.params.v, 10);
  if (!Number.isFinite(v)) return res.status(400).json({ ok: false });
  const row = db.getAdConfigByVersion(v);
  if (!row) return res.status(404).json({ ok: false });
  res.json({ version: row.version, createdAt: row.created_at, config: JSON.parse(row.json) });
});

// === 万象书屋 v2: 强制升级 / 公告 / 黑名单 / 多管理员 / 兑换码 / 告警 admin 接口 ===

// --- 强制升级 ---
app.get('/api/admin/version', requireAdmin, (req, res) => {
  res.json({ ok: true, data: db.getAppVersion() });
});

app.post('/api/admin/version', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    db.saveAppVersion(req.body || {});
    db.recordAudit({ ip: req.ip, action: 'version.save', target: String(req.body?.latest_code), detail: req.admin });
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});

// --- 公告 ---
app.get('/api/admin/announcements', requireAdmin, (req, res) => {
  res.json({ ok: true, list: db.listAllAnnouncements() });
});

app.post('/api/admin/announcement', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    const id = db.upsertAnnouncement(req.body || {});
    db.recordAudit({ ip: req.ip, action: 'announcement.upsert', target: `id=${id}`, detail: { by: req.admin.username } });
    res.json({ ok: true, id });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});

app.delete('/api/admin/announcement/:id', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  db.deleteAnnouncement(req.params.id);
  db.recordAudit({ ip: req.ip, action: 'announcement.delete', target: req.params.id, detail: { by: req.admin.username } });
  res.json({ ok: true });
});

// --- 设备黑名单 ---
app.get('/api/admin/blacklist', requireAdmin, (req, res) => {
  res.json({ ok: true, list: db.listBlockedDevices() });
});

app.post('/api/admin/blacklist', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { deviceId, reason } = req.body || {};
  try {
    db.blockDevice(deviceId, reason, req.admin.username);
    db.recordAudit({ ip: req.ip, action: 'device.block', target: deviceId, detail: { reason, by: req.admin.username } });
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});

app.delete('/api/admin/blacklist/:deviceId', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  db.unblockDevice(req.params.deviceId);
  db.recordAudit({ ip: req.ip, action: 'device.unblock', target: req.params.deviceId, detail: { by: req.admin.username } });
  res.json({ ok: true });
});

// --- 多管理员 (super 独占) ---
app.get('/api/admin/users', requireAdmin, requireRole('super'), (req, res) => {
  res.json({ ok: true, list: db.listAdminUsers() });
});

app.post('/api/admin/users', requireAdmin, requireRole('super'), async (req, res) => {
  const { username, password, role } = req.body || {};
  try {
    await db.createAdminUser({ username, password, role, creator: req.admin.username });
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});

app.post('/api/admin/users/:username/password', requireAdmin, async (req, res) => {
  const { newPassword } = req.body || {};
  // super 可改任何人, 其他人只能改自己的密码
  if (req.admin.role !== 'super' && req.admin.username !== req.params.username) {
    return res.status(403).json({ ok: false, msg: 'can only change your own password' });
  }
  try {
    await db.updateAdminPassword(req.params.username, newPassword);
    db.destroyAllSessions();  // 强制所有 session 重登
    db.recordAudit({ ip: req.ip, action: 'admin.user.passwd', target: req.params.username, detail: { by: req.admin.username } });
    res.json({ ok: true });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});

app.delete('/api/admin/users/:username', requireAdmin, requireRole('super'), (req, res) => {
  if (req.params.username === req.admin.username) {
    return res.status(400).json({ ok: false, msg: 'cannot delete yourself' });
  }
  db.deleteAdminUser(req.params.username);
  db.recordAudit({ ip: req.ip, action: 'admin.user.delete', target: req.params.username, detail: { by: req.admin.username } });
  res.json({ ok: true });
});

// --- 2FA: 当前用户开启/关闭 ---
app.post('/api/admin/2fa/setup', requireAdmin, (req, res) => {
  const username = req.admin.username;
  if (username === 'legacy') {
    return res.status(400).json({ ok: false, msg: 'legacy single-admin cannot use 2FA, please create admin_users first' });
  }
  // 生成 secret + otpauth url, 前端二维码展示, verify 时再持久化
  const secret = totpGenerateSecret();
  const otpauthUrl = totpGenerateUri(username, '万象书屋', secret);
  // 暂存到内存 (5 分钟过期)
  pendingTotpSecrets.set(username, { secret, ts: Date.now() });
  res.json({ ok: true, secret, otpauthUrl });
});

app.post('/api/admin/2fa/verify', requireAdmin, (req, res) => {
  const username = req.admin.username;
  const { code } = req.body || {};
  const pending = pendingTotpSecrets.get(username);
  if (!pending || Date.now() - pending.ts > 5 * 60_000) {
    pendingTotpSecrets.delete(username);
    return res.status(400).json({ ok: false, msg: 'setup expired, please call /2fa/setup again' });
  }
  if (!totpVerify(code, pending.secret)) {
    return res.status(400).json({ ok: false, msg: 'wrong code' });
  }
  db.setAdminTotpSecret(username, pending.secret, true);
  pendingTotpSecrets.delete(username);
  db.recordAudit({ ip: req.ip, action: 'admin.2fa.enable', target: username });
  res.json({ ok: true });
});

app.post('/api/admin/2fa/disable', requireAdmin, async (req, res) => {
  // 万象书屋: 关闭 2FA 必须验证当前 TOTP code, 防止 session 被偷后被静默关 2FA
  const username = req.admin.username;
  const { totp } = req.body || {};
  if (username === 'legacy') {
    return res.status(400).json({ ok: false, msg: 'legacy admin has no 2FA' });
  }
  const user = db.__db.prepare('SELECT totp_secret, totp_enabled FROM admin_users WHERE username=?').get(username);
  if (!user || !user.totp_enabled) {
    return res.status(400).json({ ok: false, msg: '2FA not enabled' });
  }
  if (!totp || !totpVerify(totp, user.totp_secret)) {
    return res.status(401).json({ ok: false, msg: 'invalid totp code, cannot disable 2FA' });
  }
  db.setAdminTotpSecret(username, null, false);
  db.recordAudit({ ip: req.ip, action: 'admin.2fa.disable', target: username });
  res.json({ ok: true });
});

// 暂存待验证的 TOTP secret
const pendingTotpSecrets = new Map();
setInterval(() => {
  const cutoff = Date.now() - 5 * 60_000;
  for (const [k, v] of pendingTotpSecrets) if (v.ts < cutoff) pendingTotpSecrets.delete(k);
}, 60_000).unref?.();

// --- 兑换码 ---
app.get('/api/admin/redeem-codes', requireAdmin, (req, res) => {
  const batch = req.query.batch || null;
  res.json({ ok: true, list: db.listRedeemCodes({ batch }) });
});

app.post('/api/admin/redeem-codes', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  try {
    const codes = db.createRedeemCodes({ ...(req.body || {}), creator: req.admin.username });
    db.recordAudit({ ip: req.ip, action: 'redeem.create', target: `count=${codes.length}`, detail: { batch: req.body?.batch, by: req.admin.username } });
    res.json({ ok: true, codes });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});

app.post('/api/admin/redeem-codes/revoke-batch', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
  const { batch } = req.body || {};
  if (!batch) return res.status(400).json({ ok: false, msg: 'batch required' });
  const n = db.revokeRedeemBatch(batch);
  db.recordAudit({ ip: req.ip, action: 'redeem.revoke', target: batch, detail: { count: n } });
  res.json({ ok: true, revoked: n });
});

// --- 告警规则 ---
app.get('/api/admin/alerts', requireAdmin, (req, res) => {
  res.json({ ok: true, list: db.listAlertRules() });
});

app.post('/api/admin/alert', requireAdmin, requireRole('super'), (req, res) => {
  try {
    const id = db.upsertAlertRule(req.body || {});
    res.json({ ok: true, id });
  } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
});

app.delete('/api/admin/alert/:id', requireAdmin, requireRole('super'), (req, res) => {
  db.deleteAlertRule(req.params.id);
  res.json({ ok: true });
});

// === 静态管理面板 ===
app.use(express.static(path.join(__dirname, 'public')));
// 兜底:管理面板路由都返回 admin.html (SPA)
app.get(['/admin', '/admin/*'], (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});
app.get('/', (req, res) => res.redirect('/admin'));

// 万象书屋: 全局兜底错误处理, 把 body-parser 等中间件抛出的异常 (例如 JSON 解析失败)
// 转成简短 JSON, 避免把 stack trace / 文件路径泄露到客户端
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  const status = err.status || (err.type === 'entity.parse.failed' ? 400 : 500);
  logger.error('request error', { method: req.method, url: req.url, status, msg: err.message });
  res.status(status).json({ ok: false, msg: err.message || 'server error' });
});

// 万象书屋: 拆出 app 给测试用. require('./server.js') 时不会 listen,
// 直接执行 (node server.js) 或主入口才启动 HTTP 服务.
let server = null;
function start() {
  server = app.listen(PORT, () => {
    logger.info('backend listening', { port: PORT, admin: `http://0.0.0.0:${PORT}/admin` });
  });
  scheduleMirrorJob();
  process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
  process.on('SIGINT', () => gracefulShutdown('SIGINT'));
  return server;
}

// =============================================================================
// 万象书屋 D-23: 书城 mirror cron 调度
// =============================================================================
//
// 用 setTimeout 自己排, 不引入 node-cron 新依赖.
// 策略: 每天 00:00-07:00 随机一个时刻触发抓取.
//   - 半夜起点服务器低峰, 抓得稳, 也不打扰白天用户使用
//   - 随机时间避免每天固定 hh:mm 太规律被起点反爬识别
//
// 启动时:
//   1. 算"下一次执行的时刻": 如果当前时间 < 今天 7:00, 就在剩余窗口里随机;
//      否则在明天 0:00-7:00 里随机
//   2. setTimeout 到那个时刻执行 fetchAndCache, 之后再调度下一天
//   3. 服务进程崩溃重启后会重新算, 不会重复跑
//
// 启动后还做一次"冷启抓取":
//   如果 DB 里完全没 cache (新装), 立刻执行一次, 不等到半夜
let _nextMirrorRunAt = null;
let _mirrorTimer = null;

function scheduleMirrorJob() {
  // 启动时如果 cache 全空, 立刻抓一次, 让首次启动的用户能立即用上 mirror
  setTimeout(async () => {
    if (!db.getLatestBookstoreMirror()) {
      logger.info('mirror: empty cache on boot, kick off initial fetch');
      try {
        const r = await qidianMirror.fetchAndCache(db);
        logger.info('mirror: initial fetch ok', r);
      } catch (e) {
        qidianMirror.recordFailure(db, e);
        logger.warn('mirror: initial fetch failed', { msg: e.message });
      }
    }
  }, 5_000);  // 5s 后跑, 不阻塞启动

  scheduleNextMirrorRun();
}

function scheduleNextMirrorRun() {
  if (_mirrorTimer) clearTimeout(_mirrorTimer);

  // 计算下一次抓取时刻: 0:00-7:00 之间随机
  const now = new Date();
  const target = new Date(now);
  target.setHours(0, 0, 0, 0);  // 今天 0:00
  // 0~7h 内随机毫秒数 (含 0, 不含 7h)
  const randomMs = Math.floor(Math.random() * 7 * 3600 * 1000);
  target.setTime(target.getTime() + randomMs);

  // 如果今天的随机时刻已过, 排到明天的随机时刻
  if (target.getTime() <= now.getTime()) {
    target.setDate(target.getDate() + 1);
    target.setHours(0, 0, 0, 0);
    target.setTime(target.getTime() + Math.floor(Math.random() * 7 * 3600 * 1000));
  }

  const delayMs = target.getTime() - now.getTime();
  _nextMirrorRunAt = target.toISOString();
  logger.info('mirror: next run scheduled', { at: _nextMirrorRunAt, delayMin: Math.round(delayMs / 60_000) });

  _mirrorTimer = setTimeout(async () => {
    try {
      const r = await qidianMirror.fetchAndCache(db);
      logger.info('mirror: scheduled fetch ok', r);
    } catch (e) {
      qidianMirror.recordFailure(db, e);
      logger.warn('mirror: scheduled fetch failed', { msg: e.message });
    } finally {
      // 每次跑完重新调度下一天
      scheduleNextMirrorRun();
    }
  }, delayMs);
  _mirrorTimer.unref?.();  // 不阻塞进程退出
}

// 万象书屋: 优雅关闭. SIGTERM (systemd stop / docker stop) + SIGINT (Ctrl+C) 时
// 先停止接收新连接, 等已有请求 10s 结束, 再关 db 退出
// 避免写入一半的 transaction / WAL 文件不干净
function gracefulShutdown(signal) {
  logger.info('shutting down', { signal });
  const forceExitTimer = setTimeout(() => {
    logger.error('force exit after 10s');
    process.exit(1);
  }, 10_000);
  forceExitTimer.unref();
  if (!server) { try { db.__db.close(); } catch {} return process.exit(0); }
  server.close(err => {
    if (err) {
      logger.error('http close error', { msg: err.message });
      process.exit(1);
    }
    try { db.__db.close(); } catch (e) { logger.error('db close error', { msg: e.message }); }
    logger.info('shutdown complete');
    process.exit(0);
  });
}

// 直接运行 (node server.js) 或 npm start 才启动监听
// 测试 (require('./server.js')) 不监听
if (require.main === module) {
  start();
}

module.exports = { app, start, gracefulShutdown };
