// 万象书屋: 每天 03:00 自动备份 SQLite

const logger = require('../logger');

function scheduleDailyBackup(db) {
  const fs = require('fs');
  const crypto = require('crypto');
  const pathMod = require('path');
  const dataDir = process.env.DB_PATH
    ? pathMod.dirname(process.env.DB_PATH)
    : pathMod.join(__dirname, '..', 'data');
  const backupDir = pathMod.join(dataDir, 'backup');
  try { fs.mkdirSync(backupDir, { recursive: true }); } catch {}

  const RETENTION_DAYS = parseInt(process.env.BACKUP_RETENTION_DAYS || '7', 10);
  const WEBHOOK = process.env.BACKUP_WEBHOOK_URL || '';

  function msUntilNextRun() {
    const now = new Date();
    const next = new Date(now);
    next.setHours(3, 0, 0, 0);
    if (next <= now) next.setDate(next.getDate() + 1);
    return next - now;
  }

  function fileSha256(filePath) {
    return new Promise((resolve, reject) => {
      const h = crypto.createHash('sha256');
      const s = fs.createReadStream(filePath);
      s.on('data', c => h.update(c));
      s.on('end', () => resolve(h.digest('hex')));
      s.on('error', reject);
    });
  }

  async function runBackupOnce() {
    const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
    const target = pathMod.join(backupDir, `wanxiang-${stamp}.db`);
    const checksumFile = target + '.sha256';
    try {
      await db.__db.backup(target);
      const sha256 = await fileSha256(target);
      const size = fs.statSync(target).size;
      fs.writeFileSync(checksumFile, `${sha256}  ${pathMod.basename(target)}\n`);
      logger.info('backup ok', { target, sha256: sha256.slice(0, 12), size });

      if (WEBHOOK) {
        try {
          const r = await fetch(WEBHOOK, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ok: true, target, sha256, size, ts: Date.now() }),
            signal: AbortSignal.timeout(10_000)
          });
          logger.info('backup webhook notified', { status: r.status });
        } catch (e) {
          logger.warn('backup webhook failed', { msg: e.message });
        }
      }

      const allFiles = fs.readdirSync(backupDir)
        .filter(f => f.startsWith('wanxiang-') && (f.endsWith('.db') || f.endsWith('.db.sha256')))
        .sort()
        .reverse();
      for (const f of allFiles.slice(RETENTION_DAYS * 2)) {
        try { fs.unlinkSync(pathMod.join(backupDir, f)); } catch {}
      }
    } catch (e) {
      logger.error('backup failed', { msg: e.message });
    }
  }

  function scheduleNext() {
    const ms = msUntilNextRun();
    setTimeout(async () => {
      await runBackupOnce();
      scheduleNext();
    }, ms).unref?.();
  }
  scheduleNext();
  return { runBackupOnce };
}

module.exports = { scheduleDailyBackup };
