// 万象书屋: sourceValidator 单元测试
// 跑法: cd backend && node --test test/
// 不引入 jest 等额外依赖, 用 Node 22 自带的 node:test.

const { test, describe } = require('node:test');
const assert = require('node:assert/strict');

const { validateShape, severityOf, renderSearchUrl } = require('../sourceValidator');

describe('validateShape — 基础字段', () => {
  test('空对象返 error', () => {
    const r = validateShape({});
    assert.equal(severityOf(r.issues), 'error');
    assert.ok(r.issues.some(i => i.field === 'bookSourceUrl'));
    assert.ok(r.issues.some(i => i.field === 'bookSourceName'));
  });

  test('null / 数组 / 标量 → error _root', () => {
    for (const bad of [null, [], 'string', 42]) {
      const r = validateShape(bad);
      assert.equal(severityOf(r.issues), 'error');
      assert.ok(r.issues.some(i => i.field === '_root'));
    }
  });

  test('非 http/https URL 被拒', () => {
    const r = validateShape({
      bookSourceUrl: 'ftp://example.com/',
      bookSourceName: 'x',
    });
    assert.ok(r.issues.some(i => i.field === 'bookSourceUrl' && i.severity === 'error'));
  });

  test('合法最小集: http url + name → warn (缺 ruleSearch/Toc) 但非 error', () => {
    const r = validateShape({
      bookSourceUrl: 'https://example.com/',
      bookSourceName: 'x',
      bookSourceType: 0,
    });
    assert.notEqual(severityOf(r.issues), 'error');
  });
});

describe('validateShape — header / searchUrl / ruleSearch', () => {
  test('header 不是 JSON 字符串 → warn', () => {
    const r = validateShape({
      bookSourceUrl: 'https://x.com/',
      bookSourceName: 'x',
      header: 'not a json {{{',
    });
    assert.ok(r.issues.some(i => i.field === 'header' && i.severity === 'warn'));
  });

  test('searchUrl 缺 {{key}} → warn', () => {
    const r = validateShape({
      bookSourceUrl: 'https://x.com/',
      bookSourceName: 'x',
      searchUrl: '/search?q=fixed',
    });
    assert.ok(r.issues.some(i => i.field === 'searchUrl' && i.severity === 'warn'));
  });

  test('配了 searchUrl 但缺 ruleSearch → warn', () => {
    const r = validateShape({
      bookSourceUrl: 'https://x.com/',
      bookSourceName: 'x',
      searchUrl: '/s?k={{key}}',
    });
    assert.ok(r.issues.some(i => i.field === 'ruleSearch' && i.severity === 'warn'));
  });

  test('ruleSearch.bookList 空 → warn', () => {
    const r = validateShape({
      bookSourceUrl: 'https://x.com/',
      bookSourceName: 'x',
      searchUrl: '/s?k={{key}}',
      ruleSearch: { name: 'a', bookUrl: 'b' },
    });
    assert.ok(r.issues.some(i => i.field === 'ruleSearch.bookList'));
  });
});

describe('validateShape — 文本书源 toc/content', () => {
  test('bookSourceType=0 但缺 ruleToc.chapterList → warn', () => {
    const r = validateShape({
      bookSourceUrl: 'https://x.com/',
      bookSourceName: 'x',
      bookSourceType: 0,
    });
    assert.ok(r.issues.some(i => i.field === 'ruleToc.chapterList'));
    assert.ok(r.issues.some(i => i.field === 'ruleContent.content'));
  });

  test('bookSourceType=2 (图片) 不要求 ruleToc', () => {
    const r = validateShape({
      bookSourceUrl: 'https://x.com/',
      bookSourceName: 'x',
      bookSourceType: 2,
    });
    assert.ok(!r.issues.some(i => i.field === 'ruleToc.chapterList'));
  });
});

describe('renderSearchUrl', () => {
  test('{{key}} 替换并与 bookSourceUrl 拼接', () => {
    const u = renderSearchUrl(
      {
        bookSourceUrl: 'https://example.com/',
        searchUrl: '/s?k={{key}}',
      },
      '修真'
    );
    assert.ok(u.startsWith('https://example.com/s?k='));
    assert.ok(u.includes(encodeURIComponent('修真')));
  });

  test('带空白的 {{ key }} 也能替换', () => {
    const u = renderSearchUrl(
      { bookSourceUrl: 'https://x.com/', searchUrl: '/s?k={{ key }}' },
      'abc'
    );
    assert.ok(u.includes('k=abc'));
  });

  test('searchUrl 缺失 → null', () => {
    assert.equal(renderSearchUrl({ bookSourceUrl: 'https://x.com/' }), null);
  });

  test('逗号后的 POST body 被剥掉, 只取 URL', () => {
    const u = renderSearchUrl(
      {
        bookSourceUrl: 'https://x.com/',
        searchUrl: '/api,{"method":"POST","body":"q={{key}}"}',
      },
      'test'
    );
    // 逗号前是 /api, 拼接后为 https://x.com/api
    assert.ok(u.startsWith('https://x.com/api'));
  });
});

describe('severityOf', () => {
  test('error 压倒一切', () => {
    assert.equal(severityOf([{ severity: 'warn' }, { severity: 'error' }]), 'error');
  });
  test('warn > info > ok', () => {
    assert.equal(severityOf([{ severity: 'warn' }, { severity: 'info' }]), 'warn');
    assert.equal(severityOf([{ severity: 'info' }]), 'info');
    assert.equal(severityOf([]), 'ok');
  });
});
