// 万象书屋后端 · promo / alerts / qimaoUpdater 纯逻辑补测
// 覆盖:
//   promo.js    — recordPromoUsage 全失败分支 (不存在/停用/过期/上限/单设备)
//               — promoFraudDetection 5 类告警 (multi_code / ip_burst / code_burst / same_model / brute_force)
//   alerts.js   — upsertAlertRule 插入/更新 / list / markFired / delete
//   qimaoUpdater.js — md5Sign / buildUrl / stripHtml / decryptContent 加解密往返
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

const TMP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'wxsw-promoal-'));
process.env.DB_PATH = path.join(TMP_DIR, 'wanxiang.db');
process.env.LOG_LEVEL = 'error';

const db = require('../db');
const promo = require('../models/promo');
const alerts = require('../models/alerts');
const qimao = require('../jobs/qimaoUpdater');

const NOW = Date.now();

// qimaoUpdater 内部常量 (与源码一致, 用于构造合法密文)
const QIMAO_SIGN_KEY = 'd3dGiJc651gSQ8w1';
const QIMAO_AES_KEY = Buffer.from('242ccb8230d709e1');

// ─── promo.js: recordPromoUsage ─────────────────────────────────────

test('promo recordPromoUsage: 正常使用成功 + used_count 自增', () => {
  promo.createPromoCode({ code: 'OK01', agentName: '代理A', maxUses: 3 });
  const r = promo.recordPromoUsage({ code: 'OK01', agentName: '代理A', deviceId: 'dev-1' });
  assert.deepEqual(r, { ok: true });
  const row = db.__db.prepare('SELECT used_count FROM promo_codes WHERE code=?').get('OK01');
  assert.equal(row.used_count, 1);
});

test('promo recordPromoUsage: 不存在/停用/过期/上限/单设备 各失败分支', () => {
  // 不存在
  assert.deepEqual(promo.recordPromoUsage({ code: 'NOPE', deviceId: 'd' }), { ok: false, msg: '推广码不存在' });
  // 停用
  promo.createPromoCode({ code: 'DIS01' });
  promo.updatePromoCode('DIS01', { enabled: false });
  assert.deepEqual(promo.recordPromoUsage({ code: 'DIS01', deviceId: 'd' }), { ok: false, msg: '该推广码已停用' });
  // 过期
  promo.createPromoCode({ code: 'EXP01', expiresAt: NOW - 1000 });
  assert.deepEqual(promo.recordPromoUsage({ code: 'EXP01', deviceId: 'd' }), { ok: false, msg: '该推广码已过期' });
  // 达上限
  promo.createPromoCode({ code: 'MAX01', maxUses: 1 });
  assert.deepEqual(promo.recordPromoUsage({ code: 'MAX01', deviceId: 'd1' }), { ok: true });
  assert.deepEqual(promo.recordPromoUsage({ code: 'MAX01', deviceId: 'd2' }), { ok: false, msg: '该推广码已达使用上限' });
  // 单设备限制
  promo.createPromoCode({ code: 'SINGLE01', singleDevice: true });
  assert.deepEqual(promo.recordPromoUsage({ code: 'SINGLE01', deviceId: 'sd1' }), { ok: true });
  assert.deepEqual(promo.recordPromoUsage({ code: 'SINGLE01', deviceId: 'sd1' }), { ok: false, msg: '该推广码仅限单个设备使用' });
});

test('promo recordPromoUsage: 无 max_uses (0=不限) 可重复使用', () => {
  promo.createPromoCode({ code: 'UNLIM01' });
  assert.deepEqual(promo.recordPromoUsage({ code: 'UNLIM01', deviceId: 'u1' }), { ok: true });
  assert.deepEqual(promo.recordPromoUsage({ code: 'UNLIM01', deviceId: 'u2' }), { ok: true });
});

