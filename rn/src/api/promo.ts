/**
 * 万象书屋 RN · 促销码 API
 * 对齐后端: GET /api/promo/codes, POST /api/promo/attempt, POST /api/promo/usage
 */

import {wanxiangClient} from './client';

export interface PromoCode {
  code: string;
  type: string;
  value: any;
  maxUses: number;
  usedCount: number;
  enabled: boolean;
  expiresAt?: number;
}

/**
 * 获取可用促销码列表 (非管理员接口)
 */
export async function fetchPromoCodes(): Promise<PromoCode[]> {
  try {
    const res = await wanxiangClient.instance.get('/api/promo/codes');
    return res.data?.list || [];
  } catch {
    return [];
  }
}

/**
 * 尝试兑换促销码
 */
export async function attemptPromo(code: string): Promise<{ok: boolean; msg?: string; value?: any}> {
  try {
    const res = await wanxiangClient.instance.post('/api/promo/attempt', {
      code,
      deviceId: wanxiangClient.getDeviceId(),
    });
    return res.data;
  } catch (e: any) {
    return {ok: false, msg: e.response?.data?.msg || '兑换失败'};
  }
}

/**
 * 上报促销码使用情况
 */
export async function reportPromoUsage(
  code: string,
  action: string,
): Promise<void> {
  try {
    await wanxiangClient.instance.post('/api/promo/usage', {
      code,
      action,
      deviceId: wanxiangClient.getDeviceId(),
    });
  } catch {}
}
