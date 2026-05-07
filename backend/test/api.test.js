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
  // Android 设备调 /api/iap/verify 应该被 400 拒
  const did = 'android-iap-' + Date.now();
  const reg = await request(app)
    .post('/api/device/register')
    .send({ device_id: did })
    .expect(200);
  const token = reg.body.token;

  const r = await request(app)
    .post('/api/iap/verify')
    .set('X-Platform', 'android')   // 关键: 标 android
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .send({
      device_id: did,
      product_id: 'com.wanxiang.adfree.lifetime',
      transaction_id: 'fake-tx-1',
      receipt_data: 'fake-receipt-base64',
    })
    .expect(400);
  assert.match(String(r.body.msg || ''), /iOS-only/i);
});

test('IAP verify validates required fields', async () => {
  const did = 'ios-iap-' + Date.now();
  const reg = await request(app)
    .post('/api/device/register')
    .set('X-Platform', 'ios')
    .send({ device_id: did })
    .expect(200);
  const token = reg.body.token;

  // 缺 receipt_data
  const r = await request(app)
    .post('/api/iap/verify')
    .set('X-Platform', 'ios')
    .set('X-Device-Id', did)
    .set('X-Device-Token', token)
    .send({
      device_id: did,
      product_id: 'com.wanxiang.adfree.lifetime',
      transaction_id: 'fake-tx-1',
      // receipt_data 缺
    })
    .expect(400);
  assert.match(String(r.body.msg || ''), /required/i);
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
