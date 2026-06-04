/**
 * 万象书屋 RN · 书源状态管理
 * 对齐 iOS: BookSourceRegistry
 *
 * 启动时先从 AsyncStorage 恢复缓存（毫秒级），再后台拉取最新数据。
 */

import {create} from 'zustand';
import {BookSource} from '../engine/types';
import {fetchBookSources} from '../api/sources';
import {getObject, setObject} from '../utils/storage';

const CACHE_KEY = 'wx.sources';

interface SourceState {
  sources: BookSource[];
  loading: boolean;
  error: string | null;
  lastFetchTime: number;
  loadCachedSources: () => Promise<void>;
  fetchSources: () => Promise<void>;
  getEnabledSources: () => BookSource[];
  findSource: (url: string) => BookSource | undefined;
}

export const useSourceStore = create<SourceState>((set, get) => ({
  sources: [],
  loading: false,
  error: null,
  lastFetchTime: 0,

  loadCachedSources: async () => {
    if (get().sources.length > 0) return;
    const cached = await getObject<BookSource[]>(CACHE_KEY);
    if (cached && cached.length > 0 && get().sources.length === 0) {
      set({sources: cached});
    }
  },

  fetchSources: async () => {
    set({loading: true, error: null});
    try {
      const sources = await fetchBookSources();
      if (sources.length > 0) {
        set({sources, loading: false, lastFetchTime: Date.now()});
        setObject(CACHE_KEY, sources).catch(() => {});
      } else {
        set({loading: false});
      }
    } catch (e: any) {
      set({error: e.message, loading: false});
    }
  },

  getEnabledSources: () => {
    return get().sources.filter(s => s.enabled !== false);
  },

  findSource: (url: string) => {
    return get().sources.find(s => s.bookSourceUrl === url);
  },
}));
