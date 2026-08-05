// 万象书屋: Legado `java.*` API 的 Node.js 实现
//
// 实现书源 JS 规则中用到的 java.* / source.* API,
// 让服务端引擎能执行需要 JS 的书源 (如万象书屋源).

const crypto = require('node:crypto');
const { JSONPath } = require('jsonpath-plus');
const validator = require('../sourceValidator');

const UA = 'Mozilla/5.0 (Linux; Android 12; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';

// 万象书屋: 出站请求最大重定向跳数 (与 sourceValidator.probeUrl 的 maxRedirects 一致)
const MAX_REDIRECTS = 5;

/**
 * 创建 java.* API 对象, 供 VM 沙箱中使用.
 * @param {object} opts - { result, baseUrl, source }
 */
function createJavaApi(opts = {}) {
  const store = {};   // java.put / java.get 键值存储
  let currentResult = opts.result || '';

  const api = {
    // ─── 键值存储 ───
    put(key, value) { store[key] = value; return value; },
    get(key) { return store[key] || ''; },

    // ─── JSONPath ───
    getString(path) {
      try {
        let data = currentResult;
        if (typeof data === 'string') data = JSON.parse(data);
        const results = JSONPath({ path, json: data, wrap: false });
        if (Array.isArray(results)) return results[0] != null ? String(results[0]) : '';
        return results != null ? String(results) : '';
      } catch { return ''; }
    },

    // ─── 网络 ───
    ajax(url) {
      // 同步 HTTP GET。不用 shell 拼接 (防命令注入), 通过 argv 把 URL 传给子进程.
      // 同时做同步 SSRF 校验, 拒绝私网/元数据地址.
      // 重定向逐跳校验: 子进程用 redirect:'manual', 父进程负责每一跳的 SSRF 检查
      // 与 Location 解析 — 之前子进程 fetch 默认 follow, 302/307 跳到内网地址
      // 会绕过初始校验直接被请求 (与 legadoEngine.httpGet 同一处 SSRF 缺口).
      const { execFileSync } = require('child_process');
      const dns = require('node:dns');
      let current = String(url);
      for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
        try {
          const parsed = new URL(current);
          if (!/^https?:$/.test(parsed.protocol)) return '{}';
          if (validator.isPrivateHost(parsed.hostname)) return '{}';
          const addrs = dns.lookupSync(parsed.hostname, { all: true });
          for (const a of addrs) {
            if (validator.isPrivateIp(a.address)) return '{}';
          }
        } catch { return '{}'; }
        const script = `const u=process.argv[1];
          fetch(u,{headers:{'User-Agent':process.argv[2]},redirect:'manual',signal:AbortSignal.timeout(15000)})
            .then(async r=>{
              if(r.status>=300&&r.status<400){
                const loc=r.headers.get('location')||'';
                try{r.body?.cancel();}catch{}
                process.stdout.write('__WXSW_REDIRECT__'+loc);
              }else{process.stdout.write(await r.text());}
            })
            .catch(()=>process.stdout.write('{}'))`;
        const result = execFileSync(process.execPath, ['-e', script, current, UA], {
          timeout: 15000, encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'],
        });
        if (result.startsWith('__WXSW_REDIRECT__')) {
          const loc = result.slice('__WXSW_REDIRECT__'.length);
          if (!loc) return '{}';
          try { current = new URL(loc, current).toString(); } catch { return '{}'; }
          continue;
        }
        return result;
      }
      return '{}';
    },

    // ─── 加密/哈希 ───
    md5Encode(str) {
      return crypto.createHash('md5').update(String(str)).digest('hex');
    },

    digestHex(str, algorithm) {
      const alg = (algorithm || 'sha-256').replace('-', '').toLowerCase();
      const map = { sha256: 'sha256', sha1: 'sha1', md5: 'md5' };
      return crypto.createHash(map[alg] || 'sha256').update(String(str)).digest('hex');
    },

    base64Decode(str) {
      return Buffer.from(str, 'base64').toString('utf-8');
    },

    base64DecodeToByteArray(str) {
      const buf = Buffer.from(str, 'base64');
      const arr = new Int8Array(buf.length);
      for (let i = 0; i < buf.length; i++) {
        arr[i] = buf[i] > 127 ? buf[i] - 256 : buf[i];
      }
      return arr;
    },

    base64Encode(str) {
      return Buffer.from(String(str)).toString('base64');
    },

    /**
     * AES Base64 解密 (Legado java.aesBase64DecodeToString)
     * @param {string} data - Base64 编码的密文
     * @param {string} key - 密钥字符串
     * @param {string} transformation - 如 "AES/CBC/PKCS5Padding"
     * @param {string} iv - IV 字符串
     */
    aesBase64DecodeToString(data, key, transformation, iv) {
      try {
        const ciphertext = Buffer.from(data, 'base64');
        const keyBuf = Buffer.from(key, 'utf-8');
        const ivBuf = Buffer.from(iv, 'utf-8');

        let algorithm = 'aes-128-cbc';
        if (keyBuf.length === 32) algorithm = 'aes-256-cbc';
        else if (keyBuf.length === 24) algorithm = 'aes-192-cbc';

        const decipher = crypto.createDecipheriv(algorithm, keyBuf, ivBuf);
        let decrypted = decipher.update(ciphertext);
        decrypted = Buffer.concat([decrypted, decipher.final()]);
        return decrypted.toString('utf-8');
      } catch (e) {
        console.warn('[legadoJava] aesBase64Decode failed:', e.message);
        return '';
      }
    },

    aesEncodeToBase64(data, key, transformation, iv) {
      try {
        const keyBuf = Buffer.from(key, 'utf-8');
        const ivBuf = Buffer.from(iv, 'utf-8');
        let algorithm = 'aes-128-cbc';
        if (keyBuf.length === 32) algorithm = 'aes-256-cbc';
        else if (keyBuf.length === 24) algorithm = 'aes-192-cbc';
        const cipher = crypto.createCipheriv(algorithm, keyBuf, ivBuf);
        let encrypted = cipher.update(String(data), 'utf-8');
        encrypted = Buffer.concat([encrypted, cipher.final()]);
        return encrypted.toString('base64');
      } catch { return ''; }
    },

    // ─── 时间 ───
    timeFormat(timestamp) {
      if (!timestamp) return '';
      const d = new Date(typeof timestamp === 'number' ? timestamp : parseInt(timestamp, 10));
      return d.toISOString().replace('T', ' ').slice(0, 19);
    },

    // ─── 日志 ───
    log(...args) { console.log('[legado-js]', ...args); },

    // ─── 内部: 设置当前 result (给 getString 用) ───
    _setResult(r) { currentResult = r; },
  };

  return api;
}

