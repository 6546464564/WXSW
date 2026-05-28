//
//  AdManager.swift
//  万象书屋 iOS · 广告调度器 (M3.3)
//
//  对应 Android: io.legado.app.ad.AdManager
//
//  职责:
//   - 持有多个 provider (按 /api/ad-config 的 weight 加权随机选择)
//   - 管理 init 状态 (隐私同意前不 init)
//   - 屏蔽审核期 (review_mode=true 时全部 short-circuit)
//   - 上报事件 → /api/ad-event
//   - 解析 placements 配置, 按 weight 抽签选 provider + posId (对齐 Android pickProvider)

import Foundation
import SwiftUI
import os.log

private let adLogger = Logger(subsystem: "com.wanxiang.reader", category: "AdManager")
private let adLogLock = NSLock()
func adLog(_ msg: String) {
    adLogger.error("\(msg)")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ad_debug.log")
    let line = "\(Date()): \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    adLogLock.lock()
    defer { adLogLock.unlock() }
    if FileManager.default.fileExists(atPath: url.path) {
        if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(data); fh.closeFile() }
    } else {
        try? data.write(to: url)
    }
}

@MainActor
public final class AdManager: ObservableObject {

    public static let shared = AdManager()

    @Published public private(set) var consented: Bool
    @Published public private(set) var enabled: Bool = false
    @Published public private(set) var reviewMode: Bool = false
    @Published public private(set) var bootstrapped: Bool = false

    /// 防止并发 bootstrap (对齐 Android bootstrapMutex)
    private var bootstrapping: Bool = false
    private var bootstrapWaiters: [CheckedContinuation<Void, Never>] = []

    /// 所有已 init 的 provider 实例 (对齐 Android providers map)
    private var providers: [String: any AdProvider] = ["stub": StubAdProvider()]
    public private(set) var cachedConfig: [String: Any]?

    /// 从 config 解析出的 placement 配置 (每个 placement 包含 providers 数组含 weight/posId)
    private var splashProviderSlots: [ProviderSlot] = []
    private var rewardedProviderSlots: [ProviderSlot] = []

    private static let kConsented = "wanxiang.ad.consented_v1"
    private static let kCachedConfig = "wanxiang.ad.config_v1"

    /// 加权随机选择用的内部结构
    struct ProviderSlot {
        let name: String
        let weight: Int
        let posId: String
    }

    /// UI 测试模式: 完全禁用所有广告功能
    #if TESTLAB
    public let isUITest = true
    #else
    public let isUITest = CommandLine.arguments.contains("-uitest")
    #endif

