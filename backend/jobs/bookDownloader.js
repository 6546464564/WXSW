// 万象书屋: 书籍内容下载任务 (多线程并发版)
//
// 工作流:
//   1. 从 cached_books 取 pending 的书
//   2. 用已启用书源搜索该书标题
//   3. 匹配到最佳结果后, 拉目录 → 并发下载章节内容 → 存 DB
//   4. 全部完成后标记 status='done'
//
// 用法:
//   node jobs/bookDownloader.js              # 处理下一本 pending 书
//   node jobs/bookDownloader.js --loop       # 持续循环处理
//   node jobs/bookDownloader.js --id 42      # 处理指定 ID 的书
//   node jobs/bookDownloader.js --batch 10   # 批量处理 N 本
//   node jobs/bookDownloader.js --parallel 5 # 同时下载 5 本书 (每本内部也并发)
//   node jobs/bookDownloader.js --threads 8  # 每本书 8 线程并发下载章节

const engine = require('./legadoEngine');

// 并发配置
const CHAPTER_CONCURRENCY = parseInt(process.env.DL_CHAPTER_THREADS, 10) || 6;
const BOOK_CONCURRENCY = parseInt(process.env.DL_BOOK_THREADS, 10) || 3;
const CHAPTER_DELAY_MS = parseInt(process.env.DL_CHAPTER_DELAY, 10) || 300;
const SEARCH_DELAY_MS = parseInt(process.env.DL_SEARCH_DELAY, 10) || 500;
const BOOK_DELAY_MS = parseInt(process.env.DL_BOOK_DELAY, 10) || 1000;
const MAX_RETRY = 3;
const COOLDOWN_ON_BLOCK_MS = 30000;

function loadCompatibleSources(db) {
  const rows = db.__db.prepare(
    'SELECT url, json FROM book_sources WHERE enabled = 1'
  ).all();
  const sources = [];
  for (const r of rows) {
    try {
      const src = JSON.parse(r.json);
      if (!src.searchUrl || !src.ruleSearch?.bookList) continue;
      sources.push(src);
    } catch { /* skip malformed */ }
  }
  return sources;
}

function bestMatch(results, title, author) {
  const titleNorm = title.replace(/\s/g, '').toLowerCase();
  const authorNorm = (author || '').replace(/\s/g, '').toLowerCase();

  let best = null;
  let bestScore = -1;
  for (const r of results) {
    const rName = (r.name || '').replace(/\s/g, '').toLowerCase();
    const rAuthor = (r.author || '').replace(/\s/g, '').toLowerCase();
    let score = 0;
    if (rName === titleNorm) score += 10;
    else if (rName.includes(titleNorm) || titleNorm.includes(rName)) score += 5;
    else continue;
    if (authorNorm && rAuthor.includes(authorNorm)) score += 3;
    if (score > bestScore) { bestScore = score; best = r; }
  }
  return best;
}

async function searchBookInSources(sources, title, author) {
  for (const src of sources) {
    try {
      const results = await engine.searchBook(src, title);
      if (!results.length) continue;
      const match = bestMatch(results, title, author);
      if (match) {
        return { source: src, book: match };
      }
    } catch (e) {
      console.warn(`  [search] ${src.bookSourceName} failed:`, e.message);
    }
    await engine.sleep(SEARCH_DELAY_MS);
  }
  return null;
}

/**
 * 并发控制: 限制同时运行的 Promise 数量
 */
async function pooledMap(items, concurrency, fn) {
  const results = new Array(items.length);
  let idx = 0;

  async function worker() {
    while (idx < items.length) {
      const i = idx++;
      results[i] = await fn(items[i], i);
    }
  }

  const workers = [];
  for (let w = 0; w < Math.min(concurrency, items.length); w++) {
    workers.push(worker());
  }
  await Promise.all(workers);
  return results;
}

