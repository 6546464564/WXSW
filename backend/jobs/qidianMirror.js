// 万象书屋 D-23 (2026-05-08):
// 后端定时抓 m.qidian.com 数据源, 整理成 JSON 存 DB cache 表.
// App 端通过 /api/bookstore/mirror 拉这份 cache (替代直抓起点).
//
// 抓取时机: 每天 0:00-7:00 随机一次 (主入口 server.js 用 setTimeout 排, 不引入 node-cron).
//
// Node 18+ 内置 fetch + crypto, 无需新依赖.

const crypto = require('node:crypto');

const BASE = 'https://m.qidian.com';
const UA = 'Mozilla/5.0 (Linux; Android 12; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';
const COVER_TPL = (bid) => `https://bookcover.yuewen.com/qdbimg/349573/${bid}/180`;

/** 万象书屋: 9 个 SSR 榜单 key 列表 */
const RANK_KEYS = [
  'fyRank',    // 月票榜
  'hotRank',   // 阅读榜
  'dsRank',    // 畅销榜
  'recRank',   // 推荐榜
  'updRank',   // 更新榜
  'signRank',  // 签约榜
  'newpRank',  // 新人榜
  'newbRank',  // 新书榜
  'newFans',   // 书友榜
];

const FINISH_KEYS = ['classic', 'movie', 'bestSell', 'ds'];

/** 起点 m 站「小说」分类 = 实体/出版书 (isPub=1, form=1), 非 /rank/ 网文榜 */
const PUBLISH_CAT_ID = 13100;

/** 出版榜补充: 分类 SSR 仅 20 本; 按作者搜索 isPub=1 扩池 (无 majax 分页 API) */
const PUBLISH_SEARCH_AUTHORS = [
  '刘慈欣', '余华', '东野圭吾', '马伯庸', '当年明月', '张嘉佳', '路遥', '莫言',
  '村上春树', '毛姆', '加西亚·马尔克斯', '王小波', '三毛', '钱钟书',
  '紫金陈', '麦家',
];

/** 出版 mirror 每榜条数: 首页 8 格 + 换一批缓冲 */
const PUBLISH_RANK_PREVIEW = 12;

/** 出版四榜 → 分类/搜索排序策略 */
const PUBLISH_RANK_SPECS = [
  { key: 'fyRank', sort: 'category' },
  { key: 'hotRank', sort: 'categoryTail' },
  { key: 'newbRank', sort: 'updateTime' },
  { key: 'recRank', sort: 'recommend' },
];

/** majax 路径 → SSR 聚合 key (男女通用, 用于拉每榜 10 本) */
const MAJAX_RANKS = [
  { majax: 'yuepiaolist', ssrPath: 'yuepiao', key: 'fyRank' },
  { majax: 'hotsalesList', ssrPath: 'hotsales', key: 'hotRank' },
  { majax: 'dsList', ssrPath: 'ds', key: 'dsRank' },
  { majax: 'recList', ssrPath: 'recom', key: 'recRank' },
  { majax: 'updateList', ssrPath: 'update', key: 'updRank' },
  { majax: 'signnewbookList', ssrPath: 'signnewbook', key: 'signRank' },
  { majax: 'newauthorList', ssrPath: 'newauthor', key: 'newpRank' },
  { majax: 'newbookList', ssrPath: 'newbook', key: 'newbRank' },
  { majax: 'newFansList', ssrPath: 'newFans', key: 'newFans' },
];

/** 女频 majax: dsRank/signRank 无女频接口, 用子集 */
const FEMALE_MAJAX_RANKS = MAJAX_RANKS.filter(r => !['dsRank', 'signRank'].includes(r.key));

/** majax 无女频接口的榜 → 仍用 SSR 聚合 (与男频同源, 仅作占位) */
const FEMALE_SSR_FALLBACK_KEYS = ['dsRank', 'signRank'];

const HOME_RANK_PREVIEW = 10;

/** 发布前校验: 不完整 payload 拒绝写入, 避免覆盖已有好 cache */
const MIN_RANK_BOOKS = 5;
const MIN_YUEPIAO = 20;
const MIN_FINISH_BOOKS = 3;
const MIN_PUBLISH_RANK_BOOKS = 3;