    private init() {
        if isUITest {
            self.consented = false
            self.enabled = false
            self.reviewMode = true
            self.bootstrapped = true
            adLog("[AdManager] UI test mode → all ads disabled")
            return
        }
        // 首次安装时 UserDefaults 无值 → object(forKey:) 返 nil → 视为已同意（自动授权）
        let stored = UserDefaults.standard.object(forKey: Self.kConsented)
        if stored == nil {
            UserDefaults.standard.set(true, forKey: Self.kConsented)
        }
        self.consented = UserDefaults.standard.bool(forKey: Self.kConsented)
        if let raw = UserDefaults.standard.data(forKey: Self.kCachedConfig),
           let dict = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] {
            self.cachedConfig = dict
            self.enabled = !(dict["disabled"] as? Bool ?? true)
            self.reviewMode = dict["review_mode"] as? Bool ?? false
            parsePlacements(from: dict)
        }
    }

    /// 启动时调一次, 把 /api/ad-config 拉到 cachedConfig + 持久化.
    public func refreshConfig() async {
        let config = await fetchAdConfig()
        guard !config.isEmpty else { return }
        self.cachedConfig = config
        self.enabled = !(config["disabled"] as? Bool ?? true)
        self.reviewMode = config["review_mode"] as? Bool ?? false
        parsePlacements(from: config)
        if let data = try? JSONSerialization.data(withJSONObject: config) {
            UserDefaults.standard.set(data, forKey: Self.kCachedConfig)
        }
    }

    /// 解析 placements → ProviderSlot 数组 (对齐 Android AdConfig.Placements)
    private func parsePlacements(from config: [String: Any]) {
        let placements = config["placements"] as? [String: Any] ?? [:]

        if let splash = placements["splash"] as? [String: Any],
           let providerList = splash["providers"] as? [[String: Any]] {
            self.splashProviderSlots = providerList.compactMap { parseSlot($0) }
        }

        if let rewarded = placements["rewardedReadingUnlock"] as? [String: Any],
           let providerList = rewarded["providers"] as? [[String: Any]] {
            self.rewardedProviderSlots = providerList.compactMap { parseSlot($0) }
        }
    }

    private func parseSlot(_ dict: [String: Any]) -> ProviderSlot? {
        guard let name = dict["name"] as? String else { return nil }
        let posId = (dict["iosPosId"] as? String) ?? (dict["posId"] as? String) ?? ""
        guard !posId.isEmpty else { return nil }
        let weight = dict["weight"] as? Int ?? 0
        guard weight > 0 else { return nil }
        return ProviderSlot(name: name, weight: weight, posId: posId)
    }

    // MARK: - 加权随机选择 Provider (对齐 Android pickProvider)

    /// 按 weight 加权随机从 placement 对应的 slots 中抽出一个可用的 provider + posId
    private func pickProvider(for placement: AdPlacement) -> (provider: any AdProvider, posId: String)? {
        let slots: [ProviderSlot]
        switch placement {
        case .splash:
            slots = splashProviderSlots
        case .rewardedReadingUnlock:
            slots = rewardedProviderSlots
        default:
            return nil
        }

        let candidates = slots.filter { slot in
            slot.name != "stub" && providers[slot.name] != nil
        }

        guard !candidates.isEmpty else { return nil }

        let totalWeight = candidates.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }

        var roll = Int.random(in: 0..<totalWeight)
        for c in candidates {
            roll -= c.weight
            if roll < 0 {
                if let p = providers[c.name] {
                    return (p, c.posId)
                }
            }
        }
        if let last = candidates.last, let p = providers[last.name] {
            return (p, last.posId)
        }
        return nil
    }

    // MARK: - 同意态 (PIPL)

    public func setConsent(_ granted: Bool) async {
        consented = granted
        UserDefaults.standard.set(granted, forKey: Self.kConsented)
        if granted {
            await bootstrap()
        }
    }

    public func revokeConsent() {
        consented = false
        UserDefaults.standard.set(false, forKey: Self.kConsented)
        bootstrapped = false
        providers = ["stub": StubAdProvider()]
    }

    // MARK: - 配置加载

    public func bootstrap() async {
        guard !isUITest, consented else { return }
        guard !bootstrapped else { return }

        if bootstrapping {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                bootstrapWaiters.append(cont)
            }
            return
        }
        bootstrapping = true

        await refreshConfig()
        let config = cachedConfig ?? [:]
        self.enabled = !(config["disabled"] as? Bool ?? true)
        self.reviewMode = config["review_mode"] as? Bool ?? false
        parsePlacements(from: config)

        if !enabled || reviewMode {
            providers = ["stub": StubAdProvider()]
            bootstrapped = true
            bootstrapping = false
            let earlyWaiters = bootstrapWaiters
            bootstrapWaiters.removeAll()
            for w in earlyWaiters { w.resume() }
            return
        }

        let csjAppId = (config["csj"] as? [String: Any])?["iosAppId"] as? String
            ?? (config["sdk"] as? [String: Any]).flatMap { ($0["csj"] as? [String: Any])?["iosAppId"] as? String }
            ?? (config["sdk"] as? [String: Any]).flatMap { ($0["csj"] as? [String: Any])?["appId"] as? String }
            ?? ""
        let gdtAppId = (config["ylh"] as? [String: Any])?["iosAppId"] as? String
            ?? (config["sdk"] as? [String: Any]).flatMap { ($0["ylh"] as? [String: Any])?["iosAppId"] as? String }
            ?? (config["sdk"] as? [String: Any]).flatMap { ($0["ylh"] as? [String: Any])?["appId"] as? String }
            ?? ""

        adLog("bootstrap: enabled=\(enabled) reviewMode=\(reviewMode) csjAppId=\(csjAppId) gdtAppId=\(gdtAppId)")

        // 对齐 Android initOnDemand: 按配置中 weight>0 的 provider 逐一 init
        let allSlots = Set((splashProviderSlots + rewardedProviderSlots).map { $0.name })

        if allSlots.contains("csj") && !csjAppId.isEmpty {
            do {
                adLog("initializing CSJ with appId=\(csjAppId)")
                let p = CsjAdProvider()
                try await p.bootstrap(appId: csjAppId)
                providers["csj"] = p
                adLog("CSJ bootstrap OK")
            } catch {
                adLog("CSJ bootstrap FAILED: \(error)")
            }
        }

        if allSlots.contains("ylh") && !gdtAppId.isEmpty {
            do {
                adLog("initializing GDT with appId=\(gdtAppId)")
                let p = GdtAdProvider()
                try await p.bootstrap(appId: gdtAppId)
                providers["ylh"] = p
                adLog("GDT bootstrap OK")
            } catch {
                adLog("GDT bootstrap FAILED: \(error)")
            }
        }

        // 如果所有 provider 都失败, 保留 stub
        if providers.keys.filter({ $0 != "stub" }).isEmpty {
            adLog("all providers failed, only stub available")
        }

        bootstrapped = true
        bootstrapping = false
        let waiters = bootstrapWaiters
        bootstrapWaiters.removeAll()
        for w in waiters { w.resume() }

        // 不弹 ATT 弹窗：伪装 App 弹广告追踪授权会暴露真实用途
        // 广告 SDK 无 IDFA 仍可投放非精准广告
    }

    private func fetchAdConfig() async -> [String: Any] {
        do {
            let req = WanxiangAPI.shared.request(path: "/api/ad-config", method: "GET")
            let (data, _) = try await WanxiangAPI.shared.httpData(for: req)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let config = dict["config"] as? [String: Any] {
                return config
            }
        } catch {
            adLog("fetchAdConfig failed: \(error)")
        }
        return [:]
    }

    // MARK: - 展示

    public func showSplash<V: View>(container: V) async -> Bool {
        adLog("showSplash called: consented=\(consented) reviewMode=\(reviewMode) enabled=\(enabled) bootstrapped=\(bootstrapped)")
        guard consented, !reviewMode, enabled else {
            adLog("showSplash guard failed → skip")
            return false
        }
        if !bootstrapped { await bootstrap() }

        guard let pick = pickProvider(for: .splash) else {
            adLog("showSplash: no provider available (pickProvider returned nil)")
            return false
        }
        adLog("showSplash calling provider=\(pick.provider.name.rawValue) posId=\(pick.posId)")
        let r = await pick.provider.showSplash(posId: pick.posId)
        adLog("showSplash result=\(r)")
        WanxiangAPI.shared.reportAdEvent(placement: AdPlacement.splash.rawValue, provider: pick.provider.name.rawValue, type: r ? "shown" : "skipped")
        return r
    }

    // MARK: - 确认弹窗逻辑 (对齐 Android RewardedAdHelper.tryPrompt)

    /// 广告 SDK 是否有可用的 rewarded provider（不含冷却/状态检查）
    public var hasRewardedAdProvider: Bool {
        guard consented, enabled, !reviewMode, bootstrapped else { return false }
        return pickProvider(for: .rewardedReadingUnlock) != nil
            || CommandLine.arguments.contains("-autoRewardAds")
    }

    /// 是否应该弹出"看广告解锁"确认对话框 (对齐 Android `RewardedAdHelper.tryPrompt` 前置判断)
    /// 调用方频率不限, 不满足节奏/未同意/远端关位 都返回 false
    public func shouldPromptRewarded() -> Bool {
        guard hasRewardedAdProvider else { return false }
        guard !PurifiedReadingState.shared.isActive else { return false }
        guard PurifiedReadingState.shared.canShowRewardedAdNow() else { return false }
        return true
    }

    /// 看广告解锁纯净阅读 (对齐 Android loadAndShowRewarded)
    public func showRewardedToUnlock(minutes: Int = 30) async -> Bool {
        // 测试模式: 跳过真实广告，直接解锁
        if CommandLine.arguments.contains("-autoRewardAds") {
            adLog("showRewarded: AUTO-REWARD (test mode)")
            PurifiedReadingState.shared.markRewardedSuccess(unlockMinutes: minutes)
            return true
        }

        adLog("showRewarded called: consented=\(consented) bootstrapped=\(bootstrapped)")
        guard consented else { return false }
        if !bootstrapped { await bootstrap() }

        guard let pick = pickProvider(for: .rewardedReadingUnlock) else {
            adLog("showRewarded: no provider (pickProvider nil)")
            return false
        }
        adLog("showRewarded: provider=\(pick.provider.name.rawValue) posId=\(pick.posId)")
        WanxiangAPI.shared.reportAdEvent(
            placement: AdPlacement.rewardedReadingUnlock.rawValue,
            provider: pick.provider.name.rawValue,
            type: "load"
        )
        let success = await pick.provider.showRewarded(posId: pick.posId)
        adLog("showRewarded result=\(success)")
        WanxiangAPI.shared.reportAdEvent(
            placement: AdPlacement.rewardedReadingUnlock.rawValue,
            provider: pick.provider.name.rawValue,
            type: success ? "reward" : "fail"
        )
        if success {
            PurifiedReadingState.shared.markRewardedSuccess(unlockMinutes: minutes)
        }
        return success
    }
}
