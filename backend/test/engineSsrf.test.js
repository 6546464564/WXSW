// 万象书屋: legadoEngine.httpGet / legadoJava.ajax 的重定向逐跳 SSRF 校验回归测试
// 跑法: cd backend && node --test test/engineSsrf.test.js
//
// 背景: 之前 httpGet 用 redirect:'follow' 只校验初始 URL, ajax 的子进程 fetch 也是
// 默认 follow — 一个 302/307 指向内网地址 (169.254.169.254 / 127.0.0.1 / 10.x) 的
// 响应会绕过 SSRF 防护被直接请求. 修完必须保证:
//   - 每一跳 (含重定向) 都过 isPrivateAddrAfterDns 检查
//   - 命中私网跳时不再发出网络请求
//   - 公网→公网重定向照常跟随

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');

// DNS 策略: hostname 含 'public' → 1.1.1.1, 含 'evil' → 127.0.0.1, 其他 ENOTFOUND
function mockDns() {
  const dns = require('dns');
  const original = dns.promises.lookup;
  dns.promises.lookup = async (hostname, opts) => {
    if (hostname.includes('public')) {
      return opts?.all ? [{ address: '1.1.1.1', family: 4 }] : { address: '1.1.1.1', family: 4 };
    }
    if (hostname.includes('evil')) {
      return opts?.all ? [{ address: '127.0.0.1', family: 4 }] : { address: '127.0.0.1', family: 4 };
    }
    const err = new Error('ENOTFOUND ' + hostname);
    err.code = 'ENOTFOUND';
    throw err;
  };
  return original;
}

// === legadoEngine.httpGet ===
describe('legadoEngine httpGet — 重定向逐跳 SSRF 校验', () => {
  let originalLookup;
  let originalFetch;
  let fetchLog = [];

  before(() => {
    originalLookup = mockDns();

    originalFetch = global.fetch;
    global.fetch = async (url, init) => {
      fetchLog.push(String(url));
      if (url === 'http://public.example/start') {
        return {
          status: 302, ok: false,
          headers: { get: (n) => (n.toLowerCase() === 'location' ? 'http://evil.example/' : null) },
          body: { cancel: () => {} },
        };
      }
      if (url === 'http://public.example/chain') {
        return {
          status: 301, ok: false,
          headers: { get: (n) => (n.toLowerCase() === 'location' ? 'http://public.example/final' : null) },
          body: { cancel: () => {} },
        };
      }
      return {
        status: 200, ok: true,
        headers: { get: () => null },
        text: async () => 'OK body',
        body: { cancel: () => {} },
      };
    };
  });

  after(() => {
    require('dns').promises.lookup = originalLookup;
    global.fetch = originalFetch;
  });

  function freshEngine() {
    delete require.cache[require.resolve('../sourceValidator')];
    delete require.cache[require.resolve('../jobs/legadoJava')];
    delete require.cache[require.resolve('../jobs/legadoEngine')];
    return require('../jobs/legadoEngine');
  }

  test('302 跳到私网域名 → 第二跳被 SSRF 拦, 不发出第二跳 fetch', async () => {
    fetchLog = [];
    const engine = freshEngine();
    await assert.rejects(
      () => engine.httpGet('http://public.example/start'),
      /blocked: dns -> private ip 127\.0\.0\.1/
    );
    assert.deepEqual(fetchLog, ['http://public.example/start']);
  });

  test('301 跳到公网域名 → 正常跟随并返回 body', async () => {
    fetchLog = [];
    const engine = freshEngine();
    const text = await engine.httpGet('http://public.example/chain');
    assert.equal(text, 'OK body');
    assert.deepEqual(fetchLog, ['http://public.example/chain', 'http://public.example/final']);
  });

  test('初始 URL 是私网 IP 字面量 → 直接拦, 不发任何 fetch', async () => {
    fetchLog = [];
    const engine = freshEngine();
    await assert.rejects(
      () => engine.httpGet('http://127.0.0.1:6379/'),
      /blocked: private hostname literal/
    );
    assert.equal(fetchLog.length, 0);
  });

  test('非 http(s) scheme 拒绝', async () => {
    const engine = freshEngine();
    await assert.rejects(() => engine.httpGet('file:///etc/passwd'), /blocked: non-http/);
  });
});

// === legadoJava.ajax ===
describe('legadoJava ajax — 重定向逐跳 SSRF 校验', () => {
  let originalExecFileSync;
  let originalLookupSync;
  let spawned = [];

  before(() => {
    const cp = require('child_process');
    originalExecFileSync = cp.execFileSync;
    // 模拟子进程 (redirect:'manual'): 3xx 返回 marker + location, 否则返回 body
    cp.execFileSync = (file, args) => {
      const url = args[2];
      spawned.push(url);
      if (url === 'http://public.example/start') {
        return '__WXSW_REDIRECT__http://evil.example/';
      }
      return 'BODY-' + url;
    };

    const dns = require('dns');
    originalLookupSync = dns.lookupSync;
    dns.lookupSync = (hostname, opts) => {
      if (hostname.includes('public')) return [{ address: '1.1.1.1', family: 4 }];
      if (hostname.includes('evil')) return [{ address: '127.0.0.1', family: 4 }];
      const err = new Error('ENOTFOUND ' + hostname);
      err.code = 'ENOTFOUND';
      throw err;
    };
  });

  after(() => {
    require('child_process').execFileSync = originalExecFileSync;
    require('dns').lookupSync = originalLookupSync;
  });

  function freshJava() {
    delete require.cache[require.resolve('../sourceValidator')];
    delete require.cache[require.resolve('../jobs/legadoJava')];
    return require('../jobs/legadoJava');
  }

  test('302 跳到私网域名 → 返回 {} 且不请求第二跳', () => {
    spawned = [];
    const java = freshJava().createJavaApi();
    assert.equal(java.ajax('http://public.example/start'), '{}');
    assert.deepEqual(spawned, ['http://public.example/start']);
  });

  test('公网 URL 正常返回 body', () => {
    spawned = [];
    const java = freshJava().createJavaApi();
    assert.equal(java.ajax('http://public.example/normal'), 'BODY-http://public.example/normal');
    assert.deepEqual(spawned, ['http://public.example/normal']);
  });

  test('初始 URL 私网 IP 字面量 → {} 且不启子进程', () => {
    spawned = [];
    const java = freshJava().createJavaApi();
    assert.equal(java.ajax('http://127.0.0.1:6379/'), '{}');
    assert.equal(spawned.length, 0);
  });
});
