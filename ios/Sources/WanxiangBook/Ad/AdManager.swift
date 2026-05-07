//
//  AdManager.swift
//  万象书屋 iOS · 广告调度器 (M3.3)
//
//  对应 Android: io.legado.app.ad.AdManager
//
//  职责:
//   - 持有当前 provider (按 /api/ad-config 决定; 默认 stub)
//   - 管理 init 状态 (隐私同意前不 init)
//   - 屏蔽审核期 (review_mode=true 时全部 short-circuit)
//   - 上报事件 → /api/ad-event
//

import Foundation
import SwiftUI

@MainActor
public final class AdManager: ObservableObject {

    public static let shared = AdManager()

    @Published public private(set) var consented: Bool
    @Published public private(set) var enabled: Bool = false       // /api/ad-config disabled?
    @Published public private(set) var reviewMode: Bool = false    // 审核期临时关
    @Published public private(set) var bootstrapped: Bool = false

    private var provider: any AdProvider = StubAdProvider()

    private static let kConsented = "wanxiang.ad.consented_v1"

    private init() {
        self.consented = UserDefaults.standard.bool(forKey: Self.kConsented)
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
        provider = StubAdProvider()
    }

    // MARK: - 配置加载

    /// 从 /api/ad-config 拉配置 (M3.6) → 决定 provider + appId
    public func bootstrap() async {
        guard consented else { return }
        guard !bootstrapped else { return }

        // 1. 拉广告配置
        let config = await fetchAdConfig()
        self.enabled = !(config["disabled"] as? Bool ?? true)
        self.reviewMode = config["review_mode"] as? Bool ?? false

        // 2. 审核期 / 全局禁用 → Stub
        if !enabled || reviewMode {
            provider = StubAdProvider()
            bootstrapped = true
            return
        }

        // 3. 按配置选 provider
        let csjAppId = (config["csj"] as? [String: Any])?["appId"] as? String ?? ""
        let gdtAppId = (config["ylh"] as? [String: Any])?["appId"] as? String ?? ""
        let preferredName = config["primary"] as? String ?? "csj"

        do {
            switch preferredName {
            case "csj" where !csjAppId.isEmpty:
                let p = CsjAdProvider()
                try await p.bootstrap(appId: csjAppId)
                provider = p
            case "ylh" where !gdtAppId.isEmpty:
                let p = GdtAdProvider()
                try await p.bootstrap(appId: gdtAppId)
                provider = p
            default:
                // 没 appId → Stub
                provider = StubAdProvider()
            }
            bootstrapped = true

            // ATT 弹窗 (用户同意后才弹, 不强弹)
            if ATTPrompt.shouldRequest {
                _ = await ATTPrompt.request()
            }
        } catch {
            print("[AdManager] bootstrap failed: \(error)")
            provider = StubAdProvider()
            bootstrapped = true
        }
    }

    /// 拉 /api/ad-config
    private func fetchAdConfig() async -> [String: Any] {
        do {
            let req = await WanxiangAPI.shared.request(path: "/api/ad-config", method: "GET")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let config = dict["config"] as? [String: Any] {
                return config
            }
        } catch {
            print("[AdManager] fetchAdConfig failed: \(error)")
        }
        return [:]
    }

    // MARK: - 展示

    public func showSplash<V: View>(container: V) async -> Bool {
        guard consented, !reviewMode, enabled else { return false }
        let r = await provider.showSplash(in: container)
        WanxiangAPI.shared.reportAdEvent(placement: AdPlacement.splash.rawValue, provider: provider.name.rawValue, type: r ? "shown" : "skipped")
        return r
    }

    /// 看广告解锁 30 分钟纯净阅读
    public func showRewardedToUnlock(minutes: Int = 30) async -> Bool {
        guard consented else { return false }
        // reviewMode 下也允许激励 (因为不展示 ads, 直接给奖励)
        // enabled=false 时也允许 (用 stub 立即返回 true, 让用户体验功能)
        let success = await provider.showRewarded()
        WanxiangAPI.shared.reportAdEvent(
            placement: AdPlacement.rewardedReadingUnlock.rawValue,
            provider: provider.name.rawValue,
            type: success ? "reward" : "fail"
        )
        if success {
            PurifiedReadingState.shared.extendUnlock(byMinutes: minutes)
        }
        return success
    }
}
