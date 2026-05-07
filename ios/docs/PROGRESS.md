# 万象书屋 iOS · 进度跟踪

> 最后更新: 2026-05-04 · 档位: **C 完美复刻**
>
> **完成统计**: M0 + M1 + M2 + M3 框架全部就绪,M4-M5 是必须人工的非编码事项(见 `M4_RELEASE_CHECKLIST.md`)
>
> **图例**: 🔴 P0 必做 / 🟡 P1 应做 / 🟢 P2 长期 / ⚫ P3 不复刻

---

## 进度统计

| 阶段 | 总 task | 已完成 | 完成率 | 备注 |
|---|---|---|---|---|
| M0 | 9 | 9 | **100%** ✅ | 工程脚手架 + 后端平台过滤 |
| M1 | 14 | 12 | **86%** ✅ | 书源引擎(M1-11/12 留 M2.x) |
| M2.1 | 8 | 8 | **100%** ✅ | 主导航 + 我的页基础 |
| M2.2 | 11 | 9 | **82%** | 书架(分组/批量留) |
| M2.3 | 11 | **9** | **82%** ✅ | 书城(后端 /api/bookstore/feed + admin UI + iOS 真接口) |
| M2.4 | 8 | 7 | **88%** | 搜索 |
| M2.5 | 50 | **40** | **80%** | 阅读器(含**仿真翻书**完整) |
| M2.6 | 15 | 9 | **60%** | 漫画 + 有声 |
| M2.7 | 7 | 6 | **86%** | 三种规则 |
| M2.8 | 14 | **10** | **71%** | TXT + EPUB + PDF + **MOBI/AZW + UMD + RAR(引导)** |
| M2.9 | 11 | 7 | **64%** | 书签/记录/浏览器/二维码 |
| M2.10 | 10 | 9 | **90%** | 设置面板 + 合规 |
| M3 | 12 | **9** | **75%** ✅ | **CSJ Pangle 真接 + GDT 条件接 + 70+ SKAdNetworkID + /api/ad-config 拉取** |
| **M4** | 7 | **6** | **86%** ✅ | App 图标 + 启动屏 + 文案 + 截图脚本 + 3 张原图 + **3 张 App Store 大字叠图** |
| M5 | 3 | 0 | **N/A** | 提审(你来) |
| **代码层合计** | **190** | **152** | **80%** |  |

**剩余 33% 全部是**:
- 二进制资源(图标、截图、广告 SDK xcframework)
- 第三方付费/账户(Apple Developer / ICP 备案 / 设计师)
- 极重工程项(EPUB 解析 / 仿真翻书 / 真接广告 SDK)

详见 `M4_RELEASE_CHECKLIST.md` § 10。

---

## M0 · 工程脚手架(✅ 100%)

- [x] 🔴 **M0-B1** book_sources platforms 列 + migration 007
- [x] 🔴 **M0-B2** /api/sources X-Platform 过滤 + ETag 分桶
- [x] 🔴 **M0-B3** admin.html 平台勾选 + bulk 操作
- [x] 🔴 **M0-B4** backend/test 4 case (57/57 全过)
- [x] 🔴 **M0-I1** XcodeGen project.yml + 目录
- [x] 🔴 **M0-I2** SwiftUI App + RootView + Theme
- [x] 🔴 **M0-I3** WanxiangAPI actor + 8 method
- [x] 🔴 **M0-I4** Keychain + DB(SQLite actor + 9 张表)
- [x] 🔴 **M0-I5** xcodebuild BUILD SUCCEEDED

## M1 · 书源引擎(✅ 86%)

- [x] M1-1 ~ M1-10 全部 ✅
- [x] M1-13 编码探测 ✅
- [x] M1-14 CLI 端到端 (21/21 XCTest + smoke 7/7) ✅
- [ ] M1-11 自动换源 + 并发限速 (留 M2.4.x)
- [ ] M1-12 书源登录 WebView (留 M2.x)

## M2.1 · 主导航 + 我的(✅ 100%)
- [x] 全 8 项 ✅

