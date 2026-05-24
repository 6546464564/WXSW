// 万象书屋: bookstore_feed 兜底数据 (mirror 失败时出版 tab 备用)
// 用法: node scripts/seed-bookstore-feed.js
//
// 男/女/出版主数据均走 mirror; 此表仅保留出版 fallback.

const db = require('../db');
db.init();

function coverFor(title) {
  return `https://covers.openlibrary.org/b/title/${encodeURIComponent(title)}-L.jpg`;
}

function withCover(item) {
  if (item.cover_url) return item;
  return { ...item, cover_url: coverFor(item.name) };
}

/** 出版 mirror 不可用时的最小 fallback (四榜各 2 本) */
const seedItems = [
  { channel: 'publish', section: 'banner', name: '三体', author: '刘慈欣', cover_url: '', intro: '中国科幻里程碑。', kind: '科幻', target_url: '', priority: 100 },
  { channel: 'publish', section: 'banner', name: '活着', author: '余华', cover_url: '', intro: '讲述一个人和他命运之间的友情。', kind: '文学', target_url: '', priority: 99 },
  { channel: 'publish', section: 'hot', name: '明朝那些事儿', author: '当年明月', cover_url: '', intro: '通俗说史代表作。', kind: '历史', target_url: '', priority: 80 },
  { channel: 'publish', section: 'hot', name: '人类简史', author: '尤瓦尔·赫拉利', cover_url: '', intro: '从动物到上帝的人类史。', kind: '社科', target_url: '', priority: 79 },
  { channel: 'publish', section: 'newbook', name: '长安的荔枝', author: '马伯庸', cover_url: '', intro: '以小见大的历史小说。', kind: '历史', target_url: '', priority: 70 },
  { channel: 'publish', section: 'newbook', name: '置身事内', author: '兰小欢', cover_url: '', intro: '理解中国政府与经济发展。', kind: '社科', target_url: '', priority: 69 },
  { channel: 'publish', section: 'recommend', name: '百年孤独', author: '加西亚·马尔克斯', cover_url: '', intro: '魔幻现实主义代表作。', kind: '外国文学', target_url: '', priority: 60 },
  { channel: 'publish', section: 'recommend', name: '霍乱时期的爱情', author: '马尔克斯', cover_url: '', intro: '跨越半个世纪的爱情史诗。', kind: '外国文学', target_url: '', priority: 59 },
];

if (db.__db) {
  for (const ch of ['male', 'female', 'publish']) {
    const r = db.__db.prepare('DELETE FROM bookstore_feed WHERE channel = ?').run(ch);
    console.log(`cleared ${ch}: ${r.changes} rows`);
  }
}

let inserted = 0;
for (const item of seedItems.map(withCover)) {
  db.upsertBookstoreFeed({
    channel: item.channel,
    section: item.section,
    name: item.name,
    author: item.author,
    cover_url: item.cover_url,
    intro: item.intro || null,
    kind: item.kind || null,
    target_url: item.target_url,
    source_origin: '',
    priority: item.priority,
    enabled: 1,
  });
  inserted++;
}

db.invalidateFeedCache();
console.log(`\n✓ Seeded bookstore_feed fallback: ${inserted} publish items`);

for (const ch of ['male', 'female', 'publish']) {
  const list = db.listBookstoreFeed(ch);
  console.log(`${ch}: ${list.length} items`);
}
