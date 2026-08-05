const crypto = require('crypto');
const https = require('https');

const SIGN_KEY = 'd3dGiJc651gSQ8w1';
const AES_KEY = Buffer.from('242ccb8230d709e1');
const HEADERS_TEMPLATE = {
  'app-version': '51110',
  'platform': 'android',
  'reg': '0',
  'AUTHORIZATION': '',
  'application-id': 'com.****.reader',
  'net-env': '1',
  'channel': 'unknown',
  'qm-params': ''
};

function md5Sign(params) {
  const sorted = Object.keys(params).sort().map(k => k + '=' + params[k]).join('');
  return crypto.createHash('md5').update(sorted + SIGN_KEY).digest('hex');
}

function buildUrl(baseUrl, params) {
  const headers = { ...HEADERS_TEMPLATE };
  params.sign = md5Sign(params);
  headers.sign = md5Sign(headers);
  headers.headers = JSON.stringify({ headers });
  const qs = new URLSearchParams(params).toString();
  return { url: baseUrl + '?' + qs, headers };
}

function fetchJson(url, headers) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, { headers, timeout: 15000 }, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        try { resolve(JSON.parse(data)); }
        catch { reject(new Error('invalid json')); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
  });
}

function decryptContent(encrypted) {
  const buf = Buffer.from(encrypted, 'base64');
  const iv = buf.subarray(0, 16);
  const data = buf.subarray(16);
  const decipher = crypto.createDecipheriv('aes-128-cbc', AES_KEY, iv);
  let dec = decipher.update(data);
  dec = Buffer.concat([dec, decipher.final()]);
  return dec.toString('utf-8');
}

function stripHtml(text) {
  return (text || '').replace(/<[^>]+>/g, '').trim();
}

async function getChapterList(qimaoId) {
  const { url, headers } = buildUrl('https://api-ks.wtzw.com/api/v1/chapter/chapter-list', { id: qimaoId });
  const resp = await fetchJson(url, headers);
  return (resp?.data?.chapter_lists) || [];
}

