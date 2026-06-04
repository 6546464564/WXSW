/**
 * 万象书屋 RN · 持久化存储
 * 使用 AsyncStorage (跨平台兼容，无原生编译问题)
 */

import AsyncStorage from '@react-native-async-storage/async-storage';

export async function getString(key: string): Promise<string | null> {
  return AsyncStorage.getItem(key);
}

export async function setString(key: string, value: string): Promise<void> {
  await AsyncStorage.setItem(key, value);
}

export async function getObject<T>(key: string): Promise<T | null> {
  const json = await AsyncStorage.getItem(key);
  if (!json) return null;
  try {
    return JSON.parse(json) as T;
  } catch {
    return null;
  }
}

export async function setObject(key: string, value: any): Promise<void> {
  await AsyncStorage.setItem(key, JSON.stringify(value));
}

export async function remove(key: string): Promise<void> {
  await AsyncStorage.removeItem(key);
}

export async function clear(): Promise<void> {
  await AsyncStorage.clear();
}
