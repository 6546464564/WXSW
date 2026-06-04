/**
 * 万象书屋 RN · 书城 API
 * 对齐 iOS: QidianRepository + BookstoreMirror + BookStoreViewModel
 *
 * 后端: GET /api/bookstore/mirror
 * 返回格式:
 * {
 *   ranks: { fyRank: [...], hotRank: [...], recRank: [...], newbRank: [...], ... },
 *   ranksFemale: { ... },
 *   ranksPublish: { ... },
 *   yuepiaoTop50: [...],
 *   version: "..."
 * }
 *
 * 每本书:
 * { bid, name, author, cat, subCat, wordCount, rank, rankCount, intro, coverUrl }
 */

import {wanxiangClient} from './client';

const COVER_TEMPLATE = 'https://bookcover.yuewen.com/qdbimg/349573/%s/180';

export type Channel = 'male' | 'female' | 'publish';

export interface QidianBook {
  bid: string;
  name: string;
  coverUrl: string;
  author: string;
  category: string;
  subCategory: string;
  wordCount: string;
  rank: number;
  rankName: string;
  rankCount: string;
  intro: string;
}

export interface RankingGroup {
  name: string;
  rankType: string;
  books: QidianBook[];
}

export interface BookStoreData {
  heroBook: QidianBook | null;
  rankings: RankingGroup[];
  allBooks: QidianBook[];
}

type RankType = 'fyRank' | 'hotRank' | 'dsRank' | 'recRank' | 'updRank' | 'signRank' | 'newpRank' | 'newbRank' | 'newFans';

const RANK_TITLES: Record<string, string> = {
  fyRank: '月票榜',
  hotRank: '阅读榜',
  dsRank: '畅销榜',
  recRank: '推荐榜',
  updRank: '更新榜',
  signRank: '签约榜',
  newpRank: '新人榜',
  newbRank: '新书榜',
  newFans: '书友榜',
};

const DISPLAY_SECTIONS: {key: RankType; name: string}[] = [
  {key: 'hotRank', name: '阅读榜'},
  {key: 'newbRank', name: '新书榜'},
  {key: 'recRank', name: '推荐榜'},
];

let mirrorEtag: string | null = null;
let mirrorCache: Record<string, any> | null = null;

function parseMirrorBook(obj: any, rankType: string): QidianBook | null {
  const name = (obj.name || obj.bName || '').trim();
  if (!name) return null;
  const bid = String(obj.bid ?? '').trim();
  if (!bid) return null;
  const coverUrl =
    (obj.coverUrl || '').trim() ||
    COVER_TEMPLATE.replace('%s', bid);
  return {
    bid,
    name,
    coverUrl,
    author: (obj.author || obj.bAuth || '').trim(),
    category: (obj.cat || obj.category || '').trim(),
    subCategory: (obj.subCat || obj.subCategory || '').trim(),
    wordCount: (obj.wordCount || obj.cnt || '').trim(),
    rank: typeof obj.rank === 'number' ? obj.rank : (parseInt(obj.rankNum, 10) || 0),
    rankName: RANK_TITLES[rankType] || rankType,
    rankCount: (obj.rankCount || obj.rankCnt || '').trim(),
    intro: (obj.intro || obj.desc || '').trim(),
  };
}

function parseRanksObject(ranksObj: Record<string, any[]>): Record<string, QidianBook[]> {
  const result: Record<string, QidianBook[]> = {};
  for (const [key, arr] of Object.entries(ranksObj)) {
    if (!Array.isArray(arr)) continue;
    result[key] = arr
      .map(item => parseMirrorBook(item, key))
      .filter((b): b is QidianBook => b !== null);
  }
  return result;
}

function getRanksForChannel(
  mirror: Record<string, any>,
  channel: Channel,
): Record<string, QidianBook[]> {
  let ranksObj: Record<string, any[]> | null = null;

  switch (channel) {
    case 'female':
      ranksObj = mirror.ranksFemale || mirror.ranks || null;
      break;
    case 'publish':
      ranksObj = mirror.ranksPublish || null;
      break;
    case 'male':
    default:
      ranksObj = mirror.ranks || null;
      break;
  }

  if (!ranksObj || typeof ranksObj !== 'object') return {};
  return parseRanksObject(ranksObj);
}

