// 万象书屋: admin 认证中间件 + login 限速

let db; // 由 setup() 注入

// 内存级 login 限速
const loginAttempts = new Map();

function setup(database) {
  db = database;

  // 定时清理过期 lock 记录
  setInterval(() => {
    const cutoff = Date.now() - 60 * 60 * 1000;
    for (const [ip, slot] of loginAttempts.entries()) {
      if ((slot.lockedUntil || 0) < cutoff && (slot.firstTs || 0) < cutoff) {
        loginAttempts.delete(ip);
      }
    }
  }, 30 * 60 * 1000).unref?.();
}

function loginRateLimit(req, res, next) {
  const ip = req.ip || req.connection?.remoteAddress || 'unknown';
  const now = Date.now();
  const WINDOW_MS = 60 * 1000;
  const MAX_FAILS = 5;
  const LOCK_MS = 5 * 60 * 1000;
  const slot = loginAttempts.get(ip);
  if (slot && slot.lockedUntil && slot.lockedUntil > now) {
    return res.status(429).json({ ok: false, msg: 'too many attempts, try later' });
  }
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

function requireAdmin(req, res, next) {
  const tok = req.cookies && req.cookies.adm;
  const meta = db.isValidSession(tok, req.get('User-Agent') || '', true);
  if (meta && meta.ok) {
    req.admin = { username: meta.username || 'legacy', role: meta.role || 'super' };
    return next();
  }
  return res.status(401).json({ ok: false, msg: 'unauthorized' });
}

function requireRole(roles) {
  const allowed = Array.isArray(roles) ? new Set(roles) : new Set([roles]);
  return (req, res, next) => {
    const role = req.admin?.role || 'super';
    if (allowed.has(role)) return next();
    return res.status(403).json({ ok: false, msg: 'role denied: need ' + [...allowed].join('/') });
  };
}

module.exports = {
  setup, loginRateLimit, recordLoginResult, requireAdmin, requireRole,
};
