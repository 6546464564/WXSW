/**
 * 万象书屋 RN · 设备 API
 * 对齐后端: POST /api/ping, GET /api/version-check, GET /api/announcement
 */

import {wanxiangClient} from './client';
import {APP_VERSION} from '../utils/constants';

/**
 * 心跳 (对齐 iOS WanxiangAPI.sendPing)
 */
export async function sendHeartbeat(): Promise<void> {
  try {
    await wanxiangClient.instance.post('/api/ping', {
      device_id: wanxiangClient.getDeviceId(),
    });
  } catch {}
}

/**
 * 版本检查
 */
export interface VersionCheckResult {
  needUpgrade: boolean;
  forceUpgrade: boolean;
  latestName: string;
  changelog: string;
  marketUrl: string;
}

export async function checkVersion(): Promise<VersionCheckResult> {
  const res = await wanxiangClient.instance.get('/api/version-check', {
    params: {code: 1}, // RN 版本号
  });
  return res.data;
}

/**
 * 公告
 */
export interface Announcement {
  id: number;
  title: string;
  body: string;
}

export async function fetchAnnouncements(): Promise<Announcement[]> {
  const res = await wanxiangClient.instance.get('/api/announcement', {
    params: {versionCode: 1},
  });
  return res.data?.list || [];
}

/**
 * 意见反馈
 */
export async function submitFeedback(
  content: string,
  contact?: string,
): Promise<boolean> {
  try {
    const res = await wanxiangClient.instance.post('/api/feedback', {
      content,
      contact,
      deviceId: wanxiangClient.getDeviceId(),
      appVersion: APP_VERSION,
      variant: 'lite',
    });
    return res.data?.ok === true;
  } catch {
    return false;
  }
}
