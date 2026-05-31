#!/usr/bin/env node
// 批量导入 TXT 文件到本地书库
// 用法: node scripts/import-txt-library.js /path/to/folder
//
// 文件名格式: "书名 - 作者.txt"
// 冲突处理: 同名书籍跳过

const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, '..', 'data', 'wanxiang.db');
const FOLDER = process.argv[2];

if (!FOLDER) {
  console.error('用法: node scripts/import-txt-library.js /path/to/folder');
  process.exit(1);
}

const CHAPTER_PATTERNS = [
  /^第[零一二三四五六七八九十百千万〇\d]+[章节回卷]/,
  /^[序终]章/,
  /^楔子/,
  /^番外/,
  /^\d{1,4}[、.:：]\s*.+/,
  /^\d{1,4}\s{2,}\S.+/,
  /^【\d+】/,
  /^Chapter\s+\d+/i,
];

function detectEncoding(buffer) {
  if (buffer.length >= 3 && buffer[0] === 0xEF && buffer[1] === 0xBB && buffer[2] === 0xBF) return 'utf-8';
  if (buffer.length >= 2 && buffer[0] === 0xFF && buffer[1] === 0xFE) return 'utf-16le';
  if (buffer.length >= 2 && buffer[0] === 0xFE && buffer[1] === 0xFF) return 'utf-16be';
  try {
    new TextDecoder('utf-8', { fatal: true }).decode(buffer);
    return 'utf-8';
  } catch {
    return 'gbk';
  }
}

function splitChapters(text) {
  const lines = text.split(/\r?\n/);
  let headerEnd = 0;
  for (let i = 0; i < Math.min(5, lines.length); i++) {
    if (/^书名[：:]/.test(lines[i]) || /^作者[：:]/.test(lines[i]) || lines[i].trim() === '') headerEnd = i + 1;
    else break;
  }

  const chapters = [];
  let current = null;
  let preface = '';

  for (let i = headerEnd; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    const isTitle = trimmed.length > 0 && CHAPTER_PATTERNS.some(p => p.test(trimmed));
    if (isTitle) {
      if (current) chapters.push(current);
      current = { title: trimmed, content: '' };
    } else if (current) {
      current.content += line + '\n';
    } else {
      preface += line + '\n';
    }
  }
  if (current) chapters.push(current);
  if (preface.trim().length > 10) {
    chapters.unshift({ title: '前言', content: preface.trim() });
  }
  for (const ch of chapters) ch.content = ch.content.trim();

  const merged = [];
  for (let i = 0; i < chapters.length; i++) {
    if (chapters[i].content === '' && i + 1 < chapters.length) {
      const longer = chapters[i].title.length >= chapters[i + 1].title.length
        ? chapters[i].title : chapters[i + 1].title;
      chapters[i + 1].title = longer;
    } else {
      merged.push(chapters[i]);
    }
  }
  return merged;
}

function parseFilename(filename) {
  const base = path.basename(filename, '.txt');
  const parts = base.split(' - ');
  if (parts.length >= 2) {
    return { title: parts[0].trim(), author: parts.slice(1).join(' - ').trim() };
  }
  return { title: base.trim(), author: '' };
}

const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');

const checkExists = db.prepare('SELECT id FROM cached_books WHERE title = ? AND author = ?');
const insertBook = db.prepare(`
  INSERT INTO cached_books (title, author, category, total_chapters, cached_chapters, status, created_at, updated_at)
  VALUES (?, ?, '', ?, ?, 'done', ?, ?)
`);
const insertChapter = db.prepare(`
  INSERT INTO cached_chapters (book_id, chapter_idx, title, content, word_count, status, created_at)
  VALUES (?, ?, ?, ?, ?, 'done', ?)
`);

const importBook = db.transaction((title, author, chapters) => {
  const now = Date.now();
  const r = insertBook.run(title, author, chapters.length, chapters.length, now, now);
  const bookId = Number(r.lastInsertRowid);
  for (let i = 0; i < chapters.length; i++) {
    const wc = chapters[i].content.replace(/\s/g, '').length;
    insertChapter.run(bookId, i, chapters[i].title, chapters[i].content, wc, now);
  }
  return bookId;
});

const files = fs.readdirSync(FOLDER).filter(f => f.endsWith('.txt')).sort();
console.log(`共 ${files.length} 个 TXT 文件\n`);

let imported = 0, skipped = 0, failed = 0;

for (let i = 0; i < files.length; i++) {
  const { title, author } = parseFilename(files[i]);
  process.stdout.write(`[${i + 1}/${files.length}] ${title} - ${author} ... `);

  if (checkExists.get(title, author)) {
    console.log('跳过 (已存在)');
    skipped++;
    continue;
  }

  try {
    const raw = fs.readFileSync(path.join(FOLDER, files[i]));
    const enc = detectEncoding(raw);
    let text = new TextDecoder(enc).decode(raw);
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);

    let chapters = splitChapters(text);
    if (chapters.length === 0) {
      chapters = [{ title: '全文', content: text.trim() }];
    }

    const bookId = importBook(title, author, chapters);
    console.log(`成功 (ID:${bookId}, ${chapters.length}章)`);
    imported++;
  } catch (e) {
    console.log(`失败 (${e.message})`);
    failed++;
  }
}

console.log(`\n完成: 导入 ${imported}, 跳过 ${skipped}, 失败 ${failed}`);
db.close();
