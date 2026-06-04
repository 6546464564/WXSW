// 万象书屋: Legado 规则引擎 (Node.js / cheerio + JS + JSONPath)
//
// 支持的规则语法:
//   === 选择器 ===
//   class.xxx      → querySelectorAll('.xxx')
//   tag.xxx        → querySelectorAll('xxx')
//   tag.xxx.N      → querySelectorAll('xxx')[N]
//   id.xxx         → querySelector('#xxx')
//   text.xxx       → contains(text, 'xxx')
//   @text/@href/@src/@html → 属性提取
//   ##regex        → 正则替换/移除
//   ||             → 备选规则
//
//   === JS 规则 ===
//   <js>...</js>   → 完整 JS 块 (result/baseUrl 变量)
//   @js:expr       → 内联 JS 表达式
//   {{expr}}       → 模板插值
//
//   === JSONPath ===
//   $.xxx / $..xxx → JSON 路径提取
//
//   === Java API ===
//   java.put/get, java.ajax, java.md5Encode, java.aesBase64DecodeToString 等

const cheerio = require('cheerio');
const crypto = require('crypto');
const { URL } = require('url');
const legadoJava = require('./legadoJava');
const { JSONPath } = require('jsonpath-plus');

const QIMAO_SIGN_KEY = 'd3dGiJc651gSQ8w1';
const QIMAO_HEADERS_TEMPLATE = {
  'app-version': '51110', 'platform': 'android', 'reg': '0',
  'AUTHORIZATION': '', 'application-id': 'com.****.reader',
  'net-env': '1', 'channel': 'unknown', 'qm-params': '',
};

function qimaoMd5Sign(params) {
  const sorted = Object.keys(params).sort().map(k => k + '=' + params[k]).join('');
  return crypto.createHash('md5').update(sorted + QIMAO_SIGN_KEY).digest('hex');
}

function qimaoBuildUrl(base, params) {
  params.sign = qimaoMd5Sign(params);
  const u = new URL(base);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  return u.href;
}

function qimaoHeaders() {
  const h = { ...QIMAO_HEADERS_TEMPLATE };
  h.sign = qimaoMd5Sign(h);
  h.headers = JSON.stringify({ headers: h });
  return h;
}

function isQimaoUrl(url) {
  return typeof url === 'string' && (url.includes('wtzw.com') || url.includes('qimao'));
}

function smartBuildUrl(base, params) {
  if (isQimaoUrl(base)) return qimaoBuildUrl(base, params || {});
  const u = new URL(base);
  for (const [k, v] of Object.entries(params || {})) u.searchParams.set(k, v);
  return u.href;
}

const UA = 'Mozilla/5.0 (Linux; Android 12; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';

let _proxyDispatcher = null;

function setProxyUrl(proxyUrl) {
  if (!proxyUrl) { _proxyDispatcher = null; return; }
  try {
    const { ProxyAgent } = require('undici');
    _proxyDispatcher = new ProxyAgent(proxyUrl);
  } catch (e) {
    console.warn('[legadoEngine] undici ProxyAgent unavailable:', e.message);
    _proxyDispatcher = null;
  }
}

if (process.env.PROXY_URL) {
  setProxyUrl(process.env.PROXY_URL);
  console.log('[legadoEngine] proxy enabled:', process.env.PROXY_URL.replace(/:([^@:]+)@/, ':***@'));
}

class BlockedError extends Error {
  constructor(url) { super(`Blocked by source: ${url}`); this.name = 'BlockedError'; }
}

async function httpGet(url, { headers = {}, timeout = 15000 } = {}) {
  const baseOpts = {
    headers: { 'User-Agent': UA, ...headers },
    redirect: 'follow',
    signal: AbortSignal.timeout(timeout),
  };

  async function doFetch(opts) {
    const resp = await fetch(url, opts);
    if (!resp.ok) throw new Error(`HTTP ${resp.status} for ${url}`);
    const text = await resp.text();
    if (text.length < 1000 && (text.includes('google.com') || text.includes('captcha') || text.includes('challenge'))) {
      throw new BlockedError(url);
    }
    return text;
  }

  if (_proxyDispatcher) {
    try {
      return await doFetch({ ...baseOpts, dispatcher: _proxyDispatcher });
    } catch {
      return await doFetch(baseOpts);
    }
  }
  return await doFetch(baseOpts);
}

