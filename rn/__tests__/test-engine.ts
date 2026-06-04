/**
 * 万象书屋 RN · 规则引擎测试
 * 用模拟数据测试 CSS/JSON/Regex/JS/模板/&&/||/%% 全链路
 *
 * 运行: cd rn && npx tsx test-engine.ts
 */

// @ts-nocheck
import {RuleEngine} from './src/engine/RuleEngine';
import {BookSource} from './src/engine/types';

(globalThis as any).__DEV__ = true;

const engine = new RuleEngine();

let passed = 0;
let failed = 0;

function assert(cond: boolean, msg: string) {
  if (!cond) {
    console.error(`  ❌ FAIL: ${msg}`);
    failed++;
  } else {
    passed++;
  }
}

// ═══════════════════════════════════════
// 测试 1: CSS 选择器 + 属性提取
// ═══════════════════════════════════════
async function testCssSelector() {
  console.log('\n=== 测试 1: CSS 选择器 ===');

  const html = `
  <div class="result-list">
    <div class="result-item">
      <div class="pic"><img src="/cover/1.jpg"></div>
      <div class="detail"><a href="/book/123/">斗破苍穹</a></div>
      <div class="info">
        <p><span>作者：</span><span>天蚕土豆</span></p>
        <p><span>分类：</span><span>玄幻</span></p>
      </div>
      <div class="desc">一段精彩的简介</div>
    </div>
    <div class="result-item">
      <div class="pic"><img src="/cover/2.jpg"></div>
      <div class="detail"><a href="/book/456/">完美世界</a></div>
      <div class="info">
        <p><span>作者：</span><span>辰东</span></p>
        <p><span>分类：</span><span>仙侠</span></p>
      </div>
      <div class="desc">少年走向巅峰</div>
    </div>
  </div>`;

  const bookList = await engine.selectList('.result-item', html, {});
  console.log(`  bookList: ${bookList.length} 本`);
  assert(bookList.length === 2, `期望 2, 实际 ${bookList.length}`);

  const name = await engine.selectString('.detail a@text', bookList[0], {});
  console.log(`  name: "${name}"`);
  assert(name === '斗破苍穹', `期望 "斗破苍穹", 实际 "${name}"`);

  const href = await engine.selectString('.detail a@href', bookList[0], {});
  console.log(`  href: "${href}"`);
  assert(href === '/book/123/', `期望 "/book/123/", 实际 "${href}"`);

  const coverUrl = await engine.selectString('.pic img@src', bookList[0], {});
  console.log(`  coverUrl: "${coverUrl}"`);
  assert(coverUrl === '/cover/1.jpg', `期望 "/cover/1.jpg", 实际 "${coverUrl}"`);

  const intro = await engine.selectString('.desc@text', bookList[0], {});
  console.log(`  intro: "${intro}"`);
  assert(intro === '一段精彩的简介', `期望 "一段精彩的简介", 实际 "${intro}"`);

  console.log('  ✅ CSS 选择器 通过');
}

// ═══════════════════════════════════════
// 测试 2: JSONPath
// ═══════════════════════════════════════
async function testJsonPath() {
  console.log('\n=== 测试 2: JSONPath ===');

  const json = JSON.stringify({
    data: {
      books: [
        {title: '斗破苍穹', author: '天蚕土豆', url: '/b/1'},
        {title: '完美世界', author: '辰东', url: '/b/2'},
      ],
    },
  });

  const list = await engine.selectList('$.data.books', json, {});
  console.log(`  list: ${list.length} 本`);
  assert(list.length === 2, `期望 2, 实际 ${list.length}`);

  const first = list[0];
  const name = await engine.selectString('$.title', first, {});
  console.log(`  name: "${name}"`);
  assert(name === '斗破苍穹', `期望 "斗破苍穹", 实际 "${name}"`);

  const author = await engine.selectString('$.author', first, {});
  console.log(`  author: "${author}"`);
  assert(author === '天蚕土豆', `期望 "天蚕土豆", 实际 "${author}"`);

  console.log('  ✅ JSONPath 通过');
}

// ═══════════════════════════════════════
// 测试 3: ## regex 后处理
// ═══════════════════════════════════════
async function testRegexReplace() {
  console.log('\n=== 测试 3: ## regex 后处理 ===');

  const html = `<div id="info"><h1>书名</h1><p>类型</p><p>作  者：天蚕土豆</p></div>`;
  const result = await engine.selectString('#info p:nth-of-type(2)@text##作\\s*者：', html, {});
  console.log(`  result: "${result}"`);
  assert(result === '天蚕土豆', `期望 "天蚕土豆", 实际 "${result}"`);

  console.log('  ✅ ## regex 后处理 通过');
}

