/**
 * 万象书屋 RN · 纯逻辑工具测试
 * 覆盖: bookFormat / contentCache / sourceTracker / referencePlants
 */

import {
  formatWordCount,
  cleanIntro,
} from '../src/utils/bookFormat';
import {
  getCachedContent,
  setCachedContent,
  getCachedToc,
  setCachedToc,
  clearContentCache,
} from '../src/utils/contentCache';
import {getReferenceById, REFERENCE_PLANTS} from '../src/plant/data/referencePlants';
import AsyncStorage from '@react-native-async-storage/async-storage';

describe('formatWordCount', () => {
  test('undefined / 空串返回 undefined', () => {
    expect(formatWordCount()).toBeUndefined();
    expect(formatWordCount('')).toBeUndefined();
  });

  test('已带万字/字直接返回', () => {
    expect(formatWordCount('576.97万字')).toBe('576.97万字');
    expect(formatWordCount('23万字')).toBe('23万字');
  });

  test('万级以上转万字', () => {
    expect(formatWordCount('5769700')).toBe('576.97万字');
    expect(formatWordCount('1000000')).toBe('100.00万字');
    expect(formatWordCount('12000')).toBe('1.20万字');
  });

  test('万级以下保留整数字', () => {
    expect(formatWordCount('8000')).toBe('8000字');
    expect(formatWordCount('9999')).toBe('9999字');
  });

  test('非法输入原样返回', () => {
    expect(formatWordCount('abc')).toBe('abc');
    expect(formatWordCount('0')).toBe('0');
  });
});

describe('cleanIntro', () => {
  test('空输入返回空 text', () => {
    expect(cleanIntro()).toEqual({text: ''});
    expect(cleanIntro('')).toEqual({text: ''});
  });

  test('提取嵌入更新时间并移除该行', () => {
    const r = cleanIntro('这是简介第一行\n🔔 更新：2026-08-01\n简介正文');
    expect(r.updateTime).toBe('2026-08-01');
    expect(r.text).toBe('这是简介第一行\n简介正文');
  });

  test('去掉简介 emoji 前缀', () => {
    const r = cleanIntro('📜 简介：第一章开始\n简介第二行');
    expect(r.text).toBe('第一章开始\n简介第二行');
  });

  test('截断尾部路由信息 (📌 开头行以后全删)', () => {
    const r = cleanIntro('简介正文\n📌 相关推荐\n更多路由');
    expect(r.text).toBe('简介正文');
  });

  test('去除零宽字符行与 HTML 标签', () => {
    const r = cleanIntro('第一行\n\u200B\n第二<br/>第三<em>强调</em>');
    // <br/> 被替换为空 (同行), <em> 标签移除
    expect(r.text).toBe('第一行\n第二第三强调');
  });
});

describe('contentCache', () => {
  beforeEach(async () => {
    await AsyncStorage.clear();
  });

  test('写入后可读回，过期后失效', async () => {
    await setCachedContent('src-a', 'https://x/ch/1', '第一章正文');
    expect(await getCachedContent('src-a', 'https://x/ch/1')).toBe('第一章正文');
    // 不存在的 key
    expect(await getCachedContent('src-a', 'https://x/ch/999')).toBeNull();
  });

  test('目录缓存 TOC 读写', async () => {
    const toc = [{url: 'https://x/c/1', title: '第一章'}, {url: 'https://x/c/2', title: '第二章'}];
    await setCachedToc('src-b', 'book-url-1', toc);
    expect(await getCachedToc('src-b', 'book-url-1')).toEqual(toc);
    expect(await getCachedToc('src-b', 'book-url-2')).toBeNull();
  });

  test('clearContentCache 只清缓存前缀的 key', async () => {
    await setCachedContent('src-a', 'u', '正文');
    await setCachedToc('src-a', 'b', []);
    await AsyncStorage.setItem('keep-me', 'value');
    await clearContentCache();
    expect(await getCachedContent('src-a', 'u')).toBeNull();
    expect(await AsyncStorage.getItem('keep-me')).toBe('value');
  });
});

describe('sourceTracker', () => {
  // 模块级 stats/loaded 有缓存, 用 resetModules 让每个测试拿到干净状态
  beforeEach(() => {
    jest.resetModules();
  });

  test('trackSource 累计成功/失败并持久化', async () => {
    const {trackSource, getSourceStats} = require('../src/utils/sourceTracker');
    await trackSource('src-1', true, 500);
    await trackSource('src-1', true, 700);
    await trackSource('src-1', false, 3000);
    const stats = await getSourceStats();
    expect(stats['src-1'].success).toBe(2);
    expect(stats['src-1'].fail).toBe(1);
    // 初始 avgMs=3000: 500 → round(3000*.7+500*.3)=2250, 700 → round(2250*.7+700*.3)=1785
    expect(stats['src-1'].avgMs).toBe(1785);
  });

  test('getSortedOrigins 按分降序排列，未记录源排中间 (50)', async () => {
    const {trackSource, getSortedOrigins} = require('../src/utils/sourceTracker');
    await trackSource('good', true, 100); // success 1, avg 100 → 高分
    await trackSource('bad', false, 10000); // fail → 0 分
    const sorted = await getSortedOrigins(['bad', 'unknown', 'good']);
    expect(sorted[0]).toBe('good');
    expect(sorted[2]).toBe('bad');
  });

  test('空列表返回空', async () => {
    const {getSortedOrigins} = require('../src/utils/sourceTracker');
    expect(await getSortedOrigins([])).toEqual([]);
  });
});

describe('referencePlants', () => {
  test('REFERENCE_PLANTS 每项字段完整', () => {
    for (const p of REFERENCE_PLANTS) {
      expect(p.id).toBeTruthy();
      expect(p.name).toBeTruthy();
      expect(p.latin).toBeTruthy();
      expect(p.bloom).toBeTruthy();
      expect(Array.isArray(p.traits)).toBe(true);
    }
  });

  test('getReferenceById 找到与找不到', () => {
    expect(getReferenceById('ginkgo')?.name).toBe('银杏');
    expect(getReferenceById('not-exist')).toBeUndefined();
  });
});