test('promo promoFraudDetection: 5 类告警全触发', () => {
  const now = Date.now();
  const t = now; // promo_usage.ts / promo_attempts.ts 用毫秒时间戳
  const insUsage = db.__db.prepare(
    'INSERT INTO promo_usage (code, agent_name, device_id, device_model, system_version, ip, ts) VALUES (?,?,?,?,?,?,?)'
  );
  const insAttempt = db.__db.prepare(
    'INSERT INTO promo_attempts (code, device_id, device_model, success, ip, ts) VALUES (?,?,?,?,?,?)'
  );

  // multi_code_device: 同一设备用 2 个不同码
  insUsage.run('MC01', 'a', 'multi-dev', 'iPhone', null, '1.1.1.1', t);
  insUsage.run('MC02', 'a', 'multi-dev', 'iPhone', null, '1.1.1.1', t);

  // ip_burst: 同一 IP 10 次 (>=10 → high)
  for (let i = 0; i < 10; i++) insUsage.run(`IPB${i}`, 'a', `ipb-dev-${i}`, null, null, '2.2.2.2', t);

  // code_burst: 同一 code 5 次在 30 分钟内 (spanMin < 30)
  for (let i = 0; i < 5; i++) insUsage.run('CB01', 'a', `cb-dev-${i}`, null, null, `3.3.3.${i}`, t - i * 60 * 1000);

  // same_model: 同一 code 下同型号占比 > 0.8 且总数 >=5 (6 台里 5 台 Xiaomi-14 → 0.83)
  const modelCodes = ['SM1', 'SM1', 'SM1', 'SM1', 'SM1', 'SM1'];
  const modelDevices = ['sm-dev-1', 'sm-dev-2', 'sm-dev-3', 'sm-dev-4', 'sm-dev-5', 'sm-dev-other'];
  const modelModels = ['Xiaomi-14', 'Xiaomi-14', 'Xiaomi-14', 'Xiaomi-14', 'Xiaomi-14', 'Pixel-9'];
  for (let i = 0; i < modelCodes.length; i++) {
    insUsage.run(modelCodes[i], 'a', modelDevices[i], modelModels[i], null, '4.4.4.4', t);
  }

  // brute_force: 设备 24h 内 >=10 次失败尝试
  for (let i = 0; i < 10; i++) insAttempt.run('BF01', 'bf-dev', 'iPhone', 0, '5.5.5.5', t);

  const alertsList = promo.promoFraudDetection();
  const types = new Set(alertsList.map(a => a.type));
  assert.ok(types.has('multi_code_device'), '应触发 multi_code_device');
  assert.ok(types.has('ip_burst'), '应触发 ip_burst');
  assert.ok(types.has('code_burst'), '应触发 code_burst');
  assert.ok(types.has('same_model'), '应触发 same_model');
  assert.ok(types.has('brute_force'), '应触发 brute_force');

  // 严重度排序: high 在前
  assert.equal(alertsList[0].severity, 'high');
  const ipb = alertsList.find(a => a.type === 'ip_burst');
  assert.equal(ipb.severity, 'high'); // cnt >= 10
  const mc = alertsList.find(a => a.type === 'multi_code_device');
  assert.equal(mc.detail.codes.includes('MC01'), true);
});

test('promo promoOverview: 统计字段齐全', () => {
  promo.createPromoCode({ code: 'OV01' });
  promo.recordPromoUsage({ code: 'OV01', deviceId: 'ov-1' });
  promo.recordPromoAttempt({ code: 'OV01', deviceId: 'ov-1', success: false });
  const o = promo.promoOverview();
  assert.equal(typeof o.totalCodes, 'number');
  assert.ok(o.totalUses >= 1);
  assert.ok(o.uniqueDevices >= 1);
  assert.ok(o.todayUses >= 1);
  assert.ok(o.recentAttempts >= 1);
  assert.ok(o.failedAttempts >= 1);
  assert.ok(Array.isArray(o.topCodes));
});

test('promo promoCodeStats / updatePromoCode 非法字段不更新', () => {
  promo.createPromoCode({ code: 'ST01', agentName: '代理X' });
  const upd = promo.updatePromoCode('ST01', { agent_name: '代理Y', hacked: true });
  assert.equal(upd, true);
  const row = db.__db.prepare('SELECT * FROM promo_codes WHERE code=?').get('ST01');
  assert.equal(row.agent_name, '代理Y');
  assert.equal(promo.updatePromoCode('ST01', { hacked: true }), false); // 无合法字段
  const s = promo.promoCodeStats('ST01');
  assert.equal(s.code.code, 'ST01');
  assert.equal(s.totalUses, 0);
});

// ─── alerts.js ──────────────────────────────────────────────────────

test('alerts: upsert 插入 + 更新 + 列表 + markFired + 删除', () => {
  const id = alerts.upsertAlertRule({
    name: '下载失败告警', kind: 'download_fail', threshold: 5,
    window_min: 10, webhook_url: 'https://hook.example/1', enabled: true,
  });
  assert.ok(id > 0);
  const list = alerts.listAlertRules();
  assert.equal(list.length, 1);
  assert.equal(list[0].name, '下载失败告警');
  assert.equal(list[0].webhook_kind, 'wecom'); // 默认值
  assert.equal(list[0].cooldown_min, 30);      // 默认值

  // 更新同 id
  const updId = alerts.upsertAlertRule({
    id, name: '下载失败告警V2', kind: 'download_fail', threshold: 8,
    webhook_url: 'https://hook.example/2', enabled: false, cooldown_min: 15,
  });
  assert.equal(updId, id);
  assert.equal(alerts.listAlertRules()[0].name, '下载失败告警V2');
  assert.equal(alerts.listAlertRules()[0].enabled, 0);
  assert.equal(alerts.listAlertRules()[0].cooldown_min, 15);

  alerts.markAlertFired(id);
  assert.ok(alerts.listAlertRules()[0].last_fired_at > 0);

  alerts.deleteAlertRule(id);
  assert.equal(alerts.listAlertRules().length, 0);
});

// ─── qimaoUpdater.js 纯函数 ─────────────────────────────────────────