// ═══════════════════════════════════════
// 测试 4: || 短路 (fallback)
// ═══════════════════════════════════════
async function testOrFallback() {
  console.log('\n=== 测试 4: || fallback ===');

  const html = '<div><p class="real">B</p></div>';
  const result = await engine.selectString('.nonexist@text||.real@text', html, {});
  console.log(`  result: "${result}"`);
  assert(result === 'B', `期望 "B", 实际 "${result}"`);

  console.log('  ✅ || fallback 通过');
}

// ═══════════════════════════════════════
// 测试 5: && 串联
// ═══════════════════════════════════════
async function testAndChain() {
  console.log('\n=== 测试 5: && 串联 ===');

  const html = '<div class="list"><a href="/a">Link A</a><a href="/b">Link B</a></div>';
  const list = await engine.selectList('.list&&a@href', html, {});
  console.log(`  list: ${JSON.stringify(list)}`);
  assert(list.length === 2, `期望 2, 实际 ${list.length}`);
  assert(list[0] === '/a', `期望 "/a", 实际 "${list[0]}"`);
  assert(list[1] === '/b', `期望 "/b", 实际 "${list[1]}"`);

  console.log('  ✅ && 串联 通过');
}

// ═══════════════════════════════════════
// 测试 6: 目录解析 (chapterList → chapterName / chapterUrl)
// ═══════════════════════════════════════
async function testTocParsing() {
  console.log('\n=== 测试 6: 目录解析 ===');

  const tocHtml = `
  <div id="list">
    <dl>
      <dd><a href="/chapter/1.html">第一章 起源</a></dd>
      <dd><a href="/chapter/2.html">第二章 觉醒</a></dd>
      <dd><a href="/chapter/3.html">第三章 战斗</a></dd>
    </dl>
  </div>`;

  const chapters = await engine.selectList('#list dl dd a', tocHtml, {});
  console.log(`  chapters: ${chapters.length}`);
  assert(chapters.length === 3, `期望 3, 实际 ${chapters.length}`);

  const title = await engine.selectString('@text', chapters[0], {});
  console.log(`  title: "${title}"`);
  assert(title === '第一章 起源', `期望 "第一章 起源", 实际 "${title}"`);

  const url = await engine.selectString('@href', chapters[0], {});
  console.log(`  url: "${url}"`);
  assert(url === '/chapter/1.html', `期望 "/chapter/1.html", 实际 "${url}"`);

  console.log('  ✅ 目录解析 通过');
}

// ═══════════════════════════════════════
// 测试 7: 正文内容解析 + replaceRegex 净化
// ═══════════════════════════════════════
async function testContentParsing() {
  console.log('\n=== 测试 7: 正文解析 ===');

  const html = `
  <div id="content">
    <p>一秒记住笔趣阁免费阅读！</p>
    <p>萧炎的斗气从体内涌出，化作一团耀眼的光芒。</p>
    <p>"这不可能！"对手惊呼。</p>
  </div>`;

  const content = await engine.selectString('#content@html', html, {});
  console.log(`  raw content length: ${content.length}`);
  assert(content.length > 0, '正文不应为空');
  assert(content.includes('萧炎的斗气'), '应包含正文内容');
  assert(content.includes('一秒记住'), 'raw content 包含广告 (后续 replaceRegex 清)');

  console.log('  ✅ 正文解析 通过');
}

// ═══════════════════════════════════════
// 测试 8: @js: 规则
// ═══════════════════════════════════════
async function testJsRule() {
  console.log('\n=== 测试 8: @js: 规则 ===');

  const result = await engine.selectString(
    '@js:result.toUpperCase()',
    'hello world',
    {},
  );
  console.log(`  result: "${result}"`);
  assert(result === 'HELLO WORLD', `期望 "HELLO WORLD", 实际 "${result}"`);

  const numResult = await engine.selectString(
    '@js:String(parseInt(result) + 1)',
    '42',
    {},
  );
  console.log(`  numResult: "${numResult}"`);
  assert(numResult === '43', `期望 "43", 实际 "${numResult}"`);

  console.log('  ✅ @js: 规则 通过');
}

