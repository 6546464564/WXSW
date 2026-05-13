// 万象书屋: IP 维度滑动窗口限速

const RATE_LIMIT_DISABLED = process.env.NODE_ENV === 'test' || process.env.DISABLE_RATE_LIMIT === '1';
if (process.env.DISABLE_RATE_LIMIT === '1' && process.env.NODE_ENV === 'production') {
  console.warn('[security] WARNING: DISABLE_RATE_LIMIT=1 in production, all rate limits OFF!');
}

const _allBuckets = [];
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

const MAX_BUCKET_SIZE = 50_000;

function makeRateLimit({ windowMs, max, keyPrefix = '' }) {
  if (RATE_LIMIT_DISABLED) return (req, res, next) => next();
  const bucket = new Map();
  _allBuckets.push({ bucket, windowMs });
  _startGlobalSweeper();
  return (req, res, next) => {
    const ip = req.ip || 'unknown';
    const key = keyPrefix + ip;
    const now = Date.now();
    const slot = bucket.get(key);
    if (!slot || now - slot.firstTs > windowMs) {
      if (bucket.size >= MAX_BUCKET_SIZE) {
        const cutoff = now - windowMs;
        for (const [k, v] of bucket) { if (v.firstTs < cutoff) bucket.delete(k); }
        if (bucket.size >= MAX_BUCKET_SIZE) bucket.clear();
      }
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

// 预定义各路由限速实例
const rateLimitSources     = makeRateLimit({ windowMs: 60_000, max: 10, keyPrefix: 's:' });
const rateLimitPing        = makeRateLimit({ windowMs: 10_000, max: 3, keyPrefix: 'p:' });
const rateLimitAdConfig    = makeRateLimit({ windowMs: 5_000, max: 3, keyPrefix: 'a:' });
const rateLimitAdEvent     = makeRateLimit({ windowMs: 3_000, max: 5, keyPrefix: 'e:' });
const rateLimitCrash       = makeRateLimit({ windowMs: 60_000, max: 3, keyPrefix: 'c:' });
const rateLimitEvents      = makeRateLimit({ windowMs: 5_000, max: 3, keyPrefix: 'ev:' });
const rateLimitFeedback    = makeRateLimit({ windowMs: 5 * 60_000, max: 5, keyPrefix: 'f:' });
const rateLimitSourceError = makeRateLimit({ windowMs: 30_000, max: 100, keyPrefix: 'se:' });
const rateLimitRedeem      = makeRateLimit({ windowMs: 60_000, max: 5, keyPrefix: 'r:' });

module.exports = {
  makeRateLimit,
  rateLimitSources, rateLimitPing, rateLimitAdConfig,
  rateLimitAdEvent, rateLimitCrash, rateLimitEvents,
  rateLimitFeedback, rateLimitSourceError, rateLimitRedeem,
};
