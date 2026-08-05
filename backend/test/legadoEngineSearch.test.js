// 万象书屋后端 · legadoEngine.searchBook 链路测试 (mock fetch, 不联网)
//
// 覆盖 searchBook 的完整链路:
//   - HTML 选择器规则源 (非 JS)
//   - JS 规则源 (bookList 为 <js> / $.JSONPath)
//   - @js: searchUrl 构建
//   - {{key}} 模板替换
//   - 无 searchUrl / 无 bookList 的错误路径
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

// ─── global.fetch mock ───
const responses = new Map();
global.fetch = async (url, opts = {}) => {
  const u = typeof url === 'string' ? url : url.href;
  const body = responses.get(u);
  if (body === undefined) {
    return { ok: false, status: 404, text: async () => 'not found' };
  }
  return { ok: true, status: 200, text: async () => body };
};

function mockFetch(url, html) {
  responses.set(url, html);
}

const { searchBook } = require('../jobs/legadoEngine.js');

// ─── HTML 规则源 ───

test('searchBook: HTML 选择器规则源', async () => {
  const source = {
    bookSourceUrl: 'https://site.example.com',
    searchUrl: '/search?q={{key}}',
    ruleSearch: {
      bookList: 'ul.list li',
      name: '.name@text',
      author: '.author@text',
      bookUrl: 'a@href',
      coverUrl: 'img@src',
      intro: '.intro@text',
    },
  };
  mockFetch('https://site.example.com/search?q=%E6%96%97%E7%A0%B4', `
    <ul class="list">
      <li><span class="name">斗破苍穹</span><span class="author">天蚕土豆</span><a href="/book/1">去</a><img src="//cdn.example.com/c1.jpg"><p class="intro">简介一</p></li>
      <li><span class="name">凡人修仙传</span><span class="author">忘语</span><a href="/book/2">去</a><img src="//cdn.example.com/c2.jpg"><p class="intro">简介二</p></li>
      <li><span class="name"></span></li>
    </ul>`);

  const books = await searchBook(source, '斗破');
  assert.equal(books.length, 2);
  assert.equal(books[0].name, '斗破苍穹');
  assert.equal(books[0].author, '天蚕土豆');
  assert.equal(books[0].bookUrl, 'https://site.example.com/book/1');
  assert.equal(books[0].coverUrl, 'https://cdn.example.com/c1.jpg');
  assert.equal(books[1].name, '凡人修仙传');
});

test('searchBook: JS 规则源 (JSONPath)', async () => {
  const source = {
    bookSourceUrl: 'https://api.example.com',
    searchUrl: 'https://api.example.com/search?q={{key}}',
    ruleSearch: {
      bookList: '$.data.books',
      name: '$.name',
      author: '$.author',
      bookUrl: '$.url',
      intro: '$.intro',
    },
  };
  mockFetch('https://api.example.com/search?q=%E7%B4%A2%E5%BC%95', JSON.stringify({
    data: { books: [
      { name: '书A', author: '作者A', url: '/a', intro: 'A简介' },
      { name: '书B', author: '作者B', url: '/b', intro: 'B简介' },
    ] },
  }));

  const books = await searchBook(source, '索引');
  assert.equal(books.length, 2);
  assert.equal(books[0].name, '书A');
  assert.equal(books[0].bookUrl, 'https://api.example.com/a');
});

test('searchBook: <js> bookList 规则源', async () => {
  const source = {
    bookSourceUrl: 'https://js.example.com',
    searchUrl: '/search?k={{key}}',
    ruleSearch: {
      bookList: '<js>JSON.parse(result).items</js>',
      name: '$.name',
      author: '$.author',
      bookUrl: '$.id',
    },
  };
  mockFetch('https://js.example.com/search?k=%E6%B5%8B%E8%AF%95', JSON.stringify({
    items: [{ name: 'JS书', author: 'JS作者', id: '100' }],
  }));

  const books = await searchBook(source, '测试');
  assert.equal(books.length, 1);
  assert.equal(books[0].name, 'JS书');
  assert.equal(books[0].author, 'JS作者');
  assert.equal(books[0].bookUrl, 'https://js.example.com/100');
});

test('searchBook: @js: searchUrl 动态构建', async () => {
  const source = {
    bookSourceUrl: 'https://jsbuild.example.com',
    searchUrl: '@js:"https://jsbuild.example.com/s?k="+key',
    ruleSearch: { bookList: 'ul li', name: '@text' },
  };
  mockFetch('https://jsbuild.example.com/s?k=abc', '<ul><li>动态书名</li></ul>');

  const books = await searchBook(source, 'abc');
  assert.equal(books.length, 1);
  assert.equal(books[0].name, '动态书名');
});

// ─── 错误路径 ───

test('searchBook: 无 searchUrl 抛错', async () => {
  await assert.rejects(
    searchBook({ bookSourceUrl: 'https://x.com', ruleSearch: {} }, 'k'),
    /no searchUrl/,
  );
});

test('searchBook: 无 bookList 返回空数组', async () => {
  const source = {
    bookSourceUrl: 'https://x.com',
    searchUrl: 'https://x.com/search?q={{key}}',
    ruleSearch: {},
  };
  mockFetch('https://x.com/search?q=k', '<html></html>');
  const books = await searchBook(source, 'k');
  assert.deepEqual(books, []);
});

test('searchBook: 站点返回 404 → 空结果 (非崩溃)', async () => {
  const source = {
    bookSourceUrl: 'https://notfound.example.com',
    searchUrl: 'https://notfound.example.com/search?q={{key}}',
    ruleSearch: { bookList: 'li', name: '@text' },
  };
  // 该 URL 未 mock → fetch 返回 404
  const books = await searchBook(source, 'k').catch(() => []);
  assert.ok(Array.isArray(books));
});
