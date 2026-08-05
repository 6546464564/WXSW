// 万象书屋后端 · admin 面板路由 + 公开 cache/library 路由补测
//
// 覆盖 coverage 报告里 server.js 尚未测到的纯 DB 路由 (不触发外部网络):
//   admin:  me / logout / app-extra / sources{raw,groups,export} / stats /
//           bookstore-mirror{status,preview} / ad-config{GET,history,version,staging} /
//           ad-funnel / breaker/reset / feedback{GET,PATCH} / review-mode /
//           proxy-search{config,clear-cache} / cache{stats,books,delete,reset} / qimao-update/status
//   公开:   ping / ad-events / feedback / cache/search / cache/books / chapters / content /
//           library/search / library/toc / library/content
//   admin password (放最后, 会销毁 session)
//
// 用法:
//   BCRYPT_COST=4 ADMIN_INITIAL_PASSWORD=test-password-12345 \
//     DEVICE_TOKEN_SECRET=test-secret-aaaaaaaaaaaaaaaaaaaaaaaa \
//     node --test test/adminRoutes.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');
const os = require('os');

const TMP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'wxsw-admin-'));
process.env.DB_PATH = path.join(TMP_DIR, 'wanxiang.db');
process.env.BCRYPT_COST = process.env.BCRYPT_COST || '4';
process.env.ADMIN_INITIAL_PASSWORD = process.env.ADMIN_INITIAL_PASSWORD || 'test-pw-12345';
process.env.DEVICE_TOKEN_SECRET = 'test-secret-aaaaaaaaaaaaaaaaaaaaaaaa';
process.env.LOG_LEVEL = 'error';
process.env.PORT = '0';
process.env.NODE_ENV = 'test';

const request = require('supertest');
const { app } = require('../server.js');
const db = require('../db');

const ADMIN_PW = process.env.ADMIN_INITIAL_PASSWORD;

// ─────────────────────────────────────────────
// 设备 token (供公开接口用)
// ─────────────────────────────────────────────
let deviceToken = '';
let deviceId = '';

test('device register → 拿 token', async () => {
  deviceId = 'admin-route-dev-' + Date.now();
  const r = await request(app).post('/api/device/register').send({ device_id: deviceId }).expect(200);
  assert.ok(r.body.token);
  deviceToken = r.body.token;
});

test('/api/ping 记录心跳 (带 token)', async () => {
  assert.ok(deviceToken, 'device token 应由前一个测试设置');
  await request(app).post('/api/ping')
    .set('X-Device-Id', deviceId).set('X-Device-Token', deviceToken)
    .send({ device_id: deviceId }).expect(200);
  // 缺 device_id 且无 header → 400
  await request(app).post('/api/ping')
    .set('X-Device-Token', deviceToken)
    .send({}).expect(400);
});

test('/api/ad-events 批量上报 (带 token)', async () => {
  await request(app).post('/api/ad-events')
    .set('X-Device-Id', deviceId).set('X-Device-Token', deviceToken)
    .send([{ deviceId, placement: 'splash', provider: 'csj', type: 'shown' }])
    .expect(200);
  // 无 token → 401
  await request(app).post('/api/ad-events')
    .set('X-Device-Id', deviceId)
    .send([{ deviceId, placement: 'splash', provider: 'csj', type: 'shown' }])
    .expect(401);
});

test('/api/feedback 提交反馈 (带 token)', async () => {
  const r = await request(app).post('/api/feedback')
    .set('X-Device-Id', deviceId).set('X-Device-Token', deviceToken)
    .send({ type: 'bug', content: '这是一个很长的测试反馈内容，足够长', contact: 'test@example.com', deviceId, appVer: '1.0' })
    .expect(200);
  assert.ok(r.body.id > 0, '应返回 feedback id');
  // 内容太短 → 400
  await request(app).post('/api/feedback')
    .set('X-Device-Id', deviceId).set('X-Device-Token', deviceToken)
    .send({ type: 'bug', content: '短' })
    .expect(400);
});

