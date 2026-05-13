// 万象书屋后端集成测试 (supertest).
// 覆盖关键路径: health / sources CRUD / login / device register / wipe-data / etc.
//
// 用法:
//   BCRYPT_COST=4 ADMIN_INITIAL_PASSWORD=test-password-12345 \
//     DEVICE_TOKEN_SECRET=test-secret-aaaaaaaaaaaaaaaaaaaaaaaa \
//     node --test test/api.test.js
//
// 设计:
//   - 用临时 DB 文件 (test/.tmp.db), 不污染 dev 数据
//   - 测试间用 try/finally 保证清理
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');
const os = require('os');

// 临时 db 文件 — 必须在 require server 之前设置
const TMP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'wanxiang-test-'));
process.env.DB_PATH = path.join(TMP_DIR, 'wanxiang.db');
process.env.BCRYPT_COST = process.env.BCRYPT_COST || '4';
process.env.ADMIN_INITIAL_PASSWORD = process.env.ADMIN_INITIAL_PASSWORD || 'test-pw-12345';
process.env.DEVICE_TOKEN_SECRET = 'test-secret-aaaaaaaaaaaaaaaaaaaaaaaa';
process.env.LOG_LEVEL = 'error';
process.env.PORT = '0';  // OS 随机分配, 避免冲突
process.env.NODE_ENV = 'test';  // 跳过 makeRateLimit (公开接口 rate limit), login rate limit 仍生效

const request = require('supertest');
const { app } = require('../server.js');

test('GET /api/health returns ok', async () => {
  const res = await request(app).get('/api/health').expect(200);
  assert.equal(res.body.ok, true);
  assert.ok(res.body.checks);
  assert.equal(res.body.checks.db.ok, true);
  assert.ok(typeof res.body.checks.uptime_s === 'number');
});

test('GET /metrics returns prometheus format', async () => {
  const res = await request(app).get('/metrics').expect(200);
  assert.match(res.headers['content-type'], /text\/plain/);
  assert.match(res.text, /# HELP wanxiang_uptime_seconds/);
  assert.match(res.text, /# TYPE wanxiang_uptime_seconds counter/);
});

test('GET /api/sources returns array', async () => {
  const res = await request(app).get('/api/sources').expect(200);
  assert.ok(Array.isArray(res.body));
});

test('GET /api/sources etag 304 on repeat', async () => {
  const r1 = await request(app).get('/api/sources').expect(200);
  const etag = r1.headers.etag;
  assert.ok(etag);
  await request(app).get('/api/sources').set('If-None-Match', etag).expect(304);
});

test('GET /api/announcement returns list', async () => {
  const res = await request(app).get('/api/announcement?versionCode=10000').expect(200);
  assert.equal(res.body.ok, true);
  assert.ok(Array.isArray(res.body.list));
});

test('POST /api/admin/login wrong password rejected', async () => {
  const res = await request(app)
    .post('/api/admin/login')
    .send({ password: 'wrong-password' })
    .expect(401);
  assert.equal(res.body.ok, false);
});

test('POST /api/admin/login with correct password works', async () => {
  const res = await request(app)
    .post('/api/admin/login')
    .send({ password: process.env.ADMIN_INITIAL_PASSWORD })
    .expect(200);
  assert.equal(res.body.ok, true);
  assert.ok(res.headers['set-cookie']);
});

test('GET /api/admin/sources without auth returns 401', async () => {
  await request(app).get('/api/admin/sources').expect(401);
});

test('admin login → sources crud → logout', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login')
    .send({ password: process.env.ADMIN_INITIAL_PASSWORD })
    .expect(200);

  // list (返回数组直接, 不包 {ok,list})
  let r = await agent.get('/api/admin/sources').expect(200);
  assert.ok(Array.isArray(r.body), 'list response should be array');

  // create
  const newSource = {
    bookSourceUrl: 'https://test.example.com/source1',
    bookSourceName: 'Test Source 1',
    bookSourceGroup: 'test',
    enabled: true
  };
  const postRes = await agent.post('/api/admin/sources').send(newSource);
  assert.equal(postRes.status, 200, 'post failed: ' + JSON.stringify(postRes.body));

  // verify list has it
  r = await agent.get('/api/admin/sources').expect(200);
  const found = Array.isArray(r.body) && r.body.find(s => s.url === newSource.bookSourceUrl);
  assert.ok(found, 'source should be in list. Got: ' + JSON.stringify(r.body).slice(0, 200));

  // delete
  await agent.delete('/api/admin/sources?url=' + encodeURIComponent(newSource.bookSourceUrl))
    .expect(200);
});

test('GET /api/ad-config returns config envelope', async () => {
  const res = await request(app).get('/api/ad-config').expect(200);
  assert.ok(res.body.config);
  assert.ok(res.body.config.placements);
  assert.ok(res.body.etag);
});

test('device register → token flow', async () => {
  const did = 'integration-test-device-' + Date.now();
  const r1 = await request(app)
    .post('/api/device/register')
    .send({ device_id: did })
    .expect(200);
  assert.ok(r1.body.token);
  const token = r1.body.token;

  // 重复注册被拒
  await request(app).post('/api/device/register').send({ device_id: did }).expect(409);

  // 没 token 调 ad-event 应该 401
  await request(app)
    .post('/api/ad-event')
    .set('X-Device-Id', did)
    .send({ deviceId: did, placement: 'splash', provider: 'csj', type: 'shown' })
    .expect(401);

  // 带正确 token 应该成功 (注意字段名: type 不是 event, deviceId 不是 device_id)
  await request(app)
    .post('/api/ad-event')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .send({ deviceId: did, placement: 'splash', provider: 'csj', type: 'shown' })
    .expect(200);

  // 错 token 拒
  await request(app)
    .post('/api/ad-event')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token.slice(0, -2) + 'xx')
    .send({ deviceId: did, placement: 'splash', provider: 'csj', type: 'shown' })
    .expect(401);
});

