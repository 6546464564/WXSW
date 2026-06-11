/**
 * 万象书屋 RN · App 入口
 * 对齐 iOS: WanxiangBookApp.swift
 * - 启动时注册设备 + 拉取书源 + 心跳
 * - rctpushy 热更新 (静默下载，下次冷启动生效)
 */

import React, {useEffect, useState} from 'react';
import {Platform, StatusBar, ActivityIndicator, View, useColorScheme} from 'react-native';
import {GestureHandlerRootView} from 'react-native-gesture-handler';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import {UpdateProvider, Pushy, useUpdate} from 'react-native-update';
import Navigation from './Navigation';
import ErrorBoundary from '../components/ErrorBoundary';
import {useThemeColors} from './theme';
import {wanxiangClient} from '../api/client';
import {useSourceStore} from '../store/sourceStore';
import {sendHeartbeat} from '../api/device';

// @ts-ignore
import _updateConfig from '../../update.json';
const {appKey} = _updateConfig[Platform.OS as 'ios' | 'android'];

const pushyClient = new Pushy({
  appKey,
  updateStrategy: 'silentAndLater',
});

function AppInner() {
  const fetchSources = useSourceStore(s => s.fetchSources);
  const loadCachedSources = useSourceStore(s => s.loadCachedSources);
  const [ready, setReady] = useState(false);
  const colors = useThemeColors();
  const scheme = useColorScheme();
  const {markSuccess} = useUpdate();

  useEffect(() => {
    markSuccess();
  }, [markSuccess]);

  useEffect(() => {
    async function bootstrap() {
      await Promise.all([
        loadCachedSources(),
        wanxiangClient.init().catch(() => {}),
      ]);
      setReady(true);

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

export default function App() {
  return (
    <UpdateProvider client={pushyClient}>
      <AppInner />
    </UpdateProvider>
  );
}
