// 万象书屋后端 · bookDownloader 下载流程单元测试
//
// mock legadoEngine + db, 覆盖 downloadBook 主流程的各类路径:
//   1. 绑定源直接下载成功
//   2. 无绑定源 → 搜索 → 下载成功
//   3. 搜索不到 → not_found
//   4. 绑定源 TOC 失败 → 重新搜索 → 成功 / 仍失败
//   5. 空章节列表 → error
//   6. 章节错误过多 → error
//   7. loadCompatibleSources 过滤逻辑
'use strict';

const { test, describe, before, after } = require('node:test');
const assert = require('node:assert/strict');

describe('bookDownloader — 下载流程', () => {
  let engine;
  let origToc, origContent, origSearch, origSleep;
  let origSetIntervalGlobal, origClearIntervalGlobal;
  let setIntervalCb, setIntervalMs;

  before(() => {
    engine = require('../jobs/legadoEngine');
    origToc = engine.fetchToc;
    origContent = engine.fetchContent;
    origSearch = engine.searchBook;
    origSleep = engine.sleep;

    const origSetInterval = global.setInterval;
    const origClearInterval = global.clearInterval;
    global.setInterval = (fn, ms) => { setIntervalCb = fn; setIntervalMs = ms; return { unref() {} }; };
    global.clearInterval = () => {};

    origSetIntervalGlobal = origSetInterval;
    origClearIntervalGlobal = origClearInterval;
  });

  after(() => {
    engine.fetchToc = origToc;
    engine.fetchContent = origContent;
    engine.searchBook = origSearch;
    engine.sleep = origSleep;
    global.setInterval = origSetIntervalGlobal;
    global.clearInterval = origClearIntervalGlobal;
  });

  function makeDb(overrides = {}) {
    const calls = { statuses: [], sources: [] };
    const db = {
      updateCachedBookStatus: (id, status, msg) => calls.statuses.push([status, msg]),
      updateCachedBookSource: (id, info) => calls.sources.push(info),
      updateCachedBookChapterCount: () => {},
      insertCachedChapters: () => {},
      getCachedChapter: () => null,
      saveCachedChapterContent: () => {},
      markCachedChapterError: () => {},
      refreshCachedBookCount: () => {},
      __db: { prepare: () => ({ all: () => [] }) },
      ...overrides,
    };
    return { db, calls };
  }

  test('绑定源存在 → 直接下载成功', async () => {
    engine.fetchToc = async () => [
      { title: 'c1', url: 'https://public.example/c1' },
      { title: 'c2', url: 'https://public.example/c2' },
    ];
    engine.fetchContent = async () => 'x'.repeat(100);
    engine.sleep = async () => {};
    engine.searchBook = async () => { throw new Error('不应走搜索'); };

    const { db, calls } = makeDb();
    const bookRow = { id: 1, title: '绑定书', author: '作者', source_url: 'https://bound.example', source_book_url: 'https://bound.example/book' };
    const sources = [{ bookSourceUrl: 'https://bound.example', bookSourceName: '绑定源' }];

    const ok = await require('../jobs/bookDownloader').downloadBook(db, bookRow, sources);
    assert.equal(ok, true);
    assert.equal(setIntervalMs, 30_000);
    assert.ok(calls.statuses.some(s => s[0] === 'done'), '最终状态应为 done');
  });

  test('无绑定源 → 搜索命中 → 下载成功', async () => {
    engine.fetchToc = async () => [{ title: 'c1', url: 'https://s.example/c1' }];
    engine.fetchContent = async () => 'y'.repeat(100);
    engine.sleep = async () => {};
    engine.searchBook = async (src, kw) => {
      assert.equal(kw, '搜索书');
      return [{ name: '搜索书', author: '作者', bookUrl: 'https://s.example/book', coverUrl: '', intro: '' }];
    };

    const { db, calls } = makeDb();
    const bookRow = { id: 2, title: '搜索书', author: '作者' };
    const sources = [{ bookSourceUrl: 'https://s.example', bookSourceName: '搜索源' }];

    const ok = await require('../jobs/bookDownloader').downloadBook(db, bookRow, sources);
    assert.equal(ok, true);
    assert.ok(calls.sources.length === 1, '应记录绑定源信息');
    assert.ok(calls.statuses.some(s => s[0] === 'downloading'), '应有 downloading 状态');
    assert.ok(calls.statuses.some(s => s[0] === 'done'));
  });

  test('搜索不到 → not_found', async () => {
    engine.searchBook = async () => [];
    engine.sleep = async () => {};

    const { db, calls } = makeDb();
    const bookRow = { id: 3, title: '没有的书', author: '' };
    const ok = await require('../jobs/bookDownloader').downloadBook(db, bookRow, [{ bookSourceUrl: 'https://s.example' }]);
    assert.equal(ok, false);
    const notFound = calls.statuses.find(s => s[0] === 'not_found');
    assert.ok(notFound, '应有 not_found 状态');
  });

  test('绑定源 TOC 失败 → 重新搜索 → 成功', async () => {
    let tocCalls = 0;
    engine.fetchToc = async () => {
      tocCalls++;
      if (tocCalls === 1) throw new Error('TOC blocked');
      return [{ title: 'c1', url: 'https://new.example/c1' }];
    };
    engine.fetchContent = async () => 'z'.repeat(100);
    engine.sleep = async () => {};
    engine.searchBook = async () => [{ name: '书', author: '作者', bookUrl: 'https://new.example/book', coverUrl: '', intro: '' }];

    const { db, calls } = makeDb();
    const bookRow = { id: 4, title: '书', author: '作者', source_url: 'https://dead.example', source_book_url: 'https://dead.example/book' };
    const sources = [
      { bookSourceUrl: 'https://dead.example', bookSourceName: '死源' },
      { bookSourceUrl: 'https://new.example', bookSourceName: '新源' },
    ];

    const ok = await require('../jobs/bookDownloader').downloadBook(db, bookRow, sources);
    assert.equal(ok, true, '重新搜索后应成功');
    assert.equal(tocCalls, 2);
  });

  test('绑定源 TOC 失败且重搜也失败 → error', async () => {
    engine.fetchToc = async () => { throw new Error('TOC dead'); };
    engine.searchBook = async () => [];
    engine.sleep = async () => {};

    const { db, calls } = makeDb();
    const bookRow = { id: 5, title: '书', author: '', source_url: 'https://dead.example', source_book_url: 'https://dead.example/book' };
    const ok = await require('../jobs/bookDownloader').downloadBook(db, bookRow, [{ bookSourceUrl: 'https://dead.example' }]);
    assert.equal(ok, false);
    const err = calls.statuses.find(s => s[0] === 'error');
    assert.ok(err, '应有 error 状态');
  });

  test('空章节列表 → error', async () => {
    engine.fetchToc = async () => [];
    engine.fetchContent = async () => 'x';
    engine.sleep = async () => {};
    engine.searchBook = async () => [];

    const { db, calls } = makeDb();
    const bookRow = { id: 6, title: '空书', author: '', source_url: 'https://s.example', source_book_url: 'https://s.example/book' };
    const ok = await require('../jobs/bookDownloader').downloadBook(db, bookRow, [{ bookSourceUrl: 'https://s.example' }]);
    assert.equal(ok, false);
    assert.ok(calls.statuses.some(s => s[0] === 'error' && s[1] === 'Empty chapter list'));
  });

  test('章节错误过多 → error', async () => {
    engine.fetchToc = async () => Array.from({ length: 10 }, (_, i) => ({ title: `c${i}`, url: `https://s.example/c${i}` }));
    engine.fetchContent = async () => { throw new Error('fetch fail'); };
    engine.sleep = async () => {};
    engine.searchBook = async () => [];

    const { db, calls } = makeDb();
    const bookRow = { id: 7, title: '全错书', author: '', source_url: 'https://s.example', source_book_url: 'https://s.example/book' };
    const ok = await require('../jobs/bookDownloader').downloadBook(db, bookRow, [{ bookSourceUrl: 'https://s.example' }]);
    assert.equal(ok, false);
    assert.ok(calls.statuses.some(s => s[0] === 'error' && String(s[1]).startsWith('Too many errors')), '应报 Too many errors');
  });

  test('章节内容过短 → markCachedChapterError', async () => {
    engine.fetchToc = async () => [{ title: 'c1', url: 'https://s.example/c1' }];
    engine.fetchContent = async () => 'short';
    engine.sleep = async () => {};
    engine.searchBook = async () => [];

    let marked = 0;
    const { db, calls } = makeDb({ markCachedChapterError: () => { marked++; } });
    const bookRow = { id: 8, title: '短内容书', author: '', source_url: 'https://s.example', source_book_url: 'https://s.example/book' };
    await require('../jobs/bookDownloader').downloadBook(db, bookRow, [{ bookSourceUrl: 'https://s.example' }]);
    assert.equal(marked, 1, '过短内容应标记 error');
  });

  test('loadCompatibleSources: 过滤无 searchUrl 源', () => {
    const { loadCompatibleSources } = require('../jobs/bookDownloader');
    const rows = [
      { json: JSON.stringify({ bookSourceUrl: 'https://a.example', bookSourceName: 'A', searchUrl: '/s', ruleSearch: { bookList: 'li' } }) },
      { json: JSON.stringify({ bookSourceUrl: 'https://b.example', bookSourceName: 'B' }) }, // 无 searchUrl
      { json: 'not json' }, // 坏 JSON
      { json: JSON.stringify({ bookSourceUrl: 'https://c.example', bookSourceName: 'C', searchUrl: '/s' }) }, // 无 bookList
    ];
    const db = { __db: { prepare: () => ({ all: () => rows }) } };
    const srcs = loadCompatibleSources(db);
    assert.equal(srcs.length, 1);
    assert.equal(srcs[0].bookSourceUrl, 'https://a.example');
  });

  test('loadCompatibleSources: DL_SOURCE_FILTER 过滤', () => {
    process.env.DL_SOURCE_FILTER = 'https://keep.example,https://nope.example';
    try {
      const { loadCompatibleSources } = require('../jobs/bookDownloader');
      const rows = [
        { json: JSON.stringify({ bookSourceUrl: 'https://keep.example', bookSourceName: 'K', searchUrl: '/s', ruleSearch: { bookList: 'li' } }) },
        { json: JSON.stringify({ bookSourceUrl: 'https://drop.example', bookSourceName: 'D', searchUrl: '/s', ruleSearch: { bookList: 'li' } }) },
      ];
      const db = { __db: { prepare: () => ({ all: () => rows }) } };
      const srcs = loadCompatibleSources(db);
      assert.equal(srcs.length, 1);
      assert.equal(srcs[0].bookSourceUrl, 'https://keep.example');
    } finally {
      delete process.env.DL_SOURCE_FILTER;
    }
  });
});
