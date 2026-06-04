/**
 * 万象书屋 RN · HTTP 客户端
 * 对齐 iOS: WanxiangAPI.swift
 * 对齐 Android: WanxiangBackend.kt
 *
 * - 自动带 X-Platform / X-Device-Id / X-Device-Token
 * - 启动时自动注册设备获取 token
 * - ETag 缓存支持
 */

import axios, {AxiosInstance} from 'axios';
import {Platform} from 'react-native';
import {getString, setString} from '../utils/storage';

// 后端地址 (对齐 iOS WanxiangAPI.baseURL)
const BASE_URL = 'https://wxsw.app';

const PLATFORM = Platform.OS === 'ios' ? 'ios' : 'android';

class WanxiangClient {
  private client: AxiosInstance;
  private deviceId: string = '';
  private deviceToken: string = '';
  private initialized = false;

  constructor() {
    this.client = axios.create({
      baseURL: BASE_URL,
      timeout: 15000,
      headers: {
        'Content-Type': 'application/json',
        'X-Platform': PLATFORM,
      },
    });

    this.client.interceptors.request.use(config => {
      if (this.deviceId) {
        config.headers['X-Device-Id'] = this.deviceId;
      }
      if (this.deviceToken) {
        config.headers['X-Device-Token'] = this.deviceToken;
      }
      return config;
    });

    this.client.interceptors.response.use(
      response => response,
      async error => {
        // 401: token 失效，重新注册
        if (error.response?.status === 401 && this.deviceId) {
          await this.registerDevice(true);
          // 重试原请求
          const config = error.config;
          config.headers['X-Device-Token'] = this.deviceToken;
          return this.client.request(config);
        }
        return Promise.reject(error);
      },
    );
  }

  /**
   * 初始化: 读取/生成 deviceId，注册设备获取 token
   */
  async init() {
    if (this.initialized) return;

    // 读取已存储的 deviceId
    let storedId = await getString('wx.deviceId');
    if (!storedId) {
      // 生成新的 UUID 作为 deviceId
      storedId =
        'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
          const r = (Math.random() * 16) | 0;
          const v = c === 'x' ? r : (r & 0x3) | 0x8;
          return v.toString(16);
        });
      await setString('wx.deviceId', storedId);
    }
    this.deviceId = storedId;

    // 读取已存储的 token
    const storedToken = await getString('wx.deviceToken');
    if (storedToken) {
      this.deviceToken = storedToken;
    } else {
      await this.registerDevice(false);
    }

    this.initialized = true;
  }

  /**
   * 注册设备 (对齐 iOS WanxiangAPI.registerDeviceIfNeeded)
   */
  private async registerDevice(reissue: boolean) {
    try {
      const url = reissue
        ? '/api/device/register?reissue=1'
        : '/api/device/register';
      const res = await this.client.post(url, {
        device_id: this.deviceId,
      });
      if (res.data?.token) {
        this.deviceToken = res.data.token;
        await setString('wx.deviceToken', this.deviceToken);
      }
    } catch (e: any) {
      // 409 = already registered (非 reissue 时)
      if (e.response?.status === 409 && !reissue) {
        // 尝试 reissue
        await this.registerDevice(true);
      }
    }
  }

  get instance(): AxiosInstance {
    return this.client;
  }

  getDeviceId(): string {
    return this.deviceId;
  }
}

export const wanxiangClient = new WanxiangClient();
export default wanxiangClient;
export {BASE_URL, PLATFORM};
