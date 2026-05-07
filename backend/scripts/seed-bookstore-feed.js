// 万象书屋: 给 bookstore_feed 表灌一些示例数据 (3 channel × 8 本)
// 用法: node --experimental-require-module scripts/seed-bookstore-feed.js

const db = require('../db');
db.init();

const seedItems = [
  // ==== 男生频道 ====
  { channel: 'male', section: 'banner',     name: '斗破苍穹',   author: '天蚕土豆',   cover_url: '', target_url: 'https://search?q=斗破苍穹', priority: 100 },
  { channel: 'male', section: 'banner',     name: '诡秘之主',   author: '爱潜水的乌贼', cover_url: '', target_url: 'https://search?q=诡秘之主', priority: 99 },
  { channel: 'male', section: 'recommend',  name: '吞噬星空',   author: '我吃西红柿', cover_url: '', target_url: 'https://search?q=吞噬星空', priority: 90 },
  { channel: 'male', section: 'recommend',  name: '圣墟',       author: '辰东',       cover_url: '', target_url: 'https://search?q=圣墟', priority: 89 },
  { channel: 'male', section: 'recommend',  name: '遮天',       author: '辰东',       cover_url: '', target_url: 'https://search?q=遮天', priority: 88 },
  { channel: 'male', section: 'recommend',  name: '斗罗大陆',   author: '唐家三少',   cover_url: '', target_url: 'https://search?q=斗罗大陆', priority: 87 },
  { channel: 'male', section: 'hot',        name: '武炼巅峰',   author: '莫默',       cover_url: '', target_url: 'https://search?q=武炼巅峰', priority: 80 },
  { channel: 'male', section: 'hot',        name: '修真聊天群', author: '圣骑士的传说', cover_url: '', target_url: 'https://search?q=修真聊天群', priority: 79 },

  // ==== 女生频道 ====
  { channel: 'female', section: 'banner',    name: '何以笙箫默', author: '顾漫',     cover_url: '', target_url: 'https://search?q=何以笙箫默', priority: 100 },
  { channel: 'female', section: 'banner',    name: '杉杉来吃',   author: '顾漫',     cover_url: '', target_url: 'https://search?q=杉杉来吃', priority: 99 },
  { channel: 'female', section: 'recommend', name: '甄嬛传',     author: '流潋紫',   cover_url: '', target_url: 'https://search?q=甄嬛传', priority: 90 },
  { channel: 'female', section: 'recommend', name: '芈月传',     author: '蒋胜男',   cover_url: '', target_url: 'https://search?q=芈月传', priority: 89 },
  { channel: 'female', section: 'recommend', name: '微微一笑很倾城', author: '顾漫', cover_url: '', target_url: 'https://search?q=微微一笑很倾城', priority: 88 },
  { channel: 'female', section: 'recommend', name: '三生三世十里桃花', author: '唐七', cover_url: '', target_url: 'https://search?q=三生三世十里桃花', priority: 87 },
  { channel: 'female', section: 'hot',       name: '花千骨',     author: 'fresh果果', cover_url: '', target_url: 'https://search?q=花千骨', priority: 80 },
  { channel: 'female', section: 'hot',       name: '步步惊心',   author: '桐华',     cover_url: '', target_url: 'https://search?q=步步惊心', priority: 79 },

  // ==== 出版频道 ====
  { channel: 'publish', section: 'banner',    name: '三体',         author: '刘慈欣',   cover_url: '', target_url: 'https://search?q=三体', priority: 100 },
  { channel: 'publish', section: 'banner',    name: '活着',         author: '余华',     cover_url: '', target_url: 'https://search?q=活着', priority: 99 },
  { channel: 'publish', section: 'recommend', name: '百年孤独',     author: '马尔克斯', cover_url: '', target_url: 'https://search?q=百年孤独', priority: 90 },
  { channel: 'publish', section: 'recommend', name: '红楼梦',       author: '曹雪芹',   cover_url: '', target_url: 'https://search?q=红楼梦', priority: 89 },
  { channel: 'publish', section: 'recommend', name: '人类简史',     author: '尤瓦尔·赫拉利', cover_url: '', target_url: 'https://search?q=人类简史', priority: 88 },
  { channel: 'publish', section: 'recommend', name: '苏菲的世界',   author: '乔斯坦·贾德', cover_url: '', target_url: 'https://search?q=苏菲的世界', priority: 87 },
  { channel: 'publish', section: 'hot',       name: '解忧杂货店',   author: '东野圭吾', cover_url: '', target_url: 'https://search?q=解忧杂货店', priority: 80 },
  { channel: 'publish', section: 'hot',       name: '白夜行',       author: '东野圭吾', cover_url: '', target_url: 'https://search?q=白夜行', priority: 79 },
];

let inserted = 0;
let skipped = 0;
for (const item of seedItems) {
  try {
    db.upsertBookstoreFeed({
      channel: item.channel,
      section: item.section,
      name: item.name,
      author: item.author,
      cover_url: item.cover_url,
      target_url: item.target_url,
      source_origin: '',
      priority: item.priority,
      enabled: 1,
    });
    inserted++;
  } catch (e) {
    console.error('skip', item.name, e.message);
    skipped++;
  }
}

db.invalidateFeedCache();
console.log(`\n✓ Seeded bookstore_feed: ${inserted} inserted/updated, ${skipped} skipped`);

const m = db.listBookstoreFeed('male');
const f = db.listBookstoreFeed('female');
const p = db.listBookstoreFeed('publish');
console.log(`\n现状: male=${m.items.length} female=${f.items.length} publish=${p.items.length}`);