function resolveUrl(base, relative) {
  if (!relative) return '';
  if (relative.startsWith('http://') || relative.startsWith('https://')) return relative;
  if (relative.startsWith('//')) return 'https:' + relative;
  try { return new URL(relative, base).href; } catch { return relative; }
}

function applyRegexFilter(text, regexPart) {
  if (!regexPart) return text;
  const parts = regexPart.split('##');
  let result = text;
  for (const p of parts) {
    if (!p) continue;
    try { result = result.replace(new RegExp(p, 'g'), ''); } catch {}
  }
  return result.trim();
}

function isJsRule(rule) {
  return rule && (rule.includes('<js>') || rule.startsWith('@js:') || rule.startsWith('$.'));
}

function hasTemplate(str) {
  return str && str.includes('{{');
}

// ─── HTML 选择器 (非 JS 规则) ───

function parseStep(step) {
  step = step.trim();
  if (step.startsWith('class.')) return { type: 'class', value: step.slice(6) };
  if (step.startsWith('tag.')) {
    const rest = step.slice(4);
    const dotIdx = rest.search(/\.\d+$/);
    if (dotIdx >= 0) return { type: 'tag', value: rest.slice(0, dotIdx), index: parseInt(rest.slice(dotIdx + 1), 10) };
    return { type: 'tag', value: rest };
  }
  if (step.startsWith('id.')) return { type: 'id', value: step.slice(3) };
  if (step.startsWith('text.')) return { type: 'text', value: step.slice(5) };
  return { type: 'css', value: step };
}

function execStep($, elements, step) {
  const parsed = parseStep(step);
  let result;
  switch (parsed.type) {
    case 'class':
      result = elements.find('.' + parsed.value);
      if (result.length === 0) result = $(`.${parsed.value}`);
      break;
    case 'tag':
      result = elements.find(parsed.value);
      if (result.length === 0) result = $(parsed.value);
      if (typeof parsed.index === 'number') result = result.eq(parsed.index);
      break;
    case 'id':
      result = $(`#${parsed.value}`);
      break;
    case 'text': {
      const textVal = parsed.value;
      result = elements.find('*').filter(function () { return $(this).text().includes(textVal); });
      if (result.length === 0) result = $('*').filter(function () { return $(this).text().includes(textVal); });
      break;
    }
    case 'css':
      result = elements.find(parsed.value);
      if (result.length === 0) result = $(parsed.value);
      break;
  }
  return result || $();
}

function evalRule($, elements, rule, baseUrl = '') {
  if (!rule || typeof rule !== 'string') return '';

  if (rule.includes('||')) {
    for (const alt of rule.split('||')) {
      const result = evalRule($, elements, alt.trim(), baseUrl);
      if (result) return result;
    }
    return '';
  }

  let regexFilter = '';
  let mainRule = rule;
  const regexIdx = rule.indexOf('##');
  if (regexIdx >= 0) {
    mainRule = rule.slice(0, regexIdx);
    regexFilter = rule.slice(regexIdx + 2);
  }

  const steps = mainRule.split('@');
  let current = elements;
  let extractor = null;

  for (const step of steps) {
    const s = step.trim();
    if (!s) continue;
    if (['text', 'href', 'src', 'html', 'textNodes', 'ownText'].includes(s)) { extractor = s; continue; }
    current = execStep($, current, s);
  }

  let result = '';
  switch (extractor) {
    case 'text': case 'textNodes': case 'ownText':
      result = current.first().text().trim(); break;
    case 'href':
      result = resolveUrl(baseUrl, current.first().attr('href') || ''); break;
    case 'src':
      result = resolveUrl(baseUrl, current.first().attr('src') || ''); break;
    case 'html':
      result = current.first().html() || ''; break;
    default:
      result = current.first().text().trim();
  }
  return applyRegexFilter(result, regexFilter);
}