/**
 * 创建 source.* API 对象
 */
function createSourceApi(bookSource) {
  return {
    getKey() { return bookSource.bookSourceUrl || ''; },
    bookSourceComment: bookSource.bookSourceComment || '',
    bookSourceUrl: bookSource.bookSourceUrl || '',
    bookSourceName: bookSource.bookSourceName || '',
    bookSourceGroup: bookSource.bookSourceGroup || '',
    header: bookSource.header || '',
  };
}

/**
 * 万象书屋源: decode 函数的 Node.js 原生实现
 * 对应 bookSourceComment 中的 Java/Rhino decode 函数
 */
function wanxiangDecode(base64Str) {
  const data = Buffer.from(base64Str, 'base64');
  if (data.length < 33) throw new Error('data too short for wanxiang decode');

  const keyRaw = data.subarray(0, 16);
  const ciphertext = data.subarray(16, data.length - 16);
  const ivRaw = data.subarray(data.length - 16);

  // key: Java String(byte[]) → digestHex(sha-256) → hex pairs to bytes
  // Java String(byte[]) 用 UTF-8, 转回 getBytes() 可能不等于原始 bytes
  const keyStr = Buffer.from(keyRaw).toString('utf-8');
  const keyStrBytes = Buffer.from(keyStr, 'utf-8');
  const keyHex = crypto.createHash('sha256').update(keyStrBytes).digest('hex');
  const keyBytes = Buffer.alloc(keyHex.length / 2);
  for (let i = 0; i < keyHex.length; i += 2) {
    keyBytes[i / 2] = parseInt(keyHex.substring(i, i + 2), 16);
  }

  // iv: Java String(byte[]) → md5Encode → getBytes, 然后 XOR+NOT
  const ivStr = Buffer.from(ivRaw).toString('utf-8');
  const ivStrBytes = Buffer.from(ivStr, 'utf-8');
  const ivMd5Hex = crypto.createHash('md5').update(ivStrBytes).digest('hex');
  const ivMd5Bytes = Buffer.from(ivMd5Hex, 'utf-8');
  const ivBytes = Buffer.alloc(16);
  for (let i = 0; i < 16; i++) {
    ivBytes[i] = (ivMd5Bytes[i] ^ ivStrBytes[i]) ^ 0xFF;
  }

  const decipher = crypto.createDecipheriv('aes-256-cbc', keyBytes, ivBytes);
  let decrypted = decipher.update(ciphertext);
  decrypted = Buffer.concat([decrypted, decipher.final()]);
  return decrypted.toString('utf-8');
}

