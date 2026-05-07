// 万象书屋: SSRF 防护单元测试
// 跑法: cd backend && node --test test/ssrf.test.js
//
// 覆盖:
//   1. isPrivateHost: 字面量私网/本地/AWS metadata 拒绝
//   2. isPrivateIp: 解析后 IP 私网拒绝, IPv4-mapped-IPv6 / 多播 / CGNAT 都覆盖
//   3. isPrivateAddrAfterDns: mock dns.lookup 模拟 A → 127.0.0.1 攻击
//   4. probeUrl: redirect:'manual' 30x 跳到私网时被拦, 不跟跳
//
// dns / fetch 用 Node 内置的 mock 框架 (require.cache 替换), 不引第三方库.

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');
const Module = require('module');

describe('isPrivateHost — 字面量字符串', () => {
  const { isPrivateHost } = require('../sourceValidator');

  test('localhost / 0.0.0.0', () => {
    assert.equal(isPrivateHost('localhost'), true);
    assert.equal(isPrivateHost('Localhost'), true);
    assert.equal(isPrivateHost('0.0.0.0'), true);
  });

  test('IPv4 私网各段', () => {
    assert.equal(isPrivateHost('127.0.0.1'), true);
    assert.equal(isPrivateHost('10.0.0.1'), true);
    assert.equal(isPrivateHost('172.16.0.1'), true);
    assert.equal(isPrivateHost('172.31.255.255'), true);
    assert.equal(isPrivateHost('172.32.0.1'), false); // 边界外
    assert.equal(isPrivateHost('192.168.1.1'), true);
    assert.equal(isPrivateHost('169.254.169.254'), true); // AWS metadata
  });

  test('IPv6 loopback / link-local / unique-local', () => {
    assert.equal(isPrivateHost('::1'), true);
    assert.equal(isPrivateHost('fe80::1'), true);
    assert.equal(isPrivateHost('fc00::1'), true);
    assert.equal(isPrivateHost('fd12::1'), true);
  });

  test('合法公网 hostname 不拒绝', () => {
    assert.equal(isPrivateHost('example.com'), false);
    assert.equal(isPrivateHost('cdn.bing.com'), false);
    assert.equal(isPrivateHost('8.8.8.8'), false);
  });

  test('空 / null 视作私网 (拒)', () => {
    assert.equal(isPrivateHost(''), true);
    assert.equal(isPrivateHost(null), true);
    assert.equal(isPrivateHost(undefined), true);
  });
});

describe('isPrivateIp — 解析后 IP', () => {
  const { isPrivateIp } = require('../sourceValidator');

  test('IPv4-mapped IPv6 (::ffff:127.0.0.1) 视作 127.0.0.1', () => {
    assert.equal(isPrivateIp('::ffff:127.0.0.1'), true);
    assert.equal(isPrivateIp('::ffff:8.8.8.8'), false);
  });

  test('CGNAT 100.64.0.0/10', () => {
    assert.equal(isPrivateIp('100.64.0.1'), true);
    assert.equal(isPrivateIp('100.127.255.255'), true);
    assert.equal(isPrivateIp('100.128.0.0'), false); // 边界外
  });

  test('多播 224.x / 保留段 >=224', () => {
    assert.equal(isPrivateIp('224.0.0.1'), true);
    assert.equal(isPrivateIp('239.255.255.255'), true);
    assert.equal(isPrivateIp('255.255.255.255'), true);
  });

  test('普通公网 IP 不拒', () => {
    assert.equal(isPrivateIp('8.8.8.8'), false);
    assert.equal(isPrivateIp('1.1.1.1'), false);
  });
});

