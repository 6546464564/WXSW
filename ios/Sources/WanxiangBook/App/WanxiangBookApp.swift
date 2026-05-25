//
//  WanxiangBookApp.swift
//  万象书屋 iOS · App 入口
//
//  M0-I2 阶段最小可运行 App, 后续 M2 各阶段往这里挂依赖.
//

import SwiftUI

@main
struct WanxiangBookApp: App {

    @UIApplicationDelegateAdaptor(WanxiangAppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var theme = ThemeManager.shared

    init() {
        ReadConfig.logFontDiagnostics()
        // #region agent log
        // 万象书屋 (2026-05-25): 启动诊断仅 DEBUG 构建运行;
        // RELEASE 跑 7 个字号 × 5 页测量纯浪费 200ms 启动 + 占用低内存机型 RAM.
        #if DEBUG
        _runPaginationDiagnostic()
        #endif
        // #endregion
        // -downloadAll: 启动后自动下载书架所有书籍（用于性能测试）
        if CommandLine.arguments.contains("-downloadAll") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 等 bootstrap 完成
                await BookSourceRegistry.shared.waitUntilEnabledSourcesNonEmpty(timeout: 15)
                NSLog("[WX-DL] sources: %d", BookSourceRegistry.shared.sources.count)
                guard let books = try? await BookshelfRepository.shared.listAll() else { return }
                NSLog("[WX-DL] shelf books: %d", books.count)
                for book in books {
                    let source = BookSourceRegistry.shared.find(origin: book.origin)
                    NSLog("[WX-DL] startDownload: %@ source=%@", book.name, source?.bookSourceName ?? "NIL")
                    BookDownloader.shared.startDownload(book: book, source: source)
                }
            }
        }
        // UI 自动化测试时重置状态（仅在测试环境生效）
        if CommandLine.arguments.contains("-resetAppState") {
            UserDefaults.standard.removeObject(forKey: "wx.game.unlocked")
            UserDefaults.standard.synchronize()
        }
        // -unlockApp: 测试时跳过伪装面，直接进入主界面
        #if TESTLAB
        UserDefaults.standard.set(true, forKey: "wx.game.unlocked")
        UserDefaults.standard.synchronize()
        #else
        if CommandLine.arguments.contains("-unlockApp") {
            UserDefaults.standard.set(true, forKey: "wx.game.unlocked")
            UserDefaults.standard.synchronize()
        }
        #endif
        // -uitest: 注入测试激活码到 UserDefaults，PromoCodeManager 会读取
        if CommandLine.arguments.contains("-uitest") {
            struct _TestCode: Codable { let code: String; let agentName: String }
            if let data = try? JSONEncoder().encode([_TestCode(code: "UITEST", agentName: "UITest")]) {
                UserDefaults.standard.set(data, forKey: "wx.promo.codes")
                UserDefaults.standard.synchronize()
            }
        }
    }
    // 万象书屋: 监听 App 生命周期, 进/退后台时 send ping
    @Environment(\.scenePhase) private var scenePhase

    /// 万象书屋: 跟 Android `SplashAdActivity` 对齐 — 启动先展开屏页, 完成后再进 RootView.
    /// 进程级状态, 不做 UserDefaults 持久化 (每次冷启都展示一次, 跟 Android LAUNCHER 行为一致).
    // UI 测试时跳过开屏广告；未解锁（伪装面）时也直接跳过，避免暴露 App 真实身份
    @State private var splashFinished: Bool = {
        if CommandLine.arguments.contains("-skipSplash") { return true }
        return !UserDefaults.standard.bool(forKey: "wx.game.unlocked")
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                // 万象书屋: 底层保底背景色 — 防止暗模式下 WindowGroup 黑色在视图切换瞬间漏出导致黑屏
                Color(.systemBackground).ignoresSafeArea()
                GameGateView()
                    .environmentObject(appState)
                if !splashFinished {
                    SplashAdView {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            splashFinished = true
                        }
                    }
                    .transition(.opacity)
                }
            }
            .preferredColorScheme(theme.mode.colorScheme)
            .task {
                await appState.bootstrap()
            }
            .onChange(of: scenePhase) { newPhase in
                Task { await appState.handleScenePhase(newPhase) }
            }
            .onOpenURL { url in
                guard url.scheme == "wanxiang" else { return }
                NSLog("[WX-URL] received: %@", url.absoluteString)
                if url.host == "download-all" {
                    Task {
                        // 等书源加载完
                        await BookSourceRegistry.shared.waitUntilEnabledSourcesNonEmpty(timeout: 10)
                        let sourcesCount = BookSourceRegistry.shared.sources.count
                        NSLog("[WX-URL] sources loaded: %d", sourcesCount)
                        guard let books = try? await BookshelfRepository.shared.listAll() else {
                            NSLog("[WX-URL] failed to load books")
                            return
                        }
                        NSLog("[WX-URL] books on shelf: %d", books.count)
                        for book in books {
                            let source = BookSourceRegistry.shared.find(origin: book.origin)
                            NSLog("[WX-URL] startDownload: %@ source=%@", book.name, source?.bookSourceName ?? "NIL")
                            BookDownloader.shared.startDownload(book: book, source: source)
                        }
                    }
                }
            }
        }
    }
}

