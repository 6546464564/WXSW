// 万象书屋后端 · legadoEngine 纯函数单元测试
//
// 不联网, 直接测 HTML 规则引擎的规则解析:
//   resolveUrl / evalRule / evalListRule (CSS 选择器 + ##正则 + @链式 + ||备选)
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const cheerio = require('cheerio');
const { resolveUrl, evalRule, evalListRule } = require('../jobs/legadoEngine.js');

function load(html) {
  return cheerio.load(html);
}

// ─── resolveUrl ───

test('resolveUrl: 绝对/协议相对/路径相对', () => {
  assert.equal(resolveUrl('https://a.com/b/', 'https://c.com/x'), 'https://c.com/x');
  assert.equal(resolveUrl('https://a.com/b/', '//cdn.x.com/img.png'), 'https://cdn.x.com/img.png');
  assert.equal(resolveUrl('https://a.com/b/page', '../img.png'), 'https://a.com/img.png');
  assert.equal(resolveUrl('', 'https://x.com/y'), 'https://x.com/y');
  assert.equal(resolveUrl('https://a.com/', ''), '');
  // 非法相对且 base 不可解析 → 原样返回
  assert.equal(resolveUrl('not-a-url', 'some/path'), 'some/path');
});

// ─── evalRule ───

test('evalRule: css 选择器 + text 提取', () => {
  const $ = load('<div class="book"><h1>斗破苍穹</h1><p class="author">天蚕土豆</p></div>');
  const el = $('body');
  assert.equal(evalRule($, el, '.book h1@text'), '斗破苍穹');
  assert.equal(evalRule($, el, '.book@text'), '斗破苍穹天蚕土豆');
  assert.equal(evalRule($, el, '.book p.author@text'), '天蚕土豆');
});

test('evalRule: href/src 相对转绝对', () => {
  const $ = load('<div class="list"><a href="/book/123">链接</a><img src="//cdn.x.com/c.jpg"></div>');
  const el = $('.list');
  assert.equal(evalRule($, el, 'a@href', 'https://site.com/x/'), 'https://site.com/book/123');
  assert.equal(evalRule($, el, 'img@src', 'https://site.com/x/'), 'https://cdn.x.com/c.jpg');
});

test('evalRule: ## 正则过滤', () => {
  const $ = load('<div class="t">第1章 斗破苍穹</div>');
  const el = $('.t');
  assert.equal(evalRule($, el, '@text##第\\d+章\\s*'), '斗破苍穹');
  // 多段过滤
  assert.equal(evalRule($, el, '@text##第\\d+章\\s*##斗破'), '苍穹');
});

test('evalRule: || 备选 (首个命中返回)', () => {
  const $ = load('<div class="a"><span>值A</span></div><div class="b"><span>值B</span></div>');
  const el = $('body');
  assert.equal(evalRule($, el, '.b span@text||.a span@text'), '值B');
  assert.equal(evalRule($, el, '.nonexist@text||.a span@text'), '值A');
  assert.equal(evalRule($, el, '.nonexist@text||.also-none@text'), '');
});

test('evalRule: id./class./tag. 前缀', () => {
  const $ = load('<div id="title">书名</div><p class="desc">简介内容</p><h2>标题二</h2>');
  const el = $('body');
  assert.equal(evalRule($, el, 'id.title@text'), '书名');
  assert.equal(evalRule($, el, 'class.desc@text'), '简介内容');
  assert.equal(evalRule($, el, 'tag.h2@text'), '标题二');
});

test('evalRule: html 提取', () => {
  const $ = load('<div class="c"><p>正文</p></div>');
  const el = $('.c');
  assert.equal(evalRule($, el, '@html'), '<p>正文</p>');
});

test('evalRule: 非法规则容错', () => {
  const $ = load('<div>内容</div>');
  const el = $('div');
  assert.equal(evalRule($, el, ''), '');
  assert.equal(evalRule($, el, null), '');
  // 不存在的选择器 → 空
  assert.equal(evalRule($, el, '.nope@text'), '');
});

// ─── evalListRule ───

test('evalListRule: 返回列表元素', () => {
  const $ = load('<ul class="list"><li class="item">A</li><li class="item">B</li><li class="item">C</li></ul>');
  const items = evalListRule($, 'ul.list li.item');
  assert.equal(items.length, 3);
  assert.equal(items[0].text().trim(), 'A');
  assert.equal(items[2].text().trim(), 'C');
});

test('evalListRule: 链式 @', () => {
  const $ = load('<div class="box"><div class="row"><p>1</p></div><div class="row"><p>2</p></div></div>');
  const items = evalListRule($, '.box@.row@p');
  assert.equal(items.length, 2);
});

test('evalListRule: 空规则返回空数组', () => {
  const $ = load('<div></div>');
  assert.deepEqual(evalListRule($, ''), []);
  assert.deepEqual(evalListRule($, null), []);
  // 无命中 → 空
  assert.deepEqual(evalListRule($, '.nothing'), []);
});