// === 模拟 evil DNS: hostname 字面量看着是公网, 解析后是 127.0.0.1 ===
describe('isPrivateAddrAfterDns — DNS 解析后二次校验', () => {
  // 替换 dns.promises.lookup 模拟攻击场景
  let originalLookup;
  const lookupMap = new Map(); // hostname -> [{address, family}]
  let dnsCalls = [];

  before(() => {
    const dns = require('dns');
    originalLookup = dns.promises.lookup;
    dns.promises.lookup = async (hostname, opts) => {
      dnsCalls.push(hostname);
      const entries = lookupMap.get(hostname);
      if (!entries) {
        const err = new Error('ENOTFOUND ' + hostname);
        err.code = 'ENOTFOUND';
        throw err;
      }
      return opts && opts.all ? entries : entries[0];
    };
  });

  after(() => {
    require('dns').promises.lookup = originalLookup;
  });

  test('evil.example A → 127.0.0.1: 拒绝', async () => {
    lookupMap.set('evil.example', [{ address: '127.0.0.1', family: 4 }]);
    // 这里要求 require 时拿 fresh module, 因为之前 cache 内的 isPrivateAddrAfterDns 已绑定旧 dns
    delete require.cache[require.resolve('../sourceValidator')];
    const { isPrivateAddrAfterDns } = require('../sourceValidator');
    const r = await isPrivateAddrAfterDns('evil.example');
    assert.equal(r.ok, false);
    assert.match(r.reason, /private ip 127\.0\.0\.1/);
  });

  test('多 A 记录中任一私网即拒绝', async () => {
    lookupMap.set('mixed.example', [
      { address: '8.8.8.8', family: 4 },
      { address: '10.0.0.5', family: 4 },
    ]);
    delete require.cache[require.resolve('../sourceValidator')];
    const { isPrivateAddrAfterDns } = require('../sourceValidator');
    const r = await isPrivateAddrAfterDns('mixed.example');
    assert.equal(r.ok, false);
    assert.match(r.reason, /10\.0\.0\.5/);
  });

  test('正常公网域名通过', async () => {
    lookupMap.set('public.example', [{ address: '1.1.1.1', family: 4 }]);
    delete require.cache[require.resolve('../sourceValidator')];
    const { isPrivateAddrAfterDns } = require('../sourceValidator');
    const r = await isPrivateAddrAfterDns('public.example');
    assert.equal(r.ok, true);
  });

  test('AWS metadata IP 字面量直接被字面量层拦', async () => {
    delete require.cache[require.resolve('../sourceValidator')];
    const { isPrivateAddrAfterDns } = require('../sourceValidator');
    const r = await isPrivateAddrAfterDns('169.254.169.254');
    assert.equal(r.ok, false);
    assert.match(r.reason, /private hostname literal/);
  });

  test('DNS 解析失败 → 拒绝', async () => {
    delete require.cache[require.resolve('../sourceValidator')];
    const { isPrivateAddrAfterDns } = require('../sourceValidator');
    const r = await isPrivateAddrAfterDns('does-not-exist-domain.invalid');
    assert.equal(r.ok, false);
    assert.match(r.reason, /dns:/);
  });
});

// === probeUrl: redirect 跳到私网时被拦 ===
describe('probeUrl — 30x 重定向逐跳 SSRF 校验', () => {
  let originalLookup;
  let originalFetch;
  let fetchLog = [];

  before(() => {
    const dns = require('dns');
    originalLookup = dns.promises.lookup;
    dns.promises.lookup = async (hostname, opts) => {
      // 简易策略: hostname 中含 'public' → 解析公网, 含 'evil' → 私网, 其他 → ENOTFOUND
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

    originalFetch = global.fetch;
    global.fetch = async (url, init) => {
      fetchLog.push(url);
      // 模拟 redirect: public.example → http://evil.example/ → 应在第二跳被拦
      if (url === 'http://public.example/start') {
        return {
          status: 302,
          ok: false,
          headers: new Map([['location', 'http://evil.example/']]),
          body: { cancel: () => {}, getReader: () => ({ read: async () => ({ done: true }) }) },
        };
      }
      // 普通正常响应
      return {
        status: 200,
        ok: true,
        headers: new Map(),
        body: {
          cancel: () => {},
          getReader: () => {
            let sent = false;
            return {
              read: async () => {
                if (!sent) { sent = true; return { done: false, value: new Uint8Array(50) }; }
                return { done: true };
              },
            };
          },
        },
      };
    };

    // 反代 Map 的 .get 方法 (fetch headers 用 Headers, 但这里用 Map mock)
    // Headers 的 get(name) 与 Map.get(key) 行为一致 (key 大小写敏感)
    // 所以 'location' / 'Location' 要匹配, 我们的代码用 .get('location')
  });

  after(() => {
    require('dns').promises.lookup = originalLookup;
    global.fetch = originalFetch;
  });

  test('第一跳公网 200 → ok', async () => {
    fetchLog = [];
    delete require.cache[require.resolve('../sourceValidator')];
    const { probeUrl } = require('../sourceValidator');
    const r = await probeUrl('http://public.example/normal');
    assert.equal(r.ok, true);
    assert.equal(r.status, 200);
    assert.equal(fetchLog.length, 1);
  });

  test('30x 跳到私网域名 → 第二跳被 SSRF 拦截', async () => {
    fetchLog = [];
    delete require.cache[require.resolve('../sourceValidator')];
    const { probeUrl } = require('../sourceValidator');
    const r = await probeUrl('http://public.example/start');
    assert.equal(r.ok, false);
    assert.match(r.error, /blocked: dns -> private ip 127\.0\.0\.1/);
    // 应当只发出第一跳, 第二跳在 SSRF 校验阶段就拦下来不会真的 fetch
    assert.equal(fetchLog.length, 1);
  });

  test('直接给私网 URL → 第一跳就拒, 不发 fetch', async () => {
    fetchLog = [];
    delete require.cache[require.resolve('../sourceValidator')];
    const { probeUrl } = require('../sourceValidator');
    const r = await probeUrl('http://127.0.0.1:6379/');
    assert.equal(r.ok, false);
    assert.match(r.error, /blocked/);
    assert.equal(fetchLog.length, 0);
  });

  test('非 http/https scheme 拒绝 (file: 等)', async () => {
    fetchLog = [];
    delete require.cache[require.resolve('../sourceValidator')];
    const { probeUrl } = require('../sourceValidator');
    const r = await probeUrl('file:///etc/passwd');
    assert.equal(r.ok, false);
    assert.match(r.error, /non-http scheme|invalid url/);
    assert.equal(fetchLog.length, 0);
  });
});
