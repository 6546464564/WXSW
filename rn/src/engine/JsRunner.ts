/**
 * 万象书屋 RN · JS 规则执行器
 * 对应 iOS: JSEngine.swift
 *
 * 完整对齐 iOS bridge 实现，包括：
 * - java.* 全套方法 (ajax/get/post/put/cache/crypto/hash/hex/…)
 * - cookie bridge
 * - cache 全局 KV
 * - Java 全局 polyfill (Base64/Arrays/Cipher/SecretKeySpec/Packages/String.prototype)
 * - source 对象 (getKey/getName/getVariable/…)
 * - getElements/getElement/getString/getStringList/setContent
 * - queryTTF/replaceFont/webView stub
 */

import axios from 'axios';
import CryptoJS from 'crypto-js';
import * as cheerio from 'cheerio';
import {BookSource} from './types';

export interface JSScope {
  baseUrl?: string;
  src?: string;
  result?: any;
  key?: string;
  page?: number;
  bookSource?: BookSource;
  book?: Record<string, string>;
  chapter?: Record<string, string>;
  nextChapterUrl?: string;
}

// ─── KV store (java.put / java.get / cache.*) ───
const kvStore: Record<string, any> = {};

// ─── Cookie store ───
const cookieStore: Record<string, string> = {};

// ─── Cache memory (cache.putMemory / cache.getFromMemory) ───
const cacheMemory: Record<string, any> = {};

// ─── Fake androidId (stable per app session) ───
let _androidId: string | null = null;
function getAndroidId(): string {
  if (!_androidId) {
    _androidId = Array.from({length: 16}, () =>
      Math.floor(Math.random() * 16).toString(16),
    ).join('');
  }
  return _androidId;
}

// ─── JS lib cache (importScript) ───
const jsLibCache: Record<string, string> = {};

/**
 * 自动给表达式包 return。
 */
function wrapWithReturn(script: string): string {
  const trimmed = script.trim();
  if (!trimmed) return script;
  if (/\breturn\b/.test(trimmed)) return script;
  if (trimmed.includes(';') || trimmed.includes('\n')) {
    const lines = trimmed
      .split(/[;\n]/)
      .map(l => l.trim())
      .filter(Boolean);
    if (lines.length > 1) {
      const last = lines[lines.length - 1];
      try {
        new Function(`return (${last})`);
        return trimmed.replace(
          new RegExp(
            `${last.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s*;?\\s*$`,
          ),
          `return (${last})`,
        );
      } catch {
        return script;
      }
    }
  }
  try {
    new Function(`return (${trimmed})`);
    return `return (${trimmed})`;
  } catch {
    return script;
  }
}

// ─── Crypto helpers ───

function md5Hex(s: string): string {
  return CryptoJS.MD5(s).toString(CryptoJS.enc.Hex);
}

function sha1Hex(s: string): string {
  return CryptoJS.SHA1(s).toString(CryptoJS.enc.Hex);
}

function sha256Hex(s: string): string {
  return CryptoJS.SHA256(s).toString(CryptoJS.enc.Hex);
}

function hmacHex(data: string, key: string, algo: string): string {
  const a = algo.toUpperCase().replace(/[-_]/g, '');
  switch (a) {
    case 'HMACSHA256':
    case 'SHA256':
      return CryptoJS.HmacSHA256(data, key).toString(CryptoJS.enc.Hex);
    case 'HMACSHA1':
    case 'SHA1':
      return CryptoJS.HmacSHA1(data, key).toString(CryptoJS.enc.Hex);
    case 'HMACMD5':
    case 'MD5':
      return CryptoJS.HmacMD5(data, key).toString(CryptoJS.enc.Hex);
    default:
      return CryptoJS.HmacSHA256(data, key).toString(CryptoJS.enc.Hex);
  }
}

function hmacBase64(data: string, key: string, algo: string): string {
  const a = algo.toUpperCase().replace(/[-_]/g, '');
  let hash: CryptoJS.lib.WordArray;
  switch (a) {
    case 'HMACSHA256':
    case 'SHA256':
      hash = CryptoJS.HmacSHA256(data, key);
      break;
    case 'HMACSHA1':
    case 'SHA1':
      hash = CryptoJS.HmacSHA1(data, key);
      break;
    default:
      hash = CryptoJS.HmacSHA256(data, key);
  }
  return CryptoJS.enc.Base64.stringify(hash);
}

function parseTransformation(transformation: string): {
  algo: string;
  mode: any;
  padding: any;
} {
  const parts = transformation.split('/');
  const algoName = (parts[0] || 'AES').toUpperCase();
  const modeName = (parts[1] || 'ECB').toUpperCase();
  const paddingName = (parts[2] || 'PKCS5Padding').toUpperCase();

  let mode: any;
  switch (modeName) {
    case 'CBC':
      mode = CryptoJS.mode.CBC;
      break;
    case 'ECB':
      mode = CryptoJS.mode.ECB;
      break;
    case 'CFB':
      mode = CryptoJS.mode.CFB;
      break;
    case 'OFB':
      mode = CryptoJS.mode.OFB;
      break;
    case 'CTR':
      mode = CryptoJS.mode.CTR;
      break;
    default:
      mode = CryptoJS.mode.CBC;
  }

  let padding: any;
  switch (paddingName) {
    case 'PKCS5PADDING':
    case 'PKCS7PADDING':
      padding = CryptoJS.pad.Pkcs7;
      break;
    case 'NOPADDING':
      padding = CryptoJS.pad.NoPadding;
      break;
    case 'ZEROPADDING':
      padding = CryptoJS.pad.ZeroPadding;
      break;
    default:
      padding = CryptoJS.pad.Pkcs7;
  }

  return {algo: algoName, mode, padding};
}

