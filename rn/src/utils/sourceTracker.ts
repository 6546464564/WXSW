/**
 * 万象书屋 RN · 源性能追踪
 * 对齐 iOS: SourcePerformanceTracker
 * 按历史成功率 + 响应速度对源排序
 */

import AsyncStorage from '@react-native-async-storage/async-storage';

const TRACKER_KEY = 'wanxiang.sourcePerf';

export interface SourceStat {
  success: number;
  fail: number;
  avgMs: number;
  lastUsed: number;
}

let stats: Record<string, SourceStat> = {};
let loaded = false;
let loadPromise: Promise<void> | null = null;

async function ensureLoaded() {
  if (loaded) return;
  // 万象书屋: 缓存 load promise, 并发 trackSource 只触发一次读盘,
  // 避免首次加载期间多个 await getItem 让出后重复读盘/互相覆盖.
  if (!loadPromise) {
    loadPromise = (async () => {
      try {
        const raw = await AsyncStorage.getItem(TRACKER_KEY);
        if (raw) stats = JSON.parse(raw);
      } catch {}
      loaded = true;
    })();
  }
  await loadPromise;
}

function persist() {
  AsyncStorage.setItem(TRACKER_KEY, JSON.stringify(stats)).catch(() => {});
}

export async function trackSource(origin: string, ok: boolean, ms?: number) {
  await ensureLoaded();
  const s = stats[origin] || {success: 0, fail: 0, avgMs: 3000, lastUsed: 0};
  if (ok) {
    s.success++;
    if (ms != null) s.avgMs = Math.round((s.avgMs * 0.7) + (ms * 0.3));
  } else {
    s.fail++;
  }
  s.lastUsed = Date.now();
  stats[origin] = s;
  persist();
}

function score(s: SourceStat): number {
  const total = s.success + s.fail;
  if (total === 0) return 50;
  const rate = s.success / total;
  const speed = Math.max(0, 1 - s.avgMs / 10000);
  return Math.round(rate * 70 + speed * 30);
}

export async function getSortedOrigins(origins: string[]): Promise<string[]> {
  await ensureLoaded();
  return [...origins].sort((a, b) => {
    const sa = stats[a];
    const sb = stats[b];
    return (sb ? score(sb) : 50) - (sa ? score(sa) : 50);
  });
}

export async function getSourceStats(): Promise<Record<string, SourceStat>> {
  await ensureLoaded();
  return {...stats};
}