test('qimao md5Sign: 与手动计算一致', () => {
  const params = { b: 2, a: 1, c: 3 };
  const sorted = 'a=1b=2c=3';
  const expect = crypto.createHash('md5').update(sorted + QIMAO_SIGN_KEY).digest('hex');
  assert.equal(qimao.md5Sign(params), expect);
});

test('qimao buildUrl: 参数排序 + 双签名 + url 拼接', () => {
  const { url, headers } = qimao.buildUrl('https://api-ks.wtzw.com/x', { id: '123' });
  assert.ok(url.startsWith('https://api-ks.wtzw.com/x?'));
  assert.ok(url.includes('id=123'));
  assert.ok(url.includes('sign='));
  assert.ok(headers.sign, 'headers 有签名');
  assert.ok(headers.headers, 'headers.headers 为序列化 JSON');
  const inner = JSON.parse(headers.headers);
  assert.equal(inner.headers.platform, 'android');
  assert.equal(inner.headers['app-version'], '51110');
});

test('qimao stripHtml: 去除标签并 trim', () => {
  assert.equal(qimao.stripHtml('<p>  第一章  楔子</p>'), '第一章  楔子');
  assert.equal(qimao.stripHtml('<b>a</b><i>b</i>'), 'ab');
  assert.equal(qimao.stripHtml(null), '');
  assert.equal(qimao.stripHtml(''), '');
});

test('qimao decryptContent: AES-128-CBC 加解密往返', () => {
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv('aes-128-cbc', QIMAO_AES_KEY, iv);
  let enc = cipher.update('这是七猫加密正文，测试解密。', 'utf8');
  enc = Buffer.concat([enc, cipher.final()]);
  const b64 = Buffer.concat([iv, enc]).toString('base64');
  assert.equal(qimao.decryptContent(b64), '这是七猫加密正文，测试解密。');
});

// ─── iap.js ─────────────────────────────────────────────────────────

test('iap: saveIapReceipt 必填校验 / upsert / listActive 过滤', () => {
  const iap = require('../models/iap');
  iap.init(db.__db);

  assert.throws(() => iap.saveIapReceipt({ deviceId: 'd', productId: 'p', transactionId: 't' }), /required/);
  assert.throws(() => iap.saveIapReceipt({ deviceId: 'd', productId: 'p', receiptData: 'r' }), /required/);

  // 插入 active 且未过期
  iap.saveIapReceipt({
    deviceId: 'iap-dev-1', productId: 'com.wanxiang.monthly',
    transactionId: 'tx-1', receiptData: 'data-1',
    expiresAt: Date.now() + 86400000, sandbox: false, status: 'active',
  });
  // 插入过期
  iap.saveIapReceipt({
    deviceId: 'iap-dev-1', productId: 'com.wanxiang.monthly',
    transactionId: 'tx-2', receiptData: 'data-2',
    expiresAt: Date.now() - 1000, sandbox: false, status: 'active',
  });
  // 插入 revoked
  iap.saveIapReceipt({
    deviceId: 'iap-dev-1', productId: 'com.wanxiang.lifetime',
    transactionId: 'tx-3', receiptData: 'data-3',
    expiresAt: null, sandbox: false, status: 'revoked',
  });
  // sandbox 单独计
  iap.saveIapReceipt({
    deviceId: 'iap-dev-2', productId: 'com.wanxiang.monthly',
    transactionId: 'tx-4', receiptData: 'data-4',
    expiresAt: Date.now() + 86400000, sandbox: true, status: 'active',
  });

  // active + 未过期 → 只返回 tx-1 (tx-2 过期, tx-3 revoked, tx-4 不同设备)
  const list = iap.listActiveIapForDevice('iap-dev-1');
  assert.equal(list.length, 1);
  assert.equal(list[0].transaction_id, 'tx-1');
  assert.equal(list[0].product_id, 'com.wanxiang.monthly');

  // 空 deviceId
  assert.deepEqual(iap.listActiveIapForDevice(''), []);

  // upsert 同 transactionId 更新 raw_response
  iap.saveIapReceipt({
    deviceId: 'iap-dev-1', productId: 'com.wanxiang.monthly',
    transactionId: 'tx-1', receiptData: 'data-1',
    expiresAt: Date.now() + 86400000, status: 'active', rawResponse: '{"ok":true}',
  });
  const upd = db.__db.prepare('SELECT raw_response FROM iap_receipts WHERE transaction_id=?').get('tx-1');
  assert.equal(upd.raw_response, '{"ok":true}');
});

test('iap: setIapStatus 合法/非法状态', () => {
  const iap = require('../models/iap');
  assert.throws(() => iap.setIapStatus('tx-1', 'bogus'), /invalid iap status/);
  iap.setIapStatus('tx-1', 'refunded');
  const row = db.__db.prepare('SELECT status FROM iap_receipts WHERE transaction_id=?').get('tx-1');
  assert.equal(row.status, 'refunded');
});
