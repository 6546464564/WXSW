//
//  GdtAdProvider.swift
//  万象书屋 iOS · 优量汇 (GDT / GDTMobSDK) 实现
//
//  对应 Android: io.legado.app.ad.provider.YlhProvider
//
//  注意: GDT 4.15.80 simulator slice 只有 x86_64, 不支持 arm64 simulator (Apple Silicon).
//  所以默认条件编译, 真机 archive 时在 project.yml 解开 GDTMobSDK 引用即可.
//

import Foundation
import UIKit
import SwiftUI

#if canImport(GDTMobSDK) && !targetEnvironment(simulator)
import GDTMobSDK

public actor GdtAdProvider: AdProvider {

    public let name = AdProviderName.ylh
    public private(set) var isReady: Bool = false
    private var pendingReward: CheckedContinuation<Bool, Never>?
    private var appId: String = ""

    public init() {}

    public func bootstrap(appId: String) async throws {
        guard !isReady else { return }
        guard !appId.isEmpty else { throw NSError(domain: "GDT", code: 1) }
        self.appId = appId
        await MainActor.run {
            GDTSDKConfig.registerAppId(appId)
        }
        isReady = true
    }

    public func showSplash(posId: String) async -> Bool {
        return false
    }

    public func showRewarded(posId: String) async -> Bool {
        guard isReady, !posId.isEmpty else { return false }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.pendingReward = cont
            Task { @MainActor in
                let ad = GDTRewardVideoAd(placementId: posId)
                ad.delegate = GdtRewardDelegateBridge.shared
                GdtRewardDelegateBridge.shared.adRef = ad
                GdtRewardDelegateBridge.shared.onResult = { [weak self] ok in
                    Task { await self?.completeReward(ok) }
                }
                ad.load()
            }
        }
    }

    fileprivate func completeReward(_ ok: Bool) {
        pendingReward?.resume(returning: ok)
        pendingReward = nil
    }
}

@MainActor
final class GdtRewardDelegateBridge: NSObject, GDTRewardedVideoAdDelegate {
    static let shared = GdtRewardDelegateBridge()
    var onResult: ((Bool) -> Void)?
    var adRef: GDTRewardVideoAd?
    private var rewarded = false

    func gdt_rewardVideoAdDidLoad(_ rewardedVideoAd: GDTRewardVideoAd) {
        guard let root = topViewController() else { onResult?(false); return }
        rewardedVideoAd.show(fromRootViewController: root)
    }

    func gdt_rewardVideoAd(_ rewardedVideoAd: GDTRewardVideoAd, didFailWithError error: Error) {
        onResult?(false)
        adRef = nil
    }

    func gdt_rewardVideoAdDidRewardEffective(_ rewardedVideoAd: GDTRewardVideoAd, info: [AnyHashable : Any] = [:]) {
        rewarded = true
    }

    func gdt_rewardVideoAdDidClose(_ rewardedVideoAd: GDTRewardVideoAd) {
        onResult?(rewarded)
        rewarded = false
        adRef = nil
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

#else

// 万象书屋: 没 link GDTMobSDK (e.g. simulator) 时, GdtAdProvider 退化为 Stub
public actor GdtAdProvider: AdProvider {
    public let name = AdProviderName.ylh
    public var isReady: Bool { false }
    public init() {}
    public func bootstrap(appId: String) async throws {
        throw NSError(domain: "GDT", code: 99, userInfo: [NSLocalizedDescriptionKey: "GDT 未链接 (simulator). 真机 build 才有"])
    }
    public func showSplash(posId: String) async -> Bool { false }
    public func showRewarded(posId: String) async -> Bool { false }
}

#endif
