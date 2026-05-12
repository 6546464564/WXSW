// 万象书屋: admin 认证 / 多用户 / session / 登录锁定

const bcrypt = require('bcryptjs');

let db;
let BCRYPT_COST;
let stmtGetAdminPwd, stmtUpdateAdminPwd;
let stmtCreateSession, stmtGetSession, stmtDeleteSession, stmtDeleteAllSessions;
let stmtRecordLoginFail, stmtCountLoginFail, stmtClearLoginFail, stmtLatestLoginFailTs;
let _DUMMY_PWD_HASH;

function init(database, bcryptCost) {
  db = database;
  BCRYPT_COST = bcryptCost;

  stmtGetAdminPwd = db.prepare('SELECT pwd_hash FROM admin WHERE id = 1');
  stmtUpdateAdminPwd = db.prepare('UPDATE admin SET pwd_hash=?, updated_at=? WHERE id=1');
  stmtCreateSession = db.prepare(
    'INSERT INTO admin_session(token, created_at, ip, ua_hash, username, role) VALUES (?, ?, ?, ?, ?, ?)'
  );
  stmtGetSession = db.prepare('SELECT created_at, ua_hash, username, role FROM admin_session WHERE token = ?');
  stmtDeleteSession = db.prepare('DELETE FROM admin_session WHERE token = ?');
  stmtDeleteAllSessions = db.prepare('DELETE FROM admin_session');

  stmtRecordLoginFail = db.prepare('INSERT INTO admin_login_failures (username, ip, ts) VALUES (?, ?, ?)');
  stmtCountLoginFail = db.prepare('SELECT COUNT(*) AS n FROM admin_login_failures WHERE username = ? AND ts > ?');
  stmtClearLoginFail = db.prepare('DELETE FROM admin_login_failures WHERE username = ?');
  stmtLatestLoginFailTs = db.prepare('SELECT MAX(ts) AS t FROM admin_login_failures WHERE username = ? AND ts > ?');

  _DUMMY_PWD_HASH = bcrypt.hashSync(
    'dummy-' + require('crypto').randomBytes(32).toString('hex'),
    BCRYPT_COST
  );
}

function uaHash(ua) {
  if (!ua) return '';
  return require('crypto').createHash('sha256').update(ua).digest('hex').slice(0, 16);
}

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

function createSession(ip = '', ua = '', meta = {}) {
  const token = require('crypto').randomBytes(24).toString('hex');
  stmtCreateSession.run(token, Date.now(), ip || '', uaHash(ua), meta.username || null, meta.role || null);
  return token;
}

function isValidSession(token, ua = '', returnMeta = false) {
  if (!token) return returnMeta ? null : false;
  const row = stmtGetSession.get(token);
  if (!row) return returnMeta ? null : false;
  if (Date.now() - row.created_at >= 7 * 86400 * 1000) return returnMeta ? null : false;
  if (row.ua_hash && ua && row.ua_hash !== uaHash(ua)) return returnMeta ? null : false;
  if (returnMeta) return { ok: true, username: row.username, role: row.role };
  return true;
}

function destroySession(token) { stmtDeleteSession.run(token); }
function destroyAllSessions() { stmtDeleteAllSessions.run(); }

// --- 多管理员 ---

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
}

async function verifyAdminUser(username, password) {
  if (!username || !password) return null;
  const row = db.prepare('SELECT * FROM admin_users WHERE username=?').get(username);
  if (!row) {
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

// --- 登录锁定 ---

function recordLoginFailure(username, ip) {
  stmtRecordLoginFail.run(username || '?', ip || null, Date.now());
}

function clearLoginFailures(username) {
  stmtClearLoginFail.run(username || '?');
}

function isAccountLocked(username, opt = {}) {
  const windowMin = opt.windowMin || 5;
  const threshold = opt.threshold || 5;
  const lockMin = opt.lockMin || 30;
  const since = Date.now() - windowMin * 60_000;
  const r = stmtCountLoginFail.get(username || '?', since);
  if (!r || r.n < threshold) return { locked: false };
  const t = stmtLatestLoginFailTs.get(username || '?', since);
  const lastTs = t ? t.t : Date.now();
  const unlockAt = lastTs + lockMin * 60_000;
  if (Date.now() > unlockAt) return { locked: false };
  return { locked: true, unlock_at: unlockAt };
}

module.exports = {
  init, verifyAdminPassword, verifyAdminPasswordSync, setAdminPassword,
  createSession, isValidSession, destroySession, destroyAllSessions,
  createAdminUser, verifyAdminUser, listAdminUsers, updateAdminPassword,
  deleteAdminUser, setAdminTotpSecret, recordAdminLogin,
  recordLoginFailure, clearLoginFailures, isAccountLocked,
};
