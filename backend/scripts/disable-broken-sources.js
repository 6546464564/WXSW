// 万象书屋: 禁用确认无法在 iOS 端用的源
//
// 标记原则: 只 disable "100% 不可用" 的, 保留"偶发可用"的
//   - Cloudflare 反爬 (5 sec challenge): 永远不能用
//   - 服务端硬空 (POST 后总返空骨架): 永远不能用
//
// 这跟 cleanup-ios-sources 互补:
//   - cleanup-ios-sources: 内容合规过滤 (敏感/漫画)
//   - 本脚本: 引擎实测无效过滤
//
// 用法: node --experimental-require-module scripts/disable-broken-sources.js

const sqlite = require('better-sqlite3');
const db = sqlite('./data/wanxiang.db');

// 万象书屋: 这些是经过 BookSourceCLI real-search 实测无效的源
// 都不是 iOS 引擎能力问题, 而是服务端 / 网站本身问题:
const BROKEN_NAMES = [
  '顶点小说',          // Cloudflare 反爬 + JS 验证, 客户端绕不过
  '刚够小说网',         // 同上 (也是 m.terry-haass 系统)
  '随梦小说网',         // legado 的 startBrowserAwait 反爬, 我们没 WKWebView 实现
];

const upd = db.prepare('UPDATE book_sources SET enabled=0, updated_at=? WHERE name=?');
const now = Date.now();

let disabled = 0;
for (const name of BROKEN_NAMES) {
  const r = db.prepare('SELECT name, enabled FROM book_sources WHERE name=?').get(name);
  if (!r) {
    console.log('  (skip) 没找到:', name);
    continue;
  }
  if (r.enabled === 0) {
    console.log('  (skip) 已禁用:', name);
    continue;
  }
  upd.run(now, name);
  console.log('  ✓ 禁用:', name);
  disabled++;
}

console.log(`\n总共禁用 ${disabled} 个源 (反爬/硬空)`);

const final = db.prepare(
  `SELECT count(*) AS c FROM book_sources WHERE platforms LIKE '%ios%' AND enabled=1`
).get();
console.log(`iOS 端最终有效源: ${final.c}`);