function validateMirrorPayload(payload) {
  const errors = [];
  if (!payload || typeof payload !== 'object') {
    return { ok: false, errors: ['payload must be object'] };
  }
  if (!payload.ranks || typeof payload.ranks !== 'object') {
    errors.push('missing ranks');
  } else {
    for (const key of RANK_KEYS) {
      const list = payload.ranks[key];
      if (!Array.isArray(list) || list.length < MIN_RANK_BOOKS) {
        errors.push(`ranks.${key} need >= ${MIN_RANK_BOOKS} books, got ${list?.length ?? 0}`);
      }
    }
  }
  if (!payload.finish || typeof payload.finish !== 'object') {
    errors.push('missing finish');
  } else {
    for (const key of FINISH_KEYS) {
      const list = payload.finish[key];
      if (!Array.isArray(list) || list.length < MIN_FINISH_BOOKS) {
        errors.push(`finish.${key} need >= ${MIN_FINISH_BOOKS} books, got ${list?.length ?? 0}`);
      }
    }
  }
  if (!Array.isArray(payload.yuepiaoTop50) || payload.yuepiaoTop50.length < MIN_YUEPIAO) {
    errors.push(`yuepiaoTop50 need >= ${MIN_YUEPIAO}, got ${payload.yuepiaoTop50?.length ?? 0}`);
  }
  if (!payload.ranksFemale || typeof payload.ranksFemale !== 'object') {
    errors.push('missing ranksFemale');
  } else {
    for (const { key } of FEMALE_MAJAX_RANKS) {
      const list = payload.ranksFemale[key];
      if (!Array.isArray(list) || list.length < MIN_RANK_BOOKS) {
        errors.push(`ranksFemale.${key} need >= ${MIN_RANK_BOOKS} books, got ${list?.length ?? 0}`);
      }
    }
  }
  if (!payload.ranksPublish || typeof payload.ranksPublish !== 'object') {
    errors.push('missing ranksPublish');
  } else {
    for (const { key } of PUBLISH_RANK_SPECS) {
      const list = payload.ranksPublish[key];
      if (!Array.isArray(list) || list.length < MIN_PUBLISH_RANK_BOOKS) {
        errors.push(`ranksPublish.${key} need >= ${MIN_PUBLISH_RANK_BOOKS} books, got ${list?.length ?? 0}`);
      }
    }
  }
  return { ok: errors.length === 0, errors };
}

/**
 * 解析 m.qidian.com SSR HTML 中的 vite-plugin-ssr JSON.
 * 起点用 vite-plugin-ssr 把 pageData 写在 <script id="vite-plugin-ssr_pageContext">,
 * 一次拿全, 不需 DOM 遍历.
 */
function extractPageData(html) {
  const m = html.match(/<script id="vite-plugin-ssr_pageContext"[^>]*>(.+?)<\/script>/s);
  if (!m) throw new Error('vite-ssr script 不存在 (起点改了协议?)');
  const json = JSON.parse(m[1]);
  const pd = json?.pageContext?.pageProps?.pageData;
  if (!pd) throw new Error('pageData 缺失 (起点改了字段名 / 反爬?)');
  return pd;
}

/**
 * 起点字段 → 我们的统一 Book schema.
 * /rank/ 系列字段: bName / bAuth / bid (string) / cat / subCat / cnt / desc / rankNum / rankCnt
 * /finish/ 系列: bName / bAuth / bid (number) / cat / cnt / desc / state — 没 subCat / rankNum / rankCnt
 * movie 字段最简: bName / bid / bAuth / cid only.
 */
function parseBook(obj, fallbackRank = 0) {
  const bidRaw = obj?.bid;
  if (bidRaw === null || bidRaw === undefined || bidRaw === '') return null;
  const bid = String(bidRaw);  // 兼容 number / string 两种
  const name = (obj.bName || '').trim();
  if (!name) return null;
  return {
    bid,
    name,
    author: (obj.bAuth || '').trim(),
    cat: (obj.cat || '').trim(),
    subCat: (obj.subCat || '').trim(),
    wordCount: String(obj.cnt ?? '').trim(),
    rank: typeof obj.rankNum === 'number' ? obj.rankNum : fallbackRank,
    rankCount: String(obj.rankCnt ?? '').trim(),
    intro: (obj.desc || '').trim(),
    coverUrl: COVER_TPL(bid),
  };
}

let _sessionDispatcher = null;

function _ensureSessionDispatcher() {
  if (_sessionDispatcher) return _sessionDispatcher;
  const proxyUrl = process.env.PROXY_URL;
  if (proxyUrl) {
    try {
      const { ProxyAgent } = require('undici');
      _sessionDispatcher = new ProxyAgent(proxyUrl);
      return _sessionDispatcher;
    } catch { /* undici not available */ }
  }
  try {
    _sessionDispatcher = require('./legadoEngine')._getProxyDispatcher?.() || null;
  } catch { _sessionDispatcher = null; }
  return _sessionDispatcher;
}