/**
 * Rhino/Java API 兼容层 — 让 jsLib 中的 Java 互操作代码在 Node VM 中运行
 */

function toBuffer(v) {
  if (Buffer.isBuffer(v)) return v;
  if (v instanceof Int8Array || v instanceof Uint8Array) return Buffer.from(v.buffer, v.byteOffset, v.byteLength);
  if (typeof v === 'string') return Buffer.from(v, 'utf-8');
  return Buffer.from(v);
}

function createJavaShims() {
  const _crypto = crypto;

  const javaLang = {
    System: { currentTimeMillis: () => Date.now(), arraycopy(src, sp, dst, dp, len) { toBuffer(src).copy(toBuffer(dst), dp, sp, sp + len); } },
    String: function (v) {
      const s = typeof v === 'string' ? v : (Buffer.isBuffer(v) || v instanceof Uint8Array || v instanceof Int8Array ? Buffer.from(v.buffer || v, v.byteOffset, v.byteLength).toString('utf-8') : String(v));
      return { toString() { return s; }, length() { return s.length; }, getBytes(enc) { return Buffer.from(s, enc === 'UTF-8' ? 'utf-8' : enc || 'utf-8'); }, substring(a, b) { return s.substring(a, b); } };
    },
    Integer: { toHexString: n => (n >>> 0).toString(16), parseInt: (s, r) => parseInt(s, r) },
    Byte: { TYPE: 'byte' },
    reflect: { Array: { newInstance(_type, len) { return Buffer.alloc(len); } } },
  };

  const javaxCrypto = {
    Mac: {
      getInstance(alg) {
        let _key = null;
        const algMap = { HmacSHA256: 'sha256', HmacSHA1: 'sha1', HmacMD5: 'md5' };
        return {
          init(ks) { _key = ks.getEncoded ? ks.getEncoded() : toBuffer(ks); },
          doFinal(data) {
            const hmac = _crypto.createHmac(algMap[alg] || 'sha256', toBuffer(_key));
            hmac.update(toBuffer(data));
            const buf = hmac.digest();
            const arr = new Int8Array(buf.length);
            for (let i = 0; i < buf.length; i++) arr[i] = buf[i] > 127 ? buf[i] - 256 : buf[i];
            return arr;
          },
        };
      },
    },
    Cipher: {
      DECRYPT_MODE: 2, ENCRYPT_MODE: 1,
      getInstance(transform) {
        let _mode, _keyBuf, _ivBuf;
        return {
          init(mode, ks, ivSpec) {
            _mode = mode;
            _keyBuf = ks.getEncoded ? toBuffer(ks.getEncoded()) : toBuffer(ks);
            _ivBuf = ivSpec && ivSpec.getIV ? toBuffer(ivSpec.getIV()) : toBuffer(ivSpec);
          },
          doFinal(data) {
            const alg = `aes-${_keyBuf.length * 8}-cbc`;
            if (_mode === 2) {
              const d = _crypto.createDecipheriv(alg, _keyBuf, _ivBuf);
              return Buffer.concat([d.update(toBuffer(data)), d.final()]);
            }
            const e = _crypto.createCipheriv(alg, _keyBuf, _ivBuf);
            return Buffer.concat([e.update(toBuffer(data)), e.final()]);
          },
        };
      },
    },
    spec: {
      SecretKeySpec: function (key, _alg) { const k = toBuffer(key); this.getEncoded = () => k; },
      IvParameterSpec: function (iv) { const v = toBuffer(iv); this.getIV = () => v; },
    },
  };

  const javaArrays = {
    copyOfRange(arr, from, to) {
      if (arr instanceof Int8Array || arr instanceof Uint8Array || Buffer.isBuffer(arr)) {
        return Buffer.from(arr.buffer || arr, arr.byteOffset + from, to - from);
      }
      if (Array.isArray(arr)) return arr.slice(from, to);
      return arr;
    },
  };

  const javaUtil = {
    UUID: { randomUUID() { return { toString() { return _crypto.randomUUID(); } }; } },
    Arrays: javaArrays,
  };

  return {
    java: { lang: javaLang, util: javaUtil },
    javax: { crypto: javaxCrypto },
    _javaArrays: javaArrays,
  };
}