async function downloadChapter(source, ch, bookId, chIdx, db) {
  const existing = db.getCachedChapter(bookId, chIdx);
  if (existing && existing.status === 'done') return 'skip';

  let content = null;
  for (let retry = 0; retry <= MAX_RETRY; retry++) {
    try {
      content = await engine.fetchContent(source, ch.url);
      break;
    } catch (e) {
      if (e.name === 'BlockedError') {
        console.warn(`  🚫 IP blocked, cooling down ${COOLDOWN_ON_BLOCK_MS / 1000}s...`);
        await engine.sleep(COOLDOWN_ON_BLOCK_MS);
        continue;
      }
      if (retry === MAX_RETRY) return 'error';
      await engine.sleep(2000 * Math.pow(2, retry));
    }
  }

  if (content && content.length > 50) {
    db.saveCachedChapterContent(bookId, chIdx, content);
    return 'done';
  }
  db.markCachedChapterError(bookId, chIdx);
  return 'error';
}

async function downloadBook(db, bookRow, sources, chapterThreads = CHAPTER_CONCURRENCY) {
  const { id, title, author } = bookRow;
  console.log(`\n📖 [${id}] ${title} — ${author}`);

  db.updateCachedBookStatus(id, 'searching');

  const found = await searchBookInSources(sources, title, author);
  if (!found) {
    console.log(`  ❌ Not found in any source`);
    db.updateCachedBookStatus(id, 'not_found', 'No source has this book');
    return false;
  }

  const { source, book } = found;
  console.log(`  ✅ Found: ${source.bookSourceName} → ${book.bookUrl}`);

  db.updateCachedBookSource(id, {
    sourceUrl: source.bookSourceUrl,
    sourceBookUrl: book.bookUrl,
    coverUrl: book.coverUrl,
    intro: book.intro,
  });
  db.updateCachedBookStatus(id, 'downloading');

  let chapters;
  try {
    chapters = await engine.fetchToc(source, book.bookUrl);
  } catch (e) {
    console.log(`  ❌ TOC failed:`, e.message);
    db.updateCachedBookStatus(id, 'error', `TOC: ${e.message}`);
    return false;
  }

  if (!chapters.length) {
    db.updateCachedBookStatus(id, 'error', 'Empty chapter list');
    return false;
  }

  console.log(`  📋 ${chapters.length} chapters, ${chapterThreads} threads`);
  db.updateCachedBookChapterCount(id, chapters.length);

  const chapterRows = chapters.map((ch, i) => ({ idx: i, title: ch.title, url: ch.url }));
  db.insertCachedChapters(id, chapterRows);

  // 并发下载章节 (带自适应限流)
  let doneCount = 0;
  let errorCount = 0;
  let consecutiveErrors = 0;
  const startTime = Date.now();

  const chapterItems = chapters.map((ch, i) => ({ ch, i }));

  await pooledMap(chapterItems, chapterThreads, async ({ ch, i }) => {
    // 连续错误多时自动增加延迟
    const extraDelay = consecutiveErrors > 5 ? 3000 : (consecutiveErrors > 2 ? 1000 : 0);
    await engine.sleep(CHAPTER_DELAY_MS + extraDelay + Math.random() * 300);

    const result = await downloadChapter(source, ch, id, i, db);

    if (result === 'done' || result === 'skip') {
      doneCount++;
      consecutiveErrors = 0;
    } else {
      errorCount++;
      consecutiveErrors++;
    }

    const total = doneCount + errorCount;
    if (total % 100 === 0 || total === chapters.length) {
      const elapsed = ((Date.now() - startTime) / 1000).toFixed(0);
      const speed = (total / (Date.now() - startTime) * 1000).toFixed(1);
      console.log(`  📥 [${id}] ${doneCount}/${chapters.length} (${errorCount} err) ${elapsed}s ${speed}/s`);
      db.refreshCachedBookCount(id);
    }
  });

  db.refreshCachedBookCount(id);

  if (errorCount > chapters.length * 0.5) {
    db.updateCachedBookStatus(id, 'error', `Too many errors: ${errorCount}/${chapters.length}`);
    return false;
  }

  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  db.updateCachedBookStatus(id, 'done');
  console.log(`  ✅ Done: ${doneCount}/${chapters.length} cached in ${elapsed}s`);
  return true;
}

async function processNext(db) {
  const sources = loadCompatibleSources(db);
  if (!sources.length) {
    console.error('No compatible book sources available.');
    return false;
  }
  console.log(`Loaded ${sources.length} source(s): ${sources.map(s => s.bookSourceName).join(', ')}`);
  const book = db.nextPendingBook();
  if (!book) { console.log('No pending books.'); return false; }
  return downloadBook(db, book, sources);
}