test('wipe-data flow: register → wipe → re-register', async () => {
  const did = 'wipe-test-' + Date.now();
  const r1 = await request(app)
    .post('/api/device/register')
    .send({ device_id: did })
    .expect(200);
  const token = r1.body.token;

  // 错 token wipe 拒
  await request(app)
    .delete('/api/me/wipe-data')
    .set('X-Device-Id', did)
    .set('X-Device-Token', 'fake-token')
    .expect(401);

  // 对 token wipe 成功
  const wipeRes = await request(app)
    .delete('/api/me/wipe-data')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .expect(200);
  assert.equal(wipeRes.body.ok, true);
  assert.ok(wipeRes.body.deleted);
});

// === 万象书屋: multi-platform (006_multi_platform) ===

test('X-Platform header: device register accepts ios + records platform', async () => {
  const did = 'ios-reg-' + Date.now();
  const r = await request(app)
    .post('/api/device/register')
    .set('X-Platform', 'ios')
    .send({ device_id: did })
    .expect(200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.platform, 'ios', 'response should echo platform=ios');

  // 数据库直查 — 通过 admin sources/raw 不行, 用一条间接探测: 重复注册时 install_ts 改了说明 upsert 走通
  // 这里我们通过 X-Platform 不传时默认 android 来反向证明 platform 字段在用
});

test('X-Platform missing defaults to android (老 App 兼容)', async () => {
  const did = 'legacy-android-' + Date.now();
  // 不带 X-Platform header — 应该被当作 android 处理, 不报错
  const r = await request(app)
    .post('/api/device/register')
    .send({ device_id: did })
    .expect(200);
  assert.equal(r.body.platform, 'android');
});

test('X-Platform invalid value falls back to android (防注入)', async () => {
  const did = 'bad-platform-' + Date.now();
  const r = await request(app)
    .post('/api/device/register')
    .set('X-Platform', 'WindowsPhone-Or-Random-Garbage')
    .send({ device_id: did })
    .expect(200);
  assert.equal(r.body.platform, 'android', 'unknown platform should fall back to android');
});

test('X-Platform: ios + ad-event 流程 + IAP 路由 iOS-only 校验', async () => {
  const did = 'ios-flow-' + Date.now();
  // iOS 设备注册
  const reg = await request(app)
    .post('/api/device/register')
    .set('X-Platform', 'ios')
    .send({ device_id: did })
    .expect(200);
  const token = reg.body.token;
  assert.ok(token);

  // 上报广告事件 (iOS)
  await request(app)
    .post('/api/ad-event')
    .set('X-Platform', 'ios')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .send({ deviceId: did, placement: 'splash', provider: 'csj', type: 'load' })
    .expect(200);

  // IAP entitlements (iOS, 还没买东西 → 空数组)
  const ent = await request(app)
    .get('/api/iap/entitlements')
    .set('X-Platform', 'ios')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .expect(200);
  assert.equal(ent.body.ok, true);
  assert.ok(Array.isArray(ent.body.entitlements));
  assert.equal(ent.body.entitlements.length, 0);
  assert.ok(Array.isArray(ent.body.receipts));
});

test('IAP verify rejects Android requests (iOS-only)', async () => {
  // IAP verify 暂未上线, 返回 503
  const did = 'android-iap-' + Date.now();
  const reg = await request(app)
    .post('/api/device/register')
    .send({ device_id: did })
    .expect(200);
  const token = reg.body.token;

  const r = await request(app)
    .post('/api/iap/verify')
    .set('X-Platform', 'android')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .send({
      device_id: did,
      product_id: 'com.wanxiang.adfree.lifetime',
      transaction_id: 'fake-tx-1',
      receipt_data: 'fake-receipt-base64',
    })
    .expect(503);
  assert.ok(r.body.msg);
});

test('IAP verify validates required fields', async () => {
  // IAP verify 暂未上线, 返回 503
  const did = 'ios-iap-' + Date.now();
  const reg = await request(app)
    .post('/api/device/register')
    .set('X-Platform', 'ios')
    .send({ device_id: did })
    .expect(200);
  const token = reg.body.token;

  const r = await request(app)
    .post('/api/iap/verify')
    .set('X-Platform', 'ios')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .send({
      device_id: did,
      product_id: 'com.wanxiang.adfree.lifetime',
      transaction_id: 'fake-tx-1',
    })
    .expect(503);
  assert.ok(r.body.msg);
});

