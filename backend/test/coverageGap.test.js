// 万象书屋后端 · 低覆盖模块补测
// 覆盖: version-check / announcement / promo(推广码全链路) / iap / alert rules
//
// 用法:
//   BCRYPT_COST=4 ADMIN_INITIAL_PASSWORD=test-password-12345 \
//     DEVICE_TOKEN_SECRET=test-secret-aaaaaaaaaaaaaaaaaaaaaaaa \
//     node --test test/coverageGap.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');
const os = require('os');

const TMP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'wxsw-covgap-'));
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

async function adminLogin(agent) {
  const r = await agent.post('/api/admin/login').send({ password: ADMIN_PW });
  assert.equal(r.status, 200, 'admin login 应成功');
  return r;
}

// promo 端点现需设备鉴权 (verifyDeviceTokenStrict). 注册设备拿 token,
// 请求带 X-Device-Id / X-Device-Token. test 环境 rate limit 为 no-op, 可重复注册.
async function registerDevice(deviceId) {
  const r = await request(app).post('/api/device/register').send({ device_id: deviceId });
  if (r.status === 409) {
    const r2 = await request(app).post('/api/device/register?reissue=1').send({ device_id: deviceId });
    return r2.body.token;
  }
  return r.body.token;
}

async function promoGet(path, deviceId, status = 200) {
  const token = await registerDevice(deviceId);
  return request(app).get(path)
    .set('X-Device-Id', deviceId).set('X-Device-Token', token)
    .expect(status);
}

async function promoPost(path, deviceId, body, status = 200) {
  const token = await registerDevice(deviceId);
  return request(app).post(path)
    .set('X-Device-Id', deviceId).set('X-Device-Token', token)
    .send({ device_id: deviceId, ...body })
    .expect(status);
}

// ─────────────────────────────────────────────
// /api/version-check (appVersion.js)
// ─────────────────────────────────────────────
test('version-check 默认无强制升级 (未配置)', async () => {
  const res = await request(app).get('/api/version-check').expect(200);
  assert.equal(res.body.ok === undefined, true, 'version-check 不返回 ok 字段');
  assert.equal(typeof res.body.latestCode, 'number');
  assert.equal(typeof res.body.forceUpgrade, 'boolean');
  assert.equal(typeof res.body.needUpgrade, 'boolean');
});

test('version-check 老版本触发 forceUpgrade + needUpgrade', async () => {
  db.saveAppVersion({
    latest_code: 200, latest_name: 'v2.0', min_required_code: 150,
    changelog: '测试更新', apk_url: 'https://wxsw.app/a.apk', market_url: 'https://apps.apple.com/x',
  });
  // code=100 < min(150) → 两个都 true
  const r1 = await request(app).get('/api/version-check?code=100').expect(200);
  assert.equal(r1.body.forceUpgrade, true);
  assert.equal(r1.body.needUpgrade, true);
  assert.equal(r1.body.latestName, 'v2.0');
  assert.equal(r1.body.changelog, '测试更新');
  // code=180 < latest(200) 但 >= min → 只需更新不需强制
  const r2 = await request(app).get('/api/version-check?code=180').expect(200);
  assert.equal(r2.body.forceUpgrade, false);
  assert.equal(r2.body.needUpgrade, true);
  // code=300 ≥ latest → 都不需要
  const r3 = await request(app).get('/api/version-check?code=300').expect(200);
  assert.equal(r3.body.forceUpgrade, false);
  assert.equal(r3.body.needUpgrade, false);
});

test('version-check extra_json 里 min_os 生效, review_mode 时隐藏', async () => {
  db.saveExtraConfig({ min_os: 17 });
  const r1 = await request(app).get('/api/version-check').expect(200);
  assert.equal(r1.body.min_os, 17);
  // review_mode → 不返回 min_os
  db.kvSet('review_mode', '1');
  const r2 = await request(app).get('/api/version-check').expect(200);
  assert.equal(r2.body.min_os, undefined);
  db.kvSet('review_mode', '0');
});

