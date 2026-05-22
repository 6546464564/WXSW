# 万象书屋 CHANGELOG

> 仅记录万象书屋 fork 后的项目级变更。Android App 内的版本更新记录见 [`android/app/src/main/assets/updateLog.md`](android/app/src/main/assets/updateLog.md);后端 / iOS 的细粒度变更记录见各子项目目录。

## 2026-05-21 · iOS 全量审查 & Bug 修复

**P0 崩溃修复（本次会话前已完成）**
* `BookDownloader` / `BookCover` / `ChangeSourceCandidateCache`: 将 `fatalError("cachesDirectory unavailable")` 改为 graceful fallback 到 `temporaryDirectory`，彻底消除书城搜索闪退
* `ReaderView`: 退出/切后台时还原系统亮度，防止自定义低亮度泄漏导致黑屏；补充根视图背景色
* `InAppBrowserView`: WKWebView 透明背景 + 父 View 填底色，消除暗模式黑屏闪烁

**本次会话修复（8 项）**
1. **`ReaderView.stopReadingTimer()` 阅读时长统计不准** — 停止时只记整分钟，末尾碎片丢失；新增 `readTimerStartDate` 精确计算剩余秒数并补录（≥ 10s 才计入，首次最少 30s）
2. **`ReaderView` 滚动分页连跳** — `scrollPager` 哨兵 `onAppear` 在章节切换后重绘时触发多次，快速连跳多章；改用 `scrollPagerPrevLoading` / `scrollPagerNextLoading` 防重入
3. **`WanxiangBookApp` 无效 `do-catch`** — `bootstrap()` 不 throw，包裹的 `catch` 是死代码；移除无用包装
4. **`WanxiangAPI.currentIDFV()` 主 Actor 违规** — `nonisolated` 上下文访问 `UIDevice.current.identifierForVendor`（iOS 16+ 是主线程属性），Swift 6 严格并发下崩溃；改为 `Thread.isMainThread` 分支 + `DispatchQueue.main.sync`
5. **`SourceRateLimiter` 并发竞态** — `acquireInterval`/`acquireWindow` Actor 挂起恢复后不重新检查窗口，多任务同时穿透限速导致 IP 封禁；改为 `while true` 重检循环
6. **`DB.wipeAll()` PIPL 合规漏洞** — 注销清数据时遗漏 `bookmarks`（含用户笔记）、`book_groups`、`replace_rules`、`dict_rules`、`txt_toc_rules` 五张表；补全全部 10 张表
7. **`AccountDeleteView.performWipe()` UserDefaults 清除不完整** — 遗漏 TTS 断点（`wx.tts.resume.*`）、书源 JS 变量（`wx.sourceVariable.*`）、书源登录态（`wx.sourceLogin.*`）、广告同意状态；补全所有动态前缀 key 批量清除
8. **`TtsEngine.setupAudioSession()` 启动即打断背景音乐** — `init()` 调 `setActive(true)` 导致打开 App 就 duck/停止用户正在播放的音乐；将 `setActive` 移到真正 `synth.speak()` 前的 `activateAudioSession()` 方法

---

## 2026-05-07 · 仓库整理

* 重写根 `README.md` 为「万象书屋」品牌,修复 5 条因目录调整(`app/` → `android/app/`、文档移到 `docs/`)产生的死链
* 修复 `ios/README.md` 中 `PLAN.md` / `FEATURES.md` / `PROGRESS.md` 三条相对路径死链(实际位置在 `ios/docs/`)
* 替换 `docs/NOTICE.md` 中的 `REPO_URL_PLACEHOLDER` 为 `https://github.com/6546464564/WXSW`
* 更新 `package.json`:`name` / `repository.url` / `bugs.url` / `homepage` / `license` 全部指向万象书屋新仓库,license 改为 `GPL-3.0`
* `scripts/release-check.ps1` 跟进 NOTICE 路径变化(`NOTICE.md` → `docs/NOTICE.md`)
* `scratch/` 目录从 Git 索引移除以与 `.gitignore` 设计对齐(本地保留为反编译参考产物)

## 2026-05-06 · chore: 整理仓库结构与构建忽略 (`41cc37c`)

* 调整顶层目录结构:Android 工程统一收敛到 `android/`、iOS 工程到 `ios/`、后端到 `backend/`
* 完善 `.gitignore`:覆盖 build 产物、IDE 配置(`.idea` / `.vscode` / `.cursor` / `.claude`)、SQLite 数据文件、scratch 反编译产物等

## 2026-04-29 · 万象书屋: 初始提交 (`e70c2b5`)

* 万象书屋 品牌化:包名 `com.wanxiang.reader`、新图标、自有 UI 主题 `#B8956B` 主色
* 移除前台书源管理入口,改为后端 `/api/sources` 动态下发
* 新增书城(BookStore)Tab 与运营 Feed
* 新增 Node.js + Express + SQLite 后端,含管理面板(`backend/public/admin.html`)
* 接入穿山甲 (Pangle) + 优量汇 (Tencent YLH) 激励视频广告,30s 解锁 30 分钟纯净阅读
* 内置中国大陆上架所需法律页:隐私政策、用户协议、个人信息收集清单、SDK 列表
* iOS 端启动 M0 脚手架(SwiftUI + XcodeGen),路线图见 `ios/docs/PLAN.md`

---

## Pre-fork (legado upstream)

仓库基于 [gedoor/legado](https://github.com/gedoor/legado) GPL-3.0 fork。fork 之前的上游变更见 legado 上游的发布说明。

### 2022/10/02 (legado upstream)

* 更新 cronet: 106.0.5249.79
* 正文选择菜单朗读按钮长按可切换朗读选择内容和从选择开始处一直朗读
* 源编辑输入框设置最大行数 12,在行数特别多的时候更容易滚动到其它输入
* 修复某些情况下无法搜索到标题的 bug,净化规则较多的可能会降低搜索速度 by Xwite
* 修复文件类书源换源后阅读 bug by Xwite
* Cronet 支持 DnsHttpsSvcb by g2s20150909
* 修复 web 进度同步问题 by 821938089
* 启用混淆以减小 app 大小,有 bug 请带日志反馈
* 其它一些优化
