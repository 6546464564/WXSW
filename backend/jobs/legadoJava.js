// 万象书屋: Legado `java.*` API 的 Node.js 实现
//
// 实现书源 JS 规则中用到的 java.* / source.* API,
// 让服务端引擎能执行需要 JS 的书源 (如万象书屋源).

const crypto = require('node:crypto');
const { JSONPath } = require('jsonpath-plus');

const UA = 'Mozilla/5.0 (Linux; Android 12; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';

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
      // 同步 HTTP GET (用 child_process.execSync 模拟, 因为 VM 不支持 async)
      const { execSync } = require('child_process');
      try {
        const result = execSync(
          `node -e "fetch('${url.replace(/'/g, "\\'")}',{headers:{'User-Agent':'${UA}'}}).then(r=>r.text()).then(t=>process.stdout.write(t)).catch(()=>process.stdout.write('{}'))"`,
          { timeout: 15000, encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] }
        );
        return result;
      } catch { return '{}'; }
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
 * 解析万象书屋源的请求 header
 */
function buildWanxiangHeaders(source, javaApi) {
  const headerRule = source.header || '';
  if (!headerRule.includes('@js:')) return {};

  const jsCode = headerRule.replace(/^@js:\s*/s, '').trim();
  try {
    const vm = require('vm');
    const sandbox = {
      java: javaApi,
      source: createSourceApi(source),
      Math, JSON, parseInt, parseFloat, String, Number, Array, Object, Date, RegExp,
      console: { log: () => {}, warn: () => {} },
    };
    vm.createContext(sandbox);
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
  const sandbox = {
    result: context.result || '',
    baseUrl: context.baseUrl || '',
    java: context.java,
    source: context.source,
    // 万象书屋源特有的 decode 函数
    decode: wanxiangDecode,
    // 标准全局
    Math, JSON, parseInt, parseFloat, String, Number, Array, Object, Date, RegExp,
    console: { log: (...a) => console.log('[legado-js]', ...a), warn: () => {} },
    // 拦截 eval: bookSourceComment 包含 Java/Rhino 代码, 无法在 Node VM 中运行.
    // 静默跳过, 因为关键函数 (decode 等) 已由原生实现提供.
    eval: function (code) {
      if (typeof code === 'string' && (code.includes('JavaImporter') || code.includes('Packages.'))) {
        return undefined;
      }
      // 允许其他普通 JS eval
      try { return Function('"use strict"; return (' + code + ')')(); }
      catch { return undefined; }
    },
    // Java shims (Rhino 兼容)
    JavaImporter: function () {
      this.importPackage = () => {};
      return this;
    },
    Packages: new Proxy({}, { get: () => new Proxy({}, { get: () => function () {} }) }),
    // Java Arrays shim (万象书屋源 decode 依赖)
    Arrays: {
      copyOfRange(arr, from, to) {
        if (arr instanceof Int8Array || arr instanceof Uint8Array || Buffer.isBuffer(arr)) {
          return Buffer.from(arr.buffer || arr, arr.byteOffset + from, to - from);
        }
        if (Array.isArray(arr)) return arr.slice(from, to);
        return arr;
      },
    },
    // Java crypto shims
    SecretKeySpec: function (key) { this.key = key; this.getEncoded = () => key; },
    IvParameterSpec: function (iv) { this.iv = iv; this.getIV = () => iv; },
    Cipher: {
      getInstance() { return { init() {}, doFinal(data) { return data; } }; },
    },
    // 万象书屋源 decode 里用的 intToByte
    intToByte(i) {
      const b = i & 0xFF;
      return b >= 128 ? -(256 - b) : b;
    },
  };
  vm.createContext(sandbox);

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
  const sandbox = {
    result: result || '',
    java: context.java,
    source: context.source,
    decode: wanxiangDecode,
    Math, JSON, parseInt, parseFloat, String, Number, Array, Object, Date, RegExp,
    console: { log: () => {}, warn: () => {} },
  };
  vm.createContext(sandbox);
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
};