function _resetSessionDispatcher() {
  if (_sessionDispatcher?.close) {
    try { _sessionDispatcher.close(); } catch { /* ignore */ }
  }
  _sessionDispatcher = null;
}

async function httpGet(url, extraHeaders = {}, retries = 2) {
  const dispatcher = _ensureSessionDispatcher();
  for (let attempt = 0; ; attempt++) {
    try {
      const opts = {
        headers: {
          'User-Agent': UA,
          'Referer': `${BASE}/`,
          'Accept-Language': 'zh-CN,zh;q=0.9',
          'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9',
          ...extraHeaders,
        },
        redirect: 'follow',
        signal: AbortSignal.timeout(15000),
      };
      if (dispatcher) opts.dispatcher = dispatcher;
      const resp = await fetch(url, opts);
      if (!resp.ok && resp.status !== 304) {
        throw new Error(`${url} HTTP ${resp.status}`);
      }
      return resp;
    } catch (e) {
      if (attempt >= retries) throw e;
      await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
    }
  }
}

/** 万象书屋: GET m.qidian.com/rank/?gender=<male|female> → 9 榜 × 5 本 (SSR 备用) */
async function fetchRanksAggregate(gender = 'male') {
  const resp = await httpGet(`${BASE}/rank/?gender=${gender}`);
  const html = await resp.text();
  const pd = extractPageData(html);
  const out = {};
  for (const key of RANK_KEYS) {
    const arr = Array.isArray(pd[key]) ? pd[key] : [];
    out[key] = arr.map(parseBook).filter(Boolean);
  }
  return out;
}

/** 男频 9 榜 via MAJAX (每榜 HOME_RANK_PREVIEW 本), SSR 作兜底 */
async function fetchMaleRanksViaMajax() {
  const csrf = await fetchMajaxCsrf('male', 'yuepiao');
  const out = {};
  for (const { majax, ssrPath, key } of MAJAX_RANKS) {
    try {
      const books = await fetchMajaxRankPage(majax, 'male', 1, csrf, ssrPath);
      out[key] = books.slice(0, HOME_RANK_PREVIEW);
    } catch {
      out[key] = [];
    }
  }
  return out;
}

/** GET m.qidian.com/finish/ → 4 完结榜 (经典/影视/畅销/电视剧) */
async function fetchFinishRanks() {
  const resp = await httpGet(`${BASE}/finish/`);
  const html = await resp.text();
  const pd = extractPageData(html);
  const out = {};
  for (const key of FINISH_KEYS) {
    const arr = Array.isArray(pd[key]) ? pd[key] : [];
    out[key] = arr.map((obj, i) => parseBook(obj, i + 1)).filter(Boolean);
  }
  return out;
}

/** GET 任意 rank SSR 页, 返回 _csrfToken (majax 共用) */
function parseCsrfFromResponse(ssrResp) {
  const setCookies = ssrResp.headers.getSetCookie?.() || [];
  const csrfLine = setCookies.find(c => c.startsWith('_csrfToken='));
  if (!csrfLine) throw new Error('响应无 _csrfToken Set-Cookie');
  return csrfLine.split('=')[1].split(';')[0].trim();
}

async function fetchMajaxCsrf(gender, ssrPath = 'yuepiao') {
  const ssrResp = await httpGet(`${BASE}/rank/${ssrPath}?gender=${gender}`);
  return parseCsrfFromResponse(ssrResp);
}

/** m.qidian majax 单页榜单 (需 csrf + 对应 Referer) */
async function fetchMajaxRankPage(majaxPath, gender, pageNum, csrf, ssrPath) {
  const refererPage = `${BASE}/rank/${ssrPath}?gender=${gender}`;
  const url = `${BASE}/majax/rank/${majaxPath}?_csrfToken=${csrf}&gender=${gender}&pageNum=${pageNum}`;
  const dispatcher = _ensureSessionDispatcher();
  const opts = {
    headers: {
      'User-Agent': UA,
      'Referer': refererPage,
      'Accept': 'application/json, text/plain, */*',
      'Cookie': `_csrfToken=${csrf}`,
    },
    signal: AbortSignal.timeout(15000),
  };
  if (dispatcher) opts.dispatcher = dispatcher;
  const r = await fetch(url, opts);
  if (!r.ok) throw new Error(`majax ${majaxPath} pageNum=${pageNum} HTTP ${r.status}`);
  const j = await r.json();
  if (j.code !== 0) throw new Error(`majax ${majaxPath} pageNum=${pageNum} code=${j.code} msg=${j.msg}`);
  return (j.data?.records || []).map(parseBook).filter(Boolean);
}