/**
 * Build a Packages hierarchy from Java shims so that
 * JavaImporter(Packages.javax.crypto, Packages.javax.crypto.spec, ...) works.
 */
function createPackages(shims) {
  return {
    java: {
      lang: shims.java.lang,
      util: shims.java.util,
      io: {},
    },
    javax: {
      crypto: {
        ...shims.javax.crypto,
        spec: shims.javax.crypto.spec,
      },
    },
  };
}

/**
 * JavaImporter shim: collects all own-enumerable properties from passed
 * package objects so that `with(jI) { Cipher }` resolves correctly.
 */
function JavaImporterShim(...packages) {
  for (const pkg of packages) {
    if (pkg && typeof pkg === 'object') {
      for (const [key, value] of Object.entries(pkg)) {
        this[key] = value;
      }
    }
  }
  this.importPackage = function (...morePkgs) {
    for (const pkg of morePkgs) {
      if (pkg && typeof pkg === 'object') {
        for (const [key, value] of Object.entries(pkg)) {
          this[key] = value;
        }
      }
    }
  };
}

function intToByte(i) { const b = i & 0xFF; return b >= 128 ? -(256 - b) : b; }

/**
 * 向 VM sandbox 注入 jsLib 函数
 */
function injectJsLib(sandbox, source) {
  const jsLib = source.jsLib || '';
  if (!jsLib) return;
  const vm = require('vm');
  try {
    vm.runInContext(jsLib, sandbox, { timeout: 5000 });
  } catch (e) {
    console.warn('[legadoJava] jsLib eval failed:', e.message);
  }
}

/**
 * 创建带 Java shims 的完整 VM sandbox
 * extras.java (Legado helper API) 与 Java 包层级 (java.lang/java.util) 合并到同一对象
 */
const QIMAO_SIGN_KEY = 'd3dGiJc651gSQ8w1';

function qimaoMd5Sign(params) {
  const crypto = require('crypto');
  const sorted = Object.keys(params).sort().map(k => k + '=' + params[k]).join('');
  return crypto.createHash('md5').update(sorted + QIMAO_SIGN_KEY).digest('hex');
}

function defaultBuildUrl(base, params) {
  const { URL } = require('url');
  if (typeof base === 'string' && base.includes('wtzw.com') && params) {
    params.sign = qimaoMd5Sign(params);
  }
  const u = new URL(base);
  for (const [k, v] of Object.entries(params || {})) u.searchParams.set(k, v);
  return u.href;
}

function createFullSandbox(extras) {
  const shims = createJavaShims();
  const packages = createPackages(shims);
  const merged = {
    ...shims,
    Math, JSON, parseInt, parseFloat, String, Number, Array, Object, Date, RegExp,
    encodeURIComponent, decodeURIComponent,
    Buffer, Int8Array, Uint8Array,
    console: { log: () => {}, warn: () => {} },
    buildUrl: defaultBuildUrl,
    Packages: packages,
    JavaImporter: JavaImporterShim,
    Arrays: shims._javaArrays,
    intToByte,
    SecretKeySpec: shims.javax.crypto.spec.SecretKeySpec,
    IvParameterSpec: shims.javax.crypto.spec.IvParameterSpec,
    Cipher: shims.javax.crypto.Cipher,
    ...extras,
  };
  if (extras && extras.java) {
    merged.java = { ...shims.java, ...extras.java };
  }
  return merged;
}

/**
 * 解析书源请求 header (支持 @js: 和 jsLib)
 */