/// 万象书屋: 全局 App 状态. 后续 M2 各阶段往里加 @Published.
@MainActor
final class AppState: ObservableObject {

    @Published var isBootstrapped: Bool = false
    @Published var lastError: String? = nil
    @Published var bootstrapFailed: Bool = false   // bug #4 fix: 跟 isBootstrapped 解耦, 让横幅能正确显示
    /// 当前生效的公告 (只展示一次, 用户关掉后不再弹)
    @Published var announcement: AnnouncementInfo? = nil
    /// 升级提示
    @Published var versionUpdate: VersionUpdateInfo? = nil

    private var heartbeatTimer: Task<Void, Never>? = nil
    private var memoryGuardTimer: Task<Void, Never>? = nil
    private var lastPingAt: Date? = nil
    private static let pingInterval: TimeInterval = 4 * 60   // 4 分钟一次, 跟后端 rateLimitPing 对齐

    /// 启动时拉一次设备注册 + 拉书源 + 启心跳
    func bootstrap() async {
        guard !isBootstrapped else { return }
        // UI 测试模式：跳过耗时的网络初始化，让主界面立即显示
        #if TESTLAB
        isBootstrapped = true
        await BookSourceRegistry.shared.bootstrap()
        startTestLabMemoryGuard()
        return
        #endif
        if CommandLine.arguments.contains("-uitest") {
            isBootstrapped = true
            await PromoCodeManager.shared.bootstrap()
            return
        }
        await BrowserBridgeRegistry.shared.set(
            await MainActor.run { WKWebViewBridge() }
        )
        // 万象书屋 (M2.8): 启动时 restore Cloudflare 反爬 cookie. 让用户重启 App 后
        // 30 分钟内访问反爬源 (顶点 / 随梦 / 海棠 / UAA 等) 直接秒拉, 不必再跑
        // 25s webview challenge.
        CloudflareCookieStore.shared.restoreFromDisk()
        // 万象书屋 (M2.8): 启动时检查章节图片缓存大小, 超过 500MB 自动 LRU 淘汰到 400MB.
        // 后台 detached, 不阻塞启动.
        ChapterImageCache.shared.trimIfNeeded()
        // 万象书屋: 确保新表 schema 存在 (book_groups 等)
        try? await BookGroupRepository.shared.ensureSchema()
        // 万象书屋: 注入解析器健康上报 sink (BookSource 模块不直接依赖 WanxiangAPI)
        SourceHealthSinkRegistry.shared.register(WanxiangAPISourceHealthSink())
        // 万象书屋: 启埋点 SDK (跟 Android `App.kt` `WanxiangAnalytics.init()` 等价)
        await WanxiangAnalytics.shared.start()
        // 设备注册失败不影响主流程 (纯统计用途), 静默忽略
        try? await WanxiangAPI.shared.registerDeviceIfNeeded()
        await BookSourceRegistry.shared.bootstrap()
        isBootstrapped = true
        // 万象书屋: PromoCodeManager 优先拉 — 用户可能很快进 Gate 输入反馈码，
        // 必须先于 ping/公告/版本/广告配置就绪，用 .userInitiated 优先级独立跑。
        Task.detached(priority: .userInitiated) {
            await PromoCodeManager.shared.bootstrap()
        }
        // 万象书屋 (perf): 这些请求**不要** `await .value` — 否则会拖住整个 bootstrap(),
        // 用户已进首页还在等 ping/公告/版本/广告配置串行跑完, 体感「加载慢」.
        // 与 Android Application 里异步 fire-and-forget 对齐.
        Task.detached(priority: .background) { [weak self] in
            await self?.sendPingNow()
            await self?.fetchAnnouncement()
            await self?.fetchVersionCheck()
            await AdManager.shared.refreshConfig()
        }
        // 万象书屋 (M2.4 perf): 在 splash 这 1s 期间预热 BookSourceEngine 单例
        // (含 4 个 JSEngine + stdlib 注入), 让用户进搜索页时第一次 search 不再等
        // ~200-400ms 的冷启 cost. 是 lazy singleton 的最早 access 点, 副作用 0.
        Task.detached(priority: .utility) {
            _ = BookSourceEngine.shared
        }
        // 万象书屋 (perf 2026-05-11): 启动时后台预热书城榜单. iOS RootView 用 `switch selectedTab`
        // 渲染, 只有用户点到「书城」Tab 才会首次构造 BookStoreView, 这时再发 `/api/bookstore/mirror`
        // 会让用户看到「正在加载书城…」spinner; 而 Android 用 ViewPager 邻近 Fragment 提前
        // onCreate, 等切到 Tab 时数据已就绪. 在 bootstrap 后台跑一次 prewarm, 把两个频道的榜单
        // 灌进 BookStoreViewModel 的进程级 cache, 用户切 Tab 直接命中, 不再闪 loading.
        BookStoreViewModel.prewarmInBackground()
        // 万象书屋: 书城 banner「热门排行 (月票 TOP 50)」/「完本书库 50」一并预热, 让用户
        // 从 banner 进 RankDetailView 直接命中进程级 cache, 永远不闪 ProgressView.
        RankDetailViewModel.prewarmInBackground()
        // 万象书屋: 启 4 分钟一次心跳定时器 (跟后端 rateLimitPing 对齐, 防超频)
        startHeartbeatLoop()
    }