// ─────────────────────────────────────────────
// admin 基础: me / logout / app-extra
// ─────────────────────────────────────────────
test('/api/admin/me 未登录与登录后', async () => {
  const r1 = await request(app).get('/api/admin/me').expect(200);
  assert.equal(r1.body.ok, false);
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const r2 = await agent.get('/api/admin/me').expect(200);
  assert.equal(r2.body.ok, true);
});

test('/api/admin/logout 后 admin 路由失效', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  await agent.get('/api/admin/stats').expect(200);
  await agent.post('/api/admin/logout').expect(200);
  await agent.get('/api/admin/stats').expect(401);
});

test('/api/admin/app-extra GET/POST', async () => {
  // 确保 app_versions 表 id=1 有行 (否则 saveExtraConfig 的 UPDATE 影响 0 行)
  db.saveAppVersion({ latest_code: 1, latest_name: 'v1', min_required_code: 0 });
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const r1 = await agent.get('/api/admin/app-extra').expect(200);
  assert.equal(typeof r1.body, 'object');
  await agent.post('/api/admin/app-extra').send({ min_os: '17' }).expect(200);
  const r2 = await agent.get('/api/admin/app-extra').expect(200);
  assert.equal(r2.body.min_os, '17');
  // 未登录 → 401
  await request(app).get('/api/admin/app-extra').expect(401);
});

// ─────────────────────────────────────────────
// admin 书源: raw / groups / export
// ─────────────────────────────────────────────
test('/api/admin/sources/raw + groups + export', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const url = 'https://rawroute.example.com';
  await agent.post('/api/admin/sources').send({
    bookSourceUrl: url, bookSourceName: 'raw源', bookSourceGroup: '测试组',
  }).expect(200);

  // raw (supertest 对 application/json 自动解析为对象)
  const raw = await agent.get(`/api/admin/sources/raw?url=${encodeURIComponent(url)}`).expect(200);
  assert.ok(raw.body.bookSourceName, 'raw 应返回源 JSON 对象');
  await agent.get('/api/admin/sources/raw?url=https://nope.example.com').expect(404);

  // groups
  const groups = await agent.get('/api/admin/sources/groups').expect(200);
  assert.ok(Array.isArray(groups.body.groups));
  assert.ok(groups.body.groups.includes('测试组'), '应含 测试组');

  // export
  const exp = await agent.get('/api/admin/sources/export').expect(200);
  assert.match(exp.headers['content-disposition'], /attachment/);
  assert.ok(exp.text.includes('rawroute.example.com'));
});

// ─────────────────────────────────────────────
// admin stats / bookstore-mirror / ad-config
// ─────────────────────────────────────────────
test('/api/admin/stats 返回各统计', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const r = await agent.get('/api/admin/stats').expect(200);
  assert.equal(typeof r.body.online, 'number');
  assert.ok(Array.isArray(r.body.daily));
});

test('/api/admin/bookstore-mirror status/preview', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  db.insertBookstoreMirror({
    version: 1, etag: 'adm-mirror', payload: JSON.stringify({ ranks: {} }),
    fetched_at: Date.now(), source: 'test', ok: true,
  });
  const status = await agent.get('/api/admin/bookstore-mirror/status').expect(200);
  assert.ok(status.body.latest, '应返回 latest mirror');
  const preview = await agent.get('/api/admin/bookstore-mirror/preview').expect(200);
  assert.ok(preview.text.includes('ranks'));
});

test('/api/admin/ad-config GET/history/version/staging', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);

  const cfg = { placements: { splash: { enabled: true, providers: [{ name: 'csj', weight: 1 }] } } };
  const save = await agent.post('/api/admin/ad-config').send(cfg).expect(200);
  assert.equal(save.body.ok, true);
  const version = save.body.version;
  assert.ok(version > 0);

  const get = await agent.get('/api/admin/ad-config').expect(200);
  assert.ok(get.body.config.placements.splash);

  const hist = await agent.get('/api/admin/ad-config/history').expect(200);
  assert.ok(Array.isArray(hist.body));

  const byVer = await agent.get(`/api/admin/ad-config/version/${version}`).expect(200);
  assert.ok(byVer.body.config.placements.splash);
  await agent.get('/api/admin/ad-config/version/999999').expect(404);

  // staging 流程
  await agent.put('/api/admin/ad-config/staging').send({ config: cfg, rolloutPct: 50 }).expect(200);
  await agent.post('/api/admin/ad-config/staging/abort').expect(200);
});