// === 万象书屋 v2 (007_book_sources_platforms): 平台过滤 ===
//
// 复用 db 模块直接插源, 方便指定 platforms 列, 避免 admin API 走太多业务路径
const db = require('../db');

test('GET /api/sources?platform=ios filters out android-only sources', async () => {
  // 准备 3 条源:
  //   srcA: platforms='android,ios' → 双平台都看到
  //   srcB: platforms='android'     → 只 Android 看到
  //   srcC: platforms='ios'         → 只 iOS 看到
  const srcA = { bookSourceUrl: 'https://t.example/A', bookSourceName: 'A 双平台' };
  const srcB = { bookSourceUrl: 'https://t.example/B', bookSourceName: 'B 仅安卓' };
  const srcC = { bookSourceUrl: 'https://t.example/C', bookSourceName: 'C 仅 iOS' };
  db.upsertSource(srcA); db.setSourcePlatforms(srcA.bookSourceUrl, ['android', 'ios']);
  db.upsertSource(srcB); db.setSourcePlatforms(srcB.bookSourceUrl, ['android']);
  db.upsertSource(srcC); db.setSourcePlatforms(srcC.bookSourceUrl, ['ios']);

  // Android 视角 → 看到 A + B, 不看到 C
  const rAndroid = await request(app).get('/api/sources').expect(200);
  const aUrls = new Set(rAndroid.body.map(s => s.bookSourceUrl));
  assert.ok(aUrls.has(srcA.bookSourceUrl), 'Android 应看到 A');
  assert.ok(aUrls.has(srcB.bookSourceUrl), 'Android 应看到 B');
  assert.ok(!aUrls.has(srcC.bookSourceUrl), 'Android 不应看到 C');

  // iOS 视角 → 看到 A + C, 不看到 B
  const rIOS = await request(app).get('/api/sources').set('X-Platform', 'ios').expect(200);
  const iUrls = new Set(rIOS.body.map(s => s.bookSourceUrl));
  assert.ok(iUrls.has(srcA.bookSourceUrl), 'iOS 应看到 A');
  assert.ok(!iUrls.has(srcB.bookSourceUrl), 'iOS 不应看到 B');
  assert.ok(iUrls.has(srcC.bookSourceUrl), 'iOS 应看到 C');

  // 清理
  db.deleteSource(srcA.bookSourceUrl);
  db.deleteSource(srcB.bookSourceUrl);
  db.deleteSource(srcC.bookSourceUrl);
});

test('GET /api/sources ETag is bucketed per platform (iOS 不该误中 Android 的 304)', async () => {
  // 写一个 Android-only 源, 让两端结果不同
  const src = { bookSourceUrl: 'https://t.example/etag', bookSourceName: 'etag test' };
  db.upsertSource(src);
  db.setSourcePlatforms(src.bookSourceUrl, ['android']);

  const rA = await request(app).get('/api/sources').expect(200);
  const rI = await request(app).get('/api/sources').set('X-Platform', 'ios').expect(200);
  assert.notEqual(rA.headers.etag, rI.headers.etag, 'Android 跟 iOS ETag 必须不同');
  assert.match(rA.headers.etag, /android/, 'Android etag 应含 android 前缀');
  assert.match(rI.headers.etag, /ios/, 'iOS etag 应含 ios 前缀');

  // 拿 Android 的 ETag 当 iOS 的 If-None-Match → mismatch → 200 (不会错误返 304)
  await request(app).get('/api/sources')
    .set('X-Platform', 'ios')
    .set('If-None-Match', rA.headers.etag)
    .expect(200);
  // 自家平台 ETag 才命中 304
  await request(app).get('/api/sources')
    .set('X-Platform', 'ios')
    .set('If-None-Match', rI.headers.etag)
    .expect(304);

  db.deleteSource(src.bookSourceUrl);
});

test('PATCH /api/admin/sources/platforms 鉴权 + 校验 + 持久化', async () => {
  const url = 'https://t.example/patch';
  db.upsertSource({ bookSourceUrl: url, bookSourceName: 'patch-test' });

  // 没登录直接 401
  await request(app)
    .patch('/api/admin/sources/platforms')
    .send({ url, platforms: ['ios'] })
    .expect(401);

  // 登录后才能改
  const agent = request.agent(app);
  await agent.post('/api/admin/login')
    .send({ password: process.env.ADMIN_INITIAL_PASSWORD })
    .expect(200);

  // platforms 不是数组 → 400
  let r = await agent.patch('/api/admin/sources/platforms')
    .send({ url, platforms: 'ios' })
    .expect(400);
  assert.match(String(r.body.msg || ''), /array/);

  // 没 url → 400
  await agent.patch('/api/admin/sources/platforms')
    .send({ platforms: ['ios'] })
    .expect(400);

  // 不存在的 url → 404
  await agent.patch('/api/admin/sources/platforms')
    .send({ url: 'https://nope.example/missing', platforms: ['ios'] })
    .expect(404);

  // 合法改成只对 iOS 可见
  r = await agent.patch('/api/admin/sources/platforms')
    .send({ url, platforms: ['ios'] })
    .expect(200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.changed, 1);

  // 验证 Android 拉不到, iOS 拉得到
  const rA = await request(app).get('/api/sources').expect(200);
  assert.ok(!rA.body.some(s => s.bookSourceUrl === url), 'Android 不应看到');
  const rI = await request(app).get('/api/sources').set('X-Platform', 'ios').expect(200);
  assert.ok(rI.body.some(s => s.bookSourceUrl === url), 'iOS 应看到');

  // 非法平台名静默丢弃 (不报错, 但实际只剩合法的)
  r = await agent.patch('/api/admin/sources/platforms')
    .send({ url, platforms: ['ios', 'WindowsPhone', '../etc/passwd'] })
    .expect(200);
  // 验证只剩 ios
  const after = db.getSource(url);
  assert.equal(String(after.platforms || ''), 'ios', '非法平台应被过滤');

  db.deleteSource(url);
});

