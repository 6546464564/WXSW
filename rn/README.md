# 万象书屋 Lite (React Native)

> 基于 React Native 0.85 的跨平台阅读客户端，共用万象书屋后端 API。

## 技术栈

| 层 | 技术 |
|---|---|
| 框架 | React Native 0.85 + TypeScript |
| 导航 | React Navigation 7 (Bottom Tabs + Native Stack) |
| 状态管理 | Zustand 5 |
| 网络 | Axios + 自动 Token / ETag |
| 持久化 | AsyncStorage |
| 书源引擎 | 自研 legado 规则引擎 (CSS / XPath / JSON / JS / Regex) |
| JS 执行 | 内嵌 java.* bridge + CryptoJS + Cheerio |
| UI | react-native-vector-icons + react-native-linear-gradient |

## 目录结构

```
rn/
├── src/
│   ├── api/           # 后端 API (设备注册 / 书源 / 书城 / 广告 / IAP)
│   ├── app/           # App 入口 / Navigation / Theme
│   ├── components/    # 通用组件 (BookCover / ErrorBoundary)
│   ├── engine/        # legado 规则引擎 + JS 执行器
│   │   └── parsers/   # CSS / JsonPath / Regex 解析器
│   ├── features/      # 业务页面
│   │   ├── bookshelf/ # 书架
│   │   ├── bookstore/ # 书城
│   │   ├── detail/    # 书籍详情
│   │   ├── reader/    # 阅读器 (5 种翻页模式)
│   │   ├── search/    # 搜索
│   │   └── settings/  # 我的 / 设置
│   ├── store/         # Zustand 状态 (bookshelf / reader / source)
│   └── utils/         # 存储 / 常量 / 热更新
├── android/           # Android 原生壳
├── ios/               # iOS 原生壳
└── __tests__/         # 测试
```

## 开发

```bash
# 安装依赖
npm install

# iOS (需先装 Pods)
cd ios && bundle exec pod install && cd ..
npm run ios

# Android
npm run android
```

## 后端

共用 `../backend/` 的 API，开发时后端默认 `http://localhost:3000`。
