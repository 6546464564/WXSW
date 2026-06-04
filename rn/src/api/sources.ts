/**
 * 万象书屋 RN · 书源 API
 * 对齐后端: GET /api/sources, POST /api/source-error
 */

import {wanxiangClient} from './client';
import {BookSource} from '../engine/types';

let lastEtag: string | null = null;

/**
 * 拉取书源列表 (带 ETag 缓存)
 */
export async function fetchBookSources(
  healthyOnly = false,
): Promise<BookSource[]> {
  const headers: Record<string, string> = {};
  if (lastEtag) {
    headers['If-None-Match'] = lastEtag;
  }

  const res = await wanxiangClient.instance.get('/api/sources', {
    params: healthyOnly ? {healthy: '1'} : undefined,
    headers,
    validateStatus: status => status === 200 || status === 304,
  });

  if (res.status === 304) {
    return []; // 没变化，使用缓存
  }

  const etag = res.headers['etag'];
  if (etag) lastEtag = etag;

  return res.data || [];
}

/**
 * 上报书源错误
 */
export async function reportSourceError(
  sourceUrl: string,
  errorMsg: string,
  bookUrl?: string,
): Promise<void> {
  try {
    await wanxiangClient.instance.post('/api/source-error', {
      sourceUrl,
      error: errorMsg,
      bookUrl,
      deviceId: wanxiangClient.getDeviceId(),
    });
  } catch {}
}