function evalListRule($, rule) {
  if (!rule || typeof rule !== 'string') return [];
  const steps = rule.split('@');
  let current = $.root();
  for (const step of steps) {
    const s = step.trim();
    if (!s) continue;
    current = execStep($, current, s);
  }
  const items = [];
  current.each(function () { items.push($(this)); });
  return items;
}

// ─── JS + JSONPath 规则处理 ───

function processJsRule(rule, result, baseUrl, javaApi, sourceApi, rawSource) {
  if (!rule) return result;
  let output = result;

  const jsMatch = rule.match(/<js>([\s\S]*?)<\/js>/);
  if (jsMatch) {
    output = legadoJava.evalJsBlock(jsMatch[1], {
      result: output, baseUrl, java: javaApi, source: sourceApi, _source: rawSource,
    });
    const afterJs = rule.slice(rule.indexOf('</js>') + 5).trim();
    if (afterJs) {
      output = processPostJsRule(afterJs, output, javaApi);
    }
    return output;
  }

  if (rule.includes('@js:')) {
    const parts = rule.split('@js:');
    const prePart = parts[0].trim();
    const jsExpr = parts[1].trim();
    if (prePart) {
      output = extractByPath(prePart, output);
    }
    output = legadoJava.evalJsInline(jsExpr, output, {
      java: javaApi, source: sourceApi, _source: rawSource,
      baseUrl, BASE: rawSource?.bookSourceUrl,
    });
    return output;
  }

  if (rule.startsWith('$.') || rule.startsWith('$[')) {
    return extractByPath(rule, output);
  }

  return output;
}

function processPostJsRule(rule, data, javaApi) {
  if (!rule) return data;
  // || 备选
  if (rule.includes('||')) {
    for (const alt of rule.split('||')) {
      const r = extractByPath(alt.trim(), data);
      if (r && (Array.isArray(r) ? r.length > 0 : true)) return r;
    }
    return data;
  }
  return extractByPath(rule, data);
}

function extractByPath(path, data) {
  if (!path || !path.startsWith('$')) return data;
  try {
    const json = typeof data === 'string' ? JSON.parse(data) : data;
    const results = JSONPath({ path, json, wrap: true });
    if (results.length === 1) return results[0];
    return results;
  } catch { return data; }
}

function extractSingleByPath(path, item) {
  if (!path || !path.startsWith('$')) return '';
  try {
    const results = JSONPath({ path, json: item, wrap: false });
    if (Array.isArray(results)) return results[0] != null ? String(results[0]) : '';
    return results != null ? String(results) : '';
  } catch { return ''; }
}

// ─── 高层: 搜索/章节/内容 (支持 JS 和非 JS 源) ───

