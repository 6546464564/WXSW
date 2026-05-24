// 万象书屋: 给 bookstore_feed 表灌书城运营数据
// 用法: node scripts/seed-bookstore-feed.js
//
// 出版频道 section 约定 (App 按 section 映射到 月票/阅读/新书/推荐 四栏):
//   banner    → Hero + 月票榜 TOP
//   hot       → 阅读榜
//   newbook   → 新书榜
//   recommend → 推荐榜
//   editor    → 编辑精选横滑 (optional)

const db = require('../db');
db.init();

/** Open Library 封面 (无图时客户端仍有彩色占位) */
function coverFor(title) {
  return `https://covers.openlibrary.org/b/title/${encodeURIComponent(title)}-L.jpg`;
}

function withCover(item) {
  if (item.cover_url) return item;
  return { ...item, cover_url: coverFor(item.name) };
}

const seedItems = [
  // ==== 男生频道 (编辑精选) ====
  { channel: 'male', section: 'banner', name: '斗破苍穹', author: '天蚕土豆', cover_url: '', intro: '三十年河东，三十年河西，莫欺少年穷。', kind: '玄幻', target_url: 'https://search?q=斗破苍穹', priority: 100 },
  { channel: 'male', section: 'banner', name: '诡秘之主', author: '爱潜水的乌贼', cover_url: '', intro: '蒸汽与机械的浪潮中，谁能触及非凡？', kind: '玄幻', target_url: 'https://search?q=诡秘之主', priority: 99 },
  { channel: 'male', section: 'recommend', name: '吞噬星空', author: '我吃西红柿', cover_url: '', intro: '', kind: '科幻', target_url: 'https://search?q=吞噬星空', priority: 90 },
  { channel: 'male', section: 'recommend', name: '圣墟', author: '辰东', cover_url: '', intro: '', kind: '玄幻', target_url: 'https://search?q=圣墟', priority: 89 },
  { channel: 'male', section: 'recommend', name: '遮天', author: '辰东', cover_url: '', intro: '', kind: '玄幻', target_url: 'https://search?q=遮天', priority: 88 },
  { channel: 'male', section: 'recommend', name: '斗罗大陆', author: '唐家三少', cover_url: '', intro: '', kind: '玄幻', target_url: 'https://search?q=斗罗大陆', priority: 87 },
  { channel: 'male', section: 'hot', name: '武炼巅峰', author: '莫默', cover_url: '', intro: '', kind: '玄幻', target_url: 'https://search?q=武炼巅峰', priority: 80 },
  { channel: 'male', section: 'hot', name: '修真聊天群', author: '圣骑士的传说', cover_url: '', intro: '', kind: '都市', target_url: 'https://search?q=修真聊天群', priority: 79 },

  // ==== 女生频道 (编辑精选) ====
  { channel: 'female', section: 'banner', name: '何以笙箫默', author: '顾漫', cover_url: '', intro: '', kind: '言情', target_url: 'https://search?q=何以笙箫默', priority: 100 },
  { channel: 'female', section: 'banner', name: '杉杉来吃', author: '顾漫', cover_url: '', intro: '', kind: '言情', target_url: 'https://search?q=杉杉来吃', priority: 99 },
  { channel: 'female', section: 'recommend', name: '甄嬛传', author: '流潋紫', cover_url: '', intro: '', kind: '古言', target_url: 'https://search?q=甄嬛传', priority: 90 },
  { channel: 'female', section: 'recommend', name: '芈月传', author: '蒋胜男', cover_url: '', intro: '', kind: '古言', target_url: 'https://search?q=芈月传', priority: 89 },
  { channel: 'female', section: 'recommend', name: '微微一笑很倾城', author: '顾漫', cover_url: '', intro: '', kind: '言情', target_url: 'https://search?q=微微一笑很倾城', priority: 88 },
  { channel: 'female', section: 'recommend', name: '三生三世十里桃花', author: '唐七', cover_url: '', intro: '', kind: '仙侠', target_url: 'https://search?q=三生三世十里桃花', priority: 87 },
  { channel: 'female', section: 'hot', name: '花千骨', author: 'fresh果果', cover_url: '', intro: '', kind: '仙侠', target_url: 'https://search?q=花千骨', priority: 80 },
  { channel: 'female', section: 'hot', name: '步步惊心', author: '桐华', cover_url: '', intro: '', kind: '古言', target_url: 'https://search?q=步步惊心', priority: 79 },

  // ==== 出版频道 (独立书单, 驱动四榜 + 编辑精选) ====
  { channel: 'publish', section: 'banner', name: '三体', author: '刘慈欣', cover_url: '', intro: '中国科幻里程碑，雨果奖获奖作品。', kind: '科幻', target_url: 'https://search?q=三体', priority: 100 },
  { channel: 'publish', section: 'banner', name: '活着', author: '余华', cover_url: '', intro: '讲述一个人和他命运之间的友情。', kind: '文学', target_url: 'https://search?q=活着', priority: 99 },
  { channel: 'publish', section: 'banner', name: '百年孤独', author: '加西亚·马尔克斯', cover_url: '', intro: '魔幻现实主义文学代表作。', kind: '外国文学', target_url: 'https://search?q=百年孤独', priority: 98 },
  { channel: 'publish', section: 'banner', name: '红楼梦', author: '曹雪芹', cover_url: '', intro: '中国古典小说巅峰之作。', kind: '古典名著', target_url: 'https://search?q=红楼梦', priority: 97 },
  { channel: 'publish', section: 'banner', name: '围城', author: '钱钟书', cover_url: '', intro: '中国现代文学经典讽刺小说。', kind: '文学', target_url: 'https://search?q=围城', priority: 96 },
  { channel: 'publish', section: 'banner', name: '平凡的世界', author: '路遥', cover_url: '', intro: '茅盾文学奖获奖作品。', kind: '文学', target_url: 'https://search?q=平凡的世界', priority: 95 },
  { channel: 'publish', section: 'banner', name: '挪威的森林', author: '村上春树', cover_url: '', intro: '青春与成长的经典叙事。', kind: '外国文学', target_url: 'https://search?q=挪威的森林', priority: 94 },
  { channel: 'publish', section: 'banner', name: '追风筝的人', author: '卡勒德·胡赛尼', cover_url: '', intro: '关于背叛与救赎的故事。', kind: '外国文学', target_url: 'https://search?q=追风筝的人', priority: 93 },

  { channel: 'publish', section: 'hot', name: '解忧杂货店', author: '东野圭吾', cover_url: '', intro: '温情的时空交错物语。', kind: '推理', target_url: 'https://search?q=解忧杂货店', priority: 80 },
  { channel: 'publish', section: 'hot', name: '白夜行', author: '东野圭吾', cover_url: '', intro: '绝望与共生的人性长篇。', kind: '推理', target_url: 'https://search?q=白夜行', priority: 79 },
  { channel: 'publish', section: 'hot', name: '人类简史', author: '尤瓦尔·赫拉利', cover_url: '', intro: '从动物到上帝的人类史。', kind: '社科', target_url: 'https://search?q=人类简史', priority: 78 },
  { channel: 'publish', section: 'hot', name: '苏菲的世界', author: '乔斯坦·贾德', cover_url: '', intro: '哲学入门小说。', kind: '哲学', target_url: 'https://search?q=苏菲的世界', priority: 77 },
  { channel: 'publish', section: 'hot', name: '万历十五年', author: '黄仁宇', cover_url: '', intro: '大历史观的明史经典。', kind: '历史', target_url: 'https://search?q=万历十五年', priority: 76 },
  { channel: 'publish', section: 'hot', name: '明朝那些事儿', author: '当年明月', cover_url: '', intro: '通俗说史代表作。', kind: '历史', target_url: 'https://search?q=明朝那些事儿', priority: 75 },
  { channel: 'publish', section: 'hot', name: '小王子', author: '圣埃克苏佩里', cover_url: '', intro: '写给大人的童话。', kind: '外国文学', target_url: 'https://search?q=小王子', priority: 74 },
  { channel: 'publish', section: 'hot', name: '月亮与六便士', author: '毛姆', cover_url: '', intro: '理想与现实的永恒命题。', kind: '外国文学', target_url: 'https://search?q=月亮与六便士', priority: 73 },

  { channel: 'publish', section: 'newbook', name: '额尔古纳河右岸', author: '迟子建', cover_url: '', intro: '茅盾文学奖获奖作品。', kind: '文学', target_url: 'https://search?q=额尔古纳河右岸', priority: 70 },
  { channel: 'publish', section: 'newbook', name: '云边有个小卖部', author: '张嘉佳', cover_url: '', intro: '温暖治愈的都市故事。', kind: '文学', target_url: 'https://search?q=云边有个小卖部', priority: 69 },
  { channel: 'publish', section: 'newbook', name: '长安的荔枝', author: '马伯庸', cover_url: '', intro: '以小见大的历史小说。', kind: '历史', target_url: 'https://search?q=长安的荔枝', priority: 68 },
  { channel: 'publish', section: 'newbook', name: '显微镜下的大明', author: '马伯庸', cover_url: '', intro: '明代基层政治的真实切片。', kind: '历史', target_url: 'https://search?q=显微镜下的大明', priority: 67 },
  { channel: 'publish', section: 'newbook', name: '置身事内', author: '兰小欢', cover_url: '', intro: '理解中国政府与经济发展。', kind: '社科', target_url: 'https://search?q=置身事内', priority: 66 },
  { channel: 'publish', section: 'newbook', name: '蛤蟆先生去看心理医生', author: '罗伯特·戴博德', cover_url: '', intro: '心理学入门读物。', kind: '心理', target_url: 'https://search?q=蛤蟆先生去看心理医生', priority: 65 },
  { channel: 'publish', section: 'newbook', name: '被讨厌的勇气', author: '岸见一郎', cover_url: '', intro: '阿德勒心理学对话录。', kind: '心理', target_url: 'https://search?q=被讨厌的勇气', priority: 64 },
  { channel: 'publish', section: 'newbook', name: '原则', author: '瑞·达利欧', cover_url: '', intro: '生活与工作的原则。', kind: '经管', target_url: 'https://search?q=原则', priority: 63 },

  { channel: 'publish', section: 'recommend', name: '霍乱时期的爱情', author: '马尔克斯', cover_url: '', intro: '跨越半个世纪的爱情史诗。', kind: '外国文学', target_url: 'https://search?q=霍乱时期的爱情', priority: 60 },
  { channel: 'publish', section: 'recommend', name: '局外人', author: '加缪', cover_url: '', intro: '存在主义文学经典。', kind: '外国文学', target_url: 'https://search?q=局外人', priority: 59 },
  { channel: 'publish', section: 'recommend', name: '沉默的大多数', author: '王小波', cover_url: '', intro: '特立独行的杂文随笔。', kind: '文学', target_url: 'https://search?q=沉默的大多数', priority: 58 },
  { channel: 'publish', section: 'recommend', name: '看见', author: '柴静', cover_url: '', intro: '媒体人的现场与思考。', kind: '纪实', target_url: 'https://search?q=看见', priority: 57 },
  { channel: 'publish', section: 'recommend', name: '我们仨', author: '杨绛', cover_url: '', intro: '朴素深情的家庭回忆录。', kind: '文学', target_url: 'https://search?q=我们仨', priority: 56 },
  { channel: 'publish', section: 'recommend', name: '撒哈拉的故事', author: '三毛', cover_url: '', intro: '沙漠生活的浪漫书写。', kind: '文学', target_url: 'https://search?q=撒哈拉的故事', priority: 55 },
  { channel: 'publish', section: 'recommend', name: '文化苦旅', author: '余秋雨', cover_url: '', intro: '探寻中华文化的精神足迹。', kind: '文化', target_url: 'https://search?q=文化苦旅', priority: 54 },
  { channel: 'publish', section: 'recommend', name: '美的历程', author: '李泽厚', cover_url: '', intro: '中国美学史的经典梳理。', kind: '艺术', target_url: 'https://search?q=美的历程', priority: 53 },

  { channel: 'publish', section: 'editor', name: '刀锋', author: '毛姆', cover_url: '', intro: '精神求索之旅。', kind: '外国文学', target_url: 'https://search?q=刀锋', priority: 40 },
  { channel: 'publish', section: 'editor', name: '悉达多', author: '黑塞', cover_url: '', intro: '东方智慧下的自我寻找。', kind: '外国文学', target_url: 'https://search?q=悉达多', priority: 39 },
  { channel: 'publish', section: 'editor', name: '房思琪的初恋乐园', author: '林奕含', cover_url: '', intro: '', kind: '文学', target_url: 'https://search?q=房思琪的初恋乐园', priority: 38 },
  { channel: 'publish', section: 'editor', name: '秋园', author: '杨本芬', cover_url: '', intro: '普通中国女性的一生。', kind: '文学', target_url: 'https://search?q=秋园', priority: 37 },
  { channel: 'publish', section: 'editor', name: '芯片战争', author: '克里斯·米勒', cover_url: '', intro: '全球半导体产业博弈。', kind: '科技', target_url: 'https://search?q=芯片战争', priority: 36 },
  { channel: 'publish', section: 'editor', name: '可能性的艺术', author: '刘瑜', cover_url: '', intro: '比较政治学入门。', kind: '社科', target_url: 'https://search?q=可能性的艺术', priority: 35 },
];

// 出版频道: 先清旧数据再灌 (避免重复)
if (db.__db) {
  db.__db.prepare('DELETE FROM bookstore_feed WHERE channel = ?').run('publish');
  console.log('cleared old publish feed rows');
}

let inserted = 0;
let skipped = 0;
for (const item of seedItems.map(withCover)) {
  try {
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
  } catch (e) {
    console.error('skip', item.name, e.message);
    skipped++;
  }
}

db.invalidateFeedCache();
console.log(`\n✓ Seeded bookstore_feed: ${inserted} inserted/updated, ${skipped} skipped`);

for (const ch of ['male', 'female', 'publish']) {
  const list = db.listBookstoreFeed(ch);
  const sections = {};
  for (const it of list) {
    sections[it.section] = (sections[it.section] || 0) + 1;
  }
  console.log(`${ch}: ${list.length} items`, sections);
}