test('/api/admin/ad-funnel + breaker/reset', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const funnel = await agent.get('/api/admin/ad-funnel').expect(200);
  assert.equal(funnel.body.ok, true);
  assert.ok(funnel.body.funnel);
  const reset = await agent.post('/api/admin/breaker/reset').expect(200);
  assert.equal(reset.body.ok, true);
  assert.ok(reset.body.suppressMinutes > 0);
});

// ─────────────────────────────────────────────
// admin 反馈 + 审核模式 + 代搜配置
// ─────────────────────────────────────────────
test('/api/admin/feedback 列表 + 状态更新', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const list = await agent.get('/api/admin/feedback').expect(200);
  assert.equal(list.body.ok, true);
  assert.ok(Array.isArray(list.body.list));
  assert.ok(Array.isArray(list.body.stats));
  const fb = list.body.list.find(f => f.status === 'open');
  if (fb) {
    await agent.patch(`/api/admin/feedback/${fb.id}`).send({ status: 'processing' }).expect(200);
    const after = await agent.get(`/api/admin/feedback?status=processing`).expect(200);
    assert.ok(after.body.list.some(f => f.id === fb.id));
  }
  await agent.patch('/api/admin/feedback/0').send({ status: 'done' }).expect(400);
});

test('/api/admin/review-mode GET/POST', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const r1 = await agent.get('/api/admin/review-mode').expect(200);
  assert.equal(r1.body.ok, true);
  await agent.post('/api/admin/review-mode').send({ enabled: true }).expect(200);
  const r2 = await agent.get('/api/admin/review-mode').expect(200);
  assert.equal(r2.body.enabled, true);
  await agent.post('/api/admin/review-mode').send({ enabled: false }).expect(200);
});

test('/api/admin/proxy-search config 查询/清除 + clear-cache', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const r1 = await agent.get('/api/admin/proxy-search/config').expect(200);
  assert.equal(r1.body.ok, true);
  assert.equal(typeof r1.body.hasProxy, 'boolean');
  // 清代理分支 (不传 host)
  await agent.post('/api/admin/proxy-search/config').send({}).expect(200);
  const clear = await agent.post('/api/admin/proxy-search/clear-cache').expect(200);
  assert.equal(clear.body.ok, true);
});

