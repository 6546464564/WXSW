#!/usr/bin/env node
// 万象书屋: 将 qidian_finish_books.json 导入 cached_books 表
//
// 用法: node scripts/import-qidian-books.js [path-to-json]

const path = require('path');
const fs = require('fs');

const jsonPath = process.argv[2]
  || path.join(__dirname, '..', '..', 'qidian_finish_books.json');

if (!fs.existsSync(jsonPath)) {
  console.error('JSON file not found:', jsonPath);
  process.exit(1);
}

const db = require('../db');
const books = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));

console.log(`Importing ${books.length} books from ${jsonPath}...`);

const mapped = books.map((b, i) => ({
  qidianId: b.book_id,
  title: b.title,
  author: b.author || '',
  category: b.category || '',
  coverUrl: `https://bookcover.yuewen.com/qdbimg/349573/${b.book_id}/180`,
  priority: 1000 - (b.rank || i),
}));

const inserted = db.bulkInsertCachedBooks(mapped);
const total = db.__db.prepare('SELECT COUNT(*) as n FROM cached_books').get().n;

console.log(`Done. Inserted: ${inserted}, Total in DB: ${total}`);
process.exit(0);
