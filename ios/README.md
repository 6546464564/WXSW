# 万象书屋 iOS

> 起点: 2026-05-04 · 状态: M0-I 脚手架完成 · 下一步: M1 书源引擎

完整路线图见 [docs/PLAN.md](./docs/PLAN.md);全量功能矩阵见 [docs/FEATURES.md](./docs/FEATURES.md);进度跟踪见 [docs/PROGRESS.md](./docs/PROGRESS.md)。

## 30 秒快速跑

```bash
# 1. 拉 git
cd ~/Desktop/WXSW/ios

# 2. 生成 .xcodeproj (需要 XcodeGen, 第一次跑需安装)
~/dev-tools/xcodegen/bin/xcodegen generate

# 3. 打开 Xcode (会自动用刚生成的 WanxiangBook.xcodeproj)
open WanxiangBook.xcodeproj

# 4. 在 Xcode 选 iPhone 15 模拟器 → ⌘R
```

如果还没装 iOS 模拟器 runtime,Xcode → Settings → Components → 下载 iOS 17/18 即可(5-8GB 一次性)。

## 命令行验证编译(不开 Xcode)

```bash
cd ~/Desktop/WXSW/ios
~/dev-tools/xcodegen/bin/xcodegen generate

# 注意: 用 -target 而不是 -scheme 来绕开 "no destinations" 报错
# (Xcode 26 + XcodeGen 2.45 的兼容性小坑, Xcode GUI ⌘R 不受影响)
xcodebuild -project WanxiangBook.xcodeproj \
  -target WanxiangBook \
  -sdk iphonesimulator \
  -arch arm64 \
  -configuration Debug \
  ONLY_ACTIVE_ARCH=YES \
  build
```

预期输出:`** BUILD SUCCEEDED **` 后产物在 `build/Debug-iphonesimulator/WanxiangBook.app/`(约 400KB,含 SwiftUI runtime 引用)。

## 目录结构

```
ios/
├── docs/
│   ├── PLAN.md                 ← 路线图 (M0~M5)
│   ├── FEATURES.md             ← 全量功能矩阵 (220+ 项)
│   ├── PROGRESS.md             ← 进度跟踪 (190 task checkbox)
│   ├── M4_APPSTORE_COPY.md     ← App Store 元数据
│   └── M4_RELEASE_CHECKLIST.md ← M4 上架检查清单
├── README.md                   ← 本文件
├── project.yml                 ← XcodeGen 工程描述 (源真理)
├── WanxiangBook.xcodeproj/     ← XcodeGen 生成 (也提交,方便 Xcode 直接打开)
└── Sources/WanxiangBook/
    ├── App/
    │   ├── WanxiangBookApp.swift     ← @main + AppState
    │   └── RootView.swift             ← M0 占位; M2.1.3 改 TabBar
    ├── Theme/
    │   └── WanxiangColors.swift       ← 设计系统 (#B8956B 主色)
    ├── Networking/
    │   ├── WanxiangAPI.swift          ← 后端 HTTP 客户端
    │   └── Keychain.swift             ← 设备身份持久化
    ├── Database/
    │   └── DB.swift                   ← SQLite actor (5 张核心表)
    ├── BookSource/                    ← M1 阶段建
    ├── Features/                      ← M2 阶段建 (Bookshelf/BookStore/Reader/...)
    ├── Ad/                            ← M3 阶段建 (Pangle iOS + GDT iOS)
    ├── Resources/                     ← Assets / 字体 / 法律 markdown
    └── Info.plist
```

## 配置约定

- **Bundle ID**: `com.wanxiang.reader`(跟 Android applicationId 一致)
- **Deployment Target**: iOS 17.0
- **Swift 版本**: 5.9
- **后端**: `http://104.224.156.240`(M5 备案完成切 `https://api.wanxiangbook.com`)
- **平台标识**: 全部请求带 `X-Platform: ios`,后端 `/api/sources` 自动按 platform 过滤(M0-B 已上线)

## 已知限制

- M0 阶段只是脚手架,App 启动后只显示"万象书屋 · 已就绪",**没有真正的 UI**
- 这是预期 — 后续 M2.1 会接 TabBar,M2.5 接阅读器,等等
- 想看一个真能用的 App,等 M2 完成(预计 7 个月后,Tier C 完美复刻路线)

## 下一步开发指南

1. 装 iOS 模拟器 runtime(Xcode → Settings → Components,下 iOS 18.x)
2. 跑模拟器,看启动日志:`[WanxiangAPI] device registered, token=xxx*** platform=ios`
3. 服务器侧验证:
   ```bash
   ssh root@104.224.156.240 "sqlite3 /opt/wanxiang/backend/data/wanxiang.db \
     'SELECT platform, COUNT(*) FROM device_tokens GROUP BY platform'"
   # 应该看到 ios|N
   ```
4. 启动 M1: 装 SwiftSoup → 写 `Sources/WanxiangBook/BookSource/BookSourceEngine.swift`(见 PLAN.md §3.3 任务清单)