async function searchBook(source, keyword) {
  const javaApi = legadoJava.createJavaApi();
  const sourceApi = legadoJava.createSourceApi(source);

  let searchUrl = source.searchUrl || '';
  if (!searchUrl) throw new Error('source has no searchUrl');

  let fullUrl;

  if (searchUrl.startsWith('@js:')) {
    const jsExpr = searchUrl.slice(4).trim();
    const vm = require('vm');
    const sandbox = legadoJava.createFullSandbox({
      key: keyword, page: 1,
      BASE: source.bookSourceUrl,
      java: javaApi, source: sourceApi,
      buildUrl: smartBuildUrl,
    });
    vm.createContext(sandbox);
    legadoJava.injectJsLib(sandbox, source);
    try {
      fullUrl = String(vm.runInContext(jsExpr, sandbox, { timeout: 5000 }));
    } catch (e) {
      throw new Error(`@js searchUrl eval failed: ${e.message}`);
    }
  } else {
    searchUrl = searchUrl.replace(/\{\{key\}\}/g, encodeURIComponent(keyword));
    if (hasTemplate(searchUrl)) {
      searchUrl = legadoJava.evalTemplate(searchUrl, { java: javaApi, source: sourceApi, keyword });
    }
    fullUrl = resolveUrl(source.bookSourceUrl, searchUrl);
  }

  const extraHeaders = source.header ? legadoJava.buildWanxiangHeaders(source, javaApi) : {};

  const responseText = await httpGet(fullUrl, { headers: extraHeaders });
  const rules = source.ruleSearch || {};
  if (!rules.bookList) return [];

  // JS 规则路径
  if (isJsRule(rules.bookList)) {
    const processed = processJsRule(rules.bookList, responseText, fullUrl, javaApi, sourceApi, source);
    const items = Array.isArray(processed) ? processed : [processed];
    const books = [];
    for (const item of items) {
      if (!item || typeof item !== 'object') continue;
      javaApi._setResult(typeof item === 'string' ? item : JSON.stringify(item));

      const name = rules.name ? extractSingleByPath(rules.name, item) : '';
      if (!name) continue;
      const author = rules.author ? extractSingleByPath(rules.author, item) : '';

      let bookUrl = '';
      if (rules.bookUrl) {
        const itemStr = typeof item === 'string' ? item : JSON.stringify(item);
        javaApi._setResult(itemStr);
        if (rules.bookUrl.includes('@js:')) {
          bookUrl = String(processJsRule(rules.bookUrl, itemStr, fullUrl, javaApi, sourceApi, source) || '');
        } else if (hasTemplate(rules.bookUrl)) {
          bookUrl = legadoJava.evalTemplate(rules.bookUrl, {
            java: javaApi, source: sourceApi, keyword, result: item,
          });
        } else if (rules.bookUrl.startsWith('$.')) {
          bookUrl = extractSingleByPath(rules.bookUrl, item);
        }
      }

      let coverUrl = '';
      if (rules.coverUrl) {
        if (rules.coverUrl.includes('@js:')) {
          const itemStr = typeof item === 'string' ? item : JSON.stringify(item);
          coverUrl = String(processJsRule(rules.coverUrl, itemStr, fullUrl, javaApi, sourceApi, source) || '');
        } else if (hasTemplate(rules.coverUrl)) {
          coverUrl = legadoJava.evalTemplate(rules.coverUrl, { java: javaApi, source: sourceApi, result: item });
        } else {
          coverUrl = extractSingleByPath(rules.coverUrl, item);
        }
      }
      let intro = '';
      if (rules.intro) {
        if (rules.intro.includes('@js:')) {
          const itemStr = typeof item === 'string' ? item : JSON.stringify(item);
          intro = String(processJsRule(rules.intro, itemStr, fullUrl, javaApi, sourceApi, source) || '');
        } else {
          intro = extractSingleByPath(rules.intro, item);
        }
      }

      books.push({ name, author, bookUrl: resolveUrl(fullUrl, bookUrl), coverUrl, intro });
    }
    return books;
  }

  // 非 JS: HTML 选择器路径
  const $ = cheerio.load(responseText);
  const htmlItems = evalListRule($, rules.bookList);
  const books = [];
  for (const el of htmlItems) {
    const name = evalRule($, el, rules.name, fullUrl);
    if (!name) continue;
    books.push({
      name,
      author: evalRule($, el, rules.author, fullUrl),
      bookUrl: evalRule($, el, rules.bookUrl, fullUrl),
      coverUrl: evalRule($, el, rules.coverUrl, fullUrl),
      intro: evalRule($, el, rules.intro, fullUrl),
      lastChapter: evalRule($, el, rules.lastChapter, fullUrl),
    });
  }
  return books;
}