async function processById(db, bookId) {
  const sources = loadCompatibleSources(db);
  if (!sources.length) { console.error('No compatible sources.'); return false; }
  const book = db.getCachedBook(bookId);
  if (!book) { console.error(`Book ${bookId} not found`); return false; }
  return downloadBook(db, book, sources);
}

/**
 * 取 N 本 pending 的书
 */
function takePendingBooks(db, n) {
  return db.__db.prepare(
    `SELECT * FROM cached_books WHERE status = 'pending' ORDER BY priority DESC, id ASC LIMIT ?`
  ).all(n);
}

/**
 * 并发处理多本书
 */
async function processParallel(db, bookCount = 10, bookThreads = BOOK_CONCURRENCY, chapterThreads = CHAPTER_CONCURRENCY) {
  const sources = loadCompatibleSources(db);
  if (!sources.length) {
    console.error('No compatible book sources available.');
    return;
  }
  console.log(`Sources: ${sources.map(s => s.bookSourceName).join(', ')}`);
  console.log(`Config: ${bookThreads} book threads, ${chapterThreads} chapter threads per book`);

  let totalProcessed = 0;

  while (totalProcessed < bookCount) {
    const batchSize = Math.min(bookThreads, bookCount - totalProcessed);
    const batch = takePendingBooks(db, batchSize);
    if (!batch.length) {
      console.log('\nQueue empty.');
      break;
    }

    console.log(`\n═══ Batch: ${batch.length} books ═══`);
    await pooledMap(batch, bookThreads, async (bookRow) => {
      await downloadBook(db, bookRow, sources, chapterThreads);
      await engine.sleep(BOOK_DELAY_MS * Math.random());
    });

    totalProcessed += batch.length;
  }

  const stats = db.getCacheStats();
  console.log('\n═══ Download Summary ═══');
  console.log(`Books: ${stats.total_books} total | ${stats.done_books} done | ${stats.pending_books} pending | ${stats.error_books} error`);
  console.log(`Chapters: ${stats.total_cached_chapters} cached | ${(stats.total_words || 0).toLocaleString()} words`);
}

async function processLoop(db, maxBooks = Infinity) {
  const sources = loadCompatibleSources(db);
  if (!sources.length) { console.error('No compatible sources.'); return; }
  console.log(`Sources: ${sources.map(s => s.bookSourceName).join(', ')}`);

  let processed = 0;
  while (processed < maxBooks) {
    const book = db.nextPendingBook();
    if (!book) { console.log('\nQueue empty.'); break; }
    await downloadBook(db, book, sources);
    processed++;
    if (processed < maxBooks) await engine.sleep(BOOK_DELAY_MS);
  }

  const stats = db.getCacheStats();
  console.log('\n═══ Download Summary ═══');
  console.log(`Books: ${stats.total_books} total | ${stats.done_books} done | ${stats.pending_books} pending | ${stats.error_books} error`);
  console.log(`Chapters: ${stats.total_cached_chapters} cached | ${(stats.total_words || 0).toLocaleString()} words`);
}

// CLI 入口
if (require.main === module) {
  const db = require('../db');
  const args = process.argv.slice(2);

  function getArg(flag, defaultVal) {
    const i = args.indexOf(flag);
    if (i < 0) return defaultVal;
    return parseInt(args[i + 1], 10) || defaultVal;
  }

  const chThreads = getArg('--threads', CHAPTER_CONCURRENCY);
  const bookThreads = getArg('--parallel', BOOK_CONCURRENCY);

  (async () => {
    try {
      if (args.includes('--loop')) {
        await processLoop(db, Infinity);
      } else if (args.includes('--id')) {
        const bookId = getArg('--id', 0);
        if (!bookId) { console.error('--id requires a number'); process.exit(1); }
        await processById(db, bookId);
      } else if (args.includes('--batch')) {
        const n = getArg('--batch', 10);
        await processParallel(db, n, bookThreads, chThreads);
      } else if (args.includes('--parallel')) {
        const n = getArg('--batch', 100);
        await processParallel(db, n, bookThreads, chThreads);
      } else {
        await processNext(db);
      }
    } catch (e) {
      console.error('Fatal error:', e);
      process.exit(1);
    }
    process.exit(0);
  })();
}

module.exports = { processNext, processById, processLoop, processParallel, downloadBook, loadCompatibleSources };