// ─────────────────────────────────────────────
// cache admin + 公开 cache/library 链路
// ─────────────────────────────────────────────
test('cache 全链路: 插书 → admin 管理 → 公开读取 → 删除', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);

  // 插一本 done 书 (直接 db, 避免走下载器)
  const ins = db.insertCachedBook({ qidianId: '999888', title: '缓存测试书', author: '测试作者', category: '玄幻', priority: 10 });
  const bookId = ins.lastInsertRowid;
  db.insertCachedChapters(bookId, [{ idx: 0, title: '第一章', url: 'x' }, { idx: 1, title: '第二章', url: 'x' }]);
  db.saveCachedChapterContent(bookId, 0, '第一章的正文内容');
  db.saveCachedChapterContent(bookId, 1, '第二章的正文内容');
  db.updateCachedBookStatus(bookId, 'done');
  db.refreshCachedBookCount(bookId);

  // admin stats
  const stats = await agent.get('/api/admin/cache/stats').expect(200);
  assert.equal(stats.body.ok, true);
  assert.ok(stats.body.stats.total_books >= 1);

  // admin 列表
  const list = await agent.get('/api/admin/cache/books').expect(200);
  assert.ok(list.body.books.some(b => b.id === bookId));
  await agent.get('/api/admin/cache/books?status=done').expect(200);

  // qimao update status
  await agent.get('/api/admin/cache/qimao-update/status').expect(200);

  // 公开 cache/search
  const search = await request(app).get('/api/cache/search?keyword=缓存测试').expect(200);
  assert.ok(search.body.books.some(b => b.title === '缓存测试书'));
  await request(app).get('/api/cache/search').expect(400); // 缺 keyword

  // 公开 cache/books
  const cb = await request(app).get('/api/cache/books').expect(200);
  assert.ok(cb.body.books.some(b => b.id === bookId));

  // 章节列表 + 内容
  const chs = await request(app).get(`/api/cache/books/${bookId}/chapters`).expect(200);
  assert.equal(chs.body.chapters.length, 2);
  const ch0 = await request(app).get(`/api/cache/books/${bookId}/chapters/0`).expect(200);
  assert.ok(ch0.body.content.includes('第一章的正文'));
  await request(app).get(`/api/cache/books/${bookId}/chapters/99`).expect(404); // 不存在章节
  await request(app).get('/api/cache/books/abc/chapters').expect(400); // 非法 id

  // library 公开链路
  const libSearch = await request(app).get('/api/library/search?keyword=缓存测试').expect(200);
  assert.ok(libSearch.body.books.some(b => b.id === bookId));
  await request(app).get('/api/library/search?keyword=').expect(200); // 空 → 空数组
  const toc = await request(app).get(`/api/library/toc/${bookId}`).expect(200);
  assert.equal(toc.body.chapters.length, 2);
  const libContent = await request(app).get(`/api/library/content/${bookId}/0`).expect(200);
  assert.ok(libContent.body.content.length > 0);
  await request(app).get('/api/library/toc/999999').expect(404);
  await request(app).get('/api/library/content/abc/0').expect(400);

  // admin reset + delete
  await agent.post(`/api/admin/cache/books/${bookId}/reset`).expect(200);
  await agent.delete(`/api/admin/cache/books/${bookId}`).expect(200);
  await agent.delete('/api/admin/cache/books/999999').expect(404);
  await agent.post('/api/admin/cache/books/999999/reset').expect(404);
});

// ─────────────────────────────────────────────
// 搜索/封面/目录/内容 代理路由参数校验 (不触发外部调用)
// ─────────────────────────────────────────────
test('search proxy 参数校验: 缺 keyword / 过长', async () => {
  await request(app).get('/api/search/proxy').expect(400);
  await request(app).get('/api/search/proxy?keyword=' + 'x'.repeat(101)).expect(400);
});

test('changesource 缺 name → 400', async () => {
  await request(app).get('/api/search/changesource').expect(400);
  await request(app).get('/api/search/changesource?name=斗破苍穹').then(r => {
    assert.ok(r.status === 200 || r.status === 500, '有 name 不应 400');
  });
});

test('/api/cover 缺 name → 400', async () => {
  await request(app).get('/api/cover').expect(400);
});

test('search/toc + search/content 参数校验与 source not found', async () => {
  await request(app).get('/api/search/toc').expect(400);
  await request(app).get('/api/search/toc?origin=https://a&bookUrl=https://b').then(r => {
    // 不存在该 origin → 404 (source not found), 不触发外部调用
    assert.equal(r.status, 404);
  });
  await request(app).get('/api/search/content').expect(400);
  await request(app).get('/api/search/content?origin=https://a&chapterUrl=https://b').then(r => {
    assert.equal(r.status, 404);
  });
});

// ─────────────────────────────────────────────
// admin 登录失败分支 / 锁定
// ─────────────────────────────────────────────
test('admin login 失败计数 + 锁定', async () => {
  // 用独立 IP, 避免污染 127.0.0.1 的限速状态 (trust proxy=1 生效)
  const IP = '203.0.113.10';
  await request(app).post('/api/admin/login')
    .set('X-Forwarded-For', IP).send({ username: '不存在', password: 'x' }).expect(401);
  await request(app).post('/api/admin/login')
    .set('X-Forwarded-For', IP).send({ password: 'wrong' }).expect(401);
  // 连续失败累计 (loginRateLimit 内存层 MAX_FAILS=5 → 429; DB 层 threshold=5 → 423)
  for (let i = 0; i < 3; i++) {
    await request(app).post('/api/admin/login')
      .set('X-Forwarded-For', IP).send({ username: 'lockuser', password: 'bad' });
  }
  // 第 6 次: 内存限速或 DB 账户锁定, 二者其一必然生效 (423 或 429)
  const r3 = await request(app).post('/api/admin/login')
    .set('X-Forwarded-For', IP).send({ username: 'lockuser', password: 'bad' });
  assert.ok([423, 429].includes(r3.status), `expected 423/429 got ${r3.status}`);
  assert.equal(r3.body.ok, false);
  if (r3.status === 423) {
    assert.ok(r3.body.unlock_at > Date.now());
  }
});

