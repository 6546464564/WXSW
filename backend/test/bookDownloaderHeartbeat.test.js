// 万象书屋: bookDownloader 慢速下载心跳回归测试
// 跑法: cd backend && node --test test/bookDownloaderHeartbeat.test.js
//
// 背景: backend/db.js cleanupOldData 每 30 分钟跑一次, 把 status IN
// ('searching','downloading') 且 updated_at 超过 1 小时的书重置为 pending.
// 旧逻辑只在每 100 章里程碑时刷新 updated_at — 慢速下载 (IP 封禁冷却/代理延迟/
// 低并发) 合法超过 1 小时时会被误判卡死, 下一轮 processParallel 重复拉起同一本书
// 并发下载两遍. 修复: 下载期间每 30s 心跳刷新 updated_at.
// 本测试验证: 心跳 interval 确实以 30s 注册, 且回调会触发 refreshCachedBookCount.

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');

describe('bookDownloader — 下载心跳刷新 updated_at', () => {
  let engine;
  let origToc, origContent, origSleep;
  let origSetInterval, origClearInterval;
  let heartbeatFn = null;
  let intervalMs = null;
  let refreshCount = 0;

  before(() => {
    engine = require('../jobs/legadoEngine');
    origToc = engine.fetchToc;
    origContent = engine.fetchContent;
    origSleep = engine.sleep;
    engine.fetchToc = async () => [
      { title: 'c1', url: 'https://public.example/c1' },
      { title: 'c2', url: 'https://public.example/c2' },
    ];
    engine.fetchContent = async () => 'x'.repeat(100);
    engine.sleep = async () => {};

    origSetInterval = global.setInterval;
    origClearInterval = global.clearInterval;
    global.setInterval = (fn, ms) => {
      heartbeatFn = fn;
      intervalMs = ms;
      return { unref() {} };
    };
    global.clearInterval = () => {};
  });

  after(() => {
    engine.fetchToc = origToc;
    engine.fetchContent = origContent;
    engine.sleep = origSleep;
    global.setInterval = origSetInterval;
    global.clearInterval = origClearInterval;
  });

  test('下载期间注册 30s 心跳, 回调刷新 updated_at', async () => {
    const { downloadBook } = require('../jobs/bookDownloader');
    const db = {
      updateCachedBookStatus: () => {},
      updateCachedBookSource: () => {},
      updateCachedBookChapterCount: () => {},
      insertCachedChapters: () => {},
      getCachedChapter: () => null,
      saveCachedChapterContent: () => {},
      markCachedChapterError: () => {},
      refreshCachedBookCount: () => { refreshCount++; },
    };
    const bookRow = {
      id: 7, title: '测试书', author: '作者',
      source_url: 'https://public.example',
      source_book_url: 'https://public.example/book',
    };
    const sources = [{ bookSourceUrl: 'https://public.example', bookSourceName: 's1' }];

    const ok = await downloadBook(db, bookRow, sources);
    assert.equal(ok, true);
    assert.equal(intervalMs, 30_000, '心跳必须以 30s 周期注册');
    assert.ok(heartbeatFn, '必须注册心跳回调');

    refreshCount = 0;
    heartbeatFn(); // 模拟一个心跳 tick
    assert.ok(refreshCount >= 1, '心跳 tick 必须刷新 updated_at (refreshCachedBookCount)');
  });
});
