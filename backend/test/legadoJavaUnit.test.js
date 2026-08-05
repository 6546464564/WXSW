// 万象书屋后端 · legadoJava 兼容层单元测试 (不联网)
//
// 覆盖 JS 规则引擎的 Java 兼容 API:
//   createSourceApi / evalTemplate / evalJsonPath / evalJsInline /
//   evalJsBlock / buildWanxiangHeaders
'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createSourceApi, evalTemplate, evalJsonPath, evalJsInline,
  evalJsBlock, buildWanxiangHeaders,
} = require('../jobs/legadoJava.js');

// ─── createSourceApi ───

test('createSourceApi: 透传书源字段', () => {
  const api = createSourceApi({
    bookSourceUrl: 'https://s.com', bookSourceName: '测试源',
    bookSourceGroup: '组', bookSourceComment: '注释', header: 'h',
  });
  assert.equal(api.getKey(), 'https://s.com');
  assert.equal(api.bookSourceName, '测试源');
  assert.equal(api.bookSourceGroup, '组');
  // 空源不崩
  const empty = createSourceApi({});
  assert.equal(empty.getKey(), '');
});

// ─── evalTemplate ───

test('evalTemplate: 无模板原样返回', () => {
  assert.equal(evalTemplate('abc', {}), 'abc');
  assert.equal(evalTemplate('', {}), '');
  assert.equal(evalTemplate(null, {}), null);
});

test('evalTemplate: {{key}} 替换', () => {
  assert.equal(evalTemplate('/s?k={{key}}', { keyword: '斗破' }), '/s?k=斗破');
});

test('evalTemplate: JSONPath 表达式', () => {
  const r = evalTemplate('{{$.data.id}}', { result: JSON.stringify({ data: { id: '42' } }) });
  assert.equal(r, '42');
});

test('evalTemplate: 表达式失败 → 空串', () => {
  assert.equal(evalTemplate('{{$..nope}}', { result: 'x' }), '');
  assert.equal(evalTemplate('{{undefinedVar}}', {}), '');
});

// ─── evalJsonPath ───

test('evalJsonPath: $. 与 $.. 提取', () => {
  const json = { a: { b: 1 }, list: [{ c: 'x' }, { c: 'y' }] };
  assert.deepEqual(evalJsonPath(json, '$.a.b'), [1]);
  assert.deepEqual(evalJsonPath(json, '$.list[*].c'), ['x', 'y']);
  assert.deepEqual(evalJsonPath(json, '$..c'), ['x', 'y']);
  // 不存在的路径 → 空数组
  assert.deepEqual(evalJsonPath(json, '$..nonexistent'), []);
  // JSON 字符串输入
  assert.deepEqual(evalJsonPath(JSON.stringify(json), '$.a.b'), [1]);
});

// ─── evalJsInline ───

test('evalJsInline: 内联表达式运算', () => {
  const java = (() => { /* 简化 java API 桩 */ return {}; })();
  const r = evalJsInline('result + "!"', 'hello', { java });
  assert.equal(r, 'hello!');
});

test('evalJsInline: 表达式抛错 → 返回原始 result', () => {
  const r = evalJsInline('throw new Error("x")', 'orig', {});
  assert.equal(r, 'orig');
});

// ─── evalJsBlock ───

test('evalJsBlock: <js> 块返回 lastExpr', () => {
  const source = { bookSourceUrl: 'https://js.example.com' };
  const r = evalJsBlock('"block-" + result', { result: 'R', _source: source });
  assert.equal(r, 'block-R');
});

test('evalJsBlock: 失败 → 返回原 result', () => {
  const r = evalJsBlock('throw new Error("boom")', { result: 'keep' });
  assert.equal(r, 'keep');
});

// ─── buildWanxiangHeaders ───

test('buildWanxiangHeaders: @js: 规则生成对象头', () => {
  const source = {
    bookSourceUrl: 'https://h.example.com',
    header: '@js:({ "User-Agent": "Wanxiang/1.0", "X-Token": "abc" })',
  };
  const headers = buildWanxiangHeaders(source, {});
  assert.equal(headers['User-Agent'], 'Wanxiang/1.0');
  assert.equal(headers['X-Token'], 'abc');
});

test('buildWanxiangHeaders: 非 @js: 或无规则 → 空对象', () => {
  assert.deepEqual(buildWanxiangHeaders({ bookSourceUrl: 'x', header: 'plain text' }, {}), {});
  assert.deepEqual(buildWanxiangHeaders({ bookSourceUrl: 'x' }, {}), {});
});
