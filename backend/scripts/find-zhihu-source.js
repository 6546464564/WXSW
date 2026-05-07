// 找出 search 规则里含 zhihu 或类似搜索引擎的书源
const db = require('../db');

const all = db.__db.prepare(`
  SELECT url, name, enabled, json
  FROM book_sources
  WHERE enabled = 1
`).all();

console.log('=== 检查每个书源 search 规则里是否含搜索引擎引用 ===\n');

const SUSPECT_KEYWORDS = ['zhihu', 'baidu.com', 'bing.com', 'so.com', 'sogou', 'wikipedia', 'jianshu', 'csdn'];

const flagged = [];
for (const s of all) {
  try {
    const cfg = JSON.parse(s.json);
    // 收集所有 search 相关 url 字段
    const searchUrl = cfg.searchUrl || '';
    const searchBookList = cfg.ruleSearch?.bookList || '';
    const searchName = cfg.ruleSearch?.name || '';
    const searchAuthor = cfg.ruleSearch?.author || '';
    const searchKind = cfg.ruleSearch?.kind || '';
    const searchBookUrl = cfg.ruleSearch?.bookUrl || '';
    const all_text = `${searchUrl} ${searchBookList} ${searchName} ${searchAuthor} ${searchKind} ${searchBookUrl}`.toLowerCase();
    const hits = SUSPECT_KEYWORDS.filter(k => all_text.includes(k));
    if (hits.length > 0) {
      flagged.push({ name: s.name, url: s.url, hits, searchUrl: searchUrl.substring(0, 80) });
    }
    // 看 explore 规则
    const explore = cfg.exploreUrl || '';
    if (SUSPECT_KEYWORDS.some(k => explore.toLowerCase().includes(k))) {
      flagged.push({ name: s.name, url: s.url, hits: ['explore url 含搜索引擎'], explore: explore.substring(0, 80) });
    }
  } catch (e) {
    console.log(`[parse fail] ${s.name}: ${e.message}`);
  }
}

console.log('=== 含搜索引擎引用的书源 ===\n');
if (flagged.length === 0) {
  console.log('  (无)');
} else {
  for (const f of flagged) {
    console.log(`  ⚠️  ${f.name}`);
    console.log(`      url: ${f.url}`);
    console.log(`      hits: ${f.hits.join(', ')}`);
    if (f.searchUrl) console.log(`      searchUrl: ${f.searchUrl}`);
    if (f.explore) console.log(`      explore: ${f.explore}`);
    console.log('');
  }
}

// 顺手统计每个书源的 search 配置完整性
console.log('=== Search 规则完整性诊断 ===\n');
const incomplete = [];
for (const s of all) {
  try {
    const cfg = JSON.parse(s.json);
    const issues = [];
    if (!cfg.searchUrl) issues.push('searchUrl 缺失');
    if (!cfg.ruleSearch?.bookList) issues.push('bookList 规则缺失');
    if (!cfg.ruleSearch?.name) issues.push('name 规则缺失');
    if (!cfg.ruleSearch?.bookUrl) issues.push('bookUrl 规则缺失');
    if (issues.length > 0) incomplete.push({ name: s.name, url: s.url, issues });
  } catch (_) {}
}
if (incomplete.length === 0) {
  console.log('  (全部完整)');
} else {
  for (const i of incomplete) {
    console.log(`  ⚠️  ${i.name.padEnd(30)} ${i.issues.join(', ')}`);
  }
}