    // MARK: - 心跳 / 访问统计

    private func startHeartbeatLoop() {
        heartbeatTimer?.cancel()
        heartbeatTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                await self?.sendPingNow()
            }
        }
    }

    private func sendPingNow() async {
        // 节流: 同一次 ping 不重复发 (前后台切换可能频繁触发)
        if let last = lastPingAt, Date().timeIntervalSince(last) < 60 { return }
        await WanxiangAPI.shared.sendPing()
        await MainActor.run { self.lastPingAt = Date() }
    }

    /// 万象书屋: scenePhase 切换时调用
    #if TESTLAB
    func startTestLabMemoryGuard() {
        memoryGuardTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000) // 20s
                URLCache.shared.removeAllCachedResponses()
                JSEngineCache.shared.clearAll()
                _BrowserResultCache.shared.clear()
                SyncHTTP.clearCache()
            }
        }
    }
    #endif

    /// - active   → 立即 ping (用户回到 App, 算一次活跃)
    /// - inactive → 不动
    /// - background → 取消心跳定时器 (省电, iOS 后台限制反正也跑不动)
    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            CrashBreadcrumb.leave("scene.active")
            // 后台回前台立即 ping 一次 + 重启 heartbeat
            await sendPingNow()
            if heartbeatTimer == nil || heartbeatTimer?.isCancelled == true {
                startHeartbeatLoop()
            }
            // 万象书屋 (方案 G'): 切回前台兜底刷一次源 etag.
            // 心跳 sendPingNow 已经会通过 X-Sources-Etag header 发现变更, 这里多一次 If-None-Match
            // 探测只是双保险 — 极端弱网下 ping 失败时也能在前台刷一次源.
            BookSourceRegistry.shared.refreshOnBecameActive()
            // 万象书屋: 后台源健康检测 — 距上次 ≥ 2h 时自动触发，更新各源成功率/速度得分.
            SourceHealthChecker.shared.scheduleIfNeeded()
        case .background:
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            SourceHealthChecker.shared.cancelHealthCheck()
            await WanxiangAnalytics.shared.flush()
            URLCache.shared.removeAllCachedResponses()
            _BrowserResultCache.shared.clear()
            SyncHTTP.clearCache()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    // MARK: - 公告 / 版本检查

    private func fetchAnnouncement() async {
        guard let info = try? await WanxiangAPI.shared.fetchAnnouncement() else { return }
        await MainActor.run {
            // 已展示过的公告 ID 跳过
            let key = "wx.announcement.lastSeen"
            let lastSeen = UserDefaults.standard.integer(forKey: key)
            if info.id > lastSeen {
                self.announcement = info
            }
        }
    }

    /// 用户关掉公告后调
    func markAnnouncementSeen() {
        if let id = announcement?.id {
            UserDefaults.standard.set(id, forKey: "wx.announcement.lastSeen")
        }
        announcement = nil
    }

    private func fetchVersionCheck() async {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        guard let info = try? await WanxiangAPI.shared.fetchVersionCheck(current: current) else { return }
        await MainActor.run {
            if info.shouldUpdate {
                self.versionUpdate = info
            }
        }
    }
}

