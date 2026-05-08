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
    wordCount: (obj.cnt || '').trim(),
    rank: typeof obj.rankNum === 'number' ? obj.rankNum : fallbackRank,
    rankCount: (obj.rankCnt || '').trim(),
    intro: (obj.desc || '').trim(),
    coverUrl: COVER_TPL(bid),
  };
}

async function httpGet(url, extraHeaders = {}) {
  const resp = await fetch(url, {
    headers: {
      'User-Agent': UA,
      'Referer': `${BASE}/`,
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9',
      ...extraHeaders,
    },
    redirect: 'follow',
  });
  if (!resp.ok && resp.status !== 304) {
    throw new Error(`${url} HTTP ${resp.status}`);
  }
  return resp;
}

/** 万象书屋: GET m.qidian.com/rank/?gender=male → 9 榜 × 5 本 */
async function fetchRanksAggregate() {
  const resp = await httpGet(`${BASE}/rank/?gender=male`);
  const html = await resp.text();
  const pd = extractPageData(html);
  const out = {};
  for (const key of RANK_KEYS) {
    const arr = Array.isArray(pd[key]) ? pd[key] : [];
    out[key] = arr.map(parseBook).filter(Boolean);
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

/**
 * 月票榜分页. 起点 m 站只暴露 yuepiao 这一个榜的 majax 分页接口.
 * 必须先 GET SSR 页拿 _csrfToken cookie, 然后带 cookie + query 调 majax.
 */
async function fetchYuepiao50() {
  // 第 1 步: GET SSR 页拿 csrf
  const ssrResp = await httpGet(`${BASE}/rank/yuepiao?gender=male`);
  const ssrHtml = await ssrResp.text();
  const setCookies = ssrResp.headers.getSetCookie?.() || [];
  const csrfLine = setCookies.find(c => c.startsWith('_csrfToken='));
  if (!csrfLine) throw new Error('响应无 _csrfToken Set-Cookie');
  const csrf = csrfLine.split('=')[1].split(';')[0].trim();

  // SSR 页本身 records 就是第 1 页 20 本
  const pd = extractPageData(ssrHtml);
  const page1 = (pd.records || []).map(parseBook).filter(Boolean);

  // 第 2、3 页通过 majax ajax 拿 (需 Cookie + Referer)
  const cookieHeader = `_csrfToken=${csrf}`;
  const refererPage = `${BASE}/rank/yuepiao?gender=male`;
  const fetchPage = async (pageNum) => {
    const url = `${BASE}/majax/rank/yuepiaolist?_csrfToken=${csrf}&gender=male&pageNum=${pageNum}`;
    const r = await fetch(url, {
      headers: {
        'User-Agent': UA,
        'Referer': refererPage,
        'Accept': 'application/json, text/plain, */*',
        'Cookie': cookieHeader,
      },
    });
    if (!r.ok) throw new Error(`majax pageNum=${pageNum} HTTP ${r.status}`);
    const j = await r.json();
    if (j.code !== 0) throw new Error(`majax pageNum=${pageNum} code=${j.code} msg=${j.msg}`);
    return (j.data?.records || []).map(parseBook).filter(Boolean);
  };

  const [page2, page3] = await Promise.all([fetchPage(2), fetchPage(3)]);

  // 合并去重 (按 bid)
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

/**
 * 主入口: 拉取所有数据 → 拼成 mirror payload object.
 * 任一子任务失败 → 抛异常, 整次 cron 标记 ok=0, 但 DB 旧 cache 仍可用.
 */
async function fetchMirrorPayload() {
  // 三个数据源并发抓, 任一失败抛异常
  const [ranks, yuepiaoTop50, finish] = await Promise.all([
    fetchRanksAggregate(),
    fetchYuepiao50(),
    fetchFinishRanks(),
  ]);
  return {
    version: Date.now(),
    fetchedAt: new Date().toISOString(),
    source: 'm.qidian.com',
    ranks,
    yuepiaoTop50,
    finish,
  };
}

/**
 * 后端 cron 主流程: 抓 → 存 DB → 清理旧版本.
 * 抛异常时由 caller 决定写 ok=0 or 跳过.
 */
async function fetchAndCache(db) {
  const payload = await fetchMirrorPayload();
  const payloadStr = JSON.stringify(payload);
  const etag = crypto.createHash('md5').update(payloadStr).digest('hex');

  // 万象书屋: 统计书目数量给监控展示用
  const totalBooks = Object.values(payload.ranks).reduce((s, l) => s + l.length, 0)
    + payload.yuepiaoTop50.length
    + Object.values(payload.finish).reduce((s, l) => s + l.length, 0);

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
  db.cleanupOldBookstoreMirror(24);

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
    db.cleanupOldBookstoreMirror(24);
  } catch (innerErr) {
    console.error('[qidianMirror] recordFailure also failed:', innerErr);
  }
}

module.exports = {
  fetchAndCache,
  fetchMirrorPayload,
  recordFailure,
  // 仅测试导出
  _internal: { extractPageData, parseBook, fetchRanksAggregate, fetchFinishRanks, fetchYuepiao50 },
};
