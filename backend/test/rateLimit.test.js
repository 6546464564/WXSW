// 万象书屋后端 · 限流中间件单元测试
//
// rateLimit.js 在 NODE_ENV=test 下被禁用, 这里在文件顶部改成 development
// 使 makeRateLimit 真正生效, 验证滑动窗口逻辑。
// 注意: node --test 每个文件独立进程, 该 env 只影响本文件。

process.env.NODE_ENV = 'development';

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeRateLimit } = require('../middleware/rateLimit.js');

function fakeReq(ip) {
  return { ip };
}
function fakeRes() {
  const state = { statusCode: 200, headers: {}, body: null };
  return {
    state,
    status(code) { state.statusCode = code; return this; },
    json(body) { state.body = body; return this; },
    set(k, v) { state.headers[k] = v; return this; },
  };
}
function chain(limit, ip, times) {
  const results = [];
  for (let i = 0; i < times; i++) {
    const req = fakeReq(ip);
    const res = fakeRes();
    let called = false;
    limit(req, res, () => { called = true; });
    results.push({ passed: called, status: res.state.statusCode, retryAfter: res.state.headers['Retry-After'] });
  }
  return results;
}

test('rateLimit: 窗口内超过 max 返回 429', () => {
  const limit = makeRateLimit({ windowMs: 60_000, max: 3, keyPrefix: 't:' });
  const r = chain(limit, '1.2.3.4', 5);
  assert.equal(r[0].passed, true);
  assert.equal(r[1].passed, true);
  assert.equal(r[2].passed, true);
  assert.equal(r[3].passed, false);
  assert.equal(r[3].status, 429);
  assert.equal(r[4].passed, false);
  assert.ok(r[3].retryAfter, '应有 Retry-After 头');
});

test('rateLimit: 不同 IP 相互独立', () => {
  const limit = makeRateLimit({ windowMs: 60_000, max: 2, keyPrefix: 't:' });
  // A 打满 3 次 → 第 3 次被限
  const a = chain(limit, '10.0.0.1', 3);
  assert.equal(a[0].passed, true);
  assert.equal(a[1].passed, true);
  assert.equal(a[2].passed, false, 'A 第3次应被限');
  // B 从头计数, 前 2 次不受 A 影响
  const b = chain(limit, '10.0.0.2', 2);
  assert.equal(b[0].passed, true);
  assert.equal(b[1].passed, true);
  // B 第 3 次才因自己超限被拒
  const b3 = chain(limit, '10.0.0.2', 1);
  assert.equal(b3[0].passed, false, 'B 第3次应因自己超限被拒');
});

test('rateLimit: 窗口过期后重置计数', async () => {
  const limit = makeRateLimit({ windowMs: 50, max: 1, keyPrefix: 't:' });
  const r1 = chain(limit, '10.0.0.9', 2);
  assert.equal(r1[0].passed, true);
  assert.equal(r1[1].passed, false, '窗口内第2次应被限');
  // 等待窗口过期
  await new Promise(res => setTimeout(res, 80));
  const r2 = chain(limit, '10.0.0.9', 1);
  assert.equal(r2[0].passed, true, '窗口过期后应放行');
});

test('rateLimit: keyPrefix 区分不同限速实例', () => {
  const l1 = makeRateLimit({ windowMs: 60_000, max: 1, keyPrefix: 'a:' });
  const l2 = makeRateLimit({ windowMs: 60_000, max: 1, keyPrefix: 'b:' });
  // 同一 IP 打 l1 两次被限, 但 l2 独立
  const r = chain(l1, '10.0.0.5', 2);
  assert.equal(r[1].passed, false);
  const r2 = chain(l2, '10.0.0.5', 1);
  assert.equal(r2[0].passed, true, '不同 keyPrefix 应独立计数');
});
