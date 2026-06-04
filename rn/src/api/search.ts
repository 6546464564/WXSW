/**
 * 万象书屋 RN · 搜索 API
 * 对齐后端: /api/search/proxy, /api/search/changesource
 * 对齐 iOS: WanxiangAPI.searchProxy / changeSourceProxy
 */

import {wanxiangClient} from './client';
import {
  getCachedContent,
  setCachedContent,
  getCachedToc,
  setCachedToc,
} from '../utils/contentCache';

export interface ProxySearchBook {
  origin: string;
  originName: string;
  name: string;
  author: string;
  bookUrl: string;
  coverUrl?: string;
  intro?: string;
  kind?: string;
  lastChapter?: string;
  mergedSourceURLs?: string[];
  mergedSourceNames?: string[];
}

interface ProxySearchResponse {
  ok: boolean;
  count: number;
  fromCache: boolean;
  sourceCount: number;
  books: ProxySearchBook[];
}

interface ChangeSourceResponse {
  ok: boolean;
  count: number;
  fromCache: boolean;
  sourceCount: number;
  candidates: ProxySearchBook[];
}

/**
 * 服务端代搜：关键词搜索 (对齐 iOS searchProxy)
 */
export async function searchProxy(keyword: string): Promise<ProxySearchBook[]> {
  const res = await wanxiangClient.instance.get<ProxySearchResponse>(
    '/api/search/proxy',
    {params: {keyword}, timeout: 30000},
  );
  return res.data?.books || [];
}

/**
 * 服务端代搜：换源搜索 (对齐 iOS changeSourceProxy)
 */
export async function changeSourceSearch(
  name: string,
  author: string,
  limit?: number,
): Promise<ProxySearchBook[]> {
  const params: Record<string, string | number> = {name, author};
  if (limit && limit > 0) params.limit = limit;
  const res = await wanxiangClient.instance.get<ChangeSourceResponse>(
    '/api/search/changesource',
    {params, timeout: limit === 1 ? 15000 : 30000},
  );
  return res.data?.candidates || [];
}

export interface ProxyChapter {
  title: string;
  url: string;
}

/**
 * 服务端代理：获取书籍目录 (带本地缓存)
 */
export async function fetchProxyToc(
  origin: string,
  bookUrl: string,
): Promise<ProxyChapter[]> {
  const cached = await getCachedToc<ProxyChapter>(origin, bookUrl);
  if (cached && cached.length > 0) return cached;

  const res = await wanxiangClient.instance.get<{ok: boolean; chapters: ProxyChapter[]}>(
    '/api/search/toc',
    {params: {origin, bookUrl}, timeout: 30000},
  );
  const chapters = res.data?.chapters || [];
  if (chapters.length > 0) {
    setCachedToc(origin, bookUrl, chapters).catch(() => {});
  }
  return chapters;
}

/**
 * 服务端代理：获取章节内容 (带本地缓存)
 */
export async function fetchProxyContent(
  origin: string,
  chapterUrl: string,
): Promise<string> {
  const cached = await getCachedContent(origin, chapterUrl);
  if (cached) return cached;

  const res = await wanxiangClient.instance.get<{ok: boolean; content: string}>(
    '/api/search/content',
    {params: {origin, chapterUrl}, timeout: 30000},
  );
  const content = res.data?.content || '';
  if (!content) {
    console.warn('[fetchProxyContent] empty response', {
      status: res.status,
      ok: res.data?.ok,
      hasContent: !!res.data?.content,
      dataType: typeof res.data,
      origin: origin?.slice(0, 40),
    });
  }
  if (content) {
    setCachedContent(origin, chapterUrl, content).catch(() => {});
  }
  return content;
}

/**
 * 预取章节内容 (静默, 失败不报错)
 */
export function prefetchProxyContent(
  origin: string,
  chapterUrl: string,
): void {
  getCachedContent(origin, chapterUrl).then(cached => {
    if (cached) return;
    wanxiangClient.instance
      .get<{ok: boolean; content: string}>('/api/search/content', {
        params: {origin, chapterUrl},
        timeout: 30000,
      })
      .then(res => {
        const content = res.data?.content || '';
        if (content) setCachedContent(origin, chapterUrl, content).catch(() => {});
      })
      .catch(() => {});
  });
}
