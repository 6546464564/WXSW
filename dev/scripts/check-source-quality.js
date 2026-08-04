#!/usr/bin/env node
// 万象书屋: 书源质量检验脚本
// 用法: node scripts/check-source-quality.js [--keyword 斗破苍穹] [--url https://wxsw.app]

const BACKEND = process.env.BACKEND_URL || process.argv.find((a, i) => process.argv[i - 1] === '--url') || 'https://wxsw.app';
const KEYWORD = process.env.KEYWORD || process.argv.find((a, i) => process.argv[i - 1] === '--keyword') || '斗破苍穹';
const TIMEOUT_MS = 8000;
const CONCURRENCY = 6;

async function fetchJSON(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(10000) });
  return res.json();
}

function renderSearchUrl(src, keyword) {
  const tpl = src.searchUrl;
  if (!tpl || typeof tpl !== 'string') return null;
  const encoded = encodeURIComponent(keyword);
  let url = tpl
    .replace(/\{\{key\}\}/g, encoded)
    .replace(/\{\{page\}\}/g, '1');

  if (url.startsWith('/')) {
    const base = src.bookSourceUrl.replace(/\/+$/, '');
    url = base + url;
  } else if (!/^https?:\/\//i.test(url)) {
    const base = src.bookSourceUrl.replace(/\/+$/, '');
    url = base + '/' + url;
  }

  // Handle Legado multi-line search URLs (take first line only)
  const firstLine = url.split('\n')[0].trim();
  return firstLine;
}

async function probeUrl(url, timeoutMs = TIMEOUT_MS) {
  const start = Date.now();
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    const headers = {
      'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15',
      'Accept': 'text/html,application/json,*/*',
    };
    const res = await fetch(url, { signal: ctrl.signal, headers, redirect: 'follow' });
    const body = await res.text();
    clearTimeout(timer);
    return {
      ok: res.status >= 200 && res.status < 400,
      status: res.status,
      ms: Date.now() - start,
      bytes: body.length,
      body,
    };
  } catch (e) {
    return {
      ok: false,
      status: 0,
      ms: Date.now() - start,
      bytes: 0,
      error: e.name === 'AbortError' ? 'timeout' : e.message,
      body: '',
    };
  }
}

function estimateResultCount(body, src) {
  if (!body) return 0;
  const bookList = src.ruleSearch?.bookList;
  if (!bookList) return -1;

  // Simple heuristic: count common list patterns
  const patterns = [
    /<li[\s>]/gi,
    /<div class="[^"]*book[^"]*"/gi,
    /<div class="[^"]*result[^"]*"/gi,
    /<a[^>]*href[^>]*>[^<]*<\/a>/gi,
  ];

  let maxCount = 0;
  for (const p of patterns) {
    const matches = body.match(p);
    if (matches && matches.length > maxCount) {
      maxCount = matches.length;
    }
  }
  return maxCount;
}

function scoreSource(reach, search, src) {
  let score = 0;
  const reasons = [];

  // Reachability (0-30)
  if (reach.ok) {
    score += 15;
    if (reach.ms < 1000) { score += 15; reasons.push('快速响应'); }
    else if (reach.ms < 3000) { score += 10; reasons.push('响应正常'); }
    else { score += 5; reasons.push('响应较慢'); }
  } else {
    reasons.push('不可达');
  }

  // Search (0-40)
  if (search) {
    if (search.ok) {
      score += 15;
      if (search.bytes > 5000) { score += 15; reasons.push('搜索内容丰富'); }
      else if (search.bytes > 1000) { score += 10; reasons.push('搜索有结果'); }
      else { score += 5; reasons.push('搜索结果少'); }

      if (search.ms < 2000) { score += 10; reasons.push('搜索快'); }
      else if (search.ms < 5000) { score += 5; }
    } else {
      reasons.push('搜索失败');
    }
  } else {
    reasons.push('无搜索');
  }

  // Rules completeness (0-30)
  let ruleScore = 0;
  if (src.searchUrl) ruleScore += 5;
  if (src.ruleSearch?.bookList) ruleScore += 5;
  if (src.ruleSearch?.name) ruleScore += 3;
  if (src.ruleSearch?.bookUrl) ruleScore += 2;
  if (src.ruleBookInfo?.tocUrl || src.ruleToc?.chapterList) ruleScore += 5;
  if (src.ruleToc?.chapterList) ruleScore += 5;
  if (src.ruleContent?.content) ruleScore += 5;
  score += ruleScore;

  return { score, reasons };
}