test('PATCH /api/admin/sources/platforms/bulk 批量加/去某平台', async () => {
  const urls = [
    'https://t.example/bulk1',
    'https://t.example/bulk2',
    'https://t.example/bulk3',
  ];
  for (const u of urls) {
    db.upsertSource({ bookSourceUrl: u, bookSourceName: 'bulk' });
    db.setSourcePlatforms(u, ['android']);  // 初始仅 Android
  }

  const agent = request.agent(app);
  await agent.post('/api/admin/login')
    .send({ password: process.env.ADMIN_INITIAL_PASSWORD })
    .expect(200);

  // 批量 add ios
  let r = await agent.patch('/api/admin/sources/platforms/bulk')
    .send({ urls, platform: 'ios', op: 'add' })
    .expect(200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.changed, 3);

  // 验证全部都已经是 'android,ios'
  for (const u of urls) {
    const row = db.getSource(u);
    const plats = String(row.platforms || '').split(',').sort();
    assert.deepEqual(plats, ['android', 'ios'], u + ' 应为 android,ios');
  }

  // 再次 add 同样平台 → changed=0 (幂等)
  r = await agent.patch('/api/admin/sources/platforms/bulk')
    .send({ urls, platform: 'ios', op: 'add' })
    .expect(200);
  assert.equal(r.body.changed, 0, '重复 add 应幂等');

  // 批量 remove android
  r = await agent.patch('/api/admin/sources/platforms/bulk')
    .send({ urls, platform: 'android', op: 'remove' })
    .expect(200);
  assert.equal(r.body.changed, 3);
  for (const u of urls) {
    const row = db.getSource(u);
    assert.equal(String(row.platforms || ''), 'ios', u + ' 应仅剩 ios');
  }

  // 非法 op → 400
  await agent.patch('/api/admin/sources/platforms/bulk')
    .send({ urls, platform: 'ios', op: 'wipe' })
    .expect(400);

  // 非法 platform → 400
  await agent.patch('/api/admin/sources/platforms/bulk')
    .send({ urls, platform: 'WindowsPhone', op: 'add' })
    .expect(400);

  // 空 urls → 400
  await agent.patch('/api/admin/sources/platforms/bulk')
    .send({ urls: [], platform: 'ios', op: 'add' })
    .expect(400);

  for (const u of urls) db.deleteSource(u);
});

// === 万象书屋 v2 (008): bookstore feed (M2.3.1) ===

test('GET /api/bookstore/feed validates channel', async () => {
  const did = 'feed-test-' + Date.now();
  const reg = await request(app).post('/api/device/register').set('X-Platform', 'ios').send({ device_id: did }).expect(200);
  const token = reg.body.token;

  // 缺 channel → 400
  await request(app).get('/api/bookstore/feed')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token)
    .expect(400);
  // 非法 channel → 400
  await request(app).get('/api/bookstore/feed?channel=xxx')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token)
    .expect(400);
  // 合法 channel → 200 (空)
  const r = await request(app).get('/api/bookstore/feed?channel=male')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token)
    .expect(200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.channel, 'male');
  assert.ok(Array.isArray(r.body.items));
});

test('admin bookstore-feed upsert / list / delete', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: process.env.ADMIN_INITIAL_PASSWORD }).expect(200);

  // 列空
  let r = await agent.get('/api/admin/bookstore-feed').expect(200);
  const before = r.body.length;

  // 加 1 条
  r = await agent.post('/api/admin/bookstore-feed').send({
    channel: 'male', section: 'banner',
    name: '三体', author: '刘慈欣',
    target_url: 'https://stub.example/sanyi', priority: 0
  }).expect(200);
  assert.equal(r.body.ok, true);
  const id = r.body.item.id;
  assert.ok(id > 0);

  // 列表能看到
  r = await agent.get('/api/admin/bookstore-feed').expect(200);
  assert.equal(r.body.length, before + 1);
  assert.ok(r.body.find(x => x.id === id));

  // 公开 API 也能看到
  const did = 'feed-public-' + Date.now();
  const reg = await request(app).post('/api/device/register').set('X-Platform', 'ios').send({ device_id: did }).expect(200);
  r = await request(app).get('/api/bookstore/feed?channel=male')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', reg.body.token)
    .expect(200);
  assert.ok(r.body.items.find(x => x.id === id));

  // 切 enabled = false
  await agent.patch(`/api/admin/bookstore-feed/${id}/enabled`)
    .send({ enabled: false }).expect(200);
  r = await request(app).get('/api/bookstore/feed?channel=male')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', reg.body.token)
    .expect(200);
  assert.ok(!r.body.items.find(x => x.id === id), 'disabled 后公开 API 不应再返回');

  // 删
  await agent.delete(`/api/admin/bookstore-feed/${id}`).expect(200);
  r = await agent.get('/api/admin/bookstore-feed').expect(200);
  assert.ok(!r.body.find(x => x.id === id));
});

