// 万象书屋: iOS 书源清洗 (App Store 合规 + 数据质量)
// 用法: node --experimental-require-module scripts/cleanup-ios-sources.js
//
// 干的事:
//   1. 把 7 个含"成人/百合/asmr/禁漫/黄易/宅男/肉/激情" 关键词的源,
//      iOS 平台移除 (改 platforms='android', Android 端不影响)
//   2. 把名字含"漫画"或 bookSourceType=1 的, 平台改成 'ios:manga' (后续 manga channel 用)
//      → 这一步 v1 暂时改成 'android' 一刀切, 因为 manga channel 还没单独路由
//   3. 修 source_url 为 NULL 或空的脏行 (disable)
//   4. ruleSearch / ruleContent 不全的源 disable
//   5. 名字超过 30 字的源 disable (UI 体验 + 多半是垃圾导入)

const sqlite = require('better-sqlite3');
const db = sqlite('./data/wanxiang.db');

const SENSITIVE_KEYWORDS = [
  '成人', '色', '百合', '禁漫', '黄易', '宅男', '黄', '肉', '激情',
  'h漫', 'xxx', 'asmr', 'BB', '🔞',
];

const MANGA_KEYWORDS = ['漫画', '动漫', '看漫'];

const NORMAL_KEYWORDS = ['正常', '小说', '文学', '阁', '书', '番茄'];

const rows = db.prepare(
  `SELECT url, name, platforms, enabled, json FROM book_sources WHERE platforms LIKE '%ios%'`
).all();

console.log(`扫描 ${rows.length} 个 iOS 源\n`);

const updateStmt = db.prepare(
  `UPDATE book_sources SET platforms=?, enabled=?, updated_at=? WHERE url=?`
);
const now = Date.now();

let removed = 0, mangaMoved = 0, brokenDisabled = 0, longNameTrimmed = 0, kept = 0;
const actions = [];

for (const r of rows) {
  const lower = r.name.toLowerCase();
  let json = {};
  try { json = JSON.parse(r.json); } catch (e) {}
  const hasSearch = !!json.ruleSearch && !!json.searchUrl;
  const hasContent = !!json.ruleContent;
  const isBookSourceTypeManga = json.bookSourceType === 1;

  const isSens = SENSITIVE_KEYWORDS.some(k =>
    r.name.includes(k) || lower.includes(k.toLowerCase())
  );
  const isManga = MANGA_KEYWORDS.some(k => r.name.includes(k)) || isBookSourceTypeManga;
  const isUrlBad = !r.url || r.url === '' || r.url === 'NULL';
  const isRuleBroken = !hasSearch || !hasContent;
  const isLongName = (r.name || '').length > 30;

  // 计算新 platforms
  const oldPlatforms = (r.platforms || 'android,ios').split(',');
  let newPlatforms = oldPlatforms.filter(p => p !== 'ios');
  let newEnabled = r.enabled;
  let reason = null;

  if (isSens) {
    // App Store 合规: 从 iOS 完全移除 (Android 仍可见)
    reason = 'sensitive(App Store 合规)';
    removed++;
  } else if (isManga) {
    // 漫画暂时不下发 iOS (manga channel 还没接, 给 iOS 看会进错频道)
    reason = 'manga(暂未支持 iOS manga channel)';
    mangaMoved++;
  } else if (isUrlBad) {
    reason = 'NULL/empty URL';
    newEnabled = 0;
    brokenDisabled++;
    newPlatforms = oldPlatforms;  // 保留 platforms, 只是 disable
  } else if (isRuleBroken) {
    reason = 'no ruleSearch/ruleContent';
    newEnabled = 0;
    brokenDisabled++;
    newPlatforms = oldPlatforms;
  } else if (isLongName) {
    reason = 'name too long(' + r.name.length + ' chars)';
    newEnabled = 0;
    longNameTrimmed++;
    newPlatforms = oldPlatforms;
  } else {
    kept++;
    continue;
  }

  actions.push({
    name: r.name.slice(0, 50),
    old_platforms: r.platforms,
    new_platforms: newPlatforms.join(','),
    new_enabled: newEnabled,
    reason,
  });
  updateStmt.run(newPlatforms.join(','), newEnabled, now, r.url);
}

console.log('=== 操作日志 ===');
for (const a of actions) {
  console.log(`  [${a.reason}]`);
  console.log(`    ${a.name}`);
  console.log(`    platforms: ${a.old_platforms} → ${a.new_platforms}, enabled=${a.new_enabled}`);
}

console.log('');
console.log('=== Summary ===');
console.log(`  🔞 敏感源从 iOS 移除: ${removed}`);
console.log(`  🎨 漫画源从 iOS 移除: ${mangaMoved}`);
console.log(`  ❌ URL/规则坏掉的禁用: ${brokenDisabled}`);
console.log(`  📏 名字过长的禁用: ${longNameTrimmed}`);
console.log(`  ✓ 保留: ${kept}`);

// 让 server 端 cache 失效 (要求 server 进程下次拉时重读)
try {
  const dbjs = require('../db');
  dbjs.invalidateSourcesCache && dbjs.invalidateSourcesCache();
} catch (e) {}

// 看一下最终 iOS 端能拿到的源
const finalIos = db.prepare(
  `SELECT name FROM book_sources WHERE platforms LIKE '%ios%' AND enabled=1 ORDER BY name`
).all();
console.log(`\n=== iOS 端清洗后能拉到 ${finalIos.length} 个源 ===`);
for (const r of finalIos) {
  console.log('  ✓ ' + r.name);
}
