/**
 * 万象书屋 RN · 客户端内容缓存
 * 三级缓存架构的最前端一层 (Client → Nginx → Backend SQLite)
 *
 * 使用 AsyncStorage 缓存章节正文和目录,
 * 避免重复网络请求, 实现翻页"秒开".
 */

import AsyncStorage from '@react-native-async-storage/async-storage';

const PREFIX_CONTENT = 'cc:';
const PREFIX_TOC = 'ct:';

const TTL_CONTENT = 7 * 24 * 3600 * 1000; // 7 天
const TTL_TOC = 2 * 3600 * 1000; // 2 小时

interface CacheEntry<T> {
  d: T; // data
  t: number; // timestamp
}

async function getCache<T>(key: string, ttl: number): Promise<T | null> {
  try {
    const raw = await AsyncStorage.getItem(key);
    if (!raw) return null;
    const entry: CacheEntry<T> = JSON.parse(raw);
    if (Date.now() - entry.t > ttl) {
      AsyncStorage.removeItem(key).catch(() => {});
      return null;
    }
    return entry.d;
  } catch {
    return null;
  }
}

async function setCache<T>(key: string, data: T): Promise<void> {
  try {
    const entry: CacheEntry<T> = {d: data, t: Date.now()};
    await AsyncStorage.setItem(key, JSON.stringify(entry));
  } catch {
    // storage full or write error — silently ignore
  }
}

function contentKey(origin: string, chapterUrl: string): string {
  return PREFIX_CONTENT + origin + '|' + chapterUrl;
}

function tocKey(origin: string, bookUrl: string): string {
  return PREFIX_TOC + origin + '|' + bookUrl;
}

export async function getCachedContent(
  origin: string,
  chapterUrl: string,
): Promise<string | null> {
  return getCache<string>(contentKey(origin, chapterUrl), TTL_CONTENT);
}

export async function setCachedContent(
  origin: string,
  chapterUrl: string,
  content: string,
): Promise<void> {
  return setCache(contentKey(origin, chapterUrl), content);
}

export async function getCachedToc<T>(
  origin: string,
  bookUrl: string,
): Promise<T[] | null> {
  return getCache<T[]>(tocKey(origin, bookUrl), TTL_TOC);
}

export async function setCachedToc<T>(
  origin: string,
  bookUrl: string,
  chapters: T[],
): Promise<void> {
  return setCache(tocKey(origin, bookUrl), chapters);
}

export async function clearContentCache(): Promise<void> {
  try {
    const keys = await AsyncStorage.getAllKeys();
    const cacheKeys = keys.filter(
      k => k.startsWith(PREFIX_CONTENT) || k.startsWith(PREFIX_TOC),
    );
    if (cacheKeys.length > 0) {
      await (AsyncStorage as any).multiRemove(cacheKeys);
    }
  } catch {}
}