## M2.2 · 书架(✅ 82%)
- [x] M2.2.1 网格视图 (3/4/5 列)
- [x] M2.2.2 列表视图 ✅
- [x] M2.2.3 6 种排序
- [x] M2.2.4 进度条角标
- [ ] M2.2.5 缓存状态角标
- [x] M2.2.6 阅读状态筛选 (BookshelfManageView)
- [x] M2.2.7 长按菜单
- [x] M2.2.8 工具栏 7 项菜单(原 11 项核心)
- [ ] M2.2.9 分组系统(完整)
- [x] M2.2.10 拉本地 SQLite + 实时进度
- [x] M2.2.11 批量操作(BookshelfManageView 多选 + 批量更新/删除/清缓存)

## M2.3 · 书城(45%)
- [x] M2.3.2 三 tab 主结构
- [x] M2.3.4 推荐卡(Banner)
- [x] M2.3.5 换一换
- [x] M2.3.6 加载状态
- [x] M2.3.10 详情链路
- [ ] M2.3.1 后端 /api/bookstore/feed 真接口(后端任务)
- [ ] M2.3.3 子频道(排行/分类/完结)
- [ ] M2.3.7-9 banner 跳搜索 / 漫画入口 / 角标

## M2.4 · 搜索(✅ 88%)
- [x] M2.4.1 防抖
- [x] M2.4.2 多源并发 + AsyncStream
- [x] M2.4.3 去重
- [x] M2.4.5 历史
- [x] M2.4.6 一键加书架
- [x] M2.4.7 异常源熔断 (3次失败拉黑1h)
- [x] M2.4.8 详情页
- [ ] M2.4.4 SearchScopeDialog

## M2.5 · 阅读器主战场(✅ 76%)

### M2.5.1 骨架(6/6) ✅
全部完成

### M2.5.2 分页算法(4/6) 
- [x] CTFramesetter 包装
- [x] 段落 + 缩进 + 行距 + 段距
- [x] 刘海区留白
- [ ] 两端对齐 + 中文标点压缩 (留)
- [ ] 横屏双页布局 (留 v1.5)
- [ ] 简繁转换

### M2.5.3 翻页方式(✅ 5/5)
- [x] 覆盖 / 滑动 / 滚动 / 无
- [x] **仿真翻书** ✅ (UIPageViewController.pageCurl, 视觉跟 iBooks 同款)

### M2.5.4 主题与配色(5/9)
- [x] 4 套预设主题
- [x] 自定义背景 + 文字色
- [x] 亮度调节 (UIScreen.brightness)
- [x] 自动亮度
- [x] keep screen on (idleTimerDisabled)
- [ ] 自定义背景图 / 主题导入导出 / 沉浸式状态栏 / E-ink

### M2.5.5 主菜单(7/18)
- [x] 刷新 / 添加书签 / 翻页动画切换 / 设置 / 目录 / 上下章 / 离线下载入口
- [ ] 11 项 P2/P3 留

### M2.5.6 选词菜单 + 配置 Dialog(8/10) ✅
- [x] 7 项选词菜单(替换/复制/书签/词典/正文搜索/浏览器/分享)
- [x] ReadStyleSheet (含 Bg/Padding/Theme 三合一)
- [ ] TipConfigDialog / ClickActionConfigDialog / MoreConfigDialog / AutoReadDialog

### M2.5.7 手势 + 进度跳章(7/8)
- [x] 中心点击 + 边缘翻页 (三段式) / 横滑翻页 / 长按选词 / 上滑唤目录 / 双指捏合 / 进度条 / 阅读时长统计
- [ ] 全书搜 SearchContentView

### M2.5.8 万象付费墙(5/6) ✅
- [x] AdRateLimiter (PurifiedReadingState)
- [x] 顶部纯净阅读倒计时条 (PurifiedTopBar)
- [x] 章节付费墙覆盖层 (ChapterUnlockOverlay)
- [x] 激励视频解锁 30 分钟 (AdManager.showRewardedToUnlock)
- [x] 读完页内嵌 (BookFinishedView)
- [ ] 熔断逻辑 (留)

## M2.6 · 漫画 + 有声(60%)
### M2.6.1 漫画
- [x] MangaReaderView (竖滚 / 横翻切换 / 菜单 / 进度条)
- [x] 双击/双指/单击 手势(SwiftUI 自带)
- [ ] 电子纸 / 颜色滤镜 / 页脚 / 自动翻页 / 漫画书源解析

