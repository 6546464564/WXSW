// 万象书屋: Admin 管理 API 路由
//
// 从 server.js 拆出. 所有路由挂在 /api/admin 下 (由 server.js 注册).
// 依赖通过 createAdminRouter(deps) 注入, 避免循环 require.
//
//   server.js:
//     const createAdminRouter = require('./routes/admin');
//     app.use('/api/admin', createAdminRouter({ db, logger, backupCtl, getNextRunAt, breaker }));

const express = require('express');
const crypto = require('crypto');
const multer = require('multer');
const validator = require('../sourceValidator');
const qidianMirror = require('../jobs/qidianMirror');
const bookDownloader = require('../jobs/bookDownloader');
const qimaoUpdater = require('../jobs/qimaoUpdater');
const legadoEngine = require('../jobs/legadoEngine');
const proxySearch = require('../jobs/proxySearch');

const router = express.Router();

// --- 模块级状态 (由 admin 路由持有, 与 server.js 解耦) ---
let _downloadRunning = false;
let _qimaoUpdateRunning = false;
let _qimaoUpdateProgress = null;

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
      if (!chapters._preface) chapters._preface = '';
      chapters._preface += line + '\n';
    }
  }
  if (current) chapters.push(current);

  if (chapters._preface) {
    const pre = chapters._preface.trim();
    if (pre.length > 10) {
      chapters.unshift({ title: '前言', content: pre });
    }
  }
  delete chapters._preface;

  for (const ch of chapters) ch.content = ch.content.trim();

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