test('admin 用户管理: 创建/列表/删除 + 权限', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  // 创建 operator 用户
  await agent.post('/api/admin/users').send({ username: 'op1', password: 'op-pass-12345', role: 'operator' }).expect(200);
  const list = await agent.get('/api/admin/users').expect(200);
  assert.ok(list.body.users.some(u => u.username === 'op1'));
  // 删除
  await agent.delete('/api/admin/users/op1').expect(200);
  const list2 = await agent.get('/api/admin/users').expect(200);
  assert.ok(!list2.body.users.some(u => u.username === 'op1'));
  // 未登录 → 401
  await request(app).get('/api/admin/users').expect(401);
});

test('admin 推广码 CRUD + 统计', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  await agent.post('/api/admin/promo/codes').send({ code: 'TESTPROMO', agentName: '测试代理' }).expect(200);
  const list = await agent.get('/api/admin/promo/codes').expect(200);
  assert.ok(list.body.list.some(c => c.code === 'TESTPROMO'));
  // 更新 (DB 字段名 max_uses) + 删除
  await agent.put('/api/admin/promo/codes/TESTPROMO').send({ max_uses: 5 }).expect(200);
  await agent.put('/api/admin/promo/codes/NOTEXIST').send({ max_uses: 5 }).expect(404);
  const stats = await agent.get('/api/admin/promo/stats').expect(200);
  assert.equal(stats.body.ok, true);
  await agent.get('/api/admin/promo/stats/TESTPROMO').expect(200);
  await agent.get('/api/admin/promo/fraud').expect(200);
  await agent.delete('/api/admin/promo/codes/TESTPROMO').expect(200);
  await agent.delete('/api/admin/promo/codes/TESTPROMO').expect(404);
});

test('admin 公告 CRUD', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const r = await agent.post('/api/admin/announcement').send({ title: '测试公告', content: '内容' }).expect(200);
  const list = await agent.get('/api/admin/announcements').expect(200);
  assert.ok(list.body.list.some(a => a.id === r.body.id));
  await agent.delete(`/api/admin/announcement/${r.body.id}`).expect(200);
  await agent.delete(`/api/admin/announcement/${r.body.id}`).expect(200); // 删不存在也 ok
});

test('admin 书源管理: check / enabled / platforms / delete', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  const url = 'https://manage.example.com';
  await agent.post('/api/admin/sources').send({
    bookSourceUrl: url, bookSourceName: '管理源', bookSourceGroup: '管理组',
  }).expect(200);
  // 批量 upsert (数组)
  await agent.post('/api/admin/sources').send([{ bookSourceUrl: 'https://a.example.com', bookSourceName: 'A源' }]).expect(200);
  // enabled
  await agent.patch('/api/admin/sources/enabled').send({ url, enabled: false }).expect(200);
  await agent.patch('/api/admin/sources/enabled').send({ url: 'https://nope.example.com', enabled: true }).expect(200);
  // platforms
  await agent.patch('/api/admin/sources/platforms').send({ url, platforms: ['ios', 'android'] }).expect(200);
  await agent.patch('/api/admin/sources/platforms').send({ url: 'https://nope.example.com', platforms: ['ios'] }).expect(404);
  await agent.patch('/api/admin/sources/platforms').send({ url, platforms: 'not-array' }).expect(400);
  // bulk platforms
  await agent.patch('/api/admin/sources/platforms/bulk').send({ urls: [url], platform: 'ios', op: 'add' }).expect(200);
  await agent.patch('/api/admin/sources/platforms/bulk').send({ urls: [], platform: 'ios', op: 'add' }).expect(400);
  await agent.patch('/api/admin/sources/platforms/bulk').send({ urls: [url], platform: 'windows', op: 'add' }).expect(400);
  await agent.patch('/api/admin/sources/platforms/bulk').send({ urls: [url], platform: 'ios', op: 'badop' }).expect(400);
  // check (静态检查, 不触发外部网络)
  const chk = await agent.post('/api/admin/sources/check').send({ url }).expect(200);
  assert.equal(chk.body.ok, true);
  // delete
  await agent.delete('/api/admin/sources?url=' + encodeURIComponent(url)).expect(200);
  await agent.delete('/api/admin/sources').expect(400); // 缺 url
});