// ─────────────────────────────────────────────
// /api/announcement (alerts/appVersion.js)
// ─────────────────────────────────────────────
test('announcement 空列表 + etag 304', async () => {
  const r1 = await request(app).get('/api/announcement').expect(200);
  assert.equal(r1.body.ok, true);
  assert.ok(Array.isArray(r1.body.list));
  assert.ok(r1.headers.etag);
  const etag = r1.headers.etag;
  const r2 = await request(app).get('/api/announcement').set('If-None-Match', etag).expect(304);
  assert.ok(r2.body === undefined || Object.keys(r2.body).length === 0);
});

test('announcement 按 versionCode 过滤 + admin CRUD', async () => {
  const agent = request.agent(app);
  await adminLogin(agent);

  // 创建一条 min=100, max=200 的公告
  const now = Date.now();
  const create = await agent.post('/api/admin/announcement').send({
    title: '测试公告', content: '覆盖测试内容', style: 'info',
    dismissable: true, enabled: true, start_at: now - 1000, end_at: now + 86400000,
    version_min: 100, version_max: 200,
  }).expect(200);
  assert.equal(create.body.ok, true);
  const id = create.body.id;

  // versionCode=150 能看到
  const rIn = await request(app).get('/api/announcement?versionCode=150').expect(200);
  const inList = rIn.body.list.filter(a => a.id === id);
  assert.equal(inList.length, 1, 'versionCode=150 应看到公告');
  assert.equal(inList[0].title, '测试公告');
  // versionCode=50 看不到 (< min)
  const rLow = await request(app).get('/api/announcement?versionCode=50').expect(200);
  assert.equal(rLow.body.list.filter(a => a.id === id).length, 0, 'versionCode=50 不应看到公告');
  // versionCode=300 看不到 (> max)
  const rHigh = await request(app).get('/api/announcement?versionCode=300').expect(200);
  assert.equal(rHigh.body.list.filter(a => a.id === id).length, 0, 'versionCode=300 不应看到公告');

  // admin 列表包含它
  const listAll = await agent.get('/api/admin/announcements').expect(200);
  assert.ok(listAll.body.list.some(a => a.id === id));

  // 删除
  await agent.delete(`/api/admin/announcement/${id}`).expect(200);
  const rAfter = await request(app).get('/api/announcement?versionCode=150').expect(200);
  assert.equal(rAfter.body.list.filter(a => a.id === id).length, 0, '删除后应消失');
});

// ─────────────────────────────────────────────
// /api/promo/* 公开链路 (promo.js)
// ─────────────────────────────────────────────
test('promo 公开列表在 review_mode 下返回空', async () => {
  db.kvSet('review_mode', '1');
  const r = await request(app).get('/api/promo/codes').expect(200);
  assert.deepEqual(r.body.codes, []);
  db.kvSet('review_mode', '0');
});

test('promo agent-stats 校验: 无码 400 / 不存在 / 停用', async () => {
  const did = 'device-stats-1';
  // 无码
  await promoGet('/api/promo/agent-stats', did, 400);
  // 不存在
  const rMiss = await promoGet('/api/promo/agent-stats?code=NOPE', did);
  assert.equal(rMiss.body.ok, false);
  assert.equal(rMiss.body.msg, '推广码不存在');
});