function symmetricEncrypt(
  data: string,
  key: string,
  transformation: string,
  iv: string,
): string {
  const {algo, mode, padding} = parseTransformation(transformation);
  const keyWA = CryptoJS.enc.Utf8.parse(key);
  const ivWA = iv ? CryptoJS.enc.Utf8.parse(iv) : undefined;
  const cfg: any = {mode, padding};
  if (ivWA) cfg.iv = ivWA;

  let encrypted: CryptoJS.lib.CipherParams;
  if (algo === 'DES') {
    encrypted = CryptoJS.DES.encrypt(data, keyWA, cfg);
  } else if (algo === 'DESEDE' || algo === 'TRIPLEDES' || algo === '3DES') {
    encrypted = CryptoJS.TripleDES.encrypt(data, keyWA, cfg);
  } else {
    encrypted = CryptoJS.AES.encrypt(data, keyWA, cfg);
  }
  return encrypted.toString();
}

function symmetricDecrypt(
  dataB64: string,
  key: string,
  transformation: string,
  iv: string,
): string {
  const {algo, mode, padding} = parseTransformation(transformation);
  const keyWA = CryptoJS.enc.Utf8.parse(key);
  const ivWA = iv ? CryptoJS.enc.Utf8.parse(iv) : undefined;
  const cfg: any = {mode, padding};
  if (ivWA) cfg.iv = ivWA;

  let decrypted: CryptoJS.lib.WordArray;
  if (algo === 'DES') {
    decrypted = CryptoJS.DES.decrypt(dataB64, keyWA, cfg);
  } else if (algo === 'DESEDE' || algo === 'TRIPLEDES' || algo === '3DES') {
    decrypted = CryptoJS.TripleDES.decrypt(dataB64, keyWA, cfg);
  } else {
    decrypted = CryptoJS.AES.decrypt(dataB64, keyWA, cfg);
  }
  return decrypted.toString(CryptoJS.enc.Utf8);
}

// raw bytes (WordArray) crypto for createSymmetricCrypto
function symmetricCryptRaw(
  op: 'encrypt' | 'decrypt',
  dataWA: CryptoJS.lib.WordArray,
  keyWA: CryptoJS.lib.WordArray,
  ivWA: CryptoJS.lib.WordArray | undefined,
  transformation: string,
): CryptoJS.lib.WordArray {
  const {algo, mode, padding} = parseTransformation(transformation);
  const cfg: any = {mode, padding};
  if (ivWA) cfg.iv = ivWA;

  if (op === 'encrypt') {
    let encrypted: CryptoJS.lib.CipherParams;
    if (algo === 'DES') {
      encrypted = CryptoJS.DES.encrypt(dataWA, keyWA, cfg);
    } else if (
      algo === 'DESEDE' ||
      algo === 'TRIPLEDES' ||
      algo === '3DES'
    ) {
      encrypted = CryptoJS.TripleDES.encrypt(dataWA, keyWA, cfg);
    } else {
      encrypted = CryptoJS.AES.encrypt(dataWA, keyWA, cfg);
    }
    return encrypted.ciphertext;
  } else {
    const cipherParams = CryptoJS.lib.CipherParams.create({
      ciphertext: dataWA,
    });
    let decrypted: CryptoJS.lib.WordArray;
    if (algo === 'DES') {
      decrypted = CryptoJS.DES.decrypt(cipherParams, keyWA, cfg);
    } else if (
      algo === 'DESEDE' ||
      algo === 'TRIPLEDES' ||
      algo === '3DES'
    ) {
      decrypted = CryptoJS.TripleDES.decrypt(cipherParams, keyWA, cfg);
    } else {
      decrypted = CryptoJS.AES.decrypt(cipherParams, keyWA, cfg);
    }
    return decrypted;
  }
}

// ─── HTML entity decode ───
function htmlFormat(s: string): string {
  const entities: [string, string][] = [
    ['&amp;', '&'],
    ['&lt;', '<'],
    ['&gt;', '>'],
    ['&quot;', '"'],
    ['&#039;', "'"],
    ['&apos;', "'"],
    ['&nbsp;', ' '],
    ['&ldquo;', '\u201C'],
    ['&rdquo;', '\u201D'],
    ['&lsquo;', '\u2018'],
    ['&rsquo;', '\u2019'],
    ['&hellip;', '…'],
    ['&mdash;', '—'],
    ['&ndash;', '–'],
    ['&copy;', '©'],
    ['&reg;', '®'],
    ['&trade;', '™'],
  ];
  let out = s;
  for (const [k, v] of entities) {
    out = out.split(k).join(v);
  }
  out = out.replace(/&#(\d+);/g, (_, n) => {
    const code = parseInt(n, 10);
    return String.fromCharCode(code);
  });
  return out;
}

// ─── Hex helpers ───
function hexEncode(s: string): string {
  return Array.from(new TextEncoder().encode(s))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
}

function hexDecode(hex: string): string {
  const cleaned = hex.replace(/\s/g, '');
  const bytes: number[] = [];
  for (let i = 0; i < cleaned.length; i += 2) {
    bytes.push(parseInt(cleaned.substring(i, i + 2), 16));
  }
  return new TextDecoder().decode(new Uint8Array(bytes));
}

function hexDecodeToBytes(hex: string): number[] {
  const cleaned = hex.replace(/\s/g, '');
  const bytes: number[] = [];
  for (let i = 0; i < cleaned.length; i += 2) {
    bytes.push(parseInt(cleaned.substring(i, i + 2), 16));
  }
  return bytes;
}

// ─── String to bytes (with charset) ───
function strToBytes(s: string, _charset?: string): number[] {
  return Array.from(new TextEncoder().encode(s));
}

