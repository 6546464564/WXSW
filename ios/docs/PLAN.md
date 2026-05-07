# 万象书屋 · iOS 端 落地方案

> 起草: 2026-05-04 · 状态: 待用户拍板 · 范围: 从零到 App Store 上架
>
> 决策记录(用户已选):
> - **Q1 书源引擎**: 原生(SwiftSoup + JavaScriptCore)
> - **Q2 商业化**: 完全免费 + 广告(穿山甲 iOS + 优量汇 iOS)
> - **Q3 默认书源**: 后端按 `platform=ios` 过滤精选
> - **Q4 起点**: 不复用旧 16 个 Swift 文件,从零写

---

## 0. 关键约束(开工前必须达成共识)

### 0.1 GPLv3 隔离
Android 端 `app/src/main/java/io/legado/app/**` 是从 [legado](https://github.com/gedoor/legado) (GPLv3) 分叉的。**iOS 端代码必须独立写**,不能 port Kotlin 源码。
- ✅ **可以**: 复用后端 API 协议、数据模型概念、UX 设计思路、UI 截图风格
- ❌ **不可以**: 翻译 `BookSourceParser.kt` → `BookSourceParser.swift` 的逐行实现,翻译 `ReadBookActivity.kt` 的逻辑流程

> 法律意义上 GPLv3 通过网络传输不传染(LGPL ≠ GPL),所以共用一个后端 OK,但 App 二进制如果包含 GPLv3 衍生代码,需要全 App 开源。**苹果 App Store 历史上拒过 GPLv3 App**(VLC 案例),走"独立写"路线最稳。

### 0.2 Apple 5.2.3 风险("免费阅读 + 广告变现")
**首次过审率预估 25-40%**,被拒的话最常见三种拒因(M3 阶段会逐一对治):
- **4.2 Minimum Functionality** — 嫌阅读 App 没差异化
- **5.2.3 Third-Party Content** — 审核员手动打开某书源,落到盗版站
- **5.1.1 Data Collection** — 隐私清单/政策不一致

**对治策略已写进 M3**(App 名字定位 / 首启空内容 / 广告频次控制 / 后端审核期临时关广告 / 关于页展示开源).

### 0.3 后端单实例假设
现在后端 = 单台 `104.224.156.240` + better-sqlite3 单连接同步。iOS 端上线后并发会翻倍,需要监控 `/api/sources` 的 ETag 命中率和响应时间。**M5 上架后**根据真实 QPS 决定是否上 Postgres + 连接池。

### 0.4 Bundle ID 与 IAP(即使现在不做)
- iOS Bundle ID = `com.wanxiang.reader`(跟 Android applicationId 一致)
- IAP 现在选了"不做",但**App Store Connect 配置 App 的时候就要选"是否 IAP"**,后期改成本高
- **建议**: App Store Connect 创建 App 时勾上"In-App Purchase",**SKU 暂不上架**。这样后续要切付费很轻松,现在不影响审核

---

## 1. 总览路线 (档 C · 完美复刻 · 1:1 对等 Android)

> **档位**: 用户选定 **档 C** (FEATURES.md §27),目标是 Android 上 P0/P1/P2 共 ~210 项功能 iOS 全做。
> **基准**: 单人全职;并行开发可缩短约 30-40% 时间。

| 阶段 | 名字 | 工作量 | 主要交付 |
|---|---|---|---|
| M0 | 工程脚手架 + 后端平台过滤 | 1 周 | 空 SwiftUI App 能冷启动连后端 |
| M1 | 书源引擎 (完整版) | **3 周** | 跑通 Android 兼容的全部 selector + JS 兼容垫片 |
| **M2** | **全量功能复刻** (10 个子里程碑) | **~28 周 / 6.5 月** | FEATURES.md §3-§24 全部 P0+P1+P2 上线 |
| M3 | 广告 SDK + 合规抛光 | 2 周 | TestFlight 内测包 |
| M4 | 上架前准备 | 1.5 周 | 截图 + 文案 + 构建 |
| M5 | 提审 + 通过 | 2-4 周 | 在售 |
| **合计** | | **约 38-40 周 ≈ 8.5-10 个月** | (FEATURES.md §27 估算 8-12 月,本计划取下沿) |

**M2 子里程碑预览** (按 FEATURES.md 章节聚合):

| 子里程碑 | 内容 | FEATURES 节 | 工时 |
|---|---|---|---|
| M2.1 | 主导航 + 我的页基础 | §3 | 1 周 |
| M2.2 | 书架 (视图/排序/分组/工具栏 11 项) | §4 | 2.5 周 |
| M2.3 | 书城 (男/女/出版/排行/推荐, 走后端代理) | §5 | 2.5 周 |
| M2.4 | 搜索 (多源并发 + 去重 + 历史) | §6 | 1.5 周 |
| M2.5 | **阅读器主战场** (40+ 项含分页算法) | §7 | **7 周** |
| M2.6 | 漫画 + 有声 | §8 + §9 | 4 周 |
| M2.7 | 规则系统 UI (替换/词典/TXT 目录) | §12 + §13 + §14 | 2 周 |
| M2.8 | 本地导入 + 缓存离线 | §15 + §16 | 3 周 |
| M2.9 | 书签/浏览器/二维码/文件/字体/导入导出 | §17 + §18 + §19 + §20 | 3 周 |
| M2.10 | 设置面板 (50-60 项) + 主题/封面 | §23 + §24 | 2 周 |

**关键里程碑节点**:
- M0 末: 模拟器能冷启动,后端 `/api/sources?platform=ios` 返过滤后的列表
- M1 末: 实机搜索"斗破苍穹"出 ≥ 1 个真实结果, 并能跑后端任意标 iOS 的源
- M2.5 末 (第 ~5 月): 阅读器全功能可用,可以 dogfood
- M2 末 (第 ~7 月): 全功能跑通,书架/书城/阅读器/漫画/有声/缓存/规则/设置全在
- M3 末: TestFlight 内测,crash-free 率 ≥ 99%
- M5 末: App Store 在售

---

## 2. M0 · 工程脚手架 + 后端平台过滤(1 周)

### 2.1 后端: 加 `platforms` 过滤
**前置任务,必须先做**(否则 iOS App 无法拉到精选源)。

#### Task M0-B1 · 数据库 schema 加 platforms 列
- **文件**: `backend/db.js`, `backend/migrations/00X-add-source-platforms.sql`
- **改动**:
  ```sql
  ALTER TABLE book_sources ADD COLUMN platforms TEXT NOT NULL DEFAULT 'android,ios';
  -- 默认值 'android,ios' 让历史源对所有平台可见, 不破坏 Android 现有行为
  ```
- **验收**: `sqlite3` 检查 schema 有 platforms 列,`SELECT COUNT(*) FROM book_sources WHERE platforms LIKE '%ios%'` = 全部行数
- **工作量**: 1 小时

#### Task M0-B2 · `/api/sources` 加 platform 过滤
- **文件**: `backend/server.js:717` + `backend/db.js:listEnabledSourcesJson`
- **改动**:
  - `listEnabledSourcesJson(platform = null)` 内部 `WHERE enabled=1 AND (? IS NULL OR platforms LIKE '%' || ? || '%')`
  - server.js 路由读 `req.platform`(已经被中间件解析)然后传进去
  - **ETag 计算也要按 platform 分桶**,否则 iOS 拿到 Android 的 304(`getEnabledSourcesEtag(platform)`)
- **验收**:
  - `curl -H 'X-Platform: ios' /api/sources` → 只返 `platforms LIKE '%ios%'` 的源
  - `curl -H 'X-Platform: android' /api/sources` → 只返 `platforms LIKE '%android%'` 的源
  - 两个 platform 的 ETag 不同
- **工作量**: 半天

#### Task M0-B3 · admin 面板加"平台勾选"列
- **文件**: `backend/public/admin.html` + `backend/server.js`(加 PATCH `/api/admin/sources/:id/platforms`)
- **改动**:
  - admin 表格每行加 [Android✓] [iOS✓] 两个 checkbox
  - 批量操作: "全选/全取消 iOS"
  - admin **手工挑选** 5-10 个干净的源勾上 iOS 标(古诗词网 / 公版书 / Project Gutenberg 中文区等)
- **验收**: admin 面板能勾选,数据库正确写入
- **工作量**: 半天

#### Task M0-B4 · 单元测试覆盖
- **文件**: `backend/test/api.test.js`
- **新增 case**:
  - `GET /api/sources` 不带 X-Platform → 默认 android(向下兼容)
  - `GET /api/sources` 带 X-Platform: ios → 仅返 ios 标记的
  - `GET /api/sources` 带 X-Platform: ios + If-None-Match → 304(自家平台 ETag 命中)
  - `PATCH /api/admin/sources/:id/platforms` → 鉴权 + 写入校验
- **验收**: `npm run test:api` 全绿
- **工作量**: 半天

### 2.2 iOS 工程: 起脚手架(纯 CLI, 无需 Xcode GUI)

#### Task M0-I1 · 创建 SwiftPM-friendly 工程结构
- **路径**: `ios/`(刚清空的)
- **文件树**:
  ```
  ios/
  ├── README.md                ← 简短: "用 Xcode 16+ 打开 WanxiangBook.xcodeproj"
  ├── PLAN.md                  ← 本文件
  ├── .gitignore               ← Xcode + Swift
  ├── Project.swift            ← Tuist 工程描述(替代 .xcodeproj 二进制文件)
  └── Sources/
      └── WanxiangBook/
          ├── App.swift              ← @main, 60 行
          ├── Info.plist             ← Bundle ID + ATT 描述 + ATS
          ├── PrivacyInfo.xcprivacy  ← iOS 17 隐私清单
          └── (后续 M1-M2 文件全在这里)
  ```
- **决策点 A**: 用 Tuist 还是直接 commit `.xcodeproj`?
  - **Tuist 推荐**: `.xcodeproj` 是 plist + UUID 一堆 merge 冲突源,Tuist 用 Swift 描述工程然后生成 → 几乎无冲突
  - 反方: 多一个工具链门槛(`brew install tuist`)
  - **本方案默认 Tuist**,反对就把这条改成 commit `.xcodeproj` 的方案,我立刻调
- **工作量**: 半天

#### Task M0-I2 · 最小 SwiftUI App
- **文件**: `Sources/WanxiangBook/App.swift`
- **内容**: `@main App` + 一个空白 ContentView 显示"Hello 万象书屋 iOS"
- **验收**: `xcodebuild -scheme WanxiangBook -destination 'platform=iOS Simulator,name=iPhone 15' build` 成功
- **工作量**: 1 小时

#### Task M0-I3 · 网络层骨架 WanxiangAPI
- **文件**: `Sources/WanxiangBook/Networking/WanxiangAPI.swift` + `Networking/Endpoints.swift`
- **职责**:
  - 单例 actor,管 baseURL + 通用 header(`X-Platform: ios` / `X-Device-Id` / `X-Device-Token`)
  - 5 个核心方法骨架: `registerDevice()` / `fetchSources()` / `ping()` / `fetchAdConfig()` / `reportCrash(_:)`
  - **不实现业务逻辑**,只对齐协议
- **验收**:
  - 单元测试: mock `URLProtocol` 验证发出去的 request 带正确 header
  - 跑模拟器,启动 5 秒内打 `/api/device/register`,后端日志能看到 `pf=ios` 的注册记录
- **工作量**: 1 天

#### Task M0-I4 · 持久化骨架(Keychain + SQLite + UserDefaults)
- **Keychain**: 存 `device_id`(UUID, App 删了再装也保留)+ `device_token`(后端签发)
- **SQLite**: 直接用系统 `sqlite3` C API 包装一层 actor;**不引 GRDB**(避免依赖)
  - 表: `books` / `chapters` / `book_sources` / `read_progress`
- **UserDefaults**: 阅读偏好(字号/主题/翻页方式)
- **验收**: 单元测试 CRUD 全过
- **工作量**: 2 天

#### Task M0-I5 · 端到端连通验证
- 模拟器跑起来 → 触发设备注册 → 后端 `device_tokens` 表新增 `platform=ios` 一行 → 心跳 `/api/ping` 每 4 分钟一次 → 拉 `/api/sources?platform=ios` 拿到精选列表 → 写进本地 SQLite
- **验收**: 全链路无报错,后端 `wanxiang.db` 用 `SELECT platform, COUNT(*) FROM device_tokens GROUP BY platform` 看到 ios 维度
- **工作量**: 半天

**M0 合计 · 1 周**

---

## 3. M1 · 书源引擎 完整版(3 周, Tier C 必须)

### 3.1 设计目标
让 iOS 能跑 legado 兼容的**全部书源 JSON 规则**,实现:`搜索 → 详情 → 章节列表 → 正文 → 净化 → 替换 → 编码`,同时支持 `ruleExplore`(书城频道)和 `ruleReview`(段评)等长尾规则。Tier C 要求 **跟 Android 同源同行为**,不允许"5 个公版书源跑通"的 MVP 妥协。

### 3.2 模块拆分
```
Sources/WanxiangBook/BookSource/
├── BookSourceEngine.swift          ← 入口,4 个 public method
├── Selector/
│   ├── SelectorDispatcher.swift    ← 解析 @css: / @xpath: / @json: / @js: 前缀
│   ├── CSSSelectorEngine.swift     ← SwiftSoup 包装
│   ├── XPathSelectorEngine.swift   ← libxml2 包装
│   ├── JSONPathEngine.swift        ← 简易 JSONPath 实现
│   └── JSEngine.swift              ← JavaScriptCore 包装
├── Parser/
│   ├── SearchParser.swift
│   ├── BookInfoParser.swift
│   ├── TocParser.swift
│   └── ContentParser.swift
└── Network/
    └── HTTPFetcher.swift           ← URLSession + cookie + UA + 重试
```

### 3.3 任务清单 (Tier C 完整版)
| Task | 内容 | 工作量 | 验收 |
|---|---|---|---|
| M1-1 | 装 SwiftSoup(SPM 依赖) + 包一层 `CSSSelectorEngine` (含 `:contains()` `:gt()` 等 jsoup 扩展) | 1 天 | unit test: 30 个 jsoup 兼容 case |
| M1-2 | libxml2 系统库 + `XPathSelectorEngine`(含 XPath 1.0 + 部分 2.0 函数) | 1.5 天 | unit test: 20 个真实书源的 XPath 全过 |
| M1-3 | `SelectorDispatcher` 识别 `@css:` `@xpath:` `@json:` `@js:` `@regex:` 前缀 + 多重规则组合(例 `@css:.book@text##\\d+`) | 1.5 天 | 给 50 个真实规则字符串能正确路由 |
| M1-4 | `JSEngine`(JavaScriptCore)+ Rhino 兼容垫片:`java.put` / `java.get` / `java.log` / `java.ajax` / `java.cache` 等 20+ API | 4 天 | 跑 legado 文档全部 JS 示例 + `JsExtensions` 80% 兼容 |
| M1-5 | `HTTPFetcher`:GET/POST/multipart + UA 伪装 + cookie 持久化 + 重试 + 超时 + 自动 gzip + 编码探测 | 2 天 | 抓 50 个真实站异常路径全 fallback |
| M1-6 | `SearchParser` → 跑 `ruleSearch.bookList` + 全部 8 个字段选择器 + 翻页 | 1 天 | 真实搜 → 至少 3 个源出结果 |
| M1-7 | `BookInfoParser` → 跑 `ruleBookInfo` → 含 `init` 预处理 + `tocUrl` 计算 + 元数据全字段 | 1 天 | 单测 |
| M1-8 | `TocParser` → 跑 `ruleToc.chapterList` + 多页目录翻页 + 章节去重 | 1.5 天 | 抓 5 部不同书的目录 |
| M1-9 | `ContentParser` → 跑 `ruleContent.content` + 段落分割 + 图片提取 + JS 后处理 + 多页正文 | 2 天 | 净化后正文长度合理 |
| M1-10 | `ExploreParser` → 跑 `ruleExplore`(书城/发现频道) | 1 天 | 男生/女生/出版三频道能拉列表 |
| M1-11 | 自动换源(失败次数 + 阈值切下一个) + 并发限速(`concurrentRate`) | 1 天 | mock 5 源,2 个故障能自动跳 |
| M1-12 | 书源登录(WKWebView + cookie 持久化 + 表单填充) | 1.5 天 | 至少 2 个需登录站登录后能搜 |
| M1-13 | 全平台编码探测(GBK/UTF-8/Big5)+ 自动转 String | 1 天 | 抓 GBK 站不乱码 |
| M1-14 | 端到端集成测试:CLI 工具 `swift run BookSourceCLI` 跑通 search/info/toc/content 全链路 | 1 天 | 后端 admin 标 iOS 的全部源 ≥ 80% 通过 |

**M1 合计 · 3 周**

### 3.4 风险点
- **JS 引擎不一致**: legado Android 用 Rhino,iOS 用 JavaScriptCore。Rhino 自带的 `java.*` API 在 JSC 没有,需要写垫片
- **某些源用了 OkHttp 特性**(如 dns-over-https): iOS 默认 URLSession 不一定支持,先用全平台兼容的 5 个源做基线
- **SwiftSoup CSS 选择器跟 jsoup 行为偏差**: 已知 `:contains()` 实现略有差,**测试覆盖必须高**

---

## 4. M2 · 全量功能复刻(28 周 / 6.5 月, Tier C 主体)

> 本章是档 C 的核心。每个 task 编号 `M2.x.y` 一一对应 FEATURES.md 的功能项编号(例如 M2.5.7.3 对应 FEATURES.md §7.7.3)。
> **进度跟踪**: 在 `ios/PROGRESS.md` 维护勾选清单(后续生成)。

### 4.0 模块目录(Tier C 完整)
```
Sources/WanxiangBook/
├── App/                  ← @main, AppState, RootView (TabBar)
├── Theme/                ← 万象棕金 #B8956B 设计系统
├── Networking/           ← WanxiangAPI + Endpoints
├── Database/             ← SQLite actor + 19 张表 + 9 个 DAO 等价
├── BookSource/           ← M1 输出
├── Features/
│   ├── Splash/           ← 启动 + 隐私同意 + 开屏广告
│   ├── Bookshelf/        ← 书架 (M2.2)
│   ├── BookStore/        ← 书城 (M2.3)
│   ├── Search/           ← 搜索 (M2.4)
│   ├── BookDetail/       ← 详情
│   ├── Reader/           ← 阅读器 (M2.5, 最重)
│   ├── Manga/            ← 漫画 (M2.6)
│   ├── Audio/            ← 有声 (M2.6)
│   ├── Toc/              ← 目录
│   ├── Cache/            ← 缓存离线 (M2.8)
│   ├── Bookmark/         ← 书签 (M2.9)
│   ├── ReadRecord/       ← 阅读时长统计
│   ├── My/               ← 我的页
│   ├── Settings/         ← 设置面板 (M2.10)
│   ├── Legal/            ← 法律 markdown 渲染
│   ├── Feedback/         ← 反馈
│   ├── AccountDelete/    ← 注销
│   ├── Browser/          ← 内置 WKWebView
│   ├── QrCode/           ← 扫码 (M2.9)
│   ├── FileManage/       ← 文件管理 (M2.9)
│   ├── Font/             ← 字体管理
│   ├── ImportLocal/      ← TXT/EPUB/MOBI/PDF (M2.8)
│   └── Replace + Dict + TxtToc/  ← 三种规则 (M2.7)
└── Ad/                   ← 广告 SDK (M3 接入)
```

---

### M2.1 · 主导航 + 我的页基础(1 周, 对应 FEATURES.md §3)

| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.1.1 | 万象品牌色系统 (`Color.wanxiangPrimary = #B8956B` + 强调色 + 背景 + 主题列表) | §23.6 | 0.5d |
| M2.1.2 | 全局 ViewModifier(导航栏样式 / 沉浸式状态栏 / 主题切换 observer) | §23.4 | 0.5d |
| M2.1.3 | TabBar 容器 (书架/书城/我的) | §3.1 | 0.5d |
| M2.1.4 | 我的页 List 骨架(18 项入口) | §3.2 | 1d |
| M2.1.5 | 顶部"纯净阅读"卡片(倒计时 + 延长解锁按钮 ← 等 M2.5 + M3 实现) | §3.2.1 | 1d |
| M2.1.6 | 主题模式偏好(随系统/日间/夜间)+ 持久化 | §3.2.5 | 0.5d |
| M2.1.7 | 全局崩溃捕获 → `/api/crash-log`(NSSetUncaughtExceptionHandler + signal) | §21.6 | 0.5d |
| M2.1.8 | 启动检查公告 → 显示横幅 | §21.9 | 0.5d |

---

### M2.2 · 书架(2.5 周, 对应 §4)

| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.2.1 | 网格视图(3/4/5/6 列, 偏好持久) | §4.1.1 | 1d |
| M2.2.2 | 列表视图(可切换) | §4.1.2 | 0.5d |
| M2.2.3 | 6 种排序(最近/更新/书名/手动/综合/作者) | §4.1.3 | 1d |
| M2.2.4 | 进度条角标 | §4.1.4 | 0.5d |
| M2.2.5 | 缓存状态角标 | §4.1.5 | 0.5d |
| M2.2.6 | 阅读状态筛选(追更/养肥/完结/全部) | §4.1.6 | 1d |
| M2.2.7 | 长按菜单(置顶/分组/删除/换源) | §4.1.7 | 1d |
| M2.2.8 | 工具栏:搜索 / 更新目录 / 添加本地 / 网络导入 / 书架管理 / 缓存导出 / 分组管理 / 布局 / 导入导出 / 日志(11 项) | §4.2 | 3d |
| M2.2.9 | 分组系统:CRUD + 拖拽排序 + 多选移动 + 子书架 | §4.3 | 2d |
| M2.2.10 | 拉本地 SQLite + 实时进度更新 | §4 (基础) | 1d |
| M2.2.11 | 批量更新目录(后台并发限速) | §4.2.2 | 1d |

---

### M2.3 · 书城(2.5 周, 对应 §5)

| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.3.1 | **后端加 `/api/bookstore/feed?platform=ios&channel=male` 代理接口**(避免 iOS 直 hit 起点被反爬) | §5.2 | 后端 2d |
| M2.3.2 | 三 tab 主结构(男生/女生/出版) | §5.1.1 | 1d |
| M2.3.3 | 子频道(排行/分类/完结/连载) | §5.1.2 | 1.5d |
| M2.3.4 | 推荐卡:今日必读 / 连载专区 / 完结之选 / 推荐排行 | §5.1.3 | 2d |
| M2.3.5 | "换一换" 随机刷新 | §5.1.4 | 0.5d |
| M2.3.6 | 加载状态(loading/load_failed/coming_soon) | §5.1.5 | 0.5d |
| M2.3.7 | banner 关键词点击跳搜索 | §5.1.6 | 0.5d |
| M2.3.8 | 漫画入口(若 `show_manga_ui = true`)→ ReadMangaActivity | §5.1.7 | 0.5d |
| M2.3.9 | 会员/英雄角标 | §5.1.8 | 0.5d |
| M2.3.10 | 书城 → 详情页 → 加书架 全链路 | §5 + §6.9 | 1d |
| M2.3.11 | 离线/网络异常时的优雅降级 | §5.1.5 | 0.5d |

---

### M2.4 · 搜索(1.5 周, 对应 §6)

| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.4.1 | 关键词输入(防抖 300ms)+ 搜索框 | §6.1 | 0.5d |
| M2.4.2 | 多书源并发抓取 + AsyncStream 边出边渲染 | §6.2 | 2d |
| M2.4.3 | 按"书名+作者"去重 + 按相关度排序 | §6.3 + §6.4 | 1d |
| M2.4.4 | 搜索范围筛选(全部/分组/单源)→ SearchScopeDialog | §6.5 | 1d |
| M2.4.5 | 搜索历史(本地 SQLite, 自动过期) | §6.6 + §6.7 | 0.5d |
| M2.4.6 | 一键加书架(选分组) | §6.8 | 0.5d |
| M2.4.7 | 异常源熔断(连续超时 N 次禁用 1h) | §6.10 | 1d |
| M2.4.8 | 详情页(封面/简介/目录预览/加书架/换源/开始阅读) | §6.9 | 1.5d |

---

### M2.5 · 阅读器主战场(7 周 = 35 工作日, 对应 §7)⚠️ 工程难点最集中

> **这是整个项目最大的一块**。FEATURES.md §7 列出 40+ 项功能,任何一项的省略都会让用户察觉。
> **建议**: 这一段如果有人手,**优先调 1 个人专门做阅读器**,跟其它子里程碑并行。

#### M2.5.1 阅读器骨架(1 周)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.5.1.1 | ReadBookActivity 等价 SwiftUI ReaderView 主容器 | §7.1.1 | 1d |
| M2.5.1.2 | 章节加载 + 缓存 + 上次进度恢复 | §7.1.2 + §7.1.3 | 1.5d |
| M2.5.1.3 | 横竖屏自适应 + 屏幕方向锁 | §7.1.4 + §7.1.5 | 0.5d |
| M2.5.1.4 | 保持常亮(idleTimerDisabled) | §7.1.6 | 0.5d |
| M2.5.1.5 | 章节预拉(下一章 + 上一章) | §16.7 | 1d |
| M2.5.1.6 | TocActivity 等价(目录跳转) | §7.9.1 | 0.5d |

#### M2.5.2 分页算法(2 周)⚠️ 工程难点 #1
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.5.2.1 | CoreText `CTFramesetter` 包装,给 (text, font, width, height) 出一页 NSAttributedString | §7.3.11 | 3d |
| M2.5.2.2 | 段落 + 缩进 + 行距 + 段距 排版 | §7.3.1-7.3.6 | 2d |
| M2.5.2.3 | 两端对齐 + 中文标点压缩 | §7.3.7 + §7.3.9 | 2d |
| M2.5.2.4 | 横屏双页布局 | §7.3.12 | 1.5d |
| M2.5.2.5 | 刘海区留白(safeArea) | §7.3.13 | 0.5d |
| M2.5.2.6 | 简繁转换(数据集 ~50KB) | §7.3.10 | 1d |

#### M2.5.3 翻页方式(1 周)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.5.3.1 | 覆盖 (TabView + 自定义 transition) | §7.2.1 | 1d |
| M2.5.3.2 | 滑动 (TabView .page) | §7.2.2 | 0.5d |
| M2.5.3.3 | 滚动垂直无限 (LazyVStack) | §7.2.4 | 1.5d |
| M2.5.3.4 | 无动画 | §7.2.5 | 0.2d |
| M2.5.3.5 | **仿真翻书 (Metal shader + UIBezierPath)** ⚠️ 工程难点 #2 | §7.2.3 | 4d |

#### M2.5.4 主题与配色(0.5 周)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.5.4.1 | 4 套预设主题(默认/护眼/夜间/羊皮纸) | §7.4.1 | 0.5d |
| M2.5.4.2 | 自定义背景色 + 文字色 | §7.4.2 + §7.4.3 | 0.5d |
| M2.5.4.3 | 自定义背景图(系统相册) | §7.4.4 | 1d |
| M2.5.4.4 | 主题列表导入导出 | §7.4.5 | 1d |
| M2.5.4.5 | 亮度调节 + 自动亮度 | §7.4.6 + §7.4.7 | 0.5d |
| M2.5.4.6 | 沉浸式状态栏 + E-ink 模式 | §7.4.8 + §7.4.9 | 1d |

#### M2.5.5 主菜单 18 项(1 周)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.5.5.1 | 换源 ChangeBookSourceDialog | §7.5.1 | 2d |
| M2.5.5.2 | 刷新(当前/之后/全部) | §7.5.2 | 0.5d |
| M2.5.5.3 | 离线下载入口 → CacheView | §7.5.3 | 0.2d |
| M2.5.5.4 | 编码切换(本地 TXT) | §7.5.4 | 1d |
| M2.5.5.5 | 添加书签 → BookmarkDialog | §7.5.5 | 0.5d |
| M2.5.5.6 | 编辑正文(本地修改) | §7.5.6 | 1d |
| M2.5.5.7 | 翻页动画切换 | §7.5.7 | 0.2d |
| M2.5.5.8 | 倒序正文 / 模拟阅读 / 替换开关 / 去重标题 / 重新分段 | §7.5.9-7.5.13 | 1.5d |
| M2.5.5.9 | EPUB 去注音 / 图片样式 / 更新目录 / 生效替换 / 帮助 | §7.5.14-7.5.18 | 1d |

> §7.5.8 获取/覆盖云进度 → ⚫ P3 不做(WebDAV 已删)

#### M2.5.6 选词菜单 + 配置 Dialog(1 周)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.5.6.1 | 长按选词 7 项菜单(替换/复制/书签/词典/正文搜索/浏览器/分享) | §7.6 | 1.5d |
| M2.5.6.2 | ReadStyleDialog(底部大面板) | §7.7.1 | 1d |
| M2.5.6.3 | BgTextConfigDialog | §7.7.2 | 0.5d |
| M2.5.6.4 | PaddingConfigDialog | §7.7.3 | 0.3d |
| M2.5.6.5 | TipConfigDialog(页眉页脚) | §7.7.4 | 1d |
| M2.5.6.6 | ClickActionConfigDialog(九宫格) | §7.7.5 | 1d |
| M2.5.6.7 | MoreConfigDialog | §7.7.6 | 0.5d |
| M2.5.6.8 | AutoReadDialog(自动翻页速度) | §7.7.7 | 0.5d |
| M2.5.6.9 | ContentEditDialog | §7.7.9 | 0.5d |
| M2.5.6.10 | EffectiveReplacesDialog | §7.7.10 | 0.3d |

#### M2.5.7 手势 + 进度跳章 + 全书搜索(0.5 周)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.5.7.1 | 9 区域点击映射(自定义) | §7.8.1 + §7.8.2 | 1d |
| M2.5.7.2 | 横向滑动翻页 + 长按选词 | §7.8.3 + §7.8.5 | 0.5d |
| M2.5.7.3 | 上滑唤目录 | §7.8.4 | 0.3d |
| M2.5.7.4 | 双指捏合调字号(iOS 自加) | §7.8.9 | 0.5d |
| M2.5.7.5 | 进度条拖拽 + 上下章 | §7.9.2 + §7.9.3 | 0.5d |
| M2.5.7.6 | 阅读时长统计(每秒+1 写 SQLite) | §7.9.4 | 0.5d |
| M2.5.7.7 | SearchMenu(章节内高亮) | §7.10.1 | 1d |
| M2.5.7.8 | SearchContentActivity 等价(全书搜) | §7.10.2 + §7.10.3 | 1.5d |

#### M2.5.8 万象付费墙整套(1 周, 对应 §7.12)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.5.8.1 | AdRateLimiter Swift 版(章节计数 / 解锁窗口 / 累计上限) | §7.12.5 | 1.5d |
| M2.5.8.2 | 章节付费墙覆盖层 | §7.12.1 | 1.5d |
| M2.5.8.3 | 顶部纯净阅读倒计时条 | §7.12.2 | 1d |
| M2.5.8.4 | 激励视频回调解锁 30 分钟 | §7.12.3 + §7.12.4 | 1d |
| M2.5.8.5 | 熔断逻辑(连续 N 次失败送短期解锁) | §7.12.6 | 0.5d |
| M2.5.8.6 | 读完页内嵌 view(去书架/去书城/换源/续广告) | §7.12.7 | 1d |

> ⚠️ **iOS 风险提醒**: 这套在 iOS 可能违反 **3.1.1 In-App Purchase**(看广告解锁付费功能)。Tier C 选了"完全免费 + 广告"的方案,这一段是必踩的雷。M5 阶段我们准备申诉信:**强调"广告解锁"是激励留存,不是绕开付费**。

---

### M2.6 · 漫画 + 有声(4 周, 对应 §8 + §9)

#### M2.6.1 漫画(2 周, §8)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.6.1.1 | ReadMangaActivity 等价 MangaReaderView | §8.1 | 2d |
| M2.6.1.2 | 漫画翻页(竖滚 / 横翻) | §8.2 | 2d |
| M2.6.1.3 | 电子纸模式 + 颜色滤镜 + 页脚信息 | §8.3-8.5 | 2d |
| M2.6.1.4 | 自动翻页 | §8.6 | 1d |
| M2.6.1.5 | 漫画图片预拉 + Kingfisher 缓存调优 | - | 1d |
| M2.6.1.6 | 漫画手势(双击放大 / 双指缩放 / 长按保存) | - | 1d |
| M2.6.1.7 | 漫画书源解析适配 | - | 1d |

#### M2.6.2 有声书(2 周, §9)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.6.2.1 | AudioPlayActivity 等价 AudioPlayerView | §9.1 | 1.5d |
| M2.6.2.2 | AVPlayer + AVAudioSession.playback 后台播放 | §9.2 + §9.4 | 1.5d |
| M2.6.2.3 | MPNowPlayingInfoCenter 锁屏控制 | §9.3 | 1d |
| M2.6.2.4 | MPRemoteCommandCenter(蓝牙耳机) | §9.5 | 1d |
| M2.6.2.5 | 倍速 0.5x-3x | §9.6 | 0.3d |
| M2.6.2.6 | 章节列表 / 跳章 / 进度条 | - | 1d |
| M2.6.2.7 | 定时关闭(15min/30min/60min/章末) | - | 0.5d |
| M2.6.2.8 | 试听限制 + 解锁(若产品要) | - | 1d |

---

### M2.7 · 规则系统 UI(2 周, 对应 §12 + §13 + §14)

> 注:**书源管理 UI 不做**(后端管理),只做这三种用户可创建的规则。

| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.7.1 | 替换规则列表 + 编辑(正则/范围/作用域) | §12.1 + §12.2 | 2d |
| M2.7.2 | 替换规则分组 + 导入(URL/文件/二维码) | §12.3 + §12.4 | 1.5d |
| M2.7.3 | 阅读器内替换开关 + 净化引擎执行 | §12.5 + §12.6 | 1d |
| M2.7.4 | 词典规则列表 + 编辑 + 内置词典(汉典/有道/百度) | §13 | 2d |
| M2.7.5 | 长按选词 → DictDialog 调词典 | §13.3 | 1d |
| M2.7.6 | TXT 目录规则列表 + 编辑 + 默认规则 | §14.1 + §14.2 + §14.4 | 1.5d |
| M2.7.7 | 本地 TXT 应用规则切章 | §14.3 | 1d |

---

### M2.8 · 本地导入 + 缓存离线(3 周, 对应 §15 + §16)

#### M2.8.1 本地导入(1.5 周)
| Task | 格式 | FEAT# | 工时 |
|---|---|---|---|
| M2.8.1.1 | TXT(编码探测 + 切章) | §15.1 TXT | 1.5d |
| M2.8.1.2 | EPUB(EPUBKit 或自实现 zip + xml 解析) | §15.1 EPUB | 3d |
| M2.8.1.3 | MOBI / AZW(自实现或找 swift 库) | §15.1 MOBI | 3d |
| M2.8.1.4 | PDF(PDFKit 系统) | §15.1 PDF | 1d |
| M2.8.1.5 | UMD(自实现) | §15.1 UMD | 2d |
| M2.8.1.6 | ZIP/RAR/7z 解压(libarchive bridge) | §15.1 ZIP | 1.5d |
| M2.8.1.7 | iOS 文件 App "用万象书屋打开" + Document Types | §15.2.2 | 0.5d |
| M2.8.1.8 | iOS Share Extension(从其它 app 导入) | §15.2.3 | 1d |

#### M2.8.2 缓存离线下载(1.5 周)
| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.8.2.1 | CacheActivity 等价 CacheView 列表 | §16.1 | 1d |
| M2.8.2.2 | 后台批量下载章节(BGTaskScheduler) | §16.2 + §16.3 | 3d |
| M2.8.2.3 | 下载某章之后所有 / 全部 | §16.4 + §16.5 | 0.5d |
| M2.8.2.4 | 导出书 (TXT/EPUB) | §16.6 | 2d |
| M2.8.2.5 | 进度通知(UNUserNotificationCenter) | §16.3 | 1d |
| M2.8.2.6 | 阅读时预拉下一章 | §16.7 | 0.5d |

---

### M2.9 · 书签 / 浏览器 / 二维码 / 文件 / 字体 / 导入导出(3 周, 对应 §17-§20)

| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.9.1 | BookmarkDialog(添加/编辑) | §17.1 | 0.5d |
| M2.9.2 | AllBookmarkActivity 等价跨书书签列表 | §17.2 | 1.5d |
| M2.9.3 | 书签导出 markdown | §17.3 | 0.5d |
| M2.9.4 | ReadRecordActivity 阅读时长统计页 | §17.4 + §17.5 | 1.5d |
| M2.9.5 | 内置 WKWebView 浏览器 + 书源登录 cookie 注入 | §18.1 + §18.2 | 2d |
| M2.9.6 | AVCaptureMetadataOutput 二维码扫描 | §18.3 | 1d |
| M2.9.7 | CIFilter 二维码生成 | §18.4 | 0.5d |
| M2.9.8 | 文件管理 FileManageView(沙盒目录浏览) | §19.1 | 2d |
| M2.9.9 | 字体下载 + 注册(CTFontManagerRegisterFontsForURL) | §19.2 + §19.3 | 1.5d |
| M2.9.10 | 书架 JSON 导出 / 导入 | §20.3 + §20.4 | 1d |
| M2.9.11 | iCloud 文档同步(可选, 用 NSMetadataQuery) | §20.5 | 2d |

---

### M2.10 · 设置面板 + 主题/封面 + 法律(2 周, 对应 §22 + §23 + §24)

| Task | 内容 | FEAT# | 工时 |
|---|---|---|---|
| M2.10.1 | 阅读偏好(~30 项, 减去 iOS 不适用 6 项) | §24.1 | 3d |
| M2.10.2 | 主题设置(15 项) | §24.2 + §23 | 2d |
| M2.10.3 | 封面设置(6 项) | §24.3 + §23.7-23.10 | 1.5d |
| M2.10.4 | 其它设置(~25 项, 减去 iOS 不适用 5 项) | §24.4 | 3d |
| M2.10.5 | 字体下载入口 + 字体选择 dialog | §23.11 | 0.5d |
| M2.10.6 | LegalActivity 等价(读 5 份 markdown + Markdown 渲染) | §22.1 | 0.5d |
| M2.10.7 | FeedbackActivity 等价 + 调 `/api/feedback` | §22.2 | 0.5d |
| M2.10.8 | AccountDeleteActivity 等价(本地清空 SQLite + Keychain + revoke 同意) | §22.3 + §22.4 | 0.5d |
| M2.10.9 | PrivacyInfo.xcprivacy(iOS 17+ 强制) | §22.5 | 0.5d |
| M2.10.10 | ATT 弹窗 + 引导文案 | §22.6 | 0.5d |

---

### 4.3 M2 整体难点登记
1. **分页算法 (M2.5.2)**: SwiftUI 没有 Android `StaticLayout`,必须 CoreText `CTFramesetter`,最容易超时。预留 2 周 buffer。
2. **仿真翻书 (M2.5.3.5)**: Metal shader + UIBezierPath,难度 ⭐⭐⭐⭐⭐,可以延后到 v1.5
3. **EPUB / MOBI / UMD 解析 (M2.8.1)**: Swift 生态没有现成 1:1 替代,可能需要自己写或包 C 库
4. **多源并发去重 (M2.4.2)**: AsyncStream + actor + 边出边渲染,体验关键
5. **章节付费墙 (M2.5.8)**: iOS 3.1.1 高风险,M5 提审准备申诉信
6. **后台下载 (M2.8.2.2)**: iOS BGTaskScheduler 配额严, 一次最多 30s,需要切片重启逻辑
7. **JS 引擎兼容 (M1-4)**: Rhino → JavaScriptCore 垫片要持续打补丁,**预期上线后还要补 2-4 个月**

### 4.4 进度跟踪
完成 M2 时输出 `ios/PROGRESS.md`,逐项勾选 220+ 功能;v1.0 上架前要求 P0 项 100% 完成,P1 ≥ 90%,P2 ≥ 60%。

### 4.5 并行化建议
**M2 总计 28 周, 单人全职跑完接近 7 个月**。Tier C 实际很难单人扛,**强烈建议**:
- **2 人并行**: 1 人专做 M2.5 阅读器(7 周占总量 25%),另 1 人做 M2.1-2.4 + M2.6-2.10。**总周期可压到 4-5 个月**
- **3 人并行**: 加 1 个后端,做 M2.3.1 起点代理 + 后端书源 curate + admin 工具,**总周期可压到 3-4 个月**

---

## 5. M3 · 广告 + 合规 + 抛光(1.5 周)

### 5.1 广告 SDK 接入
| Task | 内容 | 工作量 |
|---|---|---|
| M3-1 | CSJ(穿山甲) iOS SDK 集成 (Info.plist 加 SKAdNetwork 项,目前要 80+ 个) | 1 天 |
| M3-2 | YLH(优量汇) iOS SDK 集成 (同样补 SKAdNetwork) | 1 天 |
| M3-3 | 实现 `AdProvider` Swift 协议 + CSJ/YLH 两个实现 + AdManager 调度(对齐 Android `AdManager.kt`) | 1 天 |
| M3-4 | 广告位: **开屏 + 详情页底部 banner + 章节末尾原生 banner**(明确**不接插屏**降低拒审风险) | 1 天 |
| M3-5 | 广告事件 callback → `/api/ad-event` 上报(后端已就绪) | 半天 |
| M3-6 | 广告动态开关: `/api/ad-config` 拉到 `enabled=false` 时全部 AdProvider 短路 | 半天 |

### 5.2 合规 (M3 后半段, **上架成败关键**)
| Task | 内容 | 工作量 |
|---|---|---|
| M3-7 | `PrivacyInfo.xcprivacy` 详细列出: 收集的数据类型 (设备 ID / 崩溃日志 / 广告 ID) + 每个的 Required Reasons API | 半天 |
| M3-8 | ATT 弹窗: 第一次启动后 + 进我的页时各引导一次,**用户拒绝则 IDFA 取不到,广告填充率会下降但不能强制** | 半天 |
| M3-9 | 隐私政策 + 用户协议 markdown(基于 Android 现有的改 platform=iOS 字样) | 1 天 |
| M3-10 | 关于页: ICP 备案号 + 开源信息 + 用户协议链接 + 隐私政策链接 + 用 SwiftUI Markdown 渲染 | 半天 |
| M3-11 | App 名字 / 描述 / 关键词去掉"小说阅读器"字样,定位"个性化书源管理" | 半天(纯文案) |
| M3-12 | 后端 `/api/ad-config` 加 `review_mode` 字段: 审核期下发 `enabled=false`, 审核通过手动切回 `true` | 后端 1 小时,iOS 0.5 小时 |

**M3 合计 · 1.5 周**

---

## 6. M4 · 上架前准备(1 周)

| Task | 内容 | 工作量 |
|---|---|---|
| M4-1 | App 图标设计 1024×1024(可基于 Android 现有 `ic_launcher.png` 思路,设计师重画 iOS 风格的圆角阴影) | 半天 |
| M4-2 | 启动屏(SwiftUI LaunchScreen.storyboard,品牌色 + Logo) | 半小时 |
| M4-3 | App Store 截图: 6.9" iPhone Pro Max(必填) + 6.5" iPhone(必填) + 13" iPad Pro(必填),每尺寸 5 张 | 2 天 |
| M4-4 | 截图文案叠图(主标题 + 副标题,中英双语) | 1 天 |
| M4-5 | App Store Connect 配置: 名字 / 副标题 / 介绍 / 关键词 / 分级 / 测试账号 / 隐私问卷 / 价格 | 1 天 |
| M4-6 | TestFlight 内测: 邀请 5 位真实用户测试 24h,收 crash + 易用性反馈 | 2 天 |
| M4-7 | 真机测试覆盖: iPhone SE(老机) + iPhone 15 + iPad 各跑核心流程 | 半天 |

**M4 合计 · 1 周**

---

## 7. M5 · 提审 + 通过(2-4 周, 不可控)

### 7.1 流程
1. App Store Connect 提审 → 苹果审核员排队 1-3 天
2. **第一次审核结果通常 24-72h 内**
3. 被拒 → 看拒因 → 修复 → 重新提交 → 再 1-3 天

### 7.2 应对预案(按拒因 likelihood 排)
| 拒因代码 | 概率 | 应对 |
|---|---|---|
| 5.2.3 Third-Party Content | **70%** | 准备一份"申诉信",说明书源是用户自添加,App 本身没盗版内容,Cite GitHub stars 表明开源属性 |
| 4.2 Minimum Functionality | 40% | App Store 描述强调差异化: WebDAV 同步 / 批量管理 / 自定义书源 / TXT 导入 |
| 5.1.1 Data Collection | 30% | 隐私清单 + 政策 + ATT 文案三处必须字段一致 |
| 4.0 Design | 20% | 看具体截图,通常补几张交互截图能过 |
| 2.1 App Completeness | 15% | 提供 demo 账号 + 测试用书源 URL + 录屏(每次提审都附) |
| 3.1.1 In-App Purchase | <5% | 我们当前不接 IAP,只要不出现"会员/解锁"字样应该不会触发 |

### 7.3 通过后的运营
- **首日 crash 监控**: 看 `/api/admin/crashes`
- **首周用户反馈**: 看 `/api/admin/feedback`
- **首月数据分析**: device 留存 / 书源使用分布 / 广告填充率

---

## 8. 后端配套改动汇总(脱离 iOS 端独立可做)

按时间顺序:

| 时间 | 任务 | 文件 | 工作量 |
|---|---|---|---|
| M0 必做 | book_sources 加 platforms 列 + migration | `db.js` + `migrations/` | 2 小时 |
| M0 必做 | `/api/sources` 按 platform 过滤 + ETag 分桶 | `server.js` + `db.js` | 半天 |
| M0 必做 | admin 加平台勾选 UI | `admin.html` | 半天 |
| M3 必做 | `/api/ad-config` 加 `review_mode` 字段 | `server.js` + `db.js` | 1 小时 |
| M5 后期 | `/api/admin/stats` 加 platform 维度面板 | `admin.html` + `db.js` | 半天 |
| 可选 | `/api/admin/sources/curate-for-ios` 一键标"iOS 安全源" | `server.js` | 半天 |

---

## 9. 关键决策点(开工前再次确认)

### 决策点 ① · 工程描述方式
- 默认: **Tuist**(`Project.swift` 描述,无 `.xcodeproj` merge 冲突)
- 反对:回到传统 `.xcodeproj` commit
- 影响: M0-I1 实现方式,1-2 小时差距

### 决策点 ② · IAP 槽位
- 默认: **App Store Connect 创建 App 时勾上 IAP capability,但不上架 SKU**(为以后留后路)
- 反对: 完全不勾,后续要 IAP 重新提审
- 影响: M4-5 配置 1 步差

### 决策点 ③ · 真实设计师
- iOS 端的截图、图标质量直接影响 4.0 拒审概率
- 默认: **建议 M4 阶段找设计师 1-2 天工时**(预算 ¥1500-3000)
- 反对: 自己用 SwiftUI 凑截图 + 用 Sketch 画图标
- 影响: M4 工作量 + 通过率

### 决策点 ④ · TestFlight 测试者
- 默认: **找 5 个真人**(同事 / 早期用户)
- 反对: 自己一个人测
- 影响: M4-6 完成质量

### 决策点 ⑤ · 备案进度
- iOS 端 baseURL 上线时**必须**已经是 `https://api.wanxiangbook.com`(域名 + ICP 已下来)
- **最迟时间**: M5 提审前 2 周必须备案完成
- **如果还没备**: 立刻去备案(7-14 天工作日,提前办)

---

## 10. 立刻可执行的下一步 (Tier C 时间线)

> **总周期 8.5-10 个月** (单人全职), 并行可压到 3-5 个月。

| 周期 | 阶段 | 内容 |
|---|---|---|
| **第 1 周** | M0 | 后端平台过滤(B1-B4)+ iOS 工程脚手架(I1-I5)|
| **第 2-4 周** | M1 | 书源引擎完整版(14 个 task) |
| **第 5 周** | M2.1 | 主导航 + 我的页基础 |
| **第 6-7 周** | M2.2 | 书架 |
| **第 8-9 周** | M2.3 | 书城(含后端代理)|
| **第 10-10.5 周** | M2.4 | 搜索 |
| **第 11-17 周** | **M2.5** | **阅读器主战场** (8 个子模块) |
| **第 18-21 周** | M2.6 | 漫画 + 有声 |
| **第 22-23 周** | M2.7 | 三种规则系统 UI |
| **第 24-26 周** | M2.8 | 本地导入 + 缓存离线 |
| **第 27-29 周** | M2.9 | 书签/浏览器/二维码/文件/字体/导入导出 |
| **第 30-31 周** | M2.10 | 设置面板 50+ 项 + 法律 + 合规 |
| **第 32-33 周** | M3 | 广告 SDK + 合规抛光 + TestFlight |
| **第 34-35 周** | M4 | 上架准备(图标/截图/文案)|
| **第 36-40 周** | M5 | 提审 + 应对拒因(预留 2 轮) |

**最早能做的**(可以**今天**就开:不影响 Android):
1. 🟢 **M0-B1~B4**: 后端 `book_sources` 表加 `platforms` 列 + `/api/sources?platform=ios` 过滤 + admin 平台勾选 UI(1 天)
2. 🟢 **iOS 工程脚手架** M0-I1~I5(2-3 天)
3. 🟢 **同步开始 ICP 备案**(7-14 天工作日, 不开始 M5 前 2 周必备完)
4. 🟢 **同步注册 Apple Developer Program**(¥688/年, 3-5 天审核)

---

## 附录 A · 技术依赖清单

### iOS 端三方依赖(SwiftPM)
| 名字 | 用途 | 必要性 |
|---|---|---|
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | CSS 选择器 + HTML 解析 | 必须 |
| (libxml2) | XPath(系统自带,SPM 引用 `swift-libxml`) | 必须 |
| (sqlite3) | 系统自带,直接 import | 必须 |
| (JavaScriptCore) | 系统自带 | 必须 |
| 不再装其它库 | | |

### 广告 SDK
| 名字 | iOS 集成方式 | 注意 |
|---|---|---|
| 穿山甲 BUAdSDK | CocoaPods / 手动 framework | SDK 本身需要在 Info.plist 加 80+ 个 SKAdNetwork 项 |
| 优量汇 GDTSDK | CocoaPods / 手动 framework | 同样补 SKAdNetwork 项 |

> 由于既要 SwiftPM 又要 CocoaPods 不优雅,**建议**全部手动下载 .xcframework 然后引用。或全部用 CocoaPods 接管(SPM 仅用于纯 Swift 库)。

### 后端 npm 依赖(M0 加的)
- 无新增,现有依赖足够

---

## 附录 B · 风险登记表

| ID | 风险 | 严重度 | 概率 | 缓解 |
|---|---|---|---|---|
| R1 | App Store 因"5.2.3 第三方内容"拒审 | 高 | 70% | 默认空书源 + 后端审核期关广告 + 申诉信 |
| R2 | App Store 因"4.2 缺乏差异化"拒审 | 中 | 40% | 突出多源管理 / 自定义书源 / 开源属性 / 高度可配置阅读器 |
| R3 | JavaScriptCore 与 Rhino 行为不一致导致部分书源失效 | 中 | 50% | M1 阶段大量真实源回归测试; 上线后持续打补丁 |
| R4 | 阅读器分页算法工时超估 | 中 | 40% | M2.5.2 预留 2 周 buffer |
| R5 | ICP 备案被拒/延期 | 高 | 30% | M0 同步开始备案,不要拖到 M5 |
| R6 | 苹果审核员手动测出某书源指向盗版 | 高 | 60% | admin 严格审核所有标"iOS 可见"的源,只放公版/正版授权 |
| R7 | 真机调试证书 / 团队 Apple Developer 账户问题 | 低 | 10% | 提前注册 Apple Developer Program(¥688/年),M0 阶段就要拿到证书 |
| R8 | **章节付费墙触发 3.1.1 拒审** (Tier C 必踩) | 高 | 60-70% | M5 提交前后端把 `chapterUnlock.enabled=false`; 申诉信强调"激励留存,非绕开付费"; 通过后再灰度开 |
| R9 | **仿真翻书 Metal shader 实现超工时** | 中 | 50% | M2.5.3.5 可降级为 v1.5 补做,先用覆盖+滑动+滚动凑数 |
| R10 | **MOBI/UMD 解析无现成 Swift 库** | 中 | 40% | 退路:用 Objective-C 包 calibre 子集(GPLv3 兼容) 或 v1.x 跳过 |
| R11 | **后台下载 BGTaskScheduler 配额限制** | 中 | 40% | 切片下载 + 用户主动触发 + 通知中心进度展示, 而非全自动 |
| R12 | **Tier C 单人扛 7-10 个月人会崩** | 高 | 80% | 强烈建议 §4.5 的 2-3 人并行方案; 否则按 6 个月里程碑切片可独立交付 |
| R13 | **JavaScriptCore 沙盒限制(没 java.ajax 等同步 HTTP API)** | 高 | 70% | 实现垫片时把同步 ajax 转 async + Promise; 重写 JS 调用契约 |

---

> **文档结束**。等你确认决策点 ①-⑤ + 选哪一步开工,我即刻动手。
