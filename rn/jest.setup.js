/* 万象书屋 RN jest setup: mock 原生模块, 让 App.test.tsx 能在纯 JS 环境渲染 */
/* eslint-env jest */

// @react-native-clipboard/clipboard — TurboModule, 测试环境无原生二进制
jest.mock('@react-native-clipboard/clipboard', () => ({
  getString: jest.fn(async () => ''),
  setString: jest.fn(),
}));

// @react-native-async-storage/async-storage — 测试环境内存 mock (v3 无自带 jest mock)
jest.mock('@react-native-async-storage/async-storage', () => {
  const store: Record<string, string> = {};
  return {
    __esModule: true,
    default: {
      getItem: jest.fn(async (k: string) => (k in store ? store[k] : null)),
      setItem: jest.fn(async (k: string, v: string) => {
        store[k] = String(v);
      }),
      removeItem: jest.fn(async (k: string) => {
        delete store[k];
      }),
      clear: jest.fn(async () => {
        Object.keys(store).forEach(k => delete store[k]);
      }),
      getAllKeys: jest.fn(async () => Object.keys(store)),
      multiGet: jest.fn(async (keys: string[]) => keys.map(k => [k, store[k] ?? null])),
      multiSet: jest.fn(async (pairs: [string, string][]) => {
        pairs.forEach(([k, v]) => {
          store[k] = String(v);
        });
      }),
      multiRemove: jest.fn(async (keys: string[]) => {
        keys.forEach(k => delete store[k]);
      }),
    },
  };
});

// react-native-update — 热更新 SDK, 测试环境无原生能力
jest.mock('react-native-update', () => ({
  Pushy: class {
    async checkUpdate() {
      return null;
    }
    async downloadUpdate() {
      return null;
    }
    switchVersion() {}
  },
}));

// react-native-vector-icons — 需加载原生字体
jest.mock('react-native-vector-icons/Ionicons', () => 'Ionicons');

// react-native-gesture-handler — TurboModule, 测试环境无原生二进制, 全量 stub
jest.mock('react-native-gesture-handler', () => {
  const React = require('react');
  const stub = ({children, ..._rest}: any) => children;
  return {
    __esModule: true,
    default: stub,
    GestureHandlerRootView: ({children, style}: any) =>
      React.createElement('View', {style}, children),
    PanGestureHandler: stub,
    TapGestureHandler: stub,
    LongPressGestureHandler: stub,
    PinchGestureHandler: stub,
    RotationGestureHandler: stub,
    FlingGestureHandler: stub,
    NativeViewGestureHandler: stub,
    State: {},
    Directions: {},
    gestureHandlerRootHOC: (C: any) => C,
    enableExperimentalWebImplementation: () => {},
    createGestureHandler: () => {},
  };
});