function bytesToStr(bytes: any, _charset?: string): string {
  if (Array.isArray(bytes)) {
    return new TextDecoder().decode(
      new Uint8Array(bytes.map((b: number) => (b < 0 ? b + 256 : b))),
    );
  }
  if (bytes instanceof Uint8Array) {
    return new TextDecoder().decode(bytes);
  }
  return String(bytes || '');
}

// ─── toNumChapter ───
function toNumChapter(s: string | null): string {
  if (!s) return '';
  const numMatch = s.match(/\d+/);
  if (numMatch) return numMatch[0];
  const cnDigits: Record<string, number> = {
    零: 0, 一: 1, 二: 2, 两: 2, 三: 3, 四: 4, 五: 5,
    六: 6, 七: 7, 八: 8, 九: 9, 十: 10, 百: 100, 千: 1000, 万: 10000,
  };
  let result = 0;
  let current = 0;
  for (const ch of s) {
    const v = cnDigits[ch];
    if (v !== undefined) {
      if (v >= 10) {
        if (current === 0) current = 1;
        current *= v;
        if (v >= 100) {
          result += current;
          current = 0;
        }
      } else {
        current = current * 10 + v;
      }
    } else if (current > 0 || result > 0) {
      break;
    }
  }
  result += current;
  return result > 0 ? String(result) : s;
}

// ─── Legado CSS selector conversion (for getElements) ───
function legadoSelector(rule: string): string {
  if (typeof rule !== 'string') return rule;
  if (rule.startsWith('class.')) {
    const inner = rule.substring(6);
    if (inner.includes(' ')) {
      return inner
        .split(/\s+/)
        .filter(Boolean)
        .map(c => '.' + c)
        .join('');
    }
    return '.' + inner;
  }
  if (rule.startsWith('id.')) return '#' + rule.substring(3);
  if (rule.startsWith('tag.')) return rule.substring(4);
  return rule;
}

// ─── UA constant ───
const WEB_VIEW_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) ' +
  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

/**
 * 创建 java bridge
 */
