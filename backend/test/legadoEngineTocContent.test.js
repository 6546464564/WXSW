// 万象书屋后端 · legadoEngine 目录/内容/详情 链路测试 (mock fetch, 不联网)
//
// 覆盖:
//   - resolveBookInfo: 无规则直返 / $.路径 tocUrl
//   - fetchToc:        HTML 选择器规则 + JS 规则 + 无 chapterList 抛错
//   - fetchContent:    默认规则 / HTML 规则 / JS 规则 / <br>/<p> 清洗
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

// ─── global.fetch mock ───
const responses = new Map();
global.fetch = async (url) => {
  const u = typeof url === 'string' ? url : url.href;
  const body = responses.get(u);
  if (body === undefined) return { ok: false, status: 404, text: async () => 'not found' };
  return { ok: true, status: 200, text: async () => body };
};

function mockFetch(url, body) { responses.set(url, body); }

const { resolveBookInfo, fetchToc, fetchContent } = require('../jobs/legadoEngine.js');

// ─── resolveBookInfo ───

test('resolveBookInfo: 无规则直接返回 bookUrl', async () => {
  const src = { bookSourceUrl: 'https://x.com' };
  const r = await resolveBookInfo(src, 'https://x.com/book/1');
  assert.equal(r.tocUrl, 'https://x.com/book/1');
});

test('resolveBookInfo: $.路径 tocUrl 从 bookInfo 取', async () => {
  const src = {
    bookSourceUrl: 'https://x.com',
    ruleBookInfo: { tocUrl: '$.toc' },
  };
  mockFetch('https://x.com/book/2', JSON.stringify({ title: '书', toc: 'https://x.com/catalog/2' }));
  const r = await resolveBookInfo(src, 'https://x.com/book/2');
  assert.equal(r.tocUrl, 'https://x.com/catalog/2');
});

// ─── fetchToc ───

test('fetchToc: HTML 选择器规则', async () => {
  const src = {
    bookSourceUrl: 'https://toc.example.com',
    ruleToc: {
      chapterList: 'ul.chapters li',
      chapterName: 'a@text',
      chapterUrl: 'a@href',
    },
  };
  mockFetch('https://toc.example.com/book/1', `
    <ul class="chapters">
      <li><a href="/c/1">第一章</a></li>
      <li><a href="/c/2">第二章</a></li>
      <li><a href="/c/3">第三章</a></li>
    </ul>`);
  const toc = await fetchToc(src, 'https://toc.example.com/book/1');
  assert.equal(toc.length, 3);
  assert.equal(toc[0].title, '第一章');
  assert.equal(toc[0].url, 'https://toc.example.com/c/1');
});

test('fetchToc: JS 规则 (JSONPath)', async () => {
  const src = {
    bookSourceUrl: 'https://tocjs.example.com',
    ruleToc: {
      chapterList: '$.data.list',
      chapterName: '$.t',
      chapterUrl: '$.u',
    },
  };
  mockFetch('https://tocjs.example.com/book/1', JSON.stringify({
    data: { list: [{ t: '序章', u: '/c/0' }, { t: '第1章', u: '/c/1' }] },
  }));
  const toc = await fetchToc(src, 'https://tocjs.example.com/book/1');
  assert.equal(toc.length, 2);
  assert.equal(toc[0].title, '序章');
  assert.equal(toc[0].url, 'https://tocjs.example.com/c/0');
});

test('fetchToc: 无 chapterList 规则抛错', async () => {
  const src = { bookSourceUrl: 'https://x.com', ruleToc: {} };
  mockFetch('https://x.com/book/1', '<html></html>');
  await assert.rejects(fetchToc(src, 'https://x.com/book/1'), /no chapterList rule/);
});

// ─── fetchContent ───

test('fetchContent: 默认 id.content@html 规则', async () => {
  const src = { bookSourceUrl: 'https://content.example.com' };
  mockFetch('https://content.example.com/ch/1', '<html><body><div id="content"><p>第一段</p><br>第二行</div></body></html>');
  const content = await fetchContent(src, 'https://content.example.com/ch/1');
  assert.ok(content.includes('第一段'), '应含第一段');
  assert.ok(content.includes('第二行'), '应含第二行');
});

test('fetchContent: 自定义 HTML 规则 + 翻页', async () => {
  const src = {
    bookSourceUrl: 'https://content.example.com',
    ruleContent: {
      content: '.chapter-content@html',
      nextContentUrl: '.next-page a@href',
    },
  };
  mockFetch('https://content.example.com/ch/2', `<div class="chapter-content"><p>第一页正文</p></div><div class="next-page"><a href="/ch/2-p2">下一页</a></div>`);
  mockFetch('https://content.example.com/ch/2-p2', `<div class="chapter-content"><p>第二页正文</p></div>`);
  const content = await fetchContent(src, 'https://content.example.com/ch/2');
  assert.ok(content.includes('第一页正文'));
  assert.ok(content.includes('第二页正文'), '翻页内容应拼接');
});

test('fetchContent: JS 规则 (@js: 内联)', async () => {
  const src = {
    bookSourceUrl: 'https://contentjs.example.com',
    ruleContent: { content: '@js:JSON.parse(result).data.text' },
  };
  mockFetch('https://contentjs.example.com/ch/1', JSON.stringify({ data: { text: '这是正文内容' } }));
  const content = await fetchContent(src, 'https://contentjs.example.com/ch/1');
  assert.equal(content, '这是正文内容');
});