function createAdminRouter(deps) {
  const { db, logger, requireAdmin, requireRole, loginRateLimit, recordLoginResult, totpVerify, largeJson, backupCtl, getNextRunAt, breaker } = deps;

  function initProxyFromDb() {
    const saved = db.kvGet('proxy_url');
    if (saved) {
      legadoEngine.setProxyUrl(saved);
      logger.info('proxy loaded from db', { url: saved.replace(/:([^@:]+)@/, ':***@') });
    }
  }
  initProxyFromDb();

  // ─────────────────── 登录/登出 ───────────────────
  router.post('/login', loginRateLimit, async (req, res) => {
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

  router.post('/logout', requireAdmin, (req, res) => {
    db.destroySession(req.cookies.adm);
    res.clearCookie('adm');
    res.json({ ok: true });
  });

  router.post('/password', loginRateLimit, requireAdmin, async (req, res) => {
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

  router.get('/me', (req, res) => {
    const tok = req.cookies && req.cookies.adm;
    res.json({ ok: db.isValidSession(tok, req.get('User-Agent') || '') });
  });

  // ─────────────────── 多用户管理 ───────────────────
  router.get('/users', requireAdmin, (req, res) => {
    res.json({ ok: true, users: db.listAdminUsers() });
  });
  router.post('/users', requireAdmin, requireRole(['super']), async (req, res) => {
    try {
      const { username, password, role } = req.body || {};
      await db.createAdminUser({ username, password, role, creator: req.admin.username });
      res.json({ ok: true });
    } catch (e) {
      res.status(400).json({ ok: false, msg: e.message });
    }
  });
  router.delete('/users/:username', requireAdmin, requireRole(['super']), (req, res) => {
    db.deleteAdminUser(req.params.username);
    res.json({ ok: true });
  });

  // ─────────────────── 应用配置 ───────────────────
  router.get('/app-extra', requireAdmin, (req, res) => {
    res.json(db.getExtraConfig());
  });
  router.post('/app-extra', requireAdmin, (req, res) => {
    const { min_os } = req.body || {};
    const cur = db.getExtraConfig();
    if (min_os !== undefined) cur.min_os = String(min_os || '');
    db.saveExtraConfig(cur);
    res.json({ ok: true });
  });

  // ─────────────────── 书源管理 ───────────────────
  router.get('/sources', requireAdmin, (req, res) => res.json(db.listAllSources()));
  router.get('/sources/raw', requireAdmin, (req, res) => {
    const row = db.getSource(req.query.url);
    if (!row) return res.status(404).json({ ok: false });
    res.set('Content-Type', 'application/json'); res.send(row.json);
  });
  router.post('/sources', largeJson, requireAdmin, requireRole(['super', 'operator']), (req, res) => {
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
  router.delete('/sources', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    const url = req.query.url;
    if (!url) return res.status(400).json({ ok: false });
    const n = db.deleteSource(url);
    res.json({ ok: true, deleted: n });
  });
  router.post('/sources/check', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    try {
      const r = db.runSourceStaticCheck({ platform: req.body?.platform || req.query.platform || 'ios', sampleKeyword: req.body?.sampleKeyword || req.query.sampleKeyword || '斗破苍穹', url: req.body?.url || req.query.url || null });
      const { ok: okCount, error: errorCount, ...rest } = r;
      res.json({ ok: true, okCount, errorCount, ...rest });
    } catch (e) { res.status(400).json({ ok: false, msg: e.message || 'check failed' }); }
  });
  router.patch('/sources/enabled', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    const { url, enabled } = req.body || {};
    if (!url) return res.status(400).json({ ok: false });
    db.setEnabled(url, !!enabled);
    res.json({ ok: true });
  });
  router.patch('/sources/platforms', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    const { url, platforms } = req.body || {};
    if (!url) return res.status(400).json({ ok: false, msg: 'url required' });
    if (!Array.isArray(platforms)) return res.status(400).json({ ok: false, msg: 'platforms must be an array' });
    try {
      const n = db.setSourcePlatforms(url, platforms);
      if (n === 0) return res.status(404).json({ ok: false, msg: 'source not found' });
      res.json({ ok: true, changed: n });
    } catch (err) { res.status(400).json({ ok: false, msg: err.message || 'invalid' }); }
  });
  router.patch('/sources/platforms/bulk', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
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
  router.patch('/sources/group-enabled', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
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
  router.get('/sources/groups', requireAdmin, (req, res) => {
    const rows = db.__db.prepare('SELECT json FROM book_sources').all();
    const set = new Set();
    for (const r of rows) {
      try { for (const g of String(JSON.parse(r.json).bookSourceGroup || '').split(/[,;，；]/)) { const t = g.trim(); if (t) set.add(t); } } catch {}
    }
    res.json({ ok: true, groups: [...set].sort() });
  });
  router.get('/sources/export', requireAdmin, (req, res) => {
    const rows = db.__db.prepare('SELECT json FROM book_sources ORDER BY updated_at DESC').all();
    const body = '[' + rows.map(r => r.json).join(',') + ']';
    const fname = `wanxiang-sources-${new Date().toISOString().slice(0,10)}.json`;
    res.set('Content-Type', 'application/json; charset=utf-8');
    res.set('Content-Disposition', `attachment; filename="${fname}"`);
    res.send(body);
  });
  router.get('/sources/validate', requireAdmin, async (req, res) => {
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
  router.get('/sources/validate-all', requireAdmin, async (req, res) => {
    const checkSearch = String(req.query.search || '') === '1';
    const list = db.listAllSources();
    const sources = list.map(meta => { const row = db.getSource(meta.url); try { return JSON.parse(row.json); } catch { return { bookSourceUrl: meta.url, bookSourceName: meta.name }; } });
    try {
      const summary = await validator.validateAll(sources, { concurrency: 8, checkReach: true, checkSearch, timeoutMs: 6000 });
      res.json({ ok: true, ...summary });
    } catch (e) { res.status(500).json({ ok: false, msg: e.message }); }
  });

  // ─────────────────── 统计 ───────────────────
  router.get('/stats', requireAdmin, (req, res) => {
    const days = parseInt(req.query.days, 10) || 7;
    res.json({ online: db.statsOnline(), today: db.statsToday(), week: db.statsWeek(), month: db.statsMonth(), daily: db.statsDailyCurve(days) });
  });

  // ─────────────────── 书城 mirror ───────────────────
  router.get('/bookstore-mirror/status', requireAdmin, (req, res) => {
    const latest = db.getLatestBookstoreMirror();
    const recent = db.listRecentBookstoreMirror(3);
    res.json({
      latest: latest ? { version: latest.version, fetched_at: latest.fetched_at, etag: latest.etag, source: latest.source, payload_size: latest.payload?.length || 0 } : null,
      nextScheduledAt: getNextRunAt() || null,
      recent: recent.map(r => ({ id: r.id, version: r.version, fetched_at: r.fetched_at, ok: r.ok === 1, err_msg: r.err_msg, payload_size: r.payload_size, source: r.source })),
    });
  });
  router.post('/bookstore-mirror/refresh', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
    try { const result = await qidianMirror.fetchAndCache(db); logger.info('mirror manual refresh ok', result); res.json({ ok: true, ...result }); }
    catch (e) { qidianMirror.recordFailure(db, e); logger.warn('mirror manual refresh failed', { msg: e.message }); res.status(500).json({ ok: false, msg: e.message }); }
  });
  /** 万象书屋: 从可信 admin 客户端上传完整 mirror JSON (含 ranksFemale). SSH 不可达时的备用发布路径. */
  router.post('/bookstore-mirror/publish', requireAdmin, requireRole(['super', 'operator']), largeJson, (req, res) => {
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
  router.get('/bookstore-mirror/preview', requireAdmin, (req, res) => {
    const row = db.getLatestBookstoreMirror();
    res.set('Content-Type', 'application/json; charset=utf-8'); res.send(row?.payload || '{}');
  });

  // ─────────────────── 广告配置 ───────────────────
  router.get('/ad-config', requireAdmin, (req, res) => {
    const row = db.getAdConfigRaw();
    res.json({ version: row.version, etag: row.etag, config: JSON.parse(row.json) });
  });
  router.post('/ad-config', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    try {
      if (!req.body || typeof req.body !== 'object') return res.status(400).json({ ok: false, msg: 'JSON object expected' });
      const r = db.saveAdConfig(req.body);
      res.json({ ok: true, ...r });
    } catch (err) { res.status(400).json({ ok: false, msg: err.message || 'invalid ad config' }); }
  });
  router.get('/ad-config/history', requireAdmin, (req, res) => res.json(db.listAdConfigHistory(30)));
  router.get('/ad-config/version/:v', requireAdmin, (req, res) => {
    const v = parseInt(req.params.v, 10);
    if (!Number.isFinite(v)) return res.status(400).json({ ok: false });
    const row = db.getAdConfigByVersion(v);
    if (!row) return res.status(404).json({ ok: false });
    res.json({ version: row.version, createdAt: row.created_at, config: JSON.parse(row.json) });
  });
  router.put('/ad-config/staging', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    try { const { config, rolloutPct } = req.body || {}; db.setAdConfigStaging(config, rolloutPct); res.json({ ok: true }); }
    catch (e) { res.status(400).json({ ok: false, error: e.message }); }
  });
  router.post('/ad-config/staging/commit', requireAdmin, requireRole(['super']), (req, res) => {
    try { db.commitAdConfigStaging(); res.json({ ok: true }); }
    catch (e) { res.status(400).json({ ok: false, error: e.message }); }
  });
  router.post('/ad-config/staging/abort', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    db.abortAdConfigStaging(); res.json({ ok: true });
  });
  router.get('/ad-funnel', requireAdmin, (req, res) => {
    const hours = Math.max(1, Math.min(24 * 30, parseInt(req.query.hours, 10) || 24));
    res.json({ ok: true, hours, funnel: db.adEventFunnel({ hours }), breaker: breaker.cache });
  });
  router.post('/breaker/reset', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    const minutes = Math.max(1, Math.min(360, parseInt(req.query.minutes, 10) || 30));
    const r = breaker.resetBreaker(minutes);
    res.json({ ok: true, ...r, msg: `breaker suppressed for ${minutes} minutes` });
  });
  router.post('/backup/now', requireAdmin, requireRole(['super']), async (req, res) => {
    try { await backupCtl.runBackupOnce(); res.json({ ok: true, msg: 'backup triggered' }); }
    catch (e) { res.status(500).json({ ok: false, error: e.message }); }
  });

  // ─────────────────── 反馈 ───────────────────
  router.get('/feedback', requireAdmin, (req, res) => {
    const status = req.query.status || null;
    const limit = Math.max(10, Math.min(500, parseInt(req.query.limit, 10) || 200));
    res.json({ ok: true, list: db.listFeedback({ status, limit }), stats: db.feedbackStats() });
  });
  router.patch('/feedback/:id', requireAdmin, (req, res) => {
    const id = parseInt(req.params.id, 10);
    const { status, reply } = req.body || {};
    if (!id) return res.status(400).json({ ok: false, msg: 'invalid id' });
    try { db.updateFeedbackStatus(id, status, reply); res.json({ ok: true }); }
    catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
  });

  // ─────────────────── 公告 ───────────────────
  router.get('/announcements', requireAdmin, (req, res) => res.json({ ok: true, list: db.listAllAnnouncements() }));
  router.post('/announcement', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    try { const id = db.upsertAnnouncement(req.body || {}); res.json({ ok: true, id }); }
    catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
  });
  router.delete('/announcement/:id', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    db.deleteAnnouncement(req.params.id); res.json({ ok: true });
  });

  // ─────────────────── 推广代理码 ───────────────────
  router.get('/promo/codes', requireAdmin, (req, res) => res.json({ ok: true, list: db.listPromoCodes() }));
  router.post('/promo/codes', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    try {
      const { code, agentName, maxUses, singleDevice, expiresAt } = req.body || {};
      const result = db.createPromoCode({ code, agentName, maxUses, singleDevice, expiresAt, creator: req.admin.username });
      res.json({ ok: true, ...result });
    } catch (e) { res.status(400).json({ ok: false, msg: e.message }); }
  });
  router.put('/promo/codes/:code', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    const ok = db.updatePromoCode(req.params.code, req.body || {});
    if (!ok) return res.status(404).json({ ok: false, msg: '推广码不存在' });
    res.json({ ok });
  });
  router.delete('/promo/codes/:code', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    const ok = db.deletePromoCode(req.params.code);
    if (!ok) return res.status(404).json({ ok: false, msg: '推广码不存在' });
    res.json({ ok });
  });
  router.get('/promo/stats', requireAdmin, (req, res) => res.json({ ok: true, ...db.promoOverview() }));
  router.get('/promo/stats/:code', requireAdmin, (req, res) => res.json({ ok: true, ...db.promoCodeStats(req.params.code) }));
  router.get('/promo/fraud', requireAdmin, (req, res) => res.json({ ok: true, alerts: db.promoFraudDetection() }));

  // ─────────────────── 审核模式 ───────────────────
  router.get('/review-mode', requireAdmin, (req, res) => {
    res.json({ ok: true, enabled: db.kvGet('review_mode') === '1' });
  });
  router.post('/review-mode', requireAdmin, requireRole(['super']), (req, res) => {
    const enabled = !!req.body.enabled;
    db.kvSet('review_mode', enabled ? '1' : '0');
    logger.warn({ m: 'review_mode_toggled', enabled, by: req.adminUser });
    res.json({ ok: true, enabled });
  });

  // ─────────────────── 代搜配置 ───────────────────
  router.get('/proxy-search/config', requireAdmin, (req, res) => {
    const raw = db.kvGet('proxy_url') || '';
    const masked = raw ? raw.replace(/:([^@:]+)@/, ':***@') : '';
    res.json({
      ok: true,
      proxyUrl: masked,
      hasProxy: !!raw,
      cacheSize: proxySearch.searchCache.size,
      envProxy: process.env.PROXY_URL ? process.env.PROXY_URL.replace(/:([^@:]+)@/, ':***@') : null,
    });
  });

  router.post('/proxy-search/config', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
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

  router.post('/proxy-search/test', requireAdmin, async (req, res) => {
    try {
      const resp = await legadoEngine.httpGet('https://httpbin.org/ip', { timeout: 10000 });
      const ip = JSON.parse(resp);
      res.json({ ok: true, ip: ip.origin || 'unknown', raw: resp.slice(0, 200) });
    } catch (e) {
      res.json({ ok: false, msg: e.message });
    }
  });

  router.post('/proxy-search/test-search', requireAdmin, async (req, res) => {
    const keyword = (req.body.keyword || '斗破苍穹').trim();
    try {
      const sources = db.listEnabledSourcesJson('ios')
        .filter(s => s.searchUrl && s.bookSourceUrl !== (process.env.PUBLIC_URL || 'https://www.wxsw.app'));
      const result = await proxySearch.proxySearch(sources, keyword);
      res.json({ ok: true, count: result.books.length, fromCache: result.fromCache, sourceCount: result.sourceCount, books: result.books.slice(0, 20) });
    } catch (e) {
      res.json({ ok: false, msg: e.message });
    }
  });

  router.post('/proxy-search/clear-cache', requireAdmin, (req, res) => {
    const size = proxySearch.searchCache.size;
    proxySearch.searchCache.clear();
    res.json({ ok: true, msg: `已清除 ${size} 条缓存` });
  });

  // ─────────────────── 缓存管理 ───────────────────
  router.get('/cache/stats', requireAdmin, (req, res) => {
    const stats = db.getCacheStats();
    res.json({ ok: true, stats });
  });
  router.get('/cache/books', requireAdmin, (req, res) => {
    const status = req.query.status || null;
    const list = db.listCachedBooks(status);
    res.json({ ok: true, count: list.length, books: list });
  });
  router.post('/cache/download', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
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

  router.post('/cache/qimao-update', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
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
  router.get('/cache/qimao-update/status', requireAdmin, (req, res) => {
    res.json({ ok: true, running: _qimaoUpdateRunning, progress: _qimaoUpdateProgress });
  });
  router.post('/cache/qimao-import', requireAdmin, requireRole(['super', 'operator']), async (req, res) => {
    const { qimaoId, category } = req.body || {};
    if (!qimaoId) return res.status(400).json({ ok: false, msg: 'qimaoId required' });
    try {
      const result = await qimaoUpdater.importBook(db, String(qimaoId), category, logger);
      res.json({ ok: true, ...result });
    } catch (e) {
      res.status(500).json({ ok: false, msg: e.message });
    }
  });
  router.delete('/cache/books/:id', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    const bookId = parseInt(req.params.id, 10);
    if (!bookId) return res.status(400).json({ ok: false, msg: 'invalid id' });
    const book = db.getCachedBook(bookId);
    if (!book) return res.status(404).json({ ok: false, msg: 'book not found' });
    db.__db.prepare('DELETE FROM cached_chapters WHERE book_id = ?').run(bookId);
    db.__db.prepare('DELETE FROM cached_books WHERE id = ?').run(bookId);
    logger.info('library book deleted', { bookId, title: book.title });
    res.json({ ok: true, msg: `《${book.title}》已删除` });
  });
  router.post('/cache/books/:id/reset', requireAdmin, requireRole(['super', 'operator']), (req, res) => {
    const bookId = parseInt(req.params.id, 10);
    if (!bookId) return res.status(400).json({ ok: false, msg: 'invalid id' });
    const book = db.getCachedBook(bookId);
    if (!book) return res.status(404).json({ ok: false, msg: 'book not found' });
    db.updateCachedBookStatus(bookId, 'pending');
    res.json({ ok: true, msg: `book ${bookId} reset to pending` });
  });

  // ─────────────────── TXT 上传 ───────────────────
  router.post('/library/upload', requireAdmin, requireRole(['super', 'operator']),
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

  return router;
}

module.exports = createAdminRouter;