async function getChapterContent(qimaoId, chapterId, retries = 3) {
  for (let i = 0; i < retries; i++) {
    try {
      const params = { chapterId, id: qimaoId };
      const { url, headers } = buildUrl('https://api-ks.wtzw.com/api/v1/chapter/content', params);
      let resp = await fetchJson(url, headers);

      if (resp?.errors?.code === '17010104') {
        params.reader_agent = 1;
        const r2 = buildUrl('https://api-ks.wtzw.com/api/v1/chapter/content', params);
        resp = await fetchJson(r2.url, r2.headers);
      }

      const encrypted = resp?.data?.content;
      if (!encrypted) {
        if (i < retries - 1) { await sleep(500 * (i + 1)); continue; }
        return null;
      }
      return decryptContent(encrypted);
    } catch {
      if (i < retries - 1) await sleep(500 * (i + 1));
    }
  }
  return null;
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function updateBook(db, book, logger) {
  const { id: bookId, title, qimao_id } = book;
  if (!qimao_id) return { status: 'skip', reason: 'no qimao_id' };

  const chapters = await getChapterList(qimao_id);
  if (!chapters.length) return { status: 'skip', reason: 'empty chapter list' };

  const existingCount = db.__db.prepare(
    'SELECT COUNT(*) as cnt FROM cached_chapters WHERE book_id = ?'
  ).get(bookId).cnt;

  const onlineCount = chapters.length;
  if (onlineCount <= existingCount) {
    return { status: 'up_to_date', existing: existingCount, online: onlineCount };
  }

  const newChapters = chapters.slice(existingCount);
  const now = Date.now();
  let downloaded = 0;
  let failed = 0;

  const BATCH = 10;
  for (let i = 0; i < newChapters.length; i += BATCH) {
    const batch = newChapters.slice(i, i + BATCH);
    const results = await Promise.all(
      batch.map(async (ch, bi) => {
        const chIdx = existingCount + i + bi;
        const chId = String(ch.id || '');
        if (!chId) return null;
        const content = await getChapterContent(qimao_id, chId);
        if (!content) { failed++; return null; }
        const chTitle = stripHtml(ch.title);
        return { chIdx, chTitle, content, wordCount: content.length };
      })
    );

    const insertStmt = db.__db.prepare(
      'INSERT OR IGNORE INTO cached_chapters (book_id, chapter_idx, title, content, word_count, status, created_at) VALUES (?, ?, ?, ?, ?, \'done\', ?)'
    );
    for (const r of results) {
      if (r) {
        insertStmt.run(bookId, r.chIdx, r.chTitle, r.content, r.wordCount, now);
        downloaded++;
      }
    }
  }

  db.__db.prepare(
    'UPDATE cached_books SET total_chapters = ?, cached_chapters = cached_chapters + ?, updated_at = ? WHERE id = ?'
  ).run(onlineCount, downloaded, now, bookId);

  if (logger) logger.info('qimao update', { title, new: downloaded, failed, total: onlineCount });
  return { status: 'updated', newChapters: downloaded, failed, total: onlineCount };
}

async function updateAll(db, logger, progressCb) {
  const books = db.__db.prepare(
    "SELECT id, title, author, qimao_id, cached_chapters, total_chapters, category FROM cached_books WHERE qimao_id IS NOT NULL AND qimao_id != '' AND (category IS NULL OR category != '完本')"
  ).all();

  const summary = { total: books.length, updated: 0, upToDate: 0, failed: 0, newChapters: 0, errors: [] };

  for (let i = 0; i < books.length; i++) {
    const book = books[i];
    try {
      const result = await updateBook(db, book, logger);
      if (result.status === 'updated') {
        summary.updated++;
        summary.newChapters += result.newChapters;
      } else if (result.status === 'up_to_date') {
        summary.upToDate++;
      }
    } catch (e) {
      summary.failed++;
      summary.errors.push({ title: book.title, error: e.message });
      if (logger) logger.warn('qimao update error', { title: book.title, err: e.message });
    }

    if (progressCb && (i + 1) % 10 === 0) {
      progressCb({ done: i + 1, total: books.length, ...summary });
    }
    await sleep(100);
  }

  return summary;
}

async function importBook(db, qimaoId, category, logger) {
  const chapters = await getChapterList(qimaoId);
  if (!chapters.length) throw new Error('no chapters found');

  const infoUrl = buildUrl('https://api-ks.wtzw.com/api/v1/book/detail', { id: qimaoId });
  let title = '', author = '';
  try {
    const resp = await fetchJson(infoUrl.url, infoUrl.headers);
    title = stripHtml(resp?.data?.title || '');
    author = stripHtml(resp?.data?.author || '');
  } catch { /* use from chapters */ }

  if (!title) throw new Error('cannot get book info');

  const existing = db.__db.prepare('SELECT id FROM cached_books WHERE title = ? AND author = ?').get(title, author);
  if (existing) throw new Error(`book already exists: ${title}`);

  const now = Date.now();
  const cursor = db.__db.prepare(
    "INSERT INTO cached_books (title, author, category, qimao_id, total_chapters, cached_chapters, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, 0, 'done', ?, ?)"
  ).run(title, author, category || '', qimaoId, chapters.length, now, now);
  const bookId = cursor.lastInsertRowid;

  let downloaded = 0, failed = 0;
  const BATCH = 10;
  for (let i = 0; i < chapters.length; i += BATCH) {
    const batch = chapters.slice(i, i + BATCH);
    const results = await Promise.all(
      batch.map(async (ch, bi) => {
        const chIdx = i + bi;
        const chId = String(ch.id || '');
        if (!chId) return null;
        const content = await getChapterContent(qimaoId, chId);
        if (!content) { failed++; return null; }
        return { chIdx, chTitle: stripHtml(ch.title), content, wordCount: content.length };
      })
    );

    const insertStmt = db.__db.prepare(
      'INSERT INTO cached_chapters (book_id, chapter_idx, title, content, word_count, status, created_at) VALUES (?, ?, ?, ?, ?, \'done\', ?)'
    );
    for (const r of results) {
      if (r) { insertStmt.run(bookId, r.chIdx, r.chTitle, r.content, r.wordCount, now); downloaded++; }
    }
  }

  db.__db.prepare('UPDATE cached_books SET cached_chapters = ? WHERE id = ?').run(downloaded, bookId);
  if (logger) logger.info('qimao import', { title, chapters: downloaded, failed });
  return { bookId, title, author, chapters: downloaded, failed, total: chapters.length };
}

module.exports = { updateBook, updateAll, importBook, getChapterList, getChapterContent, md5Sign, buildUrl, stripHtml, decryptContent };