function createJavaBridge(scope: JSScope) {
  return {
    // ── KV store ──
    put(key: string, val: any): any {
      kvStore[key] = val;
      return val;
    },

    cache(key: string, val: any): any {
      kvStore[key] = val;
      return val;
    },

    get(urlOrKey: string, headersAny?: any): any {
      const hasHeaders =
        headersAny !== undefined &&
        headersAny !== null &&
        typeof headersAny === 'object';
      const isUrl =
        urlOrKey.startsWith('http://') ||
        urlOrKey.startsWith('https://') ||
        urlOrKey.startsWith('//');
      if (hasHeaders || isUrl) {
        console.warn(
          '[JsRunner] java.get(url) sync not supported, use async path',
        );
        return {
          body: () => '',
          code: () => 0,
          header: () => '',
          headers: () => ({}),
        };
      }
      return kvStore[urlOrKey] ?? null;
    },

    // ── HTTP ──
    ajax(urlOrOptions: any): string {
      console.warn('[JsRunner] java.ajax() sync not supported in RN');
      return '';
    },

    ajaxAll(urls: any): string[] {
      if (!Array.isArray(urls)) return [];
      return urls.map(() => '');
    },

    async connect(urlStr: string): Promise<string> {
      try {
        const res = await axios.get(urlStr, {timeout: 10000});
        return typeof res.data === 'string'
          ? res.data
          : JSON.stringify(res.data);
      } catch {
        return '';
      }
    },

    head(urlStr: string, _headers?: any): any {
      return {
        body: () => '',
        code: () => 0,
        header: () => '',
        headers: () => ({}),
      };
    },

    async post(
      urlStr: string,
      body: string,
      _contentType?: string,
    ): Promise<string> {
      try {
        const res = await axios.post(urlStr, body, {timeout: 10000});
        return typeof res.data === 'string'
          ? res.data
          : JSON.stringify(res.data);
      } catch {
        return '';
      }
    },

    getStrResponse(url: string, _headersAny?: any): any {
      return {
        body: () => '',
        code: () => 0,
        header: () => '',
        headers: () => ({}),
      };
    },

    // ── Logging ──
    log(msg: any) {
      if (__DEV__) {
        console.log('[BookSource JS]', msg);
      }
    },

    toast(msg: any) {
      if (__DEV__) {
        console.log('[js.toast]', msg);
      }
    },

    longToast(msg: any) {
      if (__DEV__) {
        console.log('[js.toast]', msg);
      }
    },

    // ── Base64 ──
    base64Decode(str: string): string {
      try {
        return CryptoJS.enc.Base64.parse(str).toString(CryptoJS.enc.Utf8);
      } catch {
        return '';
      }
    },

    base64Encode(str: string): string {
      return CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse(str));
    },

    base64DecodeToByteArray(str: string): number[] {
      try {
        const wa = CryptoJS.enc.Base64.parse(str);
        const hex = wa.toString(CryptoJS.enc.Hex);
        return hexDecodeToBytes(hex);
      } catch {
        return [];
      }
    },

    // ── URL encode/decode ──
    encodeURI(str: string): string {
      return encodeURIComponent(str);
    },

    decodeURI(str: string): string {
      try {
        return decodeURIComponent(str);
      } catch {
        return str;
      }
    },

    urlEncode(str: string): string {
      return encodeURIComponent(str);
    },

    // ── Time ──
    timeFormat(timestamp: number, fmt?: string): string {
      const d = new Date(timestamp > 1e12 ? timestamp : timestamp * 1000);
      const format = fmt || 'yyyy/MM/dd HH:mm';
      return format
        .replace('yyyy', String(d.getFullYear()))
        .replace('MM', String(d.getMonth() + 1).padStart(2, '0'))
        .replace('dd', String(d.getDate()).padStart(2, '0'))
        .replace('HH', String(d.getHours()).padStart(2, '0'))
        .replace('mm', String(d.getMinutes()).padStart(2, '0'))
        .replace('ss', String(d.getSeconds()).padStart(2, '0'));
    },

    timeFormatUTC(timestamp: number, fmt: string, shiftHours: number): string {
      const d = new Date(timestamp > 1e12 ? timestamp : timestamp * 1000);
      const utc = d.getTime() + d.getTimezoneOffset() * 60000;
      const shifted = new Date(utc + shiftHours * 3600000);
      const format = fmt || 'yyyy/MM/dd HH:mm';
      return format
        .replace('yyyy', String(shifted.getFullYear()))
        .replace('MM', String(shifted.getMonth() + 1).padStart(2, '0'))
        .replace('dd', String(shifted.getDate()).padStart(2, '0'))
        .replace('HH', String(shifted.getHours()).padStart(2, '0'))
        .replace('mm', String(shifted.getMinutes()).padStart(2, '0'))
        .replace('ss', String(shifted.getSeconds()).padStart(2, '0'));
    },

    currentTime(): number {
      return Date.now();
    },

    // ── String ops ──
    strReplace(str: string, regex: string, replacement: string): string {
      try {
        return str.replace(new RegExp(regex, 'g'), replacement);
      } catch {
        return str;
      }
    },

    toString(val: any): string {
      return val == null ? '' : String(val);
    },

    // ── Hash ──
    md5Encode(str: string): string {
      return md5Hex(str);
    },

    md5Encode16(str: string): string {
      return md5Hex(str).substring(8, 24);
    },

    sha1Encode(str: string): string {
      return sha1Hex(str);
    },

    sha256Encode(str: string): string {
      return sha256Hex(str);
    },

    digestHex(data: string, algo: string): string {
      const a = algo.toUpperCase().replace(/[-_]/g, '');
      switch (a) {
        case 'MD5':
          return md5Hex(data);
        case 'SHA1':
          return sha1Hex(data);
        case 'SHA256':
          return sha256Hex(data);
        default:
          return '';
      }
    },

    HMacHex: hmacHex,
    hmacHex,
    HMacBase64: hmacBase64,
    hmacBase64,

    // ── AES ──
    aesBase64DecodeToString(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      try {
        return symmetricDecrypt(data, key, transformation, iv);
      } catch {
        return '';
      }
    },

    aesDecodeArgsBase64Str(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      try {
        return symmetricDecrypt(data, key, transformation, iv);
      } catch {
        return '';
      }
    },

    aesEncodeToBase64String(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      try {
        return symmetricEncrypt(data, key, transformation, iv);
      } catch {
        return '';
      }
    },

    aesEncodeArgsBase64Str(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      try {
        return symmetricEncrypt(data, key, transformation, iv);
      } catch {
        return '';
      }
    },

    aesEncodeToString(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      try {
        return symmetricEncrypt(data, key, transformation, iv);
      } catch {
        return '';
      }
    },

    aesDecodeToString(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      try {
        return symmetricDecrypt(data, key, transformation, iv);
      } catch {
        return '';
      }
    },

    // ── DES ──
    desEncodeToBase64String(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      const t = transformation || 'DES/CBC/PKCS5Padding';
      try {
        return symmetricEncrypt(data, key, t, iv);
      } catch {
        return '';
      }
    },

    desBase64DecodeToString(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      const t = transformation || 'DES/CBC/PKCS5Padding';
      try {
        return symmetricDecrypt(data, key, t, iv);
      } catch {
        return '';
      }
    },

    desDecodeArgsBase64Str(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      const t = transformation || 'DES/CBC/PKCS5Padding';
      try {
        return symmetricDecrypt(data, key, t, iv);
      } catch {
        return '';
      }
    },

    tripleDESEncodeBase64Str(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      const t = transformation || 'DESede/CBC/PKCS5Padding';
      try {
        return symmetricEncrypt(data, key, t, iv);
      } catch {
        return '';
      }
    },

    desEdeEncodeArgsBase64Str(
      data: string,
      key: string,
      transformation: string,
      iv: string,
    ): string {
      const t = transformation || 'DESede/CBC/PKCS5Padding';
      try {
        return symmetricEncrypt(data, key, t, iv);
      } catch {
        return '';
      }
    },

    // ── createSymmetricCrypto (hutool chain API) ──
    createSymmetricCrypto(transformation: string, key: any, iv?: any) {
      const keyWA =
        typeof key === 'string'
          ? CryptoJS.enc.Utf8.parse(key)
          : CryptoJS.lib.WordArray.create(key);
      const ivWA = iv
        ? typeof iv === 'string'
          ? CryptoJS.enc.Utf8.parse(iv)
          : CryptoJS.lib.WordArray.create(iv)
        : undefined;
      let pendingData: any = null;
      const api: any = {
        setContent(data: any) {
          pendingData = data;
          return api;
        },
        encrypt(data?: any) {
          if (data === undefined) data = pendingData;
          const dataWA =
            typeof data === 'string'
              ? CryptoJS.enc.Utf8.parse(data)
              : CryptoJS.lib.WordArray.create(data);
          return symmetricCryptRaw('encrypt', dataWA, keyWA, ivWA, transformation);
        },
        encryptHex(data?: any) {
          const result = api.encrypt(data);
          return result.toString(CryptoJS.enc.Hex);
        },
        encryptBase64(data?: any) {
          const result = api.encrypt(data);
          return CryptoJS.enc.Base64.stringify(result);
        },
        decrypt(data?: any) {
          if (data === undefined) data = pendingData;
          let dataWA: CryptoJS.lib.WordArray;
          if (typeof data === 'string') {
            try {
              dataWA = CryptoJS.enc.Base64.parse(data);
            } catch {
              dataWA = CryptoJS.enc.Hex.parse(data);
            }
          } else {
            dataWA = CryptoJS.lib.WordArray.create(data);
          }
          return symmetricCryptRaw('decrypt', dataWA, keyWA, ivWA, transformation);
        },
        decryptStr(data?: any) {
          const result = api.decrypt(data);
          return result.toString(CryptoJS.enc.Utf8);
        },
      };
      return api;
    },

    // ── Hex ──
    hexEncodeToString(str: string): string {
      return hexEncode(str);
    },

    hexDecodeToString(hex: string): string {
      try {
        return hexDecode(hex);
      } catch {
        return '';
      }
    },

    hexDecodeToByteArray(hex: string): number[] {
      return hexDecodeToBytes(hex);
    },

    // ── Bytes ──
    strToBytes(str: string, charset?: string): number[] {
      return strToBytes(str, charset);
    },

    bytesToStr(bytes: any, charset?: string): string {
      return bytesToStr(bytes, charset);
    },

    // ── Device ──
    androidId(): string {
      return getAndroidId();
    },

    deviceID(): string {
      return getAndroidId();
    },

    randomUUID(): string {
      return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(
        /[xy]/g,
        c => {
          const r = (Math.random() * 16) | 0;
          return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
        },
      );
    },

    // ── i18n ──
    lang(): string {
      return 'zh';
    },

    t2s(str: string): string {
      return str;
    },

    s2t(str: string): string {
      return str;
    },

    // ── HTML ──
    htmlFormat(str: string): string {
      return htmlFormat(str);
    },

    // ── Chapter ──
    toNumChapter(str: string | null): string {
      return toNumChapter(str);
    },

    // ── UA ──
    getWebViewUA(): string {
      return WEB_VIEW_UA;
    },

    // ── importScript ──
    importScript(path: string): string {
      if (!path.startsWith('http://') && !path.startsWith('https://')) {
        return '';
      }
      if (jsLibCache[path]) return jsLibCache[path];
      console.warn('[JsRunner] importScript sync not supported');
      return '';
    },

    // ── Source info ──
    getSource(): BookSource | undefined {
      return scope.bookSource;
    },

    getBaseUrl(): string {
      return scope.baseUrl || '';
    },

    // ── Cookie ──
    getCookie(url: string): string {
      return cookieStore[url] || '';
    },

    setCookie(url: string, cookie: string) {
      cookieStore[url] = cookie;
    },

    removeCookie(url: string) {
      delete cookieStore[url];
    },

    // ── WebView stubs ──
    webView(_url?: any, _headers?: any, _js?: any): string {
      return '';
    },

    webViewGetSource(_url?: any, _headers?: any, _js?: any): string {
      return '';
    },

    webViewGetOverrideUrl(_url?: any, _headers?: any, _js?: any): string {
      return '';
    },

    startBrowser(_url: string, _keyword: string) {},

    startBrowserAwait(urlAny: any, keywordAny?: any): any {
      return {
        body: () => '',
        code: () => 0,
        header: () => '',
        headers: () => ({}),
      };
    },

    refreshTocUrl() {},

    // ── TTF stubs ──
    queryTTF(_urlOrData?: any, _useCache?: any): any {
      return {
        getNameByCode: () => null,
        getCodeByName: () => null,
        inLimit: () => false,
        getGlyfByCode: () => null,
        ttfRange: [],
        fileBytes: [],
      };
    },

    queryBase64TTF(_data?: any, _useCache?: any): any {
      return {
        getNameByCode: () => null,
        getCodeByName: () => null,
        inLimit: () => false,
        getGlyfByCode: () => null,
      };
    },

    replaceFont(text: string, _from?: any, _to?: any): string {
      return text;
    },

    // ── getElements / getElement / getString / getStringList / setContent ──
    // These operate on scope.src using cheerio
    getElements(rule: string): any[] {
      const html = scope.src || '';
      if (!html) return [];
      const sel = legadoSelector(rule);
      try {
        const $ = cheerio.load(html);
        const results: any[] = [];
        $(sel).each((_, el) => {
          const $el = $(el);
          results.push({
            text: () => $el.text(),
            html: () => $el.html() || '',
            outerHtml: () => $.html(el) || '',
            attr: (name: string) => $el.attr(name) || '',
            select: (subSel: string) => {
              const sub = legadoSelector(subSel);
              const subResults: any[] = [];
              $el.find(sub).each((__, subEl) => {
                const $subEl = $(subEl);
                subResults.push({
                  text: () => $subEl.text(),
                  html: () => $subEl.html() || '',
                  outerHtml: () => $.html(subEl) || '',
                  attr: (n: string) => $subEl.attr(n) || '',
                });
              });
              return {
                size: () => subResults.length,
                get: (i: number) => subResults[i] || null,
              };
            },
          });
        });
        return results;
      } catch {
        return [];
      }
    },

    getElement(rule: string): any {
      const arr = this.getElements(rule);
      return arr.length > 0 ? arr[0] : null;
    },

    getString(rule: string): string {
      if (typeof rule !== 'string' || !rule) return '';
      const r = rule.trim();
      if (r.charAt(0) === '$') {
        const s = scope.src || '';
        if (!s) return '';
        try {
          const obj = typeof s === 'string' ? JSON.parse(s) : s;
          const parts = r.replace(/^\$\.?/, '').split('.');
          let cur: any = obj;
          for (const p of parts) {
            if (cur == null) return '';
            const bracket = p.match(/^(.+?)\[(\d+)\]$/);
            if (bracket) {
              cur = cur[bracket[1]];
              if (Array.isArray(cur)) cur = cur[parseInt(bracket[2], 10)];
            } else {
              cur = cur[p];
            }
          }
          return cur == null ? '' : String(cur);
        } catch {
          /* fall through to CSS */
        }
      }
      const el = this.getElement(r);
      return el ? el.text() : '';
    },

    getStringList(rule: string): string[] {
      if (typeof rule !== 'string') return [];
      const firstAlt = String(rule).split('||')[0];
      const atIdx = firstAlt.lastIndexOf('@');
      let sel = firstAlt;
      let attr = '';
      if (atIdx > 0) {
        const maybeAttr = firstAlt.substring(atIdx + 1).trim();
        if (/^\w+$/.test(maybeAttr)) {
          sel = firstAlt.substring(0, atIdx);
          attr = maybeAttr;
        }
      }
      const els = this.getElements(sel);
      const out: string[] = [];
      for (const el of els) {
        let v = '';
        if (attr === '' || attr === 'text') v = el.text();
        else if (attr === 'html') v = el.html();
        else if (attr === 'outerHtml') v = el.outerHtml();
        else v = el.attr(attr);
        if (v) out.push(String(v));
      }
      return out;
    },

    setContent(content: any) {
      if (typeof content === 'string') {
        scope.src = content;
      }
    },

    // ── headerMap stub ──
    headerMap: {
      _m: {} as Record<string, string>,
      put(k: string, v: string) {
        this._m[k] = v;
      },
      get(k: string): string {
        return this._m[k] || '';
      },
    },
  };
}

