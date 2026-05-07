// 万象书屋: 修复 book_source name 里的脏字符 (换行/制表/控制符)
// 上一版 inline -e 双重 escape 写错了, 这里用 .js 文件正确实现
const sqlite = require('better-sqlite3');
const db = sqlite('./data/wanxiang.db');

const all = db.prepare('SELECT url, name, json FROM book_sources').all();
const upd = db.prepare('UPDATE book_sources SET name=?, updated_at=? WHERE url=?');
const now = Date.now();

// 正确正则: 只匹配 \n \r \t 和 NULL/控制符, 不匹配字母数字
const dirtyRe = /[\n\r\t\u0000-\u001F]/;

let fixed = 0;
for (const r of all) {
  if (!dirtyRe.test(r.name)) continue;
  // 优先用 json.bookSourceName (来源数据), 否则按换行切取最后一段非空
  let json = {};
  try { json = JSON.parse(r.json); } catch (e) {}
  let newName = json.bookSourceName;
  if (!newName || dirtyRe.test(newName)) {
    const segs = r.name.split(/[\n\r\t]+/).map(s => s.trim()).filter(Boolean);
    // 取最后一段 (常见情况是"上一条名 \n 真名")
    newName = segs[segs.length - 1] || r.name.trim();
  }
  // 二次清理: 去掉残留的控制符
  newName = newName.replace(/[\u0000-\u001F]/g, '').trim();
  if (newName === r.name || !newName) continue;
  console.log(`  ${JSON.stringify(r.name)} → ${JSON.stringify(newName)}`);
  upd.run(newName, now, r.url);
  fixed++;
}
console.log(`\n修复 ${fixed} 条`);

// 验证
const remaining = db.prepare('SELECT name FROM book_sources').all()
  .filter(r => dirtyRe.test(r.name));
console.log(`剩余脏 name: ${remaining.length}`);
