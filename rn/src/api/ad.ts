/**
 * 万象书屋 RN · 广告 API
 * 对齐后端: GET /api/ad-config, POST /api/ad-event, POST /api/ad-events
 */

import {wanxiangClient} from './client';

export interface AdConfig {
  enabled: boolean;
  slots: Record<string, AdSlot>;
  version?: number;
}

export interface AdSlot {
  type: string;
  adId: string;
  enabled: boolean;
  frequency?: number;
  cooldownMs?: number;
}

/**
 * 获取广告配置
 */
export async function fetchAdConfig(): Promise<AdConfig | null> {
  try {
    const res = await wanxiangClient.instance.get('/api/ad-config');
    return res.data || null;
  } catch {
    return null;
  }
}

/**
 * 上报单条广告事件
 */
export async function reportAdEvent(
  event: string,
  slotId: string,
  extra?: Record<string, any>,
): Promise<void> {
  try {
    await wanxiangClient.instance.post('/api/ad-event', {
      event,
      slotId,
      deviceId: wanxiangClient.getDeviceId(),
      ts: Date.now(),
      ...extra,
    });
  } catch {}
}

/**
 * 批量上报广告事件
 */
export async function reportAdEvents(
  events: Array<{event: string; slotId: string; ts: number}>,
): Promise<void> {
  if (events.length === 0) return;
  try {
    await wanxiangClient.instance.post('/api/ad-events', {
      events,
      deviceId: wanxiangClient.getDeviceId(),
    });
  } catch {}
}