function buildWanxiangHeaders(source, javaApi) {
  const headerRule = source.header || '';
  if (!headerRule.includes('@js:')) return {};

  const jsCode = headerRule.replace(/^@js:\s*/s, '').trim();
  try {
    const vm = require('vm');
    const sandbox = createFullSandbox({
      java: javaApi,
      source: createSourceApi(source),
    });
    vm.createContext(sandbox);
    injectJsLib(sandbox, source);
    const result = vm.runInContext(jsCode, sandbox, { timeout: 5000 });
    if (typeof result === 'string') return JSON.parse(result);
    if (typeof result === 'object') return result;
  } catch (e) {
    console.warn('[legadoJava] header eval failed:', e.message);
  }
  return {};
}

/**
 * 在 VM 沙箱中执行 <js> 块
 */
function evalJsBlock(jsCode, context) {
  const vm = require('vm');
  let _sandbox;
  const sandbox = createFullSandbox({
    result: context.result || '',
    baseUrl: context.baseUrl || '',
    java: context.java,
    source: context.source,
    decode: wanxiangDecode,
    console: { log: (...a) => console.log('[legado-js]', ...a), warn: () => {} },
    eval: function (code) {
      try { return vm.runInContext(String(code), _sandbox, { timeout: 10000 }); }
      catch { return undefined; }
    },
  });
  _sandbox = sandbox;
  vm.createContext(sandbox);
  if (context._source) injectJsLib(sandbox, context._source);

  try {
    const lastExpr = vm.runInContext(jsCode, sandbox, { timeout: 10000 });
    if (lastExpr !== undefined && lastExpr !== sandbox.result) return lastExpr;
    return sandbox.result;
  } catch (e) {
    console.warn('[legadoJava] JS eval failed:', e.message);
    return context.result;
  }
}

/**
 * 执行 @js:expr 内联表达式
 */
function evalJsInline(expr, result, context) {
  const vm = require('vm');
  const sandbox = createFullSandbox({
    result: result || '',
    baseUrl: context.baseUrl || '',
    BASE: context.BASE || '',
    java: context.java,
    source: context.source,
    decode: wanxiangDecode,
  });
  vm.createContext(sandbox);
  if (context._source) injectJsLib(sandbox, context._source);
  try {
    return vm.runInContext(expr, sandbox, { timeout: 5000 });
  } catch (e) {
    console.warn('[legadoJava] inline JS failed:', e.message, 'expr:', expr.slice(0, 80));
    return result;
  }
}

/**
 * 评估模板字符串 {{expr}} 中的表达式
 */
function evalTemplate(template, context) {
  if (!template || !template.includes('{{')) return template;
  return template.replace(/\{\{(.+?)\}\}/gs, (_, expr) => {
    const trimmed = expr.trim();

    // 纯 JSONPath 表达式 (如 $.book_id)
    if (trimmed.startsWith('$.') || trimmed.startsWith('$[')) {
      try {
        const data = typeof context.result === 'string' ? JSON.parse(context.result) : context.result;
        const results = JSONPath({ path: trimmed, json: data, wrap: false });
        if (Array.isArray(results)) return results[0] != null ? String(results[0]) : '';
        return results != null ? String(results) : '';
      } catch { return ''; }
    }

    const vm = require('vm');
    const sandbox = {
      java: context.java,
      source: context.source,
      key: context.keyword || '',
      result: context.result || '',
      decode: wanxiangDecode,
      Math, JSON, parseInt, parseFloat, String, Number, Array, Object, Date, RegExp,
    };
    vm.createContext(sandbox);
    try {
      const val = vm.runInContext(trimmed, sandbox, { timeout: 3000 });
      return val != null ? String(val) : '';
    } catch { return ''; }
  });
}

/**
 * JSONPath 提取 (支持 $.xxx, $..xxx, $[*] 等)
 */
function evalJsonPath(json, path) {
  try {
    const data = typeof json === 'string' ? JSON.parse(json) : json;
    const results = JSONPath({ path, json: data, wrap: true });
    return results;
  } catch { return []; }
}

module.exports = {
  createJavaApi,
  createSourceApi,
  wanxiangDecode,
  buildWanxiangHeaders,
  evalJsBlock,
  evalJsInline,
  evalTemplate,
  evalJsonPath,
  createFullSandbox,
  injectJsLib,
};
