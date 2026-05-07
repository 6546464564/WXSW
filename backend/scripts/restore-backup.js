#!/usr/bin/env node
// 万象书屋 - 备份恢复演练脚本.
//
// 用法:
//   node scripts/restore-backup.js [backup-file]
//
// 行为:
//   1. 如果参数缺省, 列出 data/backup/ 下所有备份文件让用户选
//   2. 校验 .sha256 sidecar (如果存在), 不一致就拒绝
//   3. 把 wanxiang.db 备份成 .pre-restore-{ts}.db (回滚保险)
//   4. 把选定的备份覆盖到 wanxiang.db
//   5. 用 sqlite3 PRAGMA integrity_check 验证恢复后的库完好
//
// 部署演练: 上线前必须跑一次, 确保备份能恢复. 不跑就上线 = 备份等于没有.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const Database = require('better-sqlite3');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, '..', 'data', 'wanxiang.db');
const BACKUP_DIR = path.join(path.dirname(DB_PATH), 'backup');

function fileSha256(p) {
  const h = crypto.createHash('sha256');
  h.update(fs.readFileSync(p));
  return h.digest('hex');
}

function listBackups() {
  if (!fs.existsSync(BACKUP_DIR)) return [];
  return fs.readdirSync(BACKUP_DIR)
    .filter(f => f.startsWith('wanxiang-') && f.endsWith('.db'))
    .sort()
    .reverse()
    .map(f => path.join(BACKUP_DIR, f));
}

async function main() {
  const arg = process.argv[2];
  let backupFile = arg;

  if (!backupFile) {
    const list = listBackups();
    if (list.length === 0) {
      console.error('[restore] no backup found in', BACKUP_DIR);
      process.exit(1);
    }
    console.log('[restore] available backups:');
    list.forEach((f, i) => console.log(`  [${i}] ${path.basename(f)}  (${fs.statSync(f).size} bytes)`));
    console.error('\n[restore] usage: node scripts/restore-backup.js <backup-file-path>');
    process.exit(1);
  }

  if (!fs.existsSync(backupFile)) {
    console.error('[restore] file not found:', backupFile);
    process.exit(1);
  }

  // 1. 校验 sha256
  const sidecar = backupFile + '.sha256';
  if (fs.existsSync(sidecar)) {
    const expected = fs.readFileSync(sidecar, 'utf8').trim().split(/\s+/)[0];
    const actual = fileSha256(backupFile);
    if (expected !== actual) {
      console.error('[restore] CHECKSUM MISMATCH!');
      console.error('  expected:', expected);
      console.error('  actual:  ', actual);
      console.error('  备份文件可能损坏, 拒绝恢复.');
      process.exit(2);
    }
    console.log('[restore] sha256 verified:', actual.slice(0, 12), '...');
  } else {
    console.warn('[restore] WARN: no .sha256 sidecar, skipping integrity check');
  }

  // 2. 当前 db 备份成 pre-restore (回滚保险)
  if (fs.existsSync(DB_PATH)) {
    const ts = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    const safety = `${DB_PATH}.pre-restore-${ts}`;
    fs.copyFileSync(DB_PATH, safety);
    console.log('[restore] current db backed up to:', safety);
  }

  // 3. 覆盖
  fs.copyFileSync(backupFile, DB_PATH);
  // WAL/SHM 残留必须删, 否则恢复后会读到老的 WAL
  ['-wal', '-shm'].forEach(suf => {
    try { fs.unlinkSync(DB_PATH + suf); } catch {}
  });
  console.log('[restore] copied backup to', DB_PATH);

  // 4. 恢复后完整性检查
  const verifyDb = new Database(DB_PATH, { readonly: true });
  try {
    const r = verifyDb.pragma('integrity_check');
    const ok = r.length === 1 && r[0].integrity_check === 'ok';
    if (ok) {
      console.log('[restore] integrity_check: OK');
    } else {
      console.error('[restore] integrity_check FAILED:', r);
      process.exit(3);
    }
  } finally {
    verifyDb.close();
  }

  console.log('\n[restore] DONE. 重启 server 后即可使用恢复后的数据.');
}

main().catch(e => { console.error('[restore] error:', e); process.exit(1); });
