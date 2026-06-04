// 万象书屋: 服务端代搜引擎
//
// 接受客户端关键词, 在服务器端并发搜索多个书源, 返回聚合结果.
// 优势: 不受手机性能限制, 高并发, 结果可缓存.

const legadoEngine = require('./legadoEngine');

const SEARCH_CONCURRENCY = 20;
const PER_SOURCE_TIMEOUT_MS = 12000;
const CACHE_TTL_MS = 30 * 60 * 1000;

const searchCache = new Map();

setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of searchCache) {
    if (now - entry.ts > CACHE_TTL_MS) searchCache.delete(key);
  }
}, 60_000);

function normalizeKey(str) {
  return str.replace(/[\s\u3000]/g, '').toLowerCase();
}

function cleanAuthor(author) {
  return author.replace(/^作者[：:]\s*/i, '').trim();
}

function dedupeKey(name, author) {
  return normalizeKey(name) + '::' + normalizeKey(cleanAuthor(author));
}

async function searchOneSource(source, keyword) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PER_SOURCE_TIMEOUT_MS);
  try {
    const books = await legadoEngine.searchBook(source, keyword);
    return books.map(b => ({
      origin: source.bookSourceUrl,
      originName: source.bookSourceName || source.bookSourceUrl,
      name: b.name || '',
      author: cleanAuthor(b.author || ''),
      bookUrl: b.bookUrl || '',
      coverUrl: b.coverUrl || '',
      intro: b.intro || '',
      kind: b.kind || '',
      lastChapter: b.lastChapter || '',
    }));
  } catch {
    return [];
  } finally {
    clearTimeout(timer);
  }
}

async function proxySearch(sources, keyword) {
  const cacheKey = normalizeKey(keyword);
  const cached = searchCache.get(cacheKey);
  if (cached && Date.now() - cached.ts < CACHE_TTL_MS) {
    return { books: cached.books, fromCache: true, sourceCount: cached.sourceCount };
  }

  const results = [];
  const dedupeIndex = new Map();

  const queue = [...sources];
  let running = 0;
  let idx = 0;

  await new Promise(resolve => {
    function next() {
      while (running < SEARCH_CONCURRENCY && idx < queue.length) {
        const source = queue[idx++];
        running++;
        searchOneSource(source, keyword).then(books => {
          for (const b of books) {
            if (!b.name) continue;
            const dk = dedupeKey(b.name, b.author);
            if (dedupeIndex.has(dk)) {
              const existing = results[dedupeIndex.get(dk)];
              if (!existing.mergedSourceURLs) {
                existing.mergedSourceURLs = [];
                existing.mergedSourceNames = [];
              }
              const seen = new Set([existing.origin, ...existing.mergedSourceURLs]);
              if (!seen.has(b.origin)) {
                existing.mergedSourceURLs.push(b.origin);
                existing.mergedSourceNames.push(b.originName);
              }
              if (!existing.intro && b.intro) existing.intro = b.intro;
              if (!existing.coverUrl && b.coverUrl) existing.coverUrl = b.coverUrl;
              if (!existing.lastChapter && b.lastChapter) existing.lastChapter = b.lastChapter;
              if (!existing.kind && b.kind) existing.kind = b.kind;
            } else {
              dedupeIndex.set(dk, results.length);
              results.push({ ...b, mergedSourceURLs: [], mergedSourceNames: [] });
            }
          }
          running--;
          next();
        });
      }
      if (running === 0) resolve();
    }
    next();
  });

  const sorted = sortByRelevance(results, keyword);

  searchCache.set(cacheKey, { books: sorted, ts: Date.now(), sourceCount: sources.length });
  return { books: sorted, fromCache: false, sourceCount: sources.length };
}

function sortByRelevance(books, keyword) {
  const kw = keyword.toLowerCase();
  return books.sort((a, b) => {
    const tierA = relevanceTier(a, kw);
    const tierB = relevanceTier(b, kw);
    if (tierA !== tierB) return tierA - tierB;
    const srcA = 1 + (a.mergedSourceURLs?.length || 0);
    const srcB = 1 + (b.mergedSourceURLs?.length || 0);
    if (srcA !== srcB) return srcB - srcA;
    // 有简介/封面的排前面
    const infoA = (a.intro ? 1 : 0) + (a.coverUrl ? 1 : 0);
    const infoB = (b.intro ? 1 : 0) + (b.coverUrl ? 1 : 0);
    return infoB - infoA;
  });
}