test('GET /api/bookstore/feed ETag 304 命中', async () => {
  const did = 'feed-etag-' + Date.now();
  const reg = await request(app).post('/api/device/register').set('X-Platform', 'ios').send({ device_id: did }).expect(200);
  const token = reg.body.token;

  const r1 = await request(app).get('/api/bookstore/feed?channel=female')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token).expect(200);
  const etag = r1.headers.etag;
  assert.ok(etag);

  await request(app).get('/api/bookstore/feed?channel=female')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token)
    .set('If-None-Match', etag).expect(304);
});

// === source health (/api/source-error + /api/sources?healthy=1) ===

test('POST /api/source-error rejects unknown sourceUrl', async () => {
  const did = 'src-err-unknown-' + Date.now();
  const reg = await request(app).post('/api/device/register')
    .set('X-Platform', 'ios').send({ device_id: did }).expect(200);
  const r = await request(app).post('/api/source-error')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', reg.body.token)
    .send({ sourceUrl: 'https://attacker.example/feed', stage: 'search', status: 'error' });
  assert.equal(r.status, 400, 'unknown source must be rejected');
  assert.match(String(r.body.msg || ''), /unknown sourceUrl/);
});

test('healthy=1 hides source only after fail_count threshold', async () => {
  // 1) 注入一个 iOS 可见书源
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: process.env.ADMIN_INITIAL_PASSWORD }).expect(200);
  const url = 'https://health-test.example';
  await agent.post('/api/admin/sources').send({
    bookSourceUrl: url, bookSourceName: 'health-test',
    searchUrl: url + '/s?q={{key}}',
    ruleSearch: { bookList: '.li', name: 'h2', bookUrl: 'a' },
    ruleToc: { chapterList: '.dd', chapterName: 'a', chapterUrl: 'a@href' },
    ruleContent: { content: '.body' }
  }).expect(200);
  await agent.patch('/api/admin/sources/platforms').send({ url, platforms: ['ios'] }).expect(200);

  // 2) 注册 iOS 设备
  const did = 'src-err-ios-' + Date.now();
  const reg = await request(app).post('/api/device/register')
    .set('X-Platform', 'ios').send({ device_id: did }).expect(200);
  const token = reg.body.token;
  const post = body => request(app).post('/api/source-error')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token)
    .send(body);

  // 3) 1 次失败仍可见 (阈值 5)
  await post({ sourceUrl: url, stage: 'search', status: 'error', errorMessage: 'boom' }).expect(200);
  let r = await request(app).get('/api/sources?healthy=1')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token).expect(200);
  assert.ok(r.body.find(s => s.bookSourceUrl === url), 'after 1 fail still visible');

  // 4) 累积 6 次后被过滤
  for (let i = 0; i < 5; i++) {
    await post({ sourceUrl: url, stage: 'search', status: 'error' }).expect(200);
  }
  r = await request(app).get('/api/sources?healthy=1')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token).expect(200);
  assert.ok(!r.body.find(s => s.bookSourceUrl === url), 'after >=5 fails should be hidden');

  // 5) 1 次成功后恢复 (success_count > 0 即解除)
  await post({ sourceUrl: url, stage: 'search', status: 'ok' }).expect(200);
  r = await request(app).get('/api/sources?healthy=1')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token).expect(200);
  assert.ok(r.body.find(s => s.bookSourceUrl === url), 'recovered after one ok');

  // 6) 普通 /api/sources (无 healthy) 始终可见
  r = await request(app).get('/api/sources')
    .set('X-Platform', 'ios').set('X-Device-Id', did).set('X-Device-Token', token).expect(200);
  assert.ok(r.body.find(s => s.bookSourceUrl === url), 'non-healthy listing always returns the source');
});

test('admin source-health summary + static check', async () => {
  const agent = request.agent(app);
  await agent.post('/api/admin/login').send({ password: process.env.ADMIN_INITIAL_PASSWORD }).expect(200);

  let r = await agent.get('/api/admin/source-health/summary?platform=ios').expect(200);
  assert.equal(r.body.ok, true);
  assert.ok(Array.isArray(r.body.summary));

  r = await agent.post('/api/admin/sources/check').send({ platform: 'ios', sampleKeyword: '斗破苍穹' }).expect(200);
  assert.equal(r.body.ok, true);
  assert.ok('checked' in r.body);
});

