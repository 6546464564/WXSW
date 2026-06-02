// 可选: 从 m.qdmm.com / www.qdmm.com 抓取女频榜.
//
// 现状 (2026-05): 全站 WAF 对无会话请求返回 HTTP 202 + probe.js 验证码.
// Playwright 可过跳转但拿不到榜单 DOM/API; 需人工在浏览器过验证码后导出 Cookie.
//
// 启用方式 (任选):
//   QDMM_COOKIE="w_tsfp=...; _csrfToken=..."  — 推荐, 从已登录/已过 WAF 的浏览器复制
//   QDMM_PLAYWRIGHT=1                         — 实验性, 通常仍无榜单数据
//
// 成功时返回 pageData (含 fyRank 等 key); 失败返回 null → qidianMirror majax 兜底.

const UA = 'Mozilla/5.0 (Linux; Android 12; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';

const QDMM_URLS = [
  'https://m.qdmm.com/rank/',
  'https://www.qdmm.com/rank/yuepiao/',
];

function extractPageDataFromHtml(html) {
  const m = html.match(/<script id="vite-plugin-ssr_pageContext"[^>]*>(.+?)<\/script>/s);
  if (m) {
    const pd = JSON.parse(m[1])?.pageContext?.pageProps?.pageData;
    if (pd && typeof pd === 'object' && Object.keys(pd).length > 0) return pd;
  }
  return null;
}

function isWafBlocked(html, status) {
  return status === 202
    || html.includes('probe.js')
    || html.includes('__captcha')
    || html.includes('x-waf-captcha')
    || (html.length < 500 && status !== 200);
}

function _getDispatcher() {
  try {
    return require('./legadoEngine')._getProxyDispatcher?.() || null;
  } catch { return null; }
}

/** 用管理员粘贴的 Cookie 直抓 (过 WAF 后从 DevTools → Network 复制) */
async function fetchWithCookie(cookieHeader) {
  const dispatcher = _getDispatcher();
  for (const url of QDMM_URLS) {
    try {
      const opts = {
        headers: {
          'User-Agent': UA,
          'Cookie': cookieHeader,
          'Accept': 'text/html,application/xhtml+xml',
          'Accept-Language': 'zh-CN,zh;q=0.9',
          'Referer': 'https://www.qdmm.com/',
        },
        redirect: 'follow',
      };
      if (dispatcher) opts.dispatcher = dispatcher;
      const resp = await fetch(url, opts);
      const html = await resp.text();
      if (isWafBlocked(html, resp.status)) continue;
      const pd = extractPageDataFromHtml(html);
      if (pd) {
        console.info('[qdmmMirror] cookie fetch ok from', url);
        return pd;
      }
    } catch (e) {
      console.warn('[qdmmMirror] cookie fetch', url, e.message);
    }
  }
  return null;
}

async function fetchWithPlaywright() {
  let chromium;
  try {
    ({ chromium } = require('playwright'));
  } catch {
    console.warn('[qdmmMirror] playwright not installed, skip');
    return null;
  }

  let browser;
  try {
    browser = await chromium.launch({
      headless: process.env.QDMM_PLAYWRIGHT_HEADED !== '1',
      args: ['--disable-blink-features=AutomationControlled'],
    });
    const ctx = await browser.newContext({ userAgent: UA, locale: 'zh-CN' });
    const page = await ctx.newPage();
    await page.goto('https://www.qdmm.com/rank/yuepiao/', {
      waitUntil: 'networkidle',
      timeout: 60000,
    });
    await page.waitForTimeout(8000);
    const html = await page.content();
    if (isWafBlocked(html, 200) || !html.trim()) {
      console.warn('[qdmmMirror] Playwright: empty or WAF shell, no rank data');
      return null;
    }
    const pd = extractPageDataFromHtml(html);
    if (pd) {
      console.info('[qdmmMirror] Playwright SSR ok, keys:', Object.keys(pd).join(','));
      return pd;
    }
    // 尝试用 Playwright 拿到的 cookie 再请求 m 站 SSR
    const cookies = await ctx.cookies();
    const cookieHeader = cookies.map(c => `${c.name}=${c.value}`).join('; ');
    if (cookieHeader) return fetchWithCookie(cookieHeader);
    return null;
  } catch (e) {
    console.warn('[qdmmMirror] Playwright failed:', e.message);
    return null;
  } finally {
    if (browser) await browser.close().catch(() => {});
  }
}

async function tryFetchFemaleRanks() {
  const manualCookie = (process.env.QDMM_COOKIE || '').trim();
  if (manualCookie) {
    const pd = await fetchWithCookie(manualCookie);
    if (pd) return pd;
    console.warn('[qdmmMirror] QDMM_COOKIE set but fetch failed (expired?)');
  }
  if (process.env.QDMM_PLAYWRIGHT === '1') {
    return fetchWithPlaywright();
  }
  return null;
}

module.exports = { tryFetchFemaleRanks, fetchWithCookie, extractPageDataFromHtml };