async function main() {
  console.log(`\n📚 万象书屋 - 书源质量检验`);
  console.log(`   后端: ${BACKEND}`);
  console.log(`   测试关键词: ${KEYWORD}`);
  console.log(`   并发: ${CONCURRENCY}  超时: ${TIMEOUT_MS}ms\n`);

  const sources = await fetchJSON(`${BACKEND}/api/sources`);
  console.log(`共 ${sources.length} 个书源, 开始检验...\n`);

  const results = new Array(sources.length);
  let cursor = 0;
  let done = 0;

  async function worker() {
    while (true) {
      const idx = cursor++;
      if (idx >= sources.length) break;
      const src = sources[idx];
      const name = src.bookSourceName || '(无名)';

      // 1. Reach check
      const reach = await probeUrl(src.bookSourceUrl);

      // 2. Search check
      let search = null;
      if (src.searchUrl && reach.ok) {
        const searchUrl = renderSearchUrl(src, KEYWORD);
        if (searchUrl) {
          search = await probeUrl(searchUrl);
        }
      }

      // 3. Score
      const { score, reasons } = scoreSource(reach, search, src);

      results[idx] = { name, url: src.bookSourceUrl, group: src.bookSourceGroup || '', reach, search, score, reasons, src };
      done++;
      process.stdout.write(`\r  进度: ${done}/${sources.length} ...`);
    }
  }

  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, sources.length) }, worker));
  console.log(`\r  进度: ${done}/${sources.length} ✅ 完成\n`);

  // Sort by score descending
  const sorted = [...results].sort((a, b) => b.score - a.score);

  // Print report
  console.log('='.repeat(100));
  console.log('排名  评分  状态    搜索    响应ms  搜索ms  名称');
  console.log('='.repeat(100));

  for (let i = 0; i < sorted.length; i++) {
    const r = sorted[i];
    const rank = String(i + 1).padStart(3);
    const score = String(r.score).padStart(3);
    const reachStatus = r.reach.ok ? '✅' : '❌';
    const searchStatus = r.search ? (r.search.ok ? '✅' : '❌') : '—';
    const reachMs = r.reach.ok ? String(r.reach.ms).padStart(5) : '   —';
    const searchMs = r.search?.ok ? String(r.search.ms).padStart(5) : '   —';
    const name = r.name.slice(0, 40);

    console.log(`${rank}   ${score}   ${reachStatus}      ${searchStatus}    ${reachMs}   ${searchMs}   ${name}`);
  }

  // Summary
  const reachable = results.filter(r => r.reach.ok).length;
  const searchable = results.filter(r => r.search?.ok).length;
  const unreachable = results.filter(r => !r.reach.ok);
  const excellent = results.filter(r => r.score >= 70);
  const good = results.filter(r => r.score >= 50 && r.score < 70);
  const poor = results.filter(r => r.score < 50);

  console.log('\n' + '='.repeat(100));
  console.log('\n📊 总结:');
  console.log(`   总书源: ${results.length}`);
  console.log(`   可达:   ${reachable} (${Math.round(reachable / results.length * 100)}%)`);
  console.log(`   可搜:   ${searchable} (${Math.round(searchable / results.length * 100)}%)`);
  console.log(`   优秀(≥70): ${excellent.length}  良好(50-69): ${good.length}  较差(<50): ${poor.length}`);

  if (unreachable.length > 0) {
    console.log('\n⚠️  不可达的书源 (建议删除或检查):');
    for (const r of unreachable) {
      console.log(`   ❌ ${r.name} | ${r.url} | ${r.reach.error || `HTTP ${r.reach.status}`}`);
    }
  }

  const searchFail = results.filter(r => r.search && !r.search.ok);
  if (searchFail.length > 0) {
    console.log('\n⚠️  搜索失败的书源 (可能需要检查规则):');
    for (const r of searchFail) {
      console.log(`   ❌ ${r.name} | ${r.search.error || `HTTP ${r.search.status}`}`);
    }
  }

  console.log();
}

main().catch(e => { console.error('Error:', e.message); process.exit(1); });