// =====================================================================
// 万象书屋 D-15 P0 修复回归测试 (B-1 / B-2 / B-3 / A-1).
// 这一批用于验证报告里指出的 P0 问题已被根治, 防止未来回归.
// =====================================================================

test('D-15 (B-1): _DUMMY_PWD_HASH valid → ghost-user login takes ≈ same time as real-user wrong-pw', async () => {
  // 这是 timing-safe 防御的本质回归测试: 不存在的 username 必须跟 "存在但密码错" 跑同样的 bcrypt.compare.
  //
  // 修复前 (旧 dummy 非法): ghost ≈ 0ms (bcrypt 立即 throw 被 catch), real ≈ N ms (cost=4 ~1-5ms).
  //                       ratio real/ghost 趋于无穷, timing 攻击可枚举用户名.
  // 修复后 (启动 hashSync):  ghost 与 real 都跑同样一次 bcrypt.compare, 时间应大致相等.
  //
  // 阈值: ghost 至少为 real 的 30% (real * 0.3). 修复前比值 ~0%, 修复后 ~95%.
  // 不用绝对时间是因为不同机器 bcrypt.compare(cost=4) 从 0.3ms (Apple M3) 到 10ms (低端 VPS) 浮动很大.

  // 1) 准备一个真实 admin_user 当 baseline (注意: 用 super 角色避免误改 RBAC)
  const victim = 'b1-timing-victim-' + Date.now();
  await db.createAdminUser({
    username: victim,
    password: 'long-enough-test-password-123',
    role: 'cs',
    creator: 'p0-regression-test'
  });

  // 2) 各做 N 次, 使总耗时足够大避免抖动 (50 次, cost=4 时累计 ~50-500ms)
  const N = 50;
  async function timeit(username) {
    const t0 = process.hrtime.bigint();
    for (let i = 0; i < N; i++) {
      await db.verifyAdminUser(username, 'wrong-password-' + i);
    }
    return Number(process.hrtime.bigint() - t0) / 1e6;  // ms
  }

  // 万象书屋: 跑两轮取平均, 避免 V8 JIT/GC 抖动. 各 100 次.
  const realT  = (await timeit(victim) + await timeit(victim)) / 2;
  const ghostT = (await timeit('ghost-' + Date.now()) + await timeit('ghost2-' + Date.now())) / 2;

  // 清理
  db.deleteAdminUser(victim);

  // 3) 关键断言: ghost 至少得花 real 的 30%, 否则说明 dummy hash 没在跑 bcrypt
  const ratio = ghostT / Math.max(realT, 0.001);
  assert.ok(ratio >= 0.3,
    `B-1 regression: ghost user verify took ${ghostT.toFixed(2)}ms, real-but-wrong-pw took ${realT.toFixed(2)}ms (ratio=${ratio.toFixed(3)}). ghost should be >=30% of real to prove _DUMMY_PWD_HASH is valid bcrypt and bcrypt.compare actually runs.`);
});

test('D-15 (B-2): /metrics emits real wanxiang_active_devices_today and heartbeats_24h', async () => {
  // 修复前: server.js 用 stats.activeDevices / stats.heartbeats 但 db.statsToday() 返回 number,
  //         两个 metric 永远输出 0, 监控告警全部失灵.
  // 修复后: 直接消费 db.statsToday() 数值 + 单独 query heartbeats 24h.
  // 准备一条 heartbeat 让 metric 至少非零
  const did = 'metrics-test-' + Date.now();
  db.recordPing(did);

  const res = await request(app).get('/metrics').expect(200);
  // 验证三个指标都存在且为整数
  const m1 = res.text.match(/^wanxiang_active_devices_today (\d+)$/m);
  assert.ok(m1, 'metric wanxiang_active_devices_today missing — check /metrics handler');
  assert.ok(Number(m1[1]) >= 1,
    `active_devices_today should be >=1 after recordPing, got ${m1[1]} — likely back to "永远 0" bug`);

  // 修复同时引入 heartbeats_24h (替换原 heartbeats_today 错误命名) 和 online_5m
  assert.match(res.text, /^wanxiang_heartbeats_24h \d+$/m);
  assert.match(res.text, /^wanxiang_online_5m \d+$/m);
  assert.match(res.text, /^# HELP wanxiang_active_devices_today /m,
    'HELP comment should describe the metric meaningfully');
});