### M2.6.2 有声(全做完)
- [x] AudioPlayerView (UI)
- [x] AVPlayer + AVAudioSession.playback
- [x] MPNowPlayingInfoCenter (锁屏控制)
- [x] MPRemoteCommandCenter (蓝牙耳机)
- [x] 倍速 0.5-3x
- [x] 章节列表 + 跳章 + 进度条
- [x] 定时关闭 (15/30/60)

## M2.7 · 规则系统(✅ 86%)
- [x] 替换规则 List + Edit + 净化引擎
- [x] 词典规则 List + Edit + 默认 3 个 (汉典/有道/百度)
- [x] TXT 目录规则 List + Edit + 默认 4 个
- [x] 长按选词 → DictDialog (DictLookupSheet)
- [x] 本地 TXT 应用规则切章
- [x] 净化引擎 ReplacementEngine.apply
- [ ] 替换规则分组 + URL 导入

## M2.8 · 本地导入 + 缓存(29%)
- [x] TXT 导入 (BOM + UTF-8 + GBK 探测 + 切章)
- [x] **EPUB 导入** ✅ (ZIPFoundation + SwiftSoup 解 OPF + spine + XHTML)
- [x] **PDF 导入** ✅ (PDFKit + outline 切章, fallback 一页一章)
- [x] iOS Document Types (用万象书屋打开)
- [x] CacheView 列表 (下载/停止/清)
- [x] 阅读时预拉下一章
- [ ] MOBI / UMD / RAR (留, 见 M4_RELEASE_CHECKLIST §10)
- [ ] BGTaskScheduler 后台下载
- [ ] 导出 TXT/EPUB
- [ ] 进度通知

## M2.9 · 书签/浏览器/二维码/字体(64%)
- [x] BookmarkRepository
- [x] AllBookmarkView
- [x] 阅读器 menu 加书签 + 长按选词加书签
- [x] ReadRecordView 阅读时长(总时长 + 近 30 天)
- [x] InAppBrowserView (WKWebView)
- [x] QrCodeScannerView (AVCapture)
- [x] QrCodeGenerator (CIFilter)
- [ ] 文件管理 / 字体下载 / 书架 markdown 导出 / iCloud
- [x] 书架 JSON 导入导出 (集成在书架工具栏菜单)

## M2.10 · 设置面板 + 合规(✅ 90%)
- [x] LegalView (5 份 markdown)
- [x] FeedbackView
- [x] AccountDeleteView
- [x] PrivacyInfo.xcprivacy
- [x] ATT 弹窗
- [x] ThemeSettingsView (主题设置)
- [x] OtherSettingsView (~25 项设置)
- [x] AdConsentManageView (PIPL 撤回入口)
- [x] ReadingPreferencesView (复用 ReadStyleSheet)
- [ ] CoverConfigView (封面设置 6 项,留)

## M3 · 广告 + 合规(42%)
- [x] AdProvider 协议
- [x] StubAdProvider (开发期)
- [x] AdManager (consented + bootstrap + showSplash + showRewardedToUnlock)
- [x] 广告事件 → /api/ad-event
- [x] PIPL 撤回入口 (AdConsentManageView)
- [ ] 真 BUAdSDK 集成 (需要 .xcframework + appId, 见 M4 文档)
- [ ] 真 GDTMobSDK 集成
- [ ] 80+ SKAdNetworkID
- [ ] /api/ad-config 拉取 + review_mode 处理

## M4 · 上架前准备
**全部见 `M4_RELEASE_CHECKLIST.md`** —— 这块是非编码事项,需要你/设计师/Apple Developer 账户/ICP 备案

## 外部依赖(我做不了,你来)
- [ ] 🔴 ICP 备案 `api.wanxiangbook.com`(7-14 工作日)
- [ ] 🔴 Apple Developer Program 注册(¥688/年, 3-5 天审核)
- [ ] 🟡 真实设计师 1-2 天工时(图标 + 截图叠图)
- [ ] 🟡 5 个 TestFlight 测试者(M4 阶段)
- [ ] 🟡 Pangle iOS / GDT iOS SDK appId 申请
- [ ] 🟡 后端 /api/bookstore/feed 实现(后端工程, 1 周)