/**
 * 女频首页 9 榜: 7 榜走 majax (真女频/言情), ds/sign 无女频 majax 则 SSR 占位.
 * qdmm WAF 不可用时这是可靠数据源 (实测与男频 SSR 仅 20/50 月票重叠).
 */
async function fetchFemaleRanksViaMajax() {
  const csrf = await fetchMajaxCsrf('female', 'yuepiao');
  const out = {};

  for (const { majax, ssrPath, key } of FEMALE_MAJAX_RANKS) {
    const books = await fetchMajaxRankPage(majax, 'female', 1, csrf, ssrPath);
    out[key] = books.slice(0, HOME_RANK_PREVIEW);
  }

  return out;
}

/** 可选: qdmm Playwright 成功时覆盖 majax 中同名 key */
async function mergeQdmmFemaleRanks(ranksFemale) {
  let qdmmMirror;
  try {
    qdmmMirror = require('./qdmmMirror');
  } catch {
    return ranksFemale;
  }
  const raw = await qdmmMirror.tryFetchFemaleRanks();
  if (!raw) return ranksFemale;

  const merged = { ...ranksFemale };
  for (const key of RANK_KEYS) {
    const arr = Array.isArray(raw[key]) ? raw[key] : [];
    const books = arr.map(parseBook).filter(Boolean).slice(0, HOME_RANK_PREVIEW);
    if (books.length > 0) merged[key] = books;
  }
  return merged;
}

/**
 * 月票榜分页. 起点 m 站只暴露 yuepiao 这一个榜的 majax 分页接口.
 * 必须先 GET SSR 页拿 _csrfToken cookie, 然后带 cookie + query 调 majax.
 */
async function fetchYuepiao50(gender = 'male') {
  const ssrResp = await httpGet(`${BASE}/rank/yuepiao?gender=${gender}`);
  const csrf = parseCsrfFromResponse(ssrResp);

  // 全走 majax: gender=female 时 SSR records 与男频同源, 仅 majax 为真女频序
  const [page1, page2, page3] = await Promise.all([
    fetchMajaxRankPage('yuepiaolist', gender, 1, csrf, 'yuepiao'),
    fetchMajaxRankPage('yuepiaolist', gender, 2, csrf, 'yuepiao'),
    fetchMajaxRankPage('yuepiaolist', gender, 3, csrf, 'yuepiao'),
  ]);

  const seen = new Set();
  const out = [];
  for (const b of [...page1, ...page2, ...page3]) {
    if (!seen.has(b.bid)) {
      seen.add(b.bid);
      out.push(b);
    }
  }
  return out.slice(0, 50);
}

function parsePublishSearchBook(obj, fallbackRank = 0) {
  if (!obj || obj.isPub !== 1) return null;
  const book = parseBook(obj, fallbackRank);
  if (!book) return null;
  return {
    ...book,
    _recommend: Number(obj.recomendCnt) || 0,
    _updateTime: String(obj.updateTime || obj.lastUpdateTime || ''),
  };
}

function parsePublishCategoryBook(obj, fallbackRank = 0) {
  const book = parseBook(obj, fallbackRank);
  if (!book) return null;
  return { ...book, _recommend: 0, _updateTime: '' };
}

/** GET m.qidian.com/category/detail?catId=13100 → 出版书列表 (SSR 首页 ~20 本) */
async function fetchPublishCategoryBooks() {
  const resp = await httpGet(`${BASE}/category/detail?catId=${PUBLISH_CAT_ID}&gender=male`);
  const html = await resp.text();
  const pd = extractPageData(html);
  const records = pd?.list?.records;
  const arr = Array.isArray(records) ? records : [];
  return arr.map(parsePublishCategoryBook).filter(Boolean);
}