// MARK: - 公告 / 版本数据

public struct AnnouncementInfo: Sendable {
    public let id: Int
    public let title: String
    public let body: String
    public let url: String?      // 点详情跳的 URL
}

public struct VersionUpdateInfo: Sendable {
    public let latestVersion: String
    public let currentVersion: String
    public let releaseNotes: String
    public let downloadUrl: String?
    public let mandatory: Bool   // 强制升级 (老版本不能用)
    public var shouldUpdate: Bool { latestVersion != currentVersion }
}

// MARK: - 解析器健康上报 sink (App target 内, 实现 BookSource 模块定义的 protocol)

/// 万象书屋: BookSource 模块没有网络层依赖, 通过 SourceHealthSink 协议把
/// 解析失败结果转发到 WanxiangAPI.reportSourceError, 后台 source_health 表会聚合.
private struct WanxiangAPISourceHealthSink: SourceHealthSink {
    func reportSourceHealth(
        sourceUrl: String,
        sourceName: String,
        stage: String,
        status: String,
        errorMessage: String?,
        sampleKeyword: String?,
        sampleUrl: String?
    ) {
        WanxiangAPI.shared.reportSourceError(
            sourceUrl: sourceUrl,
            sourceName: sourceName,
            stage: stage,
            status: status,
            errorMessage: errorMessage,
            sampleKeyword: sampleKeyword,
            sampleUrl: sampleUrl
        )
    }
}

