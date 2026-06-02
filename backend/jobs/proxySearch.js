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

function dedupeKey(name, author) {
  return normalizeKey(name) + '::' + normalizeKey(author);
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
      author: b.author || '',
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
    return srcB - srcA;
  });
}

function relevanceTier(book, kw) {
  const name = (book.name || '').toLowerCase();
  const author = (book.author || '').toLowerCase();
  if (name === kw || author === kw) return 0;
  if (name.includes(kw) || author.includes(kw)) return 1;
  return 2;
}

module.exports = { proxySearch, searchCache };