/** 按作者搜索 isPub=1 的出版书 (403 时跳过该作者, 不拖垮整次 mirror) */
async function fetchPublishSearchByAuthor(author) {
  try {
    const resp = await httpGet(`${BASE}/search?kw=${encodeURIComponent(author)}`);
    const html = await resp.text();
    const pd = extractPageData(html);
    const records = pd?.bookInfo?.records;
    const arr = Array.isArray(records) ? records : [];
    return arr.map(parsePublishSearchBook).filter(Boolean);
  } catch (e) {
    console.warn(`[qidianMirror] publish search author=${author} skipped: ${e.message}`);
    return [];
  }
}

async function fetchPublishBookPool() {
  const categoryBooks = await fetchPublishCategoryBooks();
  const merged = [];
  const seen = new Set();
  const push = (b) => {
    if (!b?.bid || seen.has(b.bid)) return;
    seen.add(b.bid);
    merged.push(b);
  };
  for (const b of categoryBooks) push(b);
  // 串行搜索, 避免并行触发 403
  for (const author of PUBLISH_SEARCH_AUTHORS) {
    const list = await fetchPublishSearchByAuthor(author);
    for (const b of list) push(b);
    await new Promise((r) => setTimeout(r, 300));
  }
  return { categoryBooks, merged };
}

function stripPublishMeta(book) {
  const { _recommend, _updateTime, ...rest } = book;
  return rest;
}

function buildPublishRankList(pool, spec, preview = HOME_RANK_PREVIEW) {
  const { categoryBooks, merged } = pool;
  let list;
  switch (spec.sort) {
    case 'category':
      list = [...categoryBooks];
      break;
    case 'categoryTail':
      list = [...categoryBooks].reverse();
      break;
    case 'updateTime':
      list = [...merged].sort((a, b) => String(b._updateTime).localeCompare(String(a._updateTime)));
      break;
    case 'recommend':
      list = [...merged].sort((a, b) => (b._recommend || 0) - (a._recommend || 0));
      break;
    default:
      list = [...merged];
  }
  return list.slice(0, preview).map(stripPublishMeta);
}

/** 出版频道四榜: 来源 catId=13100 + 作者搜索池 (起点无出版榜 majax) */
function buildPublishRanksFromPool(pool) {
  const out = {};
  for (const spec of PUBLISH_RANK_SPECS) {
    out[spec.key] = buildPublishRankList(pool, spec, PUBLISH_RANK_PREVIEW);
  }
  return out;
}

/** 出版月票 TOP50: 分类榜 + 推荐序补满 */
function buildPublishTop50FromPool(pool) {
  const byRecommend = [...pool.merged].sort((a, b) => (b._recommend || 0) - (a._recommend || 0));
  const seen = new Set();
  const out = [];
  for (const b of [...pool.categoryBooks, ...byRecommend]) {
    if (!b?.bid || seen.has(b.bid)) continue;
    seen.add(b.bid);
    out.push(stripPublishMeta(b));
    if (out.length >= 50) break;
  }
  return out;
}

// keep old API for tests
async function fetchPublishRanks() { return buildPublishRanksFromPool(await fetchPublishBookPool()); }
async function fetchPublishTop50() { return buildPublishTop50FromPool(await fetchPublishBookPool()); }

/**
 * 分批抓取避免代理并发过高导致 "Request was cancelled".
 * 批次 1: majax 排行 + SSR 排行 (串行 majax + 1 SSR)
 * 批次 2: 月票 + 完结 + 出版 (出版池只抓一次)
 */
async function fetchMirrorPayload() {
  _resetSessionDispatcher();

  // 批次 1: 排行榜
  const [ranksMajax, ranksSsr] = await Promise.all([
    fetchMaleRanksViaMajax(),
    fetchRanksAggregate('male'),
  ]);

  // 批次 2: 月票 / 完结 / 出版 (共享出版书池)
  const [yuepiaoTop50, finish, publishPool] = await Promise.all([
    fetchYuepiao50('male'),
    fetchFinishRanks(),
    fetchPublishBookPool(),
  ]);

  const ranksPublish = buildPublishRanksFromPool(publishPool);
  const yuepiaoTop50Publish = buildPublishTop50FromPool(publishPool);

  const ranks = {};
  for (const key of RANK_KEYS) {
    const majaxArr = ranksMajax[key] || [];
    ranks[key] = majaxArr.length > 0 ? majaxArr : (ranksSsr[key] || []);
  }

  // 女频: SSR gender=female 与男生榜同源; 用 majax gender=female 拿真女频榜.
  // 抓取失败时复制男生榜, 保证客户端女频 tab 结构与男频一致且永不空榜.
  let femaleData = await fetchFemaleMirrorData(ranks, yuepiaoTop50);
  const ranksFemale = femaleData.ranksFemale;
  const yuepiaoTop50Female = femaleData.yuepiaoTop50Female;

  return {
    version: Date.now(),
    fetchedAt: new Date().toISOString(),
    source: 'm.qidian.com',
    ranks,
    ranksFemale,
    yuepiaoTop50,
    yuepiaoTop50Female,
    finish,
    ranksPublish,
    yuepiaoTop50Publish,
  };
}