// ═══════════════════════════════════════
// 测试 9: {{key}} / {{page}} 模板展开
// ═══════════════════════════════════════
async function testTemplateExpansion() {
  console.log('\n=== 测试 9: 模板展开 ===');

  const url = await engine.renderURL(
    'https://example.com/search?q={{key}}&page={{page}}',
    {key: '斗破苍穹', page: 2},
  );
  console.log(`  url: "${url}"`);
  assert(url.includes(encodeURIComponent('斗破苍穹')), '应含 URL 编码关键词');
  assert(url.includes('page=2'), '应含 page=2');

  console.log('  ✅ 模板展开 通过');
}

// ═══════════════════════════════════════
// 测试 10: @put/@get 跨阶段状态
// ═══════════════════════════════════════
async function testPutGet() {
  console.log('\n=== 测试 10: @put/@get ===');

  engine.putValue('12345', 'bid', 'https://test.com');
  const val = engine.getValue('bid', 'https://test.com');
  console.log(`  bid: "${val}"`);
  assert(val === '12345', `期望 "12345", 实际 "${val}"`);

  console.log('  ✅ @put/@get 通过');
}

// ═══════════════════════════════════════
// 测试 11: <X,Y> 页码选择器
// ═══════════════════════════════════════
async function testPagePicker() {
  console.log('\n=== 测试 11: <X,Y> 页码选择器 ===');

  const url1 = await engine.renderURL(
    'https://example.com/<search,page/{{page}}>',
    {key: 'test', page: 1},
  );
  console.log(`  page1 url: "${url1}"`);
  assert(url1.includes('search'), '第1页应取X (search)');
  assert(!url1.includes('page/1'), '第1页不应含 page/1');

  const url2 = await engine.renderURL(
    'https://example.com/<search,page/{{page}}>',
    {key: 'test', page: 2},
  );
  console.log(`  page2 url: "${url2}"`);
  assert(url2.includes('page/2'), '第2页应取Y (page/2)');

  console.log('  ✅ <X,Y> 页码选择器 通过');
}

// ═══════════════════════════════════════
// 测试 12: CSS @text, @href, @src 快捷属性
// ═══════════════════════════════════════
async function testCssShortcuts() {
  console.log('\n=== 测试 12: CSS 属性快捷方式 ===');

  const html = '<a href="https://test.com" class="link">点击这里</a>';
  const text = await engine.selectString('a.link@text', html, {});
  console.log(`  @text: "${text}"`);
  assert(text === '点击这里', `期望 "点击这里", 实际 "${text}"`);

  const href = await engine.selectString('a.link@href', html, {});
  console.log(`  @href: "${href}"`);
  assert(href === 'https://test.com', `期望 "https://test.com", 实际 "${href}"`);

  const imgHtml = '<img src="/img/cover.jpg" alt="封面">';
  const src = await engine.selectString('img@src', imgHtml, {});
  console.log(`  @src: "${src}"`);
  assert(src === '/img/cover.jpg', `期望 "/img/cover.jpg", 实际 "${src}"`);

  console.log('  ✅ CSS 属性快捷方式 通过');
}

// ═══════════════════════════════════════
// 测试 13: %% 拉链合并
// ═══════════════════════════════════════
async function testZipMerge() {
  console.log('\n=== 测试 13: %% 拉链合并 ===');

  const html = `
  <div id="names"><span>A</span><span>B</span><span>C</span></div>
  <div id="urls"><span>/a</span><span>/b</span><span>/c</span></div>`;

  const merged = await engine.selectList(
    '#names span@text%%#urls span@text',
    html,
    {},
  );
  console.log(`  merged: ${JSON.stringify(merged)}`);
  assert(merged.length === 6, `期望 6, 实际 ${merged.length}`);
  assert(merged[0] === 'A', `期望 A, 实际 "${merged[0]}"`);
  assert(merged[1] === '/a', `期望 /a, 实际 "${merged[1]}"`);

  console.log('  ✅ %% 拉链合并 通过');
}

// ═══════════════════════════════════════
// 测试 14: - 前缀倒置
// ═══════════════════════════════════════
async function testInvertPrefix() {
  console.log('\n=== 测试 14: - 前缀倒置 ===');

  const html = '<ul><li>A</li><li>B</li><li>C</li></ul>';
  const normal = await engine.selectList('ul li@text', html, {});
  const inverted = await engine.selectList('-ul li@text', html, {});
  console.log(`  normal: ${JSON.stringify(normal)}`);
  console.log(`  inverted: ${JSON.stringify(inverted)}`);
  assert(normal[0] === 'A', '正序首项应为 A');
  assert(inverted[0] === 'C', '倒序首项应为 C');

  console.log('  ✅ - 前缀倒置 通过');
}