test('promo 全链路: 建码 → 列表 → usage → 上限 → 单设备 → 停用', async () => {
  const agent = request.agent(app);
  await adminLogin(agent);

  // 建码: 限制 2 次, 单设备
  const create = await agent.post('/api/admin/promo/codes').send({
    code: 'COVER01', agentName: '覆盖测试', maxUses: 2, singleDevice: true,
  }).expect(200);
  assert.equal(create.body.ok, true);

  // 公开列表可见 (非 review_mode)
  const list = await request(app).get('/api/promo/codes').expect(200);
  assert.ok(list.body.codes.some(c => c.code === 'COVER01'));
  const item = list.body.codes.find(c => c.code === 'COVER01');
  assert.equal(item.single_device, true);
  assert.equal(item.max_uses, 2);

  // agent-stats 现在有数据
  const stats = await promoGet('/api/promo/agent-stats?code=COVER01', 'device-stats-2');
  assert.equal(stats.body.ok, true);
  assert.equal(stats.body.agentName, '覆盖测试');

  // usage 成功 (设备 A)
  const u1 = await promoPost('/api/promo/usage', 'device-a', {
    code: 'COVER01', device_model: 'iPhone 15',
  });
  assert.equal(u1.body.ok, true);

  // 单设备限制: 同设备重复使用被拒
  const u2 = await promoPost('/api/promo/usage', 'device-a', { code: 'COVER01' }, 400);
  assert.equal(u2.body.msg, '该推广码仅限单个设备使用');

  // 第二个设备成功
  await promoPost('/api/promo/usage', 'device-b', { code: 'COVER01' });

  // 达到 max_uses=2 → 第三个设备被拒
  const u3 = await promoPost('/api/promo/usage', 'device-c', { code: 'COVER01' }, 400);
  assert.equal(u3.body.msg, '该推广码已达使用上限');

  // attempt 记录
  await promoPost('/api/promo/attempt', 'device-x', {
    code: 'COVER01', success: false, device_model: 'Pixel',
  });

  // admin stats
  const o = await agent.get('/api/admin/promo/stats').expect(200);
  assert.ok(o.body.totalCodes >= 1);
  assert.ok(o.body.totalUses >= 2);
  assert.ok(o.body.uniqueDevices >= 2);

  // code 级 stats
  const cs = await agent.get('/api/admin/promo/stats/COVER01').expect(200);
  assert.equal(cs.body.code.code, 'COVER01');
  assert.ok(cs.body.totalAttempts >= 1);
  assert.ok(cs.body.totalUses >= 2);
  assert.ok(cs.body.uniqueDevices >= 2);

  // 停用 → agent-stats 拒绝 + usage 拒绝
  const dis = await agent.put('/api/admin/promo/codes/COVER01').send({ enabled: false }).expect(200);
  assert.equal(dis.body.ok, true);
  const agentStatsDisabled = await promoGet('/api/promo/agent-stats?code=COVER01', 'device-stats-2');
  assert.equal(agentStatsDisabled.body.msg, '该推广码已停用');
  const uDisabled = await promoPost('/api/promo/usage', 'device-d', { code: 'COVER01' }, 400);
  assert.equal(uDisabled.body.msg, '该推广码已停用');

  // 删除
  await agent.delete('/api/admin/promo/codes/COVER01').expect(200);
  const afterDel = await promoGet('/api/promo/agent-stats?code=COVER01', 'device-stats-2');
  assert.equal(afterDel.body.msg, '推广码不存在');
});

test('promo 有效期过期拒绝', async () => {
  const agent = request.agent(app);
  await adminLogin(agent);
  await agent.post('/api/admin/promo/codes').send({
    code: 'EXPIRED01', agentName: '过期测试', expiresAt: Date.now() - 1000,
  }).expect(200);
  const u = await promoPost('/api/promo/usage', 'device-e', { code: 'EXPIRED01' }, 400);
  assert.equal(u.body.msg, '该推广码已过期');
  await agent.delete('/api/admin/promo/codes/EXPIRED01').expect(200);
});

test('promo fraud detection 抓同设备多码', async () => {
  const agent = request.agent(app);
  await adminLogin(agent);
  await agent.post('/api/admin/promo/codes').send({ code: 'FRAUD01', agentName: '风控测试' }).expect(200);
  await agent.post('/api/admin/promo/codes').send({ code: 'FRAUD02', agentName: '风控测试2' }).expect(200);
  // 同一设备用两个码
  await promoPost('/api/promo/usage', 'fraud-device', { code: 'FRAUD01' });
  await promoPost('/api/promo/usage', 'fraud-device', { code: 'FRAUD02' });
  const fraud = await agent.get('/api/admin/promo/fraud').expect(200);
  assert.ok(Array.isArray(fraud.body.alerts));
  const hit = fraud.body.alerts.find(a => a.type === 'multi_code_device' && a.detail.deviceId === 'fraud-device');
  assert.ok(hit, '应抓到同设备多码告警');
  await agent.delete('/api/admin/promo/codes/FRAUD01').expect(200);
  await agent.delete('/api/admin/promo/codes/FRAUD02').expect(200);
});