async function fetchFemaleMirrorData(maleRanks, maleYuepiao50) {
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      const [ranksFemaleRaw, yuepiaoTop50Female] = await Promise.all([
        fetchFemaleRanksViaMajax(),
        fetchYuepiao50('female'),
      ]);
      const ranksFemale = await mergeQdmmFemaleRanks(ranksFemaleRaw);
      const majaxBooks = FEMALE_MAJAX_RANKS.reduce((s, { key }) => s + (ranksFemaleRaw[key]?.length || 0), 0);
      if (majaxBooks >= FEMALE_MAJAX_RANKS.length && yuepiaoTop50Female.length > 0) {
        console.info(`[qidianMirror] female majax ok (${majaxBooks} books in 6 ranks)`);
        return { ranksFemale, yuepiaoTop50Female };
      }
      console.warn(`[qidianMirror] female fetch attempt ${attempt}: incomplete (majax=${majaxBooks}, yuepiao=${yuepiaoTop50Female.length})`);
    } catch (e) {
      console.warn(`[qidianMirror] female fetch attempt ${attempt} failed:`, e.message);
    }
  }
  console.warn('[qidianMirror] female using male ranks fallback');
  return { ranksFemale: maleRanks, yuepiaoTop50Female: maleYuepiao50 };
}

/**
 * 后端 cron 主流程: 抓 → 存 DB → 清理旧版本.
 * 抛异常时由 caller 决定写 ok=0 or 跳过.
 */
async function fetchAndCache(db) {
  const payload = await fetchMirrorPayload();
  const validation = validateMirrorPayload(payload);
  if (!validation.ok) {
    throw new Error(`mirror validation failed: ${validation.errors.join('; ')}`);
  }
  const payloadStr = JSON.stringify(payload);
  const etag = crypto.createHash('md5').update(payloadStr).digest('hex');

  // 万象书屋: 统计书目数量给监控展示用
  const totalBooks = Object.values(payload.ranks).reduce((s, l) => s + l.length, 0)
    + payload.yuepiaoTop50.length
    + Object.values(payload.finish).reduce((s, l) => s + l.length, 0)
    + (payload.ranksFemale
      ? Object.values(payload.ranksFemale).reduce((s, l) => s + l.length, 0)
      : 0)
    + (payload.yuepiaoTop50Female?.length || 0)
    + (payload.ranksPublish
      ? Object.values(payload.ranksPublish).reduce((s, l) => s + l.length, 0)
      : 0)
    + (payload.yuepiaoTop50Publish?.length || 0);

  db.insertBookstoreMirror({
    version: payload.version,
    payload: payloadStr,
    etag,
    fetched_at: Date.now(),
    source: 'm.qidian.com',
    ok: 1,
    err_msg: null,
  });

  // 只保留最近 24 条
  db.cleanupOldBookstoreMirror(3);

  return { totalBooks, etag, version: payload.version };
}

/** 抓取失败时记一条 ok=0 错误日志, 让 admin 面板能看到 */
function recordFailure(db, err) {
  try {
    db.insertBookstoreMirror({
      version: Date.now(),
      payload: '{}',
      etag: '',
      fetched_at: Date.now(),
      source: 'm.qidian.com',
      ok: 0,
      err_msg: String(err?.message || err).slice(0, 500),
    });
    db.cleanupOldBookstoreMirror(3);
  } catch (innerErr) {
    console.error('[qidianMirror] recordFailure also failed:', innerErr);
  }
}

module.exports = {
  fetchAndCache,
  fetchMirrorPayload,
  recordFailure,
  validateMirrorPayload,
  // 仅测试导出
  _internal: {
    extractPageData,
    parseBook,
    fetchRanksAggregate,
    fetchFinishRanks,
    fetchYuepiao50,
    fetchFemaleMirrorData,
    fetchFemaleRanksViaMajax,
    fetchMajaxRankPage,
    fetchPublishRanks,
    fetchPublishTop50,
    fetchPublishCategoryBooks,
  },
};
