/**
 * 万象书屋 RN · 热更新
 * 自建方案: 利用现有后端管理 JS Bundle 版本
 *
 * 流程:
 *  1. App 启动时 checkForUpdate()
 *  2. 有新版本 → 后台下载 bundle
 *  3. 下次启动加载新 bundle
 */

import {Platform} from 'react-native';
import {wanxiangClient} from '../api/client';
import {BUNDLE_VERSION} from './constants';

interface BundleInfo {
  version: string;
  url: string;
  mandatory: boolean;
  changelog?: string;
  hash?: string;
}

interface UpdateCheckResult {
  hasUpdate: boolean;
  bundle?: BundleInfo;
}

/**
 * 检查是否有新的 JS Bundle
 */
export async function checkForUpdate(): Promise<UpdateCheckResult> {
  try {
    const res = await wanxiangClient.instance.get('/api/bundle/check', {
      params: {
        version: BUNDLE_VERSION,
        platform: Platform.OS,
        variant: 'lite',
      },
    });

    if (res.data?.hasUpdate && res.data?.bundle) {
      return {hasUpdate: true, bundle: res.data.bundle};
    }
    return {hasUpdate: false};
  } catch {
    return {hasUpdate: false};
  }
}

/**
 * 下载新 Bundle
 * 实现需要 react-native-fs 或类似原生模块
 */
export async function downloadBundle(bundleUrl: string): Promise<string | null> {
  // TODO: 使用 react-native-fs 下载到 documentDirectory
  // const localPath = `${DocumentDirectoryPath}/bundle_update.jsbundle`;
  // await RNFS.downloadFile({ fromUrl: bundleUrl, toFile: localPath }).promise;
  // return localPath;
  console.log('[HotUpdate] Would download bundle from:', bundleUrl);
  return null;
}

/**
 * 上报更新结果
 */
export async function reportUpdateResult(
  version: string,
  success: boolean,
  error?: string,
): Promise<void> {
  try {
    await wanxiangClient.instance.post('/api/bundle/report', {
      version,
      success,
      error,
      platform: Platform.OS,
      deviceId: wanxiangClient.getDeviceId(),
    });
  } catch {}
}
