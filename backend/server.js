// 万象书屋后端 - Express 入口
const express = require('express');
const cookieParser = require('cookie-parser');
const path = require('path');
const fs = require('fs');
const db = require('./db');

const PORT = parseInt(process.env.PORT || '3000', 10);
const app = express();

// db.init() 已在 db.js 加载时执行（须在 prepare 语句之前建表）
// 30 分钟清一次老数据
setInterval(() => db.cleanupOldData(), 30 * 60 * 1000);

app.use(express.json({ limit: '50mb' }));
app.use(express.text({ limit: '50mb', type: 'text/*' }));
app.use(cookieParser());

// === 公共 API（App 端调用，无需登录） ===

// App 拉取书源列表
app.get('/api/sources', (req, res) => {
  res.set('Cache-Control', 'no-store');
  res.json(db.listEnabledSourcesJson());
});

// App 心跳 + 访问统计上报
app.post('/api/ping', (req, res) => {
  const deviceId =
    (req.body && typeof req.body.device_id === 'string' && req.body.device_id) ||
    req.get('X-Device-Id') ||
    null;
  if (!deviceId) return res.status(400).json({ ok: false, msg: 'device_id required' });
  db.recordPing(deviceId);
  res.json({ ok: true });
});

// === 管理 API ===

function requireAdmin(req, res, next) {
  const tok = req.cookies && req.cookies.adm;
  if (db.isValidSession(tok)) return next();
  return res.status(401).json({ ok: false, msg: 'unauthorized' });
}

app.post('/api/admin/login', (req, res) => {
  const pwd = req.body && req.body.password;
  if (!db.verifyAdminPassword(pwd)) {
    return res.status(401).json({ ok: false, msg: 'wrong password' });
  }
  const token = db.createSession();
  res.cookie('adm', token, {
    httpOnly: true, sameSite: 'strict',
    maxAge: 7 * 86400 * 1000,
    secure: !!process.env.SECURE_COOKIE
  });
  res.json({ ok: true });
});

app.post('/api/admin/logout', requireAdmin, (req, res) => {
  db.destroySession(req.cookies.adm);
  res.clearCookie('adm');
  res.json({ ok: true });
});

app.post('/api/admin/password', requireAdmin, (req, res) => {
  const { oldPassword, newPassword } = req.body || {};
  if (!db.verifyAdminPassword(oldPassword)) {
    return res.status(401).json({ ok: false, msg: 'wrong old password' });
  }
  if (!newPassword || newPassword.length < 6) {
    return res.status(400).json({ ok: false, msg: 'new password too short' });
  }
  db.setAdminPassword(newPassword);
  res.json({ ok: true });
});

// 检查登录态（前端用来判断要不要跳登录页）
app.get('/api/admin/me', (req, res) => {
  const tok = req.cookies && req.cookies.adm;
  res.json({ ok: db.isValidSession(tok) });
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

app.post('/api/admin/sources', requireAdmin, (req, res) => {
  // 接受单个对象 或 数组
  const body = req.body;
  if (Array.isArray(body)) {
    const r = db.bulkUpsert(body);
    return res.json({ ok: true, ...r });
  }
  if (body && typeof body === 'object') {
    return res.json({ ok: true, ...db.upsertSource(body) });
  }
  res.status(400).json({ ok: false, msg: 'JSON object or array expected' });
});

app.delete('/api/admin/sources', requireAdmin, (req, res) => {
  const url = req.query.url;
  if (!url) return res.status(400).json({ ok: false });
  const n = db.deleteSource(url);
  res.json({ ok: true, deleted: n });
});

app.patch('/api/admin/sources/enabled', requireAdmin, (req, res) => {
  const { url, enabled } = req.body || {};
  if (!url) return res.status(400).json({ ok: false });
  db.setEnabled(url, !!enabled);
  res.json({ ok: true });
});

app.get('/api/admin/stats', requireAdmin, (req, res) => {
  res.json({
    online: db.statsOnline(),
    today: db.statsToday(),
    week: db.statsWeek(),
    month: db.statsMonth(),
    daily: db.statsDailyCurve(7),
  });
});

// === 静态管理面板 ===
app.use(express.static(path.join(__dirname, 'public')));
// 兜底:管理面板路由都返回 admin.html (SPA)
app.get(['/admin', '/admin/*'], (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});
app.get('/', (req, res) => res.redirect('/admin'));

app.listen(PORT, () => {
  console.log(`[wanxiang] backend listening on http://0.0.0.0:${PORT}`);
  console.log(`[wanxiang] admin panel: http://0.0.0.0:${PORT}/admin`);
});