export async function fetchMirrorRaw(): Promise<Record<string, any> | null> {
  if (mirrorCache) return mirrorCache;

  const headers: Record<string, string> = {};
  if (mirrorEtag) {
    headers['If-None-Match'] = mirrorEtag;
  }

  try {
    const res = await wanxiangClient.instance.get('/api/bookstore/mirror', {
      headers,
      validateStatus: status => status === 200 || status === 304 || status === 503,
    });

    if (res.status === 304 && mirrorCache) return mirrorCache;
    if (res.status === 503) return mirrorCache;
    if (res.status !== 200) return null;

    const etag = res.headers?.etag;
    if (etag) mirrorEtag = etag;

    mirrorCache = res.data;
    return mirrorCache;
  } catch {
    return mirrorCache;
  }
}

export async function fetchBookStoreData(channel: Channel): Promise<BookStoreData> {
  const mirror = await fetchMirrorRaw();
  if (!mirror) {
    return {heroBook: null, rankings: [], allBooks: []};
  }

  const ranks = getRanksForChannel(mirror, channel);
  const heroBooks = ranks.fyRank || [];
  const heroBook = heroBooks[0] || null;

  const rankings: RankingGroup[] = DISPLAY_SECTIONS.map(({key, name}) => ({
    name,
    rankType: key,
    books: ranks[key] || [],
  }));

  const seen = new Set<string>();
  const allBooks: QidianBook[] = [];
  for (const books of Object.values(ranks)) {
    for (const book of books) {
      const k = book.bid || book.name;
      if (!seen.has(k)) {
        seen.add(k);
        allBooks.push(book);
      }
    }
  }

  return {heroBook, rankings, allBooks};
}

export async function fetchRankBooks(channel: Channel, rankType: string): Promise<QidianBook[]> {
  if (rankType === 'fyRank') return fetchYuepiaoTop50(channel);
  const mirror = await fetchMirrorRaw();
  if (!mirror) return [];
  const ranks = getRanksForChannel(mirror, channel);
  return ranks[rankType] || [];
}

export async function fetchYuepiaoTop50(channel: Channel): Promise<QidianBook[]> {
  const mirror = await fetchMirrorRaw();
  if (!mirror) return [];
  let key = 'yuepiaoTop50';
  if (channel === 'female') key = 'yuepiaoTop50Female';
  if (channel === 'publish') key = 'yuepiaoTop50Publish';
  const arr = mirror[key];
  if (!Array.isArray(arr)) {
    if (channel === 'female') return fetchYuepiaoTop50('male');
    return [];
  }
  return arr.map(item => parseMirrorBook(item, 'fyRank')).filter((b): b is QidianBook => b !== null);
}

function parseWordCount(s: string): number {
  if (!s) return 0;
  const m = s.match(/([0-9]+(?:\.[0-9]+)?)\s*万/);
  if (!m) return 0;
  return Math.round(parseFloat(m[1]) * 10000);
}

export async function fetchFinishLibrary(channel: Channel): Promise<QidianBook[]> {
  const mirror = await fetchMirrorRaw();
  if (!mirror) return [];

  if (channel === 'publish') {
    const ranks = getRanksForChannel(mirror, 'publish');
    const seen = new Set<string>();
    const out: QidianBook[] = [];
    for (const key of ['hotRank', 'newbRank', 'recRank']) {
      for (const b of ranks[key] || []) {
        if (!seen.has(b.bid)) { seen.add(b.bid); out.push(b); }
      }
    }
    return out;
  }

  const seen = new Set<string>();
  const out: QidianBook[] = [];

  if (channel !== 'female') {
    const finishObj = mirror.finish;
    if (finishObj && typeof finishObj === 'object') {
      const order = ['classic', 'bestSell', 'ds', 'movie'];
      for (const key of order) {
        const arr = finishObj[key];
        if (!Array.isArray(arr)) continue;
        for (const item of arr) {
          const book = parseMirrorBook(item, key);
          if (book && !seen.has(book.bid)) { seen.add(book.bid); out.push(book); }
        }
      }
    }
  }

  if (out.length < 50) {
    const yuepiao = await fetchYuepiaoTop50(channel);
    const high = yuepiao.filter(b => parseWordCount(b.wordCount) >= 2_000_000);
    const mid = yuepiao.filter(b => {
      const w = parseWordCount(b.wordCount);
      return w >= 1_000_000 && w < 2_000_000;
    });
    const rest = yuepiao.filter(b => parseWordCount(b.wordCount) < 1_000_000);
    for (const b of [...high, ...mid, ...rest]) {
      if (out.length >= 50) break;
      if (!seen.has(b.bid)) { seen.add(b.bid); out.push(b); }
    }
  }

  return out.slice(0, 50);
}

export function clearMirrorCache() {
  mirrorCache = null;
  mirrorEtag = null;
}

export type {QidianBook as BookStoreItem};