// 万象书屋: AppDelegate 用于早期初始化 (崩溃捕获必须越早越好, SwiftUI App 生命周期太晚)
final class WanxiangAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        NSLog("[WX-URL] AppDelegate open: %@", url.absoluteString)
        guard url.scheme == "wanxiang", url.host == "download-all" else { return false }
        Task { @MainActor in
            await BookSourceRegistry.shared.waitUntilEnabledSourcesNonEmpty(timeout: 10)
            NSLog("[WX-URL] sources: %d", BookSourceRegistry.shared.sources.count)
            guard let books = try? await BookshelfRepository.shared.listAll() else {
                NSLog("[WX-URL] failed to load books")
                return
            }
            NSLog("[WX-URL] shelf books: %d", books.count)
            for book in books {
                let source = BookSourceRegistry.shared.find(origin: book.origin)
                NSLog("[WX-URL] startDownload: %@ source=%@", book.name, source?.bookSourceName ?? "NIL")
                BookDownloader.shared.startDownload(book: book, source: source)
            }
        }
        return true
    }

    /// 万象书屋: 强制锁定简体中文 UI, 不跟随系统语言.
    ///   - 跟 Android `AppContextWrapper` 行为一致, 国内 App 标准做法
    ///     (微信 / 支付宝 / 网易云 / 起点 都是这样).
    ///   - 必须在所有 UI 加载前调用 (UIView/Bundle.main 第一次拿 strings 之前),
    ///     所以放在 AppDelegate `init` 而不是 didFinishLaunching.
    ///   - 写 SP key `AppleLanguages` = ["zh-Hans"], iOS 启动时读这个值
    ///     决定整个 Bundle 的 lproj 解析顺序.
    ///   - 用 `wx.lang.locked` 作幂等标记, 避免每次冷启都写; 用户主动想改回
    ///     英文/繁体的话改这个标记就能恢复跟系统.
    override init() {
        super.init()
        let lockKey = "wx.lang.locked_v1"
        if !UserDefaults.standard.bool(forKey: lockKey) {
            UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
            UserDefaults.standard.set(true, forKey: lockKey)
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 万象书屋 (2026-05-25): 启动主线程一次性缓存 device 信息, 后续崩溃上报等
        // 跨线程路径直接读缓存, 避免 DispatchQueue.main.sync 跨线程死锁.
        WanxiangAPI.prefillDeviceCache()
        CrashHandler.install()
        MetricKitSubscriber.shared.start()
        // 万象书屋 (2026-05-25): 低内存设备 (SE/iPhone 6/7) 主动监控可用内存,
        // 比系统 didReceiveMemoryWarning 更早触发清理, 避免被 jetsam 直接 SIGKILL.
        LowMemoryGuard.shared.start()
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        NSLog("[WX-MEM] ⚠️ 收到内存警告, 开始清理缓存")
        // #region agent log
        DebugSessionLog.log(
            location: "WanxiangBookApp.applicationDidReceiveMemoryWarning",
            message: "memory warning",
            hypothesisId: "H5",
            data: ["memMB": ProcessInfo.processInfo.physicalMemory / 1_048_576]
        )
        // #endregion
        URLCache.shared.removeAllCachedResponses()
        HTTPFetcher.shared.clearResponseCache()
        _BrowserResultCache.shared.clear()
        SyncHTTP.clearCache()
        JSEngineCache.shared.clearAll()
        NSLog("[WX-MEM] URLCache + BrowserCache + SyncHTTP + JSCache 缓存已清理")
        NotificationCenter.default.post(name: .wanxiangMemoryWarning, object: nil)
    }
}

// #region agent log
import CoreText