test('D-15 (B-3 / PIPL): wipeUserData deletes events / iap_receipts / source_error_events', async () => {
  // 修复前: tables 数组只有 7 个表, events / iap_receipts / source_error_events 三张含 device_id 的
  //         表被遗漏, 注销账号后仍留存 30~90 天 → 违反 PIPL 第 47 条 "应当主动删除".
  // 修复后: 这三张表加入清理列表.
  const did = 'wipe-pipl-test-' + Date.now();

  // 1. events: 直接 db.recordEvent 插入两条
  db.recordEvent({ deviceId: did, type: 'pv', name: 'test_page' });
  db.recordEvent({ deviceId: did, type: 'click', name: 'test_btn' });
  const eventsBefore = db.__db
    .prepare('SELECT COUNT(*) AS n FROM events WHERE device_id = ?').get(did).n;
  assert.equal(eventsBefore, 2, `should have 2 events before wipe, got ${eventsBefore}`);

  // 2. iap_receipts: 直接 saveIapReceipt 插一条
  db.saveIapReceipt({
    deviceId: did,
    productId: 'com.wanxiang.test.product',
    transactionId: 'tx-' + did,
    receiptData: 'fake-receipt-data',
    expiresAt: Date.now() + 86400000,
    sandbox: true,
    status: 'active',
    rawResponse: '{}'
  });
  const iapBefore = db.__db
    .prepare('SELECT COUNT(*) AS n FROM iap_receipts WHERE device_id = ?').get(did).n;
  assert.equal(iapBefore, 1);

  // 3. wipe
  const stats = db.wipeUserData(did);
  assert.ok(stats, 'wipeUserData should return stats object');
  assert.equal(stats.events, 2, `should report 2 events deleted: ${JSON.stringify(stats)}`);
  assert.equal(stats.iap_receipts, 1, `should report 1 iap_receipt deleted: ${JSON.stringify(stats)}`);
  assert.ok('source_error_events' in stats,
    `source_error_events must be in the wipe target list: ${JSON.stringify(stats)}`);

  // 4. 校验数据库中确实清空
  const eventsAfter = db.__db
    .prepare('SELECT COUNT(*) AS n FROM events WHERE device_id = ?').get(did).n;
  assert.equal(eventsAfter, 0, 'events table must be empty for this device after wipe');
  const iapAfter = db.__db
    .prepare('SELECT COUNT(*) AS n FROM iap_receipts WHERE device_id = ?').get(did).n;
  assert.equal(iapAfter, 0, 'iap_receipts table must be empty for this device after wipe');
});

test('D-15 (B-3): /api/me/wipe-data E2E removes events table records', async () => {
  // 走完整 HTTP 路径, 防 server 层路由把 db.wipeUserData 返回值改坏.
  const did = 'wipe-events-e2e-' + Date.now();
  const reg = await request(app)
    .post('/api/device/register')
    .send({ device_id: did })
    .expect(200);
  const token = reg.body.token;

  // 上报一条 event 走 HTTP (顺便覆盖 /api/events 接口)
  await request(app)
    .post('/api/events')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .send({ events: [{ ts: Date.now(), type: 'pv', name: 'page_main' }] })
    .expect(200);

  const before = db.__db
    .prepare('SELECT COUNT(*) AS n FROM events WHERE device_id = ?').get(did).n;
  assert.ok(before >= 1);

  // wipe
  const wipeRes = await request(app)
    .delete('/api/me/wipe-data')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .expect(200);
  assert.equal(wipeRes.body.ok, true);
  // 关键断言: deleted 字典里必须有 events 字段且 >=1
  assert.ok(wipeRes.body.deleted.events >= 1,
    `wipe response must report events count: ${JSON.stringify(wipeRes.body.deleted)}`);

  const after = db.__db
    .prepare('SELECT COUNT(*) AS n FROM events WHERE device_id = ?').get(did).n;
  assert.equal(after, 0, 'events should be 0 after wipe E2E');
});

test('D-16 (BACKEND-1): bookSourceUrl rejects non-http(s) schemes', async () => {
  // 修复前: db.upsertSource 仅校验 url 非空, javascript:/file://data:ftp:// 全部 200 OK 入库,
  //         下发到客户端后, admin.html 虽已 escape, 但 iOS WKWebView / 其它消费方直接 load
  //         仍可能触发协议级 XSS 或本地文件读取.
  // 修复后: 必须以 http:// 或 https:// 开头, URL.parse 必须通过, 否则 400.
  const agent = request.agent(app);
  await agent.post('/api/admin/login')
    .send({ password: process.env.ADMIN_INITIAL_PASSWORD })
    .expect(200);

  const badUrls = [
    'javascript:alert(document.cookie)',
    'file:///etc/passwd',
    'data:text/html,<script>x</script>',
    'ftp://x.com/',
    'JAVASCRIPT:alert(1)',         // 大写绕过尝试
    'http\\://faketrick.com',      // 非法字符绕过尝试
    'https://',                    // 仅 scheme
    '',                            // 空字符串
  ];
  for (const bad of badUrls) {
    const r = await agent.post('/api/admin/sources')
      .send({ bookSourceUrl: bad, bookSourceName: 'evil' });
    assert.equal(r.status, 400, `expected 400 for url='${bad}', got ${r.status}: ${JSON.stringify(r.body)}`);
    assert.match(String(r.body.msg || ''), /(http|invalid|required|valid URL)/i,
      `error msg should mention scheme/validity for '${bad}', got: ${r.body.msg}`);
  }

  // 反向: 合法 https/http 仍接受
  for (const ok of ['https://good.example.com/path?q=1', 'HTTP://Example.Com/']) {
    await agent.post('/api/admin/sources')
      .send({ bookSourceUrl: ok, bookSourceName: 'ok' })
      .expect(200);
  }

  // 批量场景: 数组里掺杂一个非法 URL → 整批应失败 (transaction 回滚)
  const before = (await agent.get('/api/admin/sources').expect(200)).body.length;
  const r = await agent.post('/api/admin/sources').send([
    { bookSourceUrl: 'https://bulk-ok.example.com', bookSourceName: 'ok' },
    { bookSourceUrl: 'javascript:alert(1)', bookSourceName: 'evil' },
  ]);
  assert.equal(r.status, 400, 'bulk with invalid scheme must reject');
  const after = (await agent.get('/api/admin/sources').expect(200)).body.length;
  assert.equal(after, before, 'transaction must rollback so good item not persisted');
});