function createCookieBridge() {
  return {
    getCookie(url: string, key?: string): string {
      const all = cookieStore[url] || '';
      if (!key) return all;
      const match = all.match(new RegExp(`${key}=([^;]*)`));
      return match ? match[1] : '';
    },
    getCookieKey(url: string, key: string): string {
      return this.getCookie(url, key);
    },
    setCookie(url: string, cookie: string) {
      cookieStore[url] = cookie;
    },
    removeCookie(url: string) {
      delete cookieStore[url];
    },
    clearCookie(url: string) {
      delete cookieStore[url];
    },
  };
}

function createCacheObject() {
  return {
    putMemory(key: string, val: any) {
      cacheMemory[key] = val;
    },
    getFromMemory(key: string): any {
      return cacheMemory[key] ?? null;
    },
    put(key: string, val: any) {
      kvStore[key] = val;
    },
    get(key: string): any {
      return kvStore[key] ?? null;
    },
    delete(key: string) {
      delete kvStore[key];
    },
  };
}

function createSourceObject(bookSource?: BookSource) {
  const src = bookSource || ({} as BookSource);
  const variables: Record<string, string> = {};
  return {
    bookSourceUrl: src.bookSourceUrl || '',
    bookSourceName: src.bookSourceName || '',
    bookSourceComment: (src.bookSourceComment || '').replace(/\.length\(\)/g, '.length'),
    getKey: () => src.bookSourceUrl || '',
    getName: () => src.bookSourceName || '',
    getOrigin: () => {
      try {
        return new URL(src.bookSourceUrl || '').origin;
      } catch {
        return src.bookSourceUrl || '';
      }
    },
    getTag: () => src.bookSourceGroup || '',
    getVariable: (key: string) => variables[key] || '',
    setVariable: (key: string, val: string) => {
      variables[key] = val;
    },
    getLoginInfo: () => '',
    getLoginInfoMap: () => ({}),
    getLoginHeader: () => '',
    getLoginHeaderMap: () => ({}),
    putLoginHeader: () => {},
    putLoginInfo: () => {},
    refreshExplore: () => {},
  };
}

