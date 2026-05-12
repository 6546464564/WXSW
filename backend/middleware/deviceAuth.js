// 万象书屋: 设备 token 校验 / 黑名单 / 未注册配额

const crypto = require('crypto');
const logger = require('../logger');

let db; // 由 setup() 注入

const UNREG_PER_IP_LIMIT = parseInt(process.env.UNREG_PER_IP_LIMIT, 10) || 60;
const UNREG_WINDOW_MS = 60_000;
const _unregByIp = new Map();

function _checkUnregisteredQuota(ip, did) {
  const now = Date.now();
  let bucket = _unregByIp.get(ip);
  if (!bucket || now - bucket.ts > UNREG_WINDOW_MS) {
    bucket = { ts: now, dids: new Set() };
    _unregByIp.set(ip, bucket);
  }
  bucket.dids.add(did);
  if (_unregByIp.size > 5000) {
    for (const [k, v] of _unregByIp) {
      if (now - v.ts > UNREG_WINDOW_MS) _unregByIp.delete(k);
    }
  }
  return bucket.dids.size <= UNREG_PER_IP_LIMIT;
}

function setup(database) {
  db = database;
}

function blockBlacklistedDevice(req, res, next) {
  const did = (req.body && req.body.device_id) ||
              (req.body && req.body.deviceId) ||
              req.get('X-Device-Id');
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

function verifyDeviceToken(req, res, next) {
  const did = (req.body && (req.body.device_id || req.body.deviceId)) ||
              req.get('X-Device-Id');
  if (!did) return next();
  if (typeof did !== 'string' || did.length === 0 || did.length > 128) {
    return res.status(400).json({ ok: false, msg: 'invalid device_id' });
  }
  const expected = db.getDeviceTokenHash(did);
  if (!expected) {
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
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  const ok = a.length === b.length && crypto.timingSafeEqual(a, b);
  if (!ok) {
    logger.warn('device token mismatch', { t: req.traceId, did: did.slice(0, 12) });
    return res.status(401).json({ ok: false, msg: 'device token invalid' });
  }
  db.touchDeviceSeen(did);
  next();
}

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

module.exports = {
  setup, blockBlacklistedDevice, verifyDeviceToken, verifyDeviceTokenStrict,
};