// ─────────────────────────────────────────────
// /api/iap/* (iap.js)
// ─────────────────────────────────────────────
test('iap entitlements 无 device_id 400 + 空设备返回空', async () => {
  await request(app).get('/api/iap/entitlements').expect(400);
  const r = await request(app).get('/api/iap/entitlements?device_id=none-dev').expect(200);
  assert.equal(r.body.ok, true);
  assert.deepEqual(r.body.entitlements, []);
  assert.deepEqual(r.body.receipts, []);
});

test('iap verify 占位返回 503', async () => {
  const r = await request(app).post('/api/iap/verify')
    .set('X-Device-Id', 'dev-iap').send({ receiptData: 'xx' });
  assert.equal(r.status, 503);
  assert.equal(r.body.msg, 'IAP verification not yet enabled');
});

// ─────────────────────────────────────────────
// admin 鉴权 (补充 promo 管理路由权限)
// ─────────────────────────────────────────────
test('admin promo 路由未登录 401', async () => {
  await request(app).get('/api/admin/promo/codes').expect(401);
  await request(app).get('/api/admin/promo/stats').expect(401);
  await request(app).get('/api/admin/promo/fraud').expect(401);
});

// ─────────────────────────────────────────────
// heartbeat 统计 (heartbeat.js)
// ─────────────────────────────────────────────
test('heartbeat recordPing + stats 全链路', async () => {
  // 空状态
  assert.equal(db.statsOnline(), 0);
  // 插入 2 个设备
  db.recordPing('hb-dev-1');
  db.recordPing('hb-dev-2');
  assert.ok(db.statsOnline() >= 2);
  assert.ok(db.statsToday() >= 2);
  assert.ok(db.statsWeek() >= 2);
  assert.ok(db.statsMonth() >= 2);
  // 无 deviceId 不崩
  db.recordPing('');
  // daily curve (升序: 6天前 → 今天)
  const curve = db.statsDailyCurve(7);
  assert.equal(curve.length, 7);
  assert.ok(curve[6].count >= 2, `今天(curve[6])应有我们的 ping, 实际 ${curve[6].count}`);
  // 越界天数 clamp
  assert.equal(db.statsDailyCurve(999).length, 60);
});

// ─────────────────────────────────────────────
// alert rules CRUD (alerts.js)
// ─────────────────────────────────────────────
test('alert rules upsert / list / delete / markFired', async () => {
  const id = db.upsertAlertRule({
    name: '测试规则', kind: 'http_5xx', threshold: 10, window_min: 5,
    webhook_url: 'https://example.com/hook', webhook_kind: 'wecom',
    enabled: true, cooldown_min: 30,
  });
  assert.ok(id > 0, '应返回新 id');

  const list = db.listAlertRules();
  const mine = list.find(r => r.id === id);
  assert.ok(mine, '列表应包含新规则');
  assert.equal(mine.kind, 'http_5xx');

  // markFired
  db.markAlertFired(id);
  const after = db.listAlertRules().find(r => r.id === id);
  assert.ok(after.last_fired_at > 0, '应记录 last_fired_at');

  // 更新
  const upd = db.upsertAlertRule({ id, name: '改名', kind: 'search_zero', threshold: 3, window_min: 10, webhook_url: 'x', webhook_kind: 'wecom', enabled: false, cooldown_min: 5 });
  assert.equal(upd, id, '更新应返回原 id');
  const updRow = db.listAlertRules().find(r => r.id === id);
  assert.equal(updRow.name, '改名');
  assert.equal(updRow.enabled, 0);

  // 删除
  db.deleteAlertRule(id);
  assert.equal(db.listAlertRules().find(r => r.id === id), undefined, '删除后应消失');
});

test.after(() => {
  // 清掉临时目录
  try { fs.rmSync(TMP_DIR, { recursive: true, force: true }); } catch {}
  // 强制退出避免 supertest keep-alive socket 挂住测试进程
  setTimeout(() => process.exit(0), 200).unref();
});