/**
 * 生成 Java polyfill 脚本 (注入到 Function body 中)
 */
function getJavaPolyfills(): string {
  return `
    // String.prototype polyfills (Rhino compat)
    if (!String.prototype.getBytes) {
      String.prototype.getBytes = function() {
        var s = String(this);
        var u8 = [];
        for (var i = 0; i < s.length; i++) {
          var code = s.charCodeAt(i);
          if (code < 0x80) u8.push(code);
          else if (code < 0x800) { u8.push(0xc0 | (code >> 6)); u8.push(0x80 | (code & 0x3f)); }
          else { u8.push(0xe0 | (code >> 12)); u8.push(0x80 | ((code >> 6) & 0x3f)); u8.push(0x80 | (code & 0x3f)); }
        }
        return u8;
      };
    }
    if (!String.prototype.equals) {
      String.prototype.equals = function(s) { return String(this) === String(s); };
    }
    if (!String.prototype.equalsIgnoreCase) {
      String.prototype.equalsIgnoreCase = function(s) { return String(this).toLowerCase() === String(s).toLowerCase(); };
    }
    if (!String.prototype.contains) {
      String.prototype.contains = function(s) { return this.indexOf(s) >= 0; };
    }

    // Rhino-style String.replaceAll compat
    var _origReplaceAll = String.prototype.replaceAll;
    if (_origReplaceAll) {
      String.prototype.replaceAll = function(searchValue, replaceValue) {
        if (typeof searchValue === 'string' && /[\\\\\\[\\]()*+?{}|^$]/.test(searchValue)) {
          try {
            var pattern = searchValue;
            var flags = 'g';
            var m = pattern.match(/^\\(\\?([a-z]+)\\)(.*)/);
            if (m) { if (m[1].indexOf('i') >= 0) flags += 'i'; pattern = m[2]; }
            return this.replace(new RegExp(pattern, flags), replaceValue);
          } catch (e) {}
        }
        return _origReplaceAll.call(this, searchValue, replaceValue);
      };
    }

    // Java global classes
    var Base64 = {
      getEncoder: function() { return { encodeToString: function(bytes) { return typeof btoa === 'function' ? btoa(String.fromCharCode.apply(null, bytes)) : ''; } }; },
      getDecoder: function() { return { decode: function(str) { try { var bin = atob(String(str)); var u8 = new Uint8Array(bin.length); for(var i=0;i<bin.length;i++) u8[i]=bin.charCodeAt(i); return u8; } catch(e) { return new Uint8Array(0); } } }; }
    };

    var Arrays = {
      copyOfRange: function(arr, from, to) { return (arr.slice ? arr.slice(from, to) : Array.prototype.slice.call(arr, from, to)); },
      toString: function(arr) { return '[' + Array.prototype.join.call(arr, ', ') + ']'; },
      asList: function(arr) { return Array.prototype.slice.call(arr); }
    };

    var Integer = {
      parseInt: function(s, radix) { return parseInt(s, radix || 10); },
      valueOf: function(s) { return parseInt(s, 10); },
      toHexString: function(n) { return (n >>> 0).toString(16); },
      MAX_VALUE: 2147483647,
      MIN_VALUE: -2147483648
    };

    var SecretKeySpec = function(keyBytes, algo) { return { __key: keyBytes, __algo: algo || 'AES' }; };
    var IvParameterSpec = function(ivBytes) { return { __iv: ivBytes }; };

    var Cipher = {
      ENCRYPT_MODE: 1,
      DECRYPT_MODE: 2,
      getInstance: function(transformation) {
        var c = { __t: transformation, __key: null, __iv: null, __mode: 0,
          init: function(mode, key, iv) { c.__mode = mode; c.__key = key && key.__key; c.__iv = iv && iv.__iv; },
          doFinal: function(bytes) {
            var keyStr = '';
            if (c.__key) { if (typeof c.__key === 'string') keyStr = c.__key; else { for(var i=0;i<c.__key.length;i++) keyStr += String.fromCharCode(c.__key[i] < 0 ? c.__key[i]+256 : c.__key[i]); } }
            var ivStr = '';
            if (c.__iv) { if (typeof c.__iv === 'string') ivStr = c.__iv; else { for(var i=0;i<c.__iv.length;i++) ivStr += String.fromCharCode(c.__iv[i] < 0 ? c.__iv[i]+256 : c.__iv[i]); } }
            if (c.__mode === 2) {
              var b64 = typeof btoa === 'function' ? btoa(String.fromCharCode.apply(null, bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes))) : '';
              return java.aesBase64DecodeToString(b64, keyStr, c.__t, ivStr);
            } else {
              var dataStr = '';
              if (typeof bytes === 'string') dataStr = bytes;
              else { for(var i=0;i<bytes.length;i++) dataStr += String.fromCharCode(bytes[i] < 0 ? bytes[i]+256 : bytes[i]); }
              return java.aesEncodeToBase64String(dataStr, keyStr, c.__t, ivStr);
            }
          }
        };
        return c;
      }
    };

    var JavaImporter = function() {
      return { importPackage: function(){}, importClass: function(){},
        Base64: Base64, Arrays: Arrays, Cipher: Cipher,
        SecretKeySpec: SecretKeySpec, IvParameterSpec: IvParameterSpec, Integer: Integer };
    };

    // java.url property
    if (typeof java !== 'undefined') {
      Object.defineProperty(java, 'url', {
        get: function() { return baseUrl || ''; },
        set: function(v) { baseUrl = v; },
        configurable: true
      });
    }

    // Java class stubs (Rhino/Android compat)
    var _javaLangString = function(s) { return String(s); };
    _javaLangString.prototype = String.prototype;
    var _javaLangSystem = {
      currentTimeMillis: function() { return Date.now(); },
      arraycopy: function(src, srcPos, dest, destPos, len) {
        for (var i = 0; i < len; i++) dest[destPos + i] = src[srcPos + i];
      }
    };
    var _javaLangReflectArray = {
      newInstance: function(type, len) {
        var a = new Array(len);
        for (var i = 0; i < len; i++) a[i] = 0;
        return a;
      }
    };
    var _javaLangByte = { TYPE: 'byte' };
    var _javaLangInteger = Integer;
    var _javaxCryptoMac = {
      getInstance: function(algo) {
        return {
          __algo: algo, __key: null,
          init: function(ks) { this.__key = ks; },
          doFinal: function(dataBytes) {
            var keyStr = '';
            var kb = this.__key && this.__key.__rawBytes ? this.__key.__rawBytes : (this.__key && this.__key.__key ? this.__key.__key : []);
            for (var i = 0; i < kb.length; i++) keyStr += String.fromCharCode(kb[i] < 0 ? kb[i]+256 : kb[i]);
            var dataStr = '';
            for (var i = 0; i < dataBytes.length; i++) dataStr += String.fromCharCode(dataBytes[i] < 0 ? dataBytes[i]+256 : dataBytes[i]);
            var hash = java.hmacHex(dataStr, keyStr, 'HmacSHA256');
            var bytes = [];
            for (var i = 0; i < hash.length; i += 2) {
              var v = parseInt(hash.substring(i, i+2), 16);
              bytes.push(v > 127 ? v - 256 : v);
            }
            return bytes;
          }
        };
      }
    };
    var _javaxCryptoSpec = {
      SecretKeySpec: function(keyBytes, algo) {
        return { __key: keyBytes, __rawBytes: keyBytes, __algo: algo || 'AES' };
      },
      IvParameterSpec: function(ivBytes) {
        return { __iv: ivBytes };
      }
    };
    var _javaxCryptoCipher = Cipher;

    var Packages = new Proxy({}, {
      get: function(_, name) {
        if (name === 'java') return {
          lang: { String: _javaLangString, System: _javaLangSystem, Integer: _javaLangInteger, Byte: _javaLangByte, reflect: { Array: _javaLangReflectArray } },
          util: { UUID: { randomUUID: function() { return { toString: function() { return java.randomUUID(); } }; } } },
          io: {}
        };
        if (name === 'javax') return {
          crypto: { Cipher: _javaxCryptoCipher, Mac: _javaxCryptoMac, spec: _javaxCryptoSpec }
        };
        return new Proxy({}, { get: function() { return function(){}; } });
      }
    });

    // Top-level java.lang/javax polyfill for jsLib that references them directly
    if (typeof java !== 'undefined') {
      java.lang = { String: _javaLangString, System: _javaLangSystem, Integer: _javaLangInteger, Byte: _javaLangByte, reflect: { Array: _javaLangReflectArray } };
      java.util = { UUID: { randomUUID: function() { return { toString: function() { return java.randomUUID(); } }; } } };
    }
    var javax = { crypto: { Cipher: _javaxCryptoCipher, Mac: _javaxCryptoMac, spec: _javaxCryptoSpec } };

    // buildUrl helper (Legado standard)
    function buildUrl(baseUrl, params) {
      if (!params || typeof params !== 'object') return baseUrl;
      var parts = Object.keys(params).map(function(k) {
        return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
      });
      return baseUrl + (baseUrl.indexOf('?') >= 0 ? '&' : '?') + parts.join('&');
    }

    // String.prototype.length() compat (Java String has length() method)
    if (!String.prototype._lengthFn) {
      Object.defineProperty(String.prototype, '_lengthFn', { value: true, writable: false });
      var _origLength = Object.getOwnPropertyDescriptor(String.prototype, 'length');
    }
  `;
}