async function resolveBookInfo(source, bookUrl) {
  const rules = source.ruleBookInfo || {};
  if (!rules.init && !rules.tocUrl) return { tocUrl: bookUrl };

  const javaApi = legadoJava.createJavaApi();
  const sourceApi = legadoJava.createSourceApi(source);
  const extraHeaders = source.header ? legadoJava.buildWanxiangHeaders(source, javaApi) : {};

  const responseText = await httpGet(bookUrl, { headers: extraHeaders });

  const vm = require('vm');
  const bookObj = { getVariable: () => '0' };
  const sandbox = legadoJava.createFullSandbox({
    result: responseText,
    baseUrl: bookUrl,
    java: javaApi,
    source: sourceApi,
    book: bookObj,
    decode: legadoJava.wanxiangDecode,
    BASE: source.bookSourceUrl,
    buildUrl: smartBuildUrl,
    console: { log: () => {}, warn: () => {} },
    eval: function (code) {
      if (typeof code === 'string' && (code.includes('JavaImporter') || code.includes('Packages.'))) {
        return undefined;
      }
      try { return Function('"use strict"; return (' + code + ')')(); }
      catch { return undefined; }
    },
    JavaImporter: function () { this.importPackage = () => {}; return this; },
    Packages: new Proxy({}, { get: () => new Proxy({}, { get: () => function () {} }) }),
    Arrays: {
      copyOfRange(arr, from, to) {
        if (arr instanceof Int8Array || arr instanceof Uint8Array || Buffer.isBuffer(arr)) {
          return Buffer.from(arr.buffer || arr, arr.byteOffset + from, to - from);
        }
        return Array.isArray(arr) ? arr.slice(from, to) : arr;
      },
    },
    intToByte(i) { const b = i & 0xFF; return b >= 128 ? -(256 - b) : b; },
  });
  vm.createContext(sandbox);
  legadoJava.injectJsLib(sandbox, source);

  if (rules.init) {
    const initCode = rules.init.replace(/<js>([\s\S]*?)<\/js>/, '$1').replace(/^@js:\s*/s, '');
    try {
      const initResult = vm.runInContext(initCode, sandbox, { timeout: 15000 });
      if (initResult !== undefined) sandbox.result = initResult;
    } catch (e) {
      console.warn('[resolveBookInfo] init failed:', e.message);
      return { tocUrl: bookUrl };
    }
  }

  let bookInfo = sandbox.result;
  if (typeof bookInfo === 'string') {
    try { bookInfo = JSON.parse(bookInfo); } catch {}
  }

  let tocUrl = bookUrl;
  if (rules.tocUrl) {
    if (rules.tocUrl.startsWith('@js:') || rules.tocUrl.includes('<js>')) {
      try {
        const tocExpr = rules.tocUrl.replace(/<js>([\s\S]*?)<\/js>/, '$1').replace(/^@js:\s*/s, '');
        const resolved = vm.runInContext(tocExpr, sandbox, { timeout: 5000 });
        if (resolved) tocUrl = String(resolved);
      } catch (e) {
        console.warn('[resolveBookInfo] tocUrl JS failed:', e.message);
      }
    } else if (rules.tocUrl.startsWith('$.') && typeof bookInfo === 'object') {
      const tocPath = rules.tocUrl.replace(/^\$\./, '');
      tocUrl = bookInfo[tocPath] || bookUrl;
    }
  }

  return { tocUrl, bookInfo };
}

async function fetchToc(source, bookUrl) {
  const javaApi = legadoJava.createJavaApi();
  const sourceApi = legadoJava.createSourceApi(source);
  const extraHeaders = source.header ? legadoJava.buildWanxiangHeaders(source, javaApi) : {};

  const { tocUrl } = await resolveBookInfo(source, bookUrl);
  const responseText = await httpGet(tocUrl, { headers: extraHeaders });
  const rules = source.ruleToc || {};
  if (!rules.chapterList) throw new Error('source has no chapterList rule');

  // JS 规则
  if (isJsRule(rules.chapterList)) {
    const processed = processJsRule(rules.chapterList, responseText, tocUrl, javaApi, sourceApi, source);
    const items = Array.isArray(processed) ? processed : [];
    return items.map(item => {
      if (!item || typeof item !== 'object') return null;

      let title = '';
      const nameRule = rules.chapterName || '$.name';
      if (nameRule.startsWith('$.')) {
        title = extractSingleByPath(nameRule, item);
      } else {
        title = item[nameRule] || '';
      }
      if (!title) title = item.title || item.name || '';

      let url = '';
      const urlRule = rules.chapterUrl || '$.url';
      if (urlRule.includes('@js:') || urlRule.includes('<js>')) {
        const itemStr = typeof item === 'string' ? item : JSON.stringify(item);
        javaApi._setResult(itemStr);
        url = String(processJsRule(urlRule, itemStr, tocUrl, javaApi, sourceApi, source) || '');
      } else if (urlRule.startsWith('$.')) {
        url = extractSingleByPath(urlRule, item);
      } else {
        url = item[urlRule] || '';
      }
      if (!url) url = item.url || item.path || '';

      if (!title || !url) return null;
      return { title: String(title), url: resolveUrl(tocUrl, String(url)) };
    }).filter(Boolean);
  }

  // HTML 选择器
  const allChapters = [];
  let currentUrl = bookUrl;
  let pageCount = 0;
  const html = responseText;

  while (currentUrl && pageCount < 20) {
    const pageHtml = pageCount === 0 ? html : await httpGet(currentUrl, { headers: extraHeaders });
    const $page = cheerio.load(pageHtml);

    const items = evalListRule($page, rules.chapterList);
    for (const el of items) {
      const title = evalRule($page, el, rules.chapterName || 'tag.a@text', currentUrl);
      const url = evalRule($page, el, rules.chapterUrl || 'tag.a@href', currentUrl);
      if (title && url) allChapters.push({ title, url });
    }

    if (rules.nextTocUrl) {
      const nextUrl = evalRule($page, $page.root(), rules.nextTocUrl, currentUrl);
      if (nextUrl && nextUrl !== currentUrl) { currentUrl = nextUrl; pageCount++; await sleep(500); }
      else break;
    } else break;
  }
  return allChapters;
}