private func _runPaginationDiagnostic() {
    let testText = (1...40).map { "　　这是第\($0)段正文内容，用于测试分页引擎在不同字号下的表现。万象书屋阅读器需要确保每一页的内容都能完整填充可用区域，减少底部空白。" }.joined(separator: "\n")
    let title = "测试章节标题"
    let viewportW: CGFloat = 430  // iPhone 17 Pro Max width
    let viewportH: CGFloat = 885  // approx content area height
    let padH: CGFloat = 20
    let padTop: CGFloat = 24
    let padBot: CGFloat = 18
    let headerH: CGFloat = 22
    let footerH: CGFloat = 22
    let canvasW = viewportW - padH * 2
    let canvasH = viewportH - padTop - padBot - headerH - footerH

    for textSize in [14, 16, 18, 20, 22, 24, 28] as [CGFloat] {
        let config = ReadConfigSnapshot(
            textSize: textSize, lineSpacing: 1.2, paragraphSpacing: 6,
            letterSpacing: 0, indentChars: 2, fontFamily: ""
        )
        let pages = PaginationEngine.paginate(
            text: testText, chapterIndex: 0, chapterTitle: title,
            canvasSize: CGSize(width: canvasW, height: canvasH), config: config
        )
        _dbg63Log("DIAG textSize=\(textSize) canvasW=\(canvasW) canvasH=\(canvasH) pageCount=\(pages.count)")

        let attrStr = _diagMakeAttr(title: title, body: testText, config: config)
        let framesetter = CTFramesetterCreateWithAttributedString(attrStr)
        var startIdx: CFIndex = 0
        for (pi, page) in pages.enumerated() {
            let path = CGPath(rect: CGRect(origin: .zero, size: CGSize(width: canvasW, height: canvasH)), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(startIdx, 0), path, nil)
            let vis = CTFrameGetVisibleStringRange(frame)
            let ctLines = CTFrameGetLines(frame) as! [CTLine]
            var lastY: CGFloat = 0
            if !ctLines.isEmpty {
                var origins = [CGPoint](repeating: .zero, count: ctLines.count)
                CTFrameGetLineOrigins(frame, CFRangeMake(0, ctLines.count), &origins)
                lastY = origins[ctLines.count - 1].y
            }
            var lastAsc: CGFloat = 0, lastDesc: CGFloat = 0, lastLead: CGFloat = 0
            if let last = ctLines.last { CTLineGetTypographicBounds(last, &lastAsc, &lastDesc, &lastLead) }
            let usedH = canvasH - lastY + lastDesc
            let wasteH = lastY - lastDesc

            // Now measure what UITextView.sizeThatFits would return for this page's body text
            let bodyText: String
            let titleH: CGFloat
            let (strippedTitle, rest) = _diagStripTitle(page.text, chapterTitle: title)
            if strippedTitle != nil {
                let titleFont = UIFont.boldSystemFont(ofSize: (textSize * 1.5).rounded())
                let titleAttr = NSAttributedString(string: strippedTitle!, attributes: [.font: titleFont])
                let titleSz = titleAttr.boundingRect(with: CGSize(width: canvasW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil)
                titleH = ceil(titleSz.height) + 24
                bodyText = rest
            } else {
                titleH = 0
                bodyText = page.text
            }

            let uiFont = UIFont.systemFont(ofSize: textSize)
            let paraStyle = NSMutableParagraphStyle()
            paraStyle.lineSpacing = textSize * (1.2 - 1.0)
            paraStyle.paragraphSpacing = 0
            paraStyle.paragraphSpacingBefore = 6
            paraStyle.lineBreakMode = .byCharWrapping
            let bodyAttr = NSAttributedString(string: bodyText, attributes: [
                .font: uiFont, .paragraphStyle: paraStyle
            ])
            let bodyRect = bodyAttr.boundingRect(with: CGSize(width: canvasW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let bodyH = ceil(bodyRect.height)
            let totalRenderedH = titleH + bodyH
            let gap = canvasH - totalRenderedH

            _dbg63Log("DIAG page\(pi) sz=\(textSize) lines=\(ctLines.count) visLen=\(vis.length) ctUsedH=\(String(format: "%.1f", usedH)) ctWasteH=\(String(format: "%.1f", wasteH)) titleH=\(String(format: "%.1f", titleH)) bodyH=\(String(format: "%.1f", bodyH)) totalH=\(String(format: "%.1f", totalRenderedH)) gap=\(String(format: "%.1f", gap)) canvasH=\(String(format: "%.1f", canvasH))")

            startIdx += vis.length
            if pi >= 4 { break }
        }
    }
}

private func _diagMakeAttr(title: String, body: String, config: ReadConfigSnapshot) -> NSAttributedString {
    let bodyFont = UIFont.systemFont(ofSize: config.textSize)
    let titleSize = (config.textSize * 1.5).rounded()
    let titleFont = UIFont.boldSystemFont(ofSize: titleSize)
    let bodyPara = NSMutableParagraphStyle()
    bodyPara.lineSpacing = config.textSize * (config.lineSpacing - 1.0)
    bodyPara.paragraphSpacing = 0
    bodyPara.paragraphSpacingBefore = config.paragraphSpacing
    bodyPara.lineBreakMode = .byCharWrapping
    let titlePara = NSMutableParagraphStyle()
    titlePara.lineSpacing = titleSize * 0.15
    titlePara.paragraphSpacing = 24
    titlePara.lineBreakMode = .byCharWrapping
    let result = NSMutableAttributedString()
    result.append(NSAttributedString(string: title + "\n", attributes: [.font: titleFont, .paragraphStyle: titlePara]))
    let processedBody = PaginationEngine.applyParagraphLayout(body, config: config)
    result.append(NSAttributedString(string: processedBody, attributes: [.font: bodyFont, .paragraphStyle: bodyPara]))
    return result
}

private func _diagStripTitle(_ text: String, chapterTitle: String) -> (String?, String) {
    let t = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, text.hasPrefix(t) else { return (nil, text) }
    let rest = text.dropFirst(t.count)
    if rest.hasPrefix("\n") { return (t, String(rest.dropFirst())) }
    return (t, String(rest))
}
// #endregion