// ═══════════════════════════════════════
// 测试 15: CSS !exclude 排除
// ═══════════════════════════════════════
async function testCssExclude() {
  console.log('\n=== 测试 15: CSS ! 排除 ===');

  const html = '<div class="list"><p class="ad">广告</p><p>正文1</p><p>正文2</p></div>';
  const list = await engine.selectList('.list p@text!.ad', html, {});
  console.log(`  list: ${JSON.stringify(list)}`);
  assert(!list.includes('广告'), '不应包含被排除的 .ad');
  assert(list.includes('正文1'), '应包含正文1');

  console.log('  ✅ CSS ! 排除 通过');
}

// ═══════════════════════════════════════
// 测试 16: <js>...</js> 内联 JS 块
// ═══════════════════════════════════════
async function testInlineJsBlock() {
  console.log('\n=== 测试 16: <js>...</js> 内联 JS ===');

  const url = await engine.renderURL(
    'https://example.com/<js>"page_" + page</js>.html',
    {page: 3},
  );
  console.log(`  url: "${url}"`);
  assert(url.includes('page_3'), `应含 page_3, 实际 "${url}"`);

  console.log('  ✅ <js> 内联 JS 通过');
}

// ═══════════════════════════════════════
// 测试 17: Legado CSS 格式 (class./tag./id./text.)
// ═══════════════════════════════════════
async function testLegadoCssFormat() {
  console.log('\n=== 测试 17: Legado CSS 格式 ===');

  const html = `
  <div class="container">
    <div class="item">
      <div class="itemtxt">
        <h3><a href="/book/123/">斗破苍穹</a></h3>
        <p><span>玄幻</span><span>天蚕土豆</span></p>
        <p><a href="/author/1">天蚕土豆</a></p>
        <i>连载</i><i>300万字</i><i>2026更新</i>
        <ul><li><a href="/chapter/latest">第2000章 大结局</a></li></ul>
      </div>
      <img src="/cover/1.jpg">
    </div>
    <div class="item">
      <div class="itemtxt">
        <h3><a href="/book/456/">完美世界</a></h3>
        <p><span>仙侠</span><span>辰东</span></p>
        <p><a href="/author/2">辰东</a></p>
        <i>完结</i><i>500万字</i><i>2020</i>
        <ul><li><a href="/chapter/final">最终章</a></li></ul>
      </div>
      <img src="/cover/2.jpg">
    </div>
  </div>`;

  // class.item → .item
  const bookList = await engine.selectList('class.item', html, {});
  console.log(`  class.item: ${bookList.length} 本`);
  assert(bookList.length === 2, `期望 2, 实际 ${bookList.length}`);

  const first = bookList[0];

  // class.itemtxt@tag.h3@tag.a@text
  const name = await engine.selectString('class.itemtxt@tag.h3@tag.a@text', first, {});
  console.log(`  name: "${name}"`);
  assert(name === '斗破苍穹', `期望 "斗破苍穹", 实际 "${name}"`);

  // class.itemtxt@tag.h3@tag.a@href
  const bookUrl = await engine.selectString('class.itemtxt@tag.h3@tag.a@href', first, {});
  console.log(`  bookUrl: "${bookUrl}"`);
  assert(bookUrl === '/book/123/', `期望 "/book/123/", 实际 "${bookUrl}"`);

  // class.itemtxt@tag.p.1@tag.a@text (第2个<p>中的<a>)
  const author = await engine.selectString('class.itemtxt@tag.p.1@tag.a@text', first, {});
  console.log(`  author: "${author}"`);
  assert(author === '天蚕土豆', `期望 "天蚕土豆", 实际 "${author}"`);

  // class.item@tag.img@src
  const cover = await engine.selectString('class.item@tag.img@src', first, {});
  console.log(`  cover: "${cover}"`);
  assert(cover === '/cover/1.jpg', `期望 "/cover/1.jpg", 实际 "${cover}"`);

  // class.itemtxt@tag.p.0@tag.span.1@text (第1个<p>中第2个<span>)
  const spanText = await engine.selectString('class.itemtxt@tag.p.0@tag.span.1@text', first, {});
  console.log(`  span.1: "${spanText}"`);
  assert(spanText === '天蚕土豆', `期望 "天蚕土豆", 实际 "${spanText}"`);

  // class.itemtxt@tag.i.2@text (第3个<i>)
  const iText = await engine.selectString('class.itemtxt@tag.i.2@text', first, {});
  console.log(`  i.2: "${iText}"`);
  assert(iText === '2026更新', `期望 "2026更新", 实际 "${iText}"`);

  // class.itemtxt@tag.ul@tag.li.0@tag.a@text
  const lastChapter = await engine.selectString(
    'class.itemtxt@tag.ul@tag.li.0@tag.a@text',
    first,
    {},
  );
  console.log(`  lastChapter: "${lastChapter}"`);
  assert(lastChapter === '第2000章 大结局', `期望 "第2000章 大结局", 实际 "${lastChapter}"`);

  console.log('  ✅ Legado CSS 格式 通过');
}

