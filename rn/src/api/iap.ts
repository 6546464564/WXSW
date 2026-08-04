/**
 * 万象书屋 RN · IAP (内购) API
 * 对齐后端: POST /api/iap/verify, GET /api/iap/entitlements
 */

import {wanxiangClient} from './client';

export interface Entitlement {
  productId: string;
  expiresAt?: number;
  isActive: boolean;
}

/**
 * 验证购买收据
 */
export async function verifyReceipt(
  receiptData: string,
  productId: string,
  transactionId: string,
): Promise<{ok: boolean; entitlements?: Entitlement[]}> {
  try {
    const res = await wanxiangClient.instance.post('/api/iap/verify', {
      receiptData,
      productId,
      transactionId,
      deviceId: wanxiangClient.getDeviceId(),
    });
    return res.data;
  } catch {
    return {ok: false};
  }
}

/**
 * 获取当前设备权益
 */
export async function fetchEntitlements(): Promise<Entitlement[]> {
  try {
    const res = await wanxiangClient.instance.get('/api/iap/entitlements');
    return res.data?.entitlements || [];
  } catch {
    return [];
  }
}