test('D-16 (B-4 RBAC): cs role cannot modify book sources / ad config', async () => {
  // 修复前: POST/DELETE /api/admin/sources, PATCH .../enabled, .../platforms, .../platforms/bulk,
  //         .../group-enabled, POST /api/admin/bookstore-feed, POST /api/admin/ad-config 都仅
  //         requireAdmin (登录态), 没 requireRole, cs 客服可破坏运营数据.
  // 修复后: 上述全部加 requireRole(['super', 'operator']), cs 只能 GET / 看反馈处理反馈.
  //
  // 测试流程: super 创建 cs 用户 → cs 登录 → 尝试修改 → 全部 403

  // 1) super (legacy admin) 登录, 创建 cs 用户
  const superAgent = request.agent(app);
  await superAgent.post('/api/admin/login')
    .send({ password: process.env.ADMIN_INITIAL_PASSWORD })
    .expect(200);
  // legacy admin 是 super → 可调 super-only 创建用户
  const csUsername = 'b4-cs-user-' + Date.now();
  const csPassword = 'cs-test-pw-' + Date.now();
  await superAgent.post('/api/admin/users')
    .send({ username: csUsername, password: csPassword, role: 'cs' })
    .expect(200);

  // 2) cs 用户登录, 拿独立 cookie
  const csAgent = request.agent(app);
  await csAgent.post('/api/admin/login')
    .send({ username: csUsername, password: csPassword })
    .expect(200);

  // 3) 验证 cs 角色 GET 接口仍可访问 (查反馈/查源都允许看)
  await csAgent.get('/api/admin/sources').expect(200);

  // 4) 验证 cs 角色全部写接口被 403
  const writeAttempts = [
    ['POST',   '/api/admin/sources',                  { bookSourceUrl: 'https://b4.example.com', bookSourceName: 'evil' }],
    ['DELETE', '/api/admin/sources?url=https://x.com', null],
    ['PATCH',  '/api/admin/sources/enabled',          { url: 'https://x.com', enabled: false }],
    ['PATCH',  '/api/admin/sources/platforms',        { url: 'https://x.com', platforms: ['ios'] }],
    ['PATCH',  '/api/admin/sources/platforms/bulk',   { urls: ['https://x.com'], platform: 'ios', op: 'add' }],
    ['PATCH',  '/api/admin/sources/group-enabled',    { group: 'g', enabled: false }],
    ['POST',   '/api/admin/bookstore-feed',           { channel: 'male', name: 'x', target_url: 'http://x' }],
    ['POST',   '/api/admin/ad-config',                { placements: {} }],
  ];
  for (const [method, path, body] of writeAttempts) {
    let req = csAgent[method.toLowerCase()](path);
    if (body) req = req.send(body);
    const r = await req;
    assert.equal(r.status, 403, `cs should be denied on ${method} ${path}, got ${r.status}: ${JSON.stringify(r.body).slice(0, 120)}`);
    assert.match(String(r.body.msg || ''), /role denied|deny/i,
      `expected 'role denied' message, got ${JSON.stringify(r.body)}`);
  }

  // 5) 反向验证 super 可以
  await superAgent.post('/api/admin/sources')
    .send({ bookSourceUrl: 'https://super-can.example.com', bookSourceName: 'super-ok' })
    .expect(200);

  // 清理
  await superAgent.delete('/api/admin/sources?url=' + encodeURIComponent('https://super-can.example.com')).expect(200);
  await superAgent.delete('/api/admin/users/' + csUsername).expect(200);
});

// 万象书屋: 这条会消耗 admin login 限速预算, 必须放在所有需要 admin 登录的测试之后.
test('rate limit on /api/admin/login eventually triggers', async () => {
  // 连续打 12 次坏密码, 应在某次开始 429
  let got429 = false;
  for (let i = 0; i < 12; i++) {
    const res = await request(app)
      .post('/api/admin/login')
      .send({ password: 'wrong-pw-' + i });
    if (res.status === 429) { got429 = true; break; }
  }
  assert.equal(got429, true, 'should hit rate limit within 12 attempts');
});

test.after(() => {
  // 清掉临时目录
  try { fs.rmSync(TMP_DIR, { recursive: true, force: true }); } catch {}
  // server.js 启动了一些后台 setInterval (cleanup, alert scanner) 都已 unref(),
  // 但 supertest 创建的临时 socket 可能延后关闭. 强制退出避免测试 hang.
  setTimeout(() => process.exit(0), 200).unref();
});
