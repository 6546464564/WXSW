#!/usr/bin/env node
/**
 * 导入 txt 格式书籍到 cached_books / cached_chapters
 * 用法: node scripts/import-txt-books.js <folder>
 */
'use strict';

const fs = require('fs');
const path = require('path');
const db = require('../db');

const folder = process.argv[2];
if (!folder || !fs.existsSync(folder)) {
  console.error('用法: node scripts/import-txt-books.js <txt文件夹路径>');
  process.exit(1);
}

const CHAPTER_PATTERNS = [
  /^第[零一二三四五六七八九十百千万〇\d]+[章节回卷]/,
  /^[序终]章/,
  /^楔子/,
  /^番外/,
  /^\d{1,4}[、，.．：:]\s*.+/,
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
  let startIdx = 0;
  for (let i = 0; i < Math.min(5, lines.length); i++) {
    if (lines[i].startsWith('书名：') || lines[i].startsWith('作者：') || lines[i].trim() === '') {
      startIdx = i + 1;
    } else break;
  }

  const chapters = [];
  let currentTitle = null;
  let currentLines = [];
  let preface = '';

  for (let i = startIdx; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    const isTitle = trimmed.length > 0 && CHAPTER_PATTERNS.some(p => p.test(trimmed));
    if (isTitle) {
      if (currentTitle) {
        chapters.push({ title: currentTitle, content: currentLines.join('\n').trim() });
      }
      currentTitle = trimmed;
      currentLines = [];
    } else if (currentTitle) {
      currentLines.push(line);
    } else {
      preface += line + '\n';
    }
  }
  if (currentTitle) {
    chapters.push({ title: currentTitle, content: currentLines.join('\n').trim() });
  }
  if (preface.trim().length > 10) {
    chapters.unshift({ title: '前言', content: preface.trim() });
  }

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

const files = fs.readdirSync(folder).filter(f => f.endsWith('.txt')).sort();
console.log(`找到 ${files.length} 个 txt 文件`);

const insertBook = db.__db.prepare(`
  INSERT OR REPLACE INTO cached_books (title, author, category, status, total_chapters, cached_chapters, priority)
  VALUES (?, ?, ?, 'done', ?, ?, 10)
`);
const deleteChapters = db.__db.prepare(`DELETE FROM cached_chapters WHERE book_id = ?`);
const now = Date.now();
const insertChapter = db.__db.prepare(`
  INSERT INTO cached_chapters (book_id, chapter_idx, title, content, word_count, status, created_at)
  VALUES (?, ?, ?, ?, ?, 'done', ${now})
`);
const findBook = db.__db.prepare(`SELECT id FROM cached_books WHERE title = ? AND author = ?`);

let imported = 0, skipped = 0, overwritten = 0;

const importAll = db.__db.transaction(() => {
  for (const file of files) {
    const match = file.replace('.txt', '').match(/^(.+?)\s*-\s*(.+)$/);
    if (!match) {
      console.log(`  跳过 (无法解析文件名): ${file}`);
      skipped++;
      continue;
    }
    const [, title, author] = match;
    const filePath = path.join(folder, file);
    const raw = fs.readFileSync(filePath);
    const enc = detectEncoding(raw);
    let text = new TextDecoder(enc).decode(raw);
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
    const chapters = splitChapters(text);

    if (chapters.length === 0) {
      chapters = [{ title: '全文', content: text.trim() }];
    }

    const existing = findBook.get(title, author);
    if (existing) {
      deleteChapters.run(existing.id);
      db.__db.prepare(`UPDATE cached_books SET status='done', total_chapters=?, cached_chapters=?, priority=10 WHERE id=?`)
        .run(chapters.length, chapters.length, existing.id);
      const bookId = existing.id;
      for (let i = 0; i < chapters.length; i++) {
        insertChapter.run(bookId, i, chapters[i].title, chapters[i].content, chapters[i].content.length);
      }
      overwritten++;
    } else {
      const info = insertBook.run(title, author, null, chapters.length, chapters.length);
      const bookId = info.lastInsertRowid;
      for (let i = 0; i < chapters.length; i++) {
        insertChapter.run(bookId, i, chapters[i].title, chapters[i].content, chapters[i].content.length);
      }
      imported++;
    }

    if ((imported + overwritten) % 20 === 0) {
      process.stdout.write(`  进度: ${imported + overwritten}/${files.length} (新增${imported} 覆盖${overwritten} 跳过${skipped})\r`);
    }
  }
});

importAll();
console.log(`\n完成: 新增 ${imported} | 覆盖 ${overwritten} | 跳过 ${skipped} | 总计 ${imported + overwritten + skipped}`);

const stats = db.getCacheStats();
console.log(`数据库: ${stats.done_books} 本完成 | ${stats.total_cached_chapters} 章 | ${(stats.total_words / 10000).toFixed(0)}万字`);