// ═══════════════════════════════════════
// 测试 18: Legado id./text. 选择器
// ═══════════════════════════════════════
async function testLegadoIdText() {
  console.log('\n=== 测试 18: id./text. 选择器 ===');

  const html = `
  <div id="list">
    <ul>
      <li><a href="/ch/1">第一章</a></li>
      <li><a href="/ch/2">第二章</a></li>
    </ul>
  </div>
  <div class="pager">
    <a href="/toc/1">上一页</a>
    <a href="/toc/3">下一页</a>
  </div>`;

  // id.list@tag.ul@tag.li
  const chapters = await engine.selectList('id.list@tag.ul@tag.li', html, {});
  console.log(`  id.list chapters: ${chapters.length}`);
  assert(chapters.length === 2, `期望 2, 实际 ${chapters.length}`);

  const title = await engine.selectString('tag.a@text', chapters[0], {});
  console.log(`  title: "${title}"`);
  assert(title === '第一章', `期望 "第一章", 实际 "${title}"`);

  // text.下一页@href
  const nextUrl = await engine.selectString('text.下一页@href', html, {});
  console.log(`  nextUrl: "${nextUrl}"`);
  assert(nextUrl === '/toc/3', `期望 "/toc/3", 实际 "${nextUrl}"`);

  console.log('  ✅ id./text. 选择器 通过');
}

// ═══════════════════════════════════════
// 测试 19: 端到端 search 模拟 (JSON API 源)
// ═══════════════════════════════════════
async function testSearchE2E() {
  console.log('\n=== 测试 17: 端到端搜索模拟 ===');

  const source: BookSource = {
    bookSourceUrl: 'https://api.example.com',
    bookSourceName: '测试JSON源',
    searchUrl: '/api/search?keyword={{key}}',
    ruleSearch: {
      bookList: '$.data.books',
      name: '$.title',
      author: '$.author',
      bookUrl: '$.url',
      coverUrl: '$.cover',
      intro: '$.description',
    },
  };

  const mockJson = JSON.stringify({
    data: {
      books: [
        {
          title: '斗破苍穹',
          author: '天蚕土豆',
          url: '/book/1',
          cover: '/cover/1.jpg',
          description: '一段描述',
        },
      ],
    },
  });

  const ctx = {baseUrl: source.bookSourceUrl, bookSource: source, key: '斗破'};

  const bookList = await engine.selectList(source.ruleSearch!.bookList!, mockJson, ctx);
  assert(bookList.length === 1, `期望 1 本, 实际 ${bookList.length}`);

  const item = bookList[0];
  const name = await engine.selectString(source.ruleSearch!.name!, item, ctx);
  const author = await engine.selectString(source.ruleSearch!.author!, item, ctx);
  const bookUrl = await engine.selectString(source.ruleSearch!.bookUrl!, item, ctx);
  console.log(`  name="${name}", author="${author}", url="${bookUrl}"`);
  assert(name === '斗破苍穹', `名称错误: "${name}"`);
  assert(author === '天蚕土豆', `作者错误: "${author}"`);
  assert(bookUrl === '/book/1', `URL 错误: "${bookUrl}"`);

  console.log('  ✅ 端到端搜索模拟 通过');
}

// ═══════════════════════════════════════
// 主入口
// ═══════════════════════════════════════
async function main() {
  console.log('🔧 万象书屋 RN 规则引擎测试\n');

  await testCssSelector();
  await testJsonPath();
  await testRegexReplace();
  await testOrFallback();
  await testAndChain();
  await testTocParsing();
  await testContentParsing();
  await testJsRule();
  await testTemplateExpansion();
  await testPutGet();
  await testPagePicker();
  await testCssShortcuts();
  await testZipMerge();
  await testInvertPrefix();
  await testCssExclude();
  await testInlineJsBlock();
  await testLegadoCssFormat();
  await testLegadoIdText();
  await testSearchE2E();

  console.log(`\n${'='.repeat(40)}`);
  console.log(`✅ ${passed} passed, ❌ ${failed} failed`);
  if (failed > 0) process.exit(1);
}

main().catch(e => {
  console.error('Fatal:', e);
  process.exit(1);
});
