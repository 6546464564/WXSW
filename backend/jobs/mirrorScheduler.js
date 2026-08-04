// 万象书屋: 书城 mirror 定时抓取调度

const logger = require('../logger');
const qidianMirror = require('./qidianMirror');

let _nextMirrorRunAt = null;
let _mirrorTimer = null;

function getNextRunAt() { return _nextMirrorRunAt; }

function scheduleMirrorJob(db) {
  // 启动时如果 cache 全空, 5s 后立刻抓一次
  setTimeout(async () => {
    if (!db.getLatestBookstoreMirror()) {
      logger.info('mirror: empty cache on boot, kick off initial fetch');
      try {
        const r = await Promise.race([
          qidianMirror.fetchAndCache(db),
          new Promise((_, rej) => setTimeout(() => rej(new Error('mirror initial fetch timed out (10min)')), 10 * 60 * 1000)),
        ]);
        logger.info('mirror: initial fetch ok', r);
      } catch (e) {
        qidianMirror.recordFailure(db, e);
        logger.warn('mirror: initial fetch failed', { msg: e.message });
      }
    }
  }, 5_000);

  scheduleNextMirrorRun(db);
}

function scheduleNextMirrorRun(db) {
  if (_mirrorTimer) clearTimeout(_mirrorTimer);

  const now = new Date();
  const target = new Date(now);
  target.setHours(0, 0, 0, 0);
  const randomMs = Math.floor(Math.random() * 7 * 3600 * 1000);
  target.setTime(target.getTime() + randomMs);

  if (target.getTime() <= now.getTime()) {
    target.setDate(target.getDate() + 1);
    target.setHours(0, 0, 0, 0);
    target.setTime(target.getTime() + Math.floor(Math.random() * 7 * 3600 * 1000));
  }

  const delayMs = target.getTime() - now.getTime();
  _nextMirrorRunAt = target.toISOString();
  logger.info('mirror: next run scheduled', { at: _nextMirrorRunAt, delayMin: Math.round(delayMs / 60_000) });

  _mirrorTimer = setTimeout(async () => {
    try {
      // 整体兜底超时: 防止上游无超时卡死导致后续镜像永久停摆
      const r = await Promise.race([
        qidianMirror.fetchAndCache(db),
        new Promise((_, rej) => setTimeout(() => rej(new Error('mirror run timed out (10min)')), 10 * 60 * 1000)),
      ]);
      logger.info('mirror: scheduled fetch ok', r);
    } catch (e) {
      qidianMirror.recordFailure(db, e);
      logger.warn('mirror: scheduled fetch failed', { msg: e.message });
    } finally {
      scheduleNextMirrorRun(db);
    }
  }, delayMs);
  _mirrorTimer.unref?.();
}

module.exports = { scheduleMirrorJob, getNextRunAt };
