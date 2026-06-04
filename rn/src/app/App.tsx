/**
 * 万象书屋 RN · App 入口
 * 对齐 iOS: WanxiangBookApp.swift
 * - 启动时注册设备 + 拉取书源 + 心跳
 */

import React, {useEffect, useState} from 'react';
import {StatusBar, ActivityIndicator, View, useColorScheme} from 'react-native';
import {GestureHandlerRootView} from 'react-native-gesture-handler';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import Navigation from './Navigation';
import ErrorBoundary from '../components/ErrorBoundary';
import {useThemeColors} from './theme';
import {wanxiangClient} from '../api/client';
import {useSourceStore} from '../store/sourceStore';
import {sendHeartbeat} from '../api/device';

export default function App() {
  const fetchSources = useSourceStore(s => s.fetchSources);
  const loadCachedSources = useSourceStore(s => s.loadCachedSources);
  const [ready, setReady] = useState(false);
  const colors = useThemeColors();
  const scheme = useColorScheme();

  useEffect(() => {
    async function bootstrap() {
      // 1. 并行: 恢复本地缓存 + 客户端认证初始化
      await Promise.all([
        loadCachedSources(),
        wanxiangClient.init().catch(() => {}),
      ]);
      setReady(true);

      // 2. 后台: 拉最新书源 + 心跳
      fetchSources().catch(() => {});
      sendHeartbeat().catch(() => {});
    }
    bootstrap();
  }, [fetchSources, loadCachedSources]);

  if (!ready) {
    return (
      <View
        style={{
          flex: 1,
          justifyContent: 'center',
          alignItems: 'center',
          backgroundColor: colors.background,
        }}>
        <ActivityIndicator size="large" color={colors.primary} />
      </View>
    );
  }

  return (
    <GestureHandlerRootView style={{flex: 1}}>
      <ErrorBoundary>
        <SafeAreaProvider>
          <StatusBar
            barStyle={scheme === 'dark' ? 'light-content' : 'dark-content'}
            backgroundColor={colors.background}
          />
          <Navigation />
        </SafeAreaProvider>
      </ErrorBoundary>
    </GestureHandlerRootView>
  );
}
