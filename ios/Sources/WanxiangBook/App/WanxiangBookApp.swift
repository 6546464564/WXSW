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
    // 万象书屋: 监听 App 生命周期, 进/退后台时 send ping
    @Environment(\.scenePhase) private var scenePhase

    /// 万象书屋: 跟 Android `SplashAdActivity` 对齐 — 启动先展开屏页, 完成后再进 RootView.
    /// 进程级状态, 不做 UserDefaults 持久化 (每次冷启都展示一次, 跟 Android LAUNCHER 行为一致).
    @State private var splashFinished = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
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
            .task {
                await appState.bootstrap()
            }
            .onChange(of: scenePhase) { _, newPhase in
                Task { await appState.handleScenePhase(newPhase) }
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
    private var lastPingAt: Date? = nil
    private static let pingInterval: TimeInterval = 4 * 60   // 4 分钟一次, 跟后端 rateLimitPing 对齐

    /// 启动时拉一次设备注册 + 拉书源 + 启心跳
    func bootstrap() async {
        guard !isBootstrapped else { return }
        await BrowserBridgeRegistry.shared.set(
            await MainActor.run { WKWebViewBridge() }
        )
        // 万象书屋 (M2.8): 启动时 restore Cloudflare 反爬 cookie. 让用户重启 App 后
        // 30 分钟内访问反爬源 (顶点 / 随梦 / 海棠 / UAA 等) 直接秒拉, 不必再跑
        // 25s webview challenge.
        CloudflareCookieStore.shared.restoreFromDisk()
        // 万象书屋: 确保新表 schema 存在 (book_groups 等)
        try? await BookGroupRepository.shared.ensureSchema()
        // 万象书屋: 注入解析器健康上报 sink (BookSource 模块不直接依赖 WanxiangAPI)
        SourceHealthSinkRegistry.shared.register(WanxiangAPISourceHealthSink())
        // 万象书屋: 启埋点 SDK (跟 Android `App.kt` `WanxiangAnalytics.init()` 等价)
        await WanxiangAnalytics.shared.start()
        do {
            try await WanxiangAPI.shared.registerDeviceIfNeeded()
            await BookSourceRegistry.shared.bootstrap()
            isBootstrapped = true
        } catch {
            lastError = "\(error)"
            bootstrapFailed = true
            isBootstrapped = true
        }
        // 万象书屋: 启动后立即首次 ping (访问统计) + 拉公告/版本 + 拉广告配置
        // 广告配置 consent 与否都拉 (只是配置, 无个人数据); SDK init 仍受 consent 控制
        await Task.detached(priority: .background) { [weak self] in
            await self?.sendPingNow()
            await self?.fetchAnnouncement()
            await self?.fetchVersionCheck()
            await AdManager.shared.refreshConfig()
        }.value
        // 万象书屋 (M2.4 perf): 在 splash 这 1s 期间预热 BookSourceEngine 单例
        // (含 4 个 JSEngine + stdlib 注入), 让用户进搜索页时第一次 search 不再等
        // ~200-400ms 的冷启 cost. 是 lazy singleton 的最早 access 点, 副作用 0.
        Task.detached(priority: .utility) {
            _ = BookSourceEngine.shared
        }
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
    /// - active   → 立即 ping (用户回到 App, 算一次活跃)
    /// - inactive → 不动
    /// - background → 取消心跳定时器 (省电, iOS 后台限制反正也跑不动)
    func handleScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            // 后台回前台立即 ping 一次 + 重启 heartbeat
            await sendPingNow()
            if heartbeatTimer == nil || heartbeatTimer?.isCancelled == true {
                startHeartbeatLoop()
            }
            // 万象书屋 (方案 G'): 切回前台兜底刷一次源 etag.
            // 心跳 sendPingNow 已经会通过 X-Sources-Etag header 发现变更, 这里多一次 If-None-Match
            // 探测只是双保险 — 极端弱网下 ping 失败时也能在前台刷一次源.
            BookSourceRegistry.shared.refreshOnBecameActive()
        case .background:
            heartbeatTimer?.cancel()
            heartbeatTimer = nil
            // 万象书屋: 切后台时强制 flush 埋点队列, 避免事件留在内存里被进程回收丢掉
            // (跟 Android `BaseActivity.onPause` 里 `WanxiangAnalytics.flush()` 等价)
            await WanxiangAnalytics.shared.flush()
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
        // M2.1.7: 全局崩溃捕获 (在第一行业务代码之前安装)
        CrashHandler.install()
        return true
    }
}