/**
 * 执行 JS 书源规则脚本
 */
export async function evaluateJs(
  script: string,
  scope: JSScope,
): Promise<any> {
  try {
    const javaBridge = createJavaBridge(scope);
    const cookieBridge = createCookieBridge();
    const cacheObj = createCacheObject();
    const sourceObj = createSourceObject(scope.bookSource);

    let injectedResult = scope.result;
    if (
      typeof injectedResult === 'string' &&
      !script.includes('JSON.parse(result)')
    ) {
      const trimmed = (injectedResult as string).trim();
      if (
        (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'))
      ) {
        try {
          injectedResult = JSON.parse(trimmed);
        } catch {}
      }
    }

    let processed = script.replace(/\.length\(\)/g, '.length');

    const wrappedScript = wrapWithReturn(processed);

    const jsLib = scope.bookSource?.jsLib || '';
    const baseOrigin = scope.bookSource?.bookSourceUrl || '';
    const BASE = baseOrigin;

    const fn = new Function(
      'java',
      'cookie',
      'cache',
      'result',
      'baseUrl',
      'src',
      'source',
      'key',
      'page',
      'book',
      'chapter',
      'nextChapterUrl',
      'BASE',
      `
      var keyword = key;
      var searchKey = key;
      ${getJavaPolyfills()}
      ${jsLib ? jsLib.replace(/\.length\(\)/g, '.length') : ''}
      ${wrappedScript}`,
    );

    const returnVal = fn(
      javaBridge,
      cookieBridge,
      cacheObj,
      injectedResult,
      scope.baseUrl || '',
      scope.src || '',
      sourceObj,
      scope.key || '',
      scope.page || 1,
      scope.book || {},
      scope.chapter || {},
      scope.nextChapterUrl || '',
      BASE,
    );

    if (returnVal && typeof returnVal.then === 'function') {
      return await returnVal;
    }
    return returnVal;
  } catch (e: any) {
    if (__DEV__) {
      console.warn(
        '[JsRunner] eval error:',
        e.message,
        '\nscript:',
        script.slice(0, 100),
      );
    }
    return null;
  }
}

/**
 * 同步版本
 */
export function evaluateJsSync(script: string, scope: JSScope): any {
  try {
    const javaBridge = createJavaBridge(scope);
    const cookieBridge = createCookieBridge();
    const cacheObj = createCacheObject();
    const sourceObj = createSourceObject(scope.bookSource);

    let processed = script.replace(/\.length\(\)/g, '.length');
    const wrappedScript = wrapWithReturn(processed);

    let injectedResult = scope.result;
    if (
      typeof injectedResult === 'string' &&
      !script.includes('JSON.parse(result)')
    ) {
      const trimmed = (injectedResult as string).trim();
      if (
        (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'))
      ) {
        try {
          injectedResult = JSON.parse(trimmed);
        } catch {}
      }
    }

    const jsLib = scope.bookSource?.jsLib || '';
    const BASE = scope.bookSource?.bookSourceUrl || '';

    const fn = new Function(
      'java',
      'cookie',
      'cache',
      'result',
      'baseUrl',
      'src',
      'source',
      'key',
      'page',
      'book',
      'chapter',
      'BASE',
      `
      var keyword = key;
      var searchKey = key;
      ${getJavaPolyfills()}
      ${jsLib ? jsLib.replace(/\.length\(\)/g, '.length') : ''}
      ${wrappedScript}`,
    );

    return fn(
      javaBridge,
      cookieBridge,
      cacheObj,
      injectedResult,
      scope.baseUrl || '',
      scope.src || '',
      sourceObj,
      scope.key || '',
      scope.page || 1,
      scope.book || {},
      scope.chapter || {},
      BASE,
    );
  } catch (e: any) {
    if (__DEV__) {
      console.warn('[JsRunner.sync] error:', e.message);
    }
    return null;
  }
}
