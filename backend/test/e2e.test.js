// 万象书屋后端 · 真 server e2e 测试
//
// 区别于 api.test.js (supertest 直接挂 app), 这里调用 server.start()
// 监听真实端口, 用原生 fetch 走完整 HTTP 链路 (含中间件全链、真实 TCP、
// 实际端口绑定)。覆盖关键公开接口的"浏览器视角"健康度。
//
// 用法:
//   BCRYPT_COST=4 ADMIN_INITIAL_PASSWORD=test-password-12345 \
//     DEVICE_TOKEN_SECRET=test-secret-aaaaaaaaaaaaaaaaaaaaaaaa \
//     node --test test/e2e.test.js
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const fs = require('fs');
const os = require('os');

const TMP_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'wxsw-e2e-'));
process.env.DB_PATH = path.join(TMP_DIR, 'wanxiang.db');
process.env.BCRYPT_COST = process.env.BCRYPT_COST || '4';
process.env.ADMIN_INITIAL_PASSWORD = process.env.ADMIN_INITIAL_PASSWORD || 'test-pw-12345';
process.env.DEVICE_TOKEN_SECRET = 'test-secret-aaaaaaaaaaaaaaaaaaaaaaaa';
process.env.LOG_LEVEL = 'error';
process.env.PORT = '0';          // 随机端口
process.env.NODE_ENV = 'test';

const { app, start } = require('../server.js');
const db = require('../db');

let server;
let baseURL;

test.before(async () => {
  // 插一条 mirror 缓存, 避免启动 5s 后触发外部抓取 (e2e 不应依赖外网)
  db.insertBookstoreMirror({
    version: 1, etag: 'e2e-mirror', payload: JSON.stringify({ books: [] }),
    fetched_at: Date.now(), source: 'test', ok: true,
  });
  server = start();
  await new Promise((resolve, reject) => {
    server.on('listening', () => {
      const addr = server.address();
      baseURL = `http://127.0.0.1:${addr.port}`;
      resolve();
    });
    server.on('error', reject);
  });
});

test.after(() => {
  try { fs.rmSync(TMP_DIR, { recursive: true, force: true }); } catch {}
  try { server?.close(); } catch {}
  try { db.__db?.close(); } catch {}
  // 强制退出避免 keep-alive socket 挂住测试进程
  setTimeout(() => process.exit(0), 200).unref();
});

test('e2e: health 完整链路', async () => {
  const res = await fetch(`${baseURL}/api/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.checks.db.ok, true);
});

test('e2e: sources 返回数组 + etag', async () => {
  const res = await fetch(`${baseURL}/api/sources`);
  assert.equal(res.status, 200);
  assert.ok(res.headers.get('etag'));
  const body = await res.json();
  assert.ok(Array.isArray(body));
  // 万象书库 (library source) 一定在列
  assert.ok(body.some(s => s.bookSourceName === '万象书库'),
    'library source 应被 ensureLibrarySource 注册');
});

test('e2e: 公告 etag 304 协商', async () => {
  const r1 = await fetch(`${baseURL}/api/announcement`);
  assert.equal(r1.status, 200);
  const etag = r1.headers.get('etag');
  assert.ok(etag);
  const r2 = await fetch(`${baseURL}/api/announcement`, { headers: { 'If-None-Match': etag } });
  assert.equal(r2.status, 304);
});

test('e2e: 管理路由未登录 401 (真实 HTTP)', async () => {
  const res = await fetch(`${baseURL}/api/admin/sources`);
  assert.equal(res.status, 401);
});

test('e2e: 管理登录 → 书源 CRUD 全链路', async () => {
  // 登录
  const login = await fetch(`${baseURL}/api/admin/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: process.env.ADMIN_INITIAL_PASSWORD }),
  });
  assert.equal(login.status, 200);
  const setCookie = login.headers.get('set-cookie');
  assert.ok(setCookie, '应返回 session cookie');

  const cookie = setCookie.split(';')[0];
  const authHeaders = { Cookie: cookie, 'Content-Type': 'application/json' };

  // 新建书源
  const url = 'https://e2e.example.com';
  const created = await fetch(`${baseURL}/api/admin/sources`, {
    method: 'POST', headers: authHeaders,
    body: JSON.stringify({ bookSourceUrl: url, bookSourceName: 'e2e源' }),
  });
  assert.ok([200, 201].includes(created.status), `创建书源应成功, got ${created.status}`);

  // 列表应包含
  const list = await fetch(`${baseURL}/api/admin/sources`, { headers: { Cookie: cookie } });
  assert.equal(list.status, 200);
  const listBody = await list.json();
  assert.ok(Array.isArray(listBody), 'sources list 应为数组');
  assert.ok(listBody.some(s => s.url === url), '书源列表应含新建源');

  // 删除
  const del = await fetch(`${baseURL}/api/admin/sources?url=${encodeURIComponent(url)}`, {
    method: 'DELETE', headers: { Cookie: cookie },
  });
  assert.ok([200, 404].includes(del.status));
});

test('e2e: 搜索代理有优雅失败而非 500', async () => {
  const res = await fetch(`${baseURL}/api/search/proxy`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ keyword: '测试' }),
  });
  // 可能成功或服务端判定无可用源, 但绝不应 5xx
  assert.ok(res.status < 500, `搜索代理不应 5xx, got ${res.status}`);
});

test('e2e: 未知路由 404 JSON', async () => {
  const res = await fetch(`${baseURL}/api/definitely-not-exists`);
  assert.equal(res.status, 404);
});

test('e2e: promo usage 未鉴权 401 + 鉴权后缺参 400', async () => {
  // 未带设备凭证 → strict 鉴权拒绝 401
  const unauth = await fetch(`${baseURL}/api/promo/usage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code: 'X', device_id: 'device-e2e-1' }),
  });
  assert.equal(unauth.status, 401);

  // 注册设备拿 token
  const reg = await fetch(`${baseURL}/api/device/register`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ device_id: 'device-e2e-12345' }),
  });
  assert.equal(reg.status, 200);
  const { token } = await reg.json();

  // 带凭证但缺 code → 400
  const res = await fetch(`${baseURL}/api/promo/usage`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Device-Id': 'device-e2e-12345', 'X-Device-Token': token,
    },
    body: JSON.stringify({ device_id: 'device-e2e-12345' }), // 缺 code
  });
  assert.equal(res.status, 400);
});