async function fetchContent(source, chapterUrl) {
  const javaApi = legadoJava.createJavaApi();
  const sourceApi = legadoJava.createSourceApi(source);
  const extraHeaders = source.header ? legadoJava.buildWanxiangHeaders(source, javaApi) : {};

  const responseText = await httpGet(chapterUrl, { headers: extraHeaders });
  const rules = source.ruleContent || {};
  const contentRule = rules.content || 'id.content@html';

  // JS 规则 (@js: 内联)
  if (isJsRule(contentRule)) {
    let content = processJsRule(contentRule, responseText, chapterUrl, javaApi, sourceApi, source);
    if (typeof content === 'object') content = JSON.stringify(content);
    content = String(content || '');
    if (content.includes('<')) {
      const $c = cheerio.load(content);
      $c('br').replaceWith('\n');
      $c('p').each(function () { $c(this).prepend('\n'); });
      content = $c.text().trim();
    }
    return content.replace(/\n{3,}/g, '\n\n').trim();
  }

  // HTML 选择器
  const $ = cheerio.load(responseText);
  let content = evalRule($, $.root(), contentRule, chapterUrl);

  if (content.includes('<')) {
    const $c = cheerio.load(content);
    $c('br').replaceWith('\n');
    $c('p').each(function () { $c(this).prepend('\n'); });
    content = $c.text().trim();
  }

  // 翻页拼接
  if (rules.nextContentUrl) {
    let nextUrl = evalRule($, $.root(), rules.nextContentUrl, chapterUrl);
    let pages = 0;
    while (nextUrl && nextUrl !== chapterUrl && pages < 10) {
      await sleep(300);
      const nextHtml = await httpGet(nextUrl, { headers: extraHeaders });
      const $n = cheerio.load(nextHtml);
      let nextContent = evalRule($n, $n.root(), contentRule, nextUrl);
      if (nextContent.includes('<')) {
        const $nc = cheerio.load(nextContent);
        $nc('br').replaceWith('\n');
        $nc('p').each(function () { $nc(this).prepend('\n'); });
        nextContent = $nc.text().trim();
      }
      content += '\n' + nextContent;
      const nn = evalRule($n, $n.root(), rules.nextContentUrl, nextUrl);
      if (!nn || nn === nextUrl) break;
      nextUrl = nn; pages++;
    }
  }

  return content.replace(/\n{3,}/g, '\n\n').trim();
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

module.exports = {
  searchBook,
  resolveBookInfo,
  fetchToc,
  fetchContent,
  httpGet,
  resolveUrl,
  evalRule,
  evalListRule,
  sleep,
  BlockedError,
  setProxyUrl,
  _getProxyDispatcher: () => _proxyDispatcher,
};
