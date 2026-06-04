/**
 * 万象书屋 RN · 规则引擎 Live 测试
 * 用真实书源（速读谷）做 search → bookInfo → toc → content 全链路
 *
 * 运行: cd rn && npx tsx test-engine-live.ts
 */

// @ts-nocheck
import {RuleEngine} from './src/engine/RuleEngine';
import {BookSource} from './src/engine/types';
import axios from 'axios';

(globalThis as any).__DEV__ = true;

const engine = new RuleEngine();

async function main() {
  console.log('🌐 规则引擎 Live 测试 (速读谷)\n');

  // 1. 从后端拿速读谷书源
  let source: BookSource;
  try {
    const res = await axios.get('http://localhost:3000/api/sources', {
      headers: {'X-Platform': 'ios'},
    });
    const sudugu = (res.data as BookSource[]).find(
      s => s.bookSourceUrl?.includes('sudugu'),
    );
    if (!sudugu) {
      console.error('❌ 后端未返回速读谷书源');
      process.exit(1);
    }
    source = sudugu;
    console.log(`📖 书源: ${source.bookSourceName} (${source.bookSourceUrl})`);
  } catch (e: any) {
    console.error('❌ 无法连接后端:', e.message);
    process.exit(1);
  }

  // 2. Search
  console.log('\n--- 搜索: "斗破苍穹" ---');
  try {
    const results = await engine.search(source, '斗破苍穹');
    console.log(`  结果: ${results.length} 本`);
    if (results.length === 0) {
      console.error('❌ 搜索无结果');
      process.exit(1);
    }

    const first = results[0];
    console.log(`  [1] ${first.name} - ${first.author}`);
    console.log(`      url: ${first.bookUrl}`);
    console.log(`      cover: ${first.coverUrl || '(none)'}`);
    console.log(`      intro: ${(first.intro || '').slice(0, 50)}...`);

    if (results.length > 1) {
      console.log(`  [2] ${results[1].name} - ${results[1].author}`);
    }

    // 3. BookInfo
    console.log('\n--- 书详 ---');
    const bookUrl = first.bookUrl;
    if (bookUrl) {
      const info = await engine.getBookInfo(source, bookUrl);
      console.log(`  书名: ${info.name}`);
      console.log(`  作者: ${info.author}`);
      console.log(`  分类: ${info.kind || '(none)'}`);
      console.log(`  封面: ${info.coverUrl || '(none)'}`);
      console.log(`  简介: ${(info.intro || '').slice(0, 80)}...`);

      // 4. TOC
      console.log('\n--- 目录 ---');
      const tocUrl = info.tocUrl || bookUrl;
      const chapters = await engine.getToc(source, tocUrl);
      console.log(`  共 ${chapters.length} 章`);
      if (chapters.length > 0) {
        console.log(`  [1] ${chapters[0].title} → ${chapters[0].url}`);
        if (chapters.length > 1) {
          console.log(`  [2] ${chapters[1].title} → ${chapters[1].url}`);
        }
        const last = chapters[chapters.length - 1];
        console.log(`  [${chapters.length}] ${last.title} → ${last.url}`);
      }

      // 5. Content
      if (chapters.length > 0 && chapters[0].url) {
        console.log('\n--- 正文 (第1章) ---');
        const content = await engine.getContent(source, chapters[0].url);
        const lines = content.split('\n').filter(l => l.trim());
        console.log(`  行数: ${lines.length}`);
        console.log(`  前3行:`);
        for (const line of lines.slice(0, 3)) {
          console.log(`    ${line.slice(0, 60)}`);
        }
      }
    }

    console.log('\n✅ Live 测试完成');
  } catch (e: any) {
    console.error('❌ 测试失败:', e.message);
    if (e.response) {
      console.error('  HTTP status:', e.response.status);
    }
    process.exit(1);
  }
}

main().catch(e => {
  console.error('Fatal:', e);
  process.exit(1);
});