function relevanceTier(book, kw) {
  const name = (book.name || '').toLowerCase().replace(/\s+/g, '');
  const author = (book.author || '').toLowerCase().replace(/^作者[：:]/, '').replace(/\s+/g, '');
  if (name === kw) return 0;          // 书名完全匹配
  if (author === kw) return 1;        // 作者完全匹配
  if (name.startsWith(kw)) return 2;  // 书名前缀匹配
  if (name.includes(kw)) return 3;    // 书名包含
  if (author.includes(kw)) return 4;  // 作者包含
  return 5;
}

const changeSourceCache = new Map();

setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of changeSourceCache) {
    if (now - entry.ts > CACHE_TTL_MS) changeSourceCache.delete(key);
  }
}, 60_000);

async function changeSourceSearch(sources, name, author, { limit } = {}) {
  const cacheKey = normalizeKey(name) + '::' + normalizeKey(author);
  const cached = changeSourceCache.get(cacheKey);
  if (cached && Date.now() - cached.ts < CACHE_TTL_MS) {
    const out = limit ? cached.candidates.slice(0, limit) : cached.candidates;
    return { candidates: out, fromCache: true, sourceCount: cached.sourceCount };
  }

  // Fast path: check proxySearch cache for instant match
  const proxyCached = searchCache.get(normalizeKey(name));
  if (proxyCached && Date.now() - proxyCached.ts < CACHE_TTL_MS) {
    const n1 = name.trim();
    const a1 = author.trim();
    const hits = [];
    const seenOrigins = new Set();
    for (const b of proxyCached.books) {
      if ((b.name || '').trim() !== n1) continue;
      if (a1 && (b.author || '').trim() && (b.author || '').trim() !== a1) continue;
      if (seenOrigins.has(b.origin)) continue;
      seenOrigins.add(b.origin);
      hits.push(b);
      // Expand merged sources as separate candidates
      if (b.mergedSourceURLs) {
        for (let i = 0; i < b.mergedSourceURLs.length; i++) {
          const mOrigin = b.mergedSourceURLs[i];
          if (!seenOrigins.has(mOrigin)) {
            seenOrigins.add(mOrigin);
            hits.push({ ...b, origin: mOrigin, originName: b.mergedSourceNames?.[i] || mOrigin });
          }
        }
      }
    }
    if (hits.length > 0) {
      changeSourceCache.set(cacheKey, { candidates: hits, ts: Date.now(), sourceCount: sources.length });
      const out = limit ? hits.slice(0, limit) : hits;
      return { candidates: out, fromCache: true, sourceCount: sources.length };
    }
  }

  const n1 = name.trim();
  const a1 = author.trim();
  const candidates = [];
  const seenOrigins = new Set();
  const wantEarly = limit === 1;

  const queue = [...sources];
  let running = 0;
  let idx = 0;
  let earlyDone = false;

  await new Promise(resolve => {
    function next() {
      if (earlyDone) { if (running === 0) resolve(); return; }
      while (running < SEARCH_CONCURRENCY && idx < queue.length) {
        const source = queue[idx++];
        running++;
        searchOneSource(source, n1).then(books => {
          for (const b of books) {
            if (earlyDone) break;
            const n2 = (b.name || '').trim();
            const a2 = (b.author || '').trim();
            if (n2 !== n1) continue;
            if (a1 && a2 && a1 !== a2) continue;
            if (seenOrigins.has(b.origin)) continue;
            seenOrigins.add(b.origin);
            candidates.push(b);
            if (wantEarly) { earlyDone = true; break; }
          }
          running--;
          next();
        });
      }
      if (running === 0) resolve();
    }
    next();
  });

  if (!wantEarly || candidates.length === 0) {
    changeSourceCache.set(cacheKey, { candidates, ts: Date.now(), sourceCount: sources.length });
  }
  const out = limit ? candidates.slice(0, limit) : candidates;
  return { candidates: out, fromCache: false, sourceCount: sources.length };
}

module.exports = { proxySearch, searchCache, changeSourceSearch };