test('admin TXT 上传到书库', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  // 缺文件 → 400
  await agent.post('/api/admin/library/upload').send({ title: '无文件' }).expect(400);
  // 缺标题 → 400
  await agent.post('/api/admin/library/upload')
    .attach('file', Buffer.from('第一章\n正文内容'), 'book.txt')
    .expect(400);
  // 正常上传 (GBK 编码自动识别, 或 UTF-8)
  const utf8 = '第一章 开始\n这是第一章内容。\n\n第二章 后续\n这是第二章内容。\n';
  const r = await agent.post('/api/admin/library/upload')
    .field('title', 'TXT测试书')
    .field('author', '测试作者')
    .field('category', '玄幻')
    .attach('file', Buffer.from(utf8, 'utf-8'), 'book.txt')
    .expect(200);
  assert.equal(r.body.ok, true);
  assert.ok(r.body.chapters >= 2);
  // 重复书名: cached_books 的 UNIQUE 是 qidian_id 而非 title, 同名书会再次入库
  // (上传路由的 409 分支仅在 qidian_id 冲突时触发)
  const r2 = await agent.post('/api/admin/library/upload')
    .field('title', 'TXT测试书')
    .attach('file', Buffer.from('第一章\n内容', 'utf-8'), 'book2.txt')
    .expect(200);
  assert.equal(r2.body.ok, true);
});

test('admin qimao-import 参数校验', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  // 缺 qimaoId → 400
  await agent.post('/api/admin/cache/qimao-import').send({}).expect(400);
});

test('admin 校验: sources/validate 参数校验', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  // 缺 url → 400
  await agent.get('/api/admin/sources/validate').expect(400);
  // 不存在的 url → 404
  await agent.get('/api/admin/sources/validate?url=https%3A%2F%2Fnope.example.com').expect(404);
});

// ─────────────────────────────────────────────
// admin password (放最后: 会销毁所有 session)
// ─────────────────────────────────────────────
test('/api/admin/password 旧密码校验 + 修改', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: ADMIN_PW }).expect(200);
  // 旧密码错误 → 401
  await agent.post('/api/admin/password').send({ oldPassword: 'wrong-old', newPassword: 'newpass123' }).expect(401);
  // 新密码太短 → 400
  await agent.post('/api/admin/password').send({ oldPassword: ADMIN_PW, newPassword: 'short' }).expect(400);
  // 新密码与旧相同 → 400
  await agent.post('/api/admin/password').send({ oldPassword: ADMIN_PW, newPassword: ADMIN_PW }).expect(400);
  // 修改成功
  await agent.post('/api/admin/password').send({ oldPassword: ADMIN_PW, newPassword: 'new-pass-12345' }).expect(200);
  // 修改后 session 全毁 → 原 cookie 失效
  await agent.get('/api/admin/stats').expect(401);
  // 新密码可登录
  const agent2 = request.agent(app);
  await agent2.post('/api/admin/login').send({ password: 'new-pass-12345' }).expect(200);
  await agent2.get('/api/admin/stats').expect(200);
});

test.after(() => {
  try { fs.rmSync(TMP_DIR, { recursive: true, force: true }); } catch {}
  setTimeout(() => process.exit(0), 200).unref();
});
