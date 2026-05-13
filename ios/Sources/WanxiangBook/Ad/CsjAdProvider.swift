//
//  CsjAdProvider.swift
//  万象书屋 iOS · 穿山甲 (Pangle / BUAdSDK) 实现
//
//  对应 Android: io.legado.app.ad.provider.CsjProvider
//
//  接口:
//   - bootstrap(appId): BUAdSDKConfiguration + start
//   - showSplash(posId): 先尝试 splash, 40006/40020 等自动 fallback 新插屏全屏视频
//   - showRewarded(posId): BUNativeExpressRewardedVideoAd
//
//  对齐 Android 关键行为:
//   - CSJ 新流量主默认不发开屏代码位, splash API 返回 40006/40020 → fallback loadFullScreenVideoAd
//   - posId 由 /api/ad-config 下发, 不硬编码

import Foundation
import UIKit
import SwiftUI

#if canImport(BUAdSDK)
import BUAdSDK

public actor CsjAdProvider: AdProvider {

    public let name = AdProviderName.csj
    public private(set) var isReady: Bool = false

    private var pendingReward: CheckedContinuation<Bool, Never>?
    private var pendingSplash: CheckedContinuation<Bool, Never>?

    public init() {}

    public func bootstrap(appId: String) async throws {
        guard !isReady else { return }
        guard !appId.isEmpty else { throw NSError(domain: "CSJ", code: 1, userInfo: [NSLocalizedDescriptionKey: "appId required"]) }

        let cfg = BUAdSDKConfiguration()
        cfg.appID = appId
        cfg.useMediation = false
        #if DEBUG
        cfg.debugLog = 1
        #else
        cfg.debugLog = 0
        #endif

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            BUAdSDKManager.start(asyncCompletionHandler: { success, error in
                if success {
                    Task { await self.markReady() }
                    cont.resume()
                } else {
                    cont.resume(throwing: error ?? NSError(domain: "CSJ", code: 2))
                }
            })
        }
    }

    private func markReady() { isReady = true }

    // MARK: - Splash (对齐 Android loadSplashAd + interstitial fallback)

    public func showSplash(posId: String) async -> Bool {
        guard isReady, !posId.isEmpty else { return false }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.pendingSplash = cont
            Task { @MainActor in
                CsjSplashDelegateBridge.shared.onResult = { [weak self] ok in
                    Task { await self?.completeSplash(ok) }
                }
                CsjSplashDelegateBridge.shared.posId = posId
                // 直接尝试全屏视频，因为 iOS 新插屏 posId 不支持 splash 格式
                // 先尝试 splash API，如果失败再 fallback
                CsjSplashDelegateBridge.shared.loadSplash(posId: posId)
            }
        }
    }

    fileprivate func completeSplash(_ ok: Bool) {
        pendingSplash?.resume(returning: ok)
        pendingSplash = nil
    }

    // MARK: - Rewarded

    public func showRewarded(posId: String) async -> Bool {
        guard isReady, !posId.isEmpty else { return false }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.pendingReward = cont
            Task { @MainActor in
                adLog("[CsjRewarded] loading posId=\(posId)")
                let model = BURewardedVideoModel()
                model.userId = "wanxiang"
                model.rewardName = "纯净阅读"
                model.rewardAmount = 1

                let slot = BUAdSlot()
                slot.id = posId
                slot.adType = .rewardVideo
                let ad = BUNativeExpressRewardedVideoAd(slot: slot, rewardedVideoModel: model)
                ad.delegate = CsjRewardDelegateBridge.shared
                CsjRewardDelegateBridge.shared.reset()
                CsjRewardDelegateBridge.shared.adRef = ad
                CsjRewardDelegateBridge.shared.onResult = { [weak self] result in
                    Task { await self?.completeReward(result) }
                }
                ad.loadData()
            }
        }
    }

    fileprivate func completeReward(_ ok: Bool) {
        pendingReward?.resume(returning: ok)
        pendingReward = nil
    }
}

// MARK: - Splash Delegate Bridge (对齐 Android interstitial-as-splash fallback)

final class CsjSplashDelegateBridge: NSObject {

    static let shared = CsjSplashDelegateBridge()
    var onResult: ((Bool) -> Void)?
    var posId: String = ""
    private var splashAd: BUSplashAd?
    private var dispatched = false

    private func dispatch(_ result: Bool) {
        guard !dispatched else { return }
        dispatched = true
        onResult?(result)
        onResult = nil
    }

    @MainActor
    func loadSplash(posId: String) {
        self.posId = posId
        self.dispatched = false
        let splash = BUSplashAd(slotID: posId, adSize: UIScreen.main.bounds.size)
        splash.delegate = self
        splash.tolerateTimeout = 3.0
        self.splashAd = splash
        splash.loadData()
    }

    @MainActor
    private func fallbackToFullScreenVideo() {
        adLog("[CsjSplash] creating fullscreen ad for posId=\(posId)")
        let slot = BUAdSlot()
        slot.id = posId
        slot.adType = .fullscreenVideo
        slot.position = .fullscreen
        let ad = BUNativeExpressFullscreenVideoAd(slot: slot)
        ad.delegate = CsjFullscreenDelegateBridge.shared
        CsjFullscreenDelegateBridge.shared.onResult = { [weak self] ok in
            self?.dispatch(ok)
        }
        CsjFullscreenDelegateBridge.shared.adRef = ad
        ad.loadData()
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

extension CsjSplashDelegateBridge: BUSplashAdDelegate {
    nonisolated func splashAdLoadSuccess(_ splashAd: BUSplashAd) {
        DispatchQueue.main.async {
            adLog("[CsjSplash] loadSuccess, showing…")
            guard let root = self.topViewController() else {
                adLog("[CsjSplash] no rootVC → false")
                self.dispatch(false)
                return
            }
            splashAd.showSplashView(inRootViewController: root)
        }
    }

    nonisolated func splashAdLoadFail(_ splashAd: BUSplashAd, error: BUAdError?) {
        DispatchQueue.main.async {
            let code = error?.code ?? -1
            adLog("[CsjSplash] loadFail code=\(code) msg=\(error?.localizedDescription ?? "")")
            if code == 40006 || code == 40020 || code == 40016 || code == 40019 {
                adLog("[CsjSplash] fallback to fullscreen video")
                self.splashAd = nil
                self.fallbackToFullScreenVideo()
            } else {
                adLog("[CsjSplash] non-recoverable error → false")
                self.splashAd = nil
                self.dispatch(false)
            }
        }
    }

    nonisolated func splashAdRenderFail(_ splashAd: BUSplashAd, error: BUAdError?) {
        DispatchQueue.main.async {
            adLog("[CsjSplash] renderFail code=\(error?.code ?? -1)")
            self.splashAd = nil
            self.dispatch(false)
        }
    }

    nonisolated func splashVideoAdDidPlayFinish(_ splashAd: BUSplashAd, didFailWithError error: (any Error)?) {}

    nonisolated func splashAdDidClose(_ splashAd: BUSplashAd, closeType: BUSplashAdCloseType) {
        DispatchQueue.main.async {
            adLog("[CsjSplash] didClose closeType=\(closeType.rawValue) → true")
            self.splashAd = nil
            self.dispatch(true)
        }
    }

    nonisolated func splashAdRenderSuccess(_ splashAd: BUSplashAd) {}
    nonisolated func splashAdDidShow(_ splashAd: BUSplashAd) {}
    nonisolated func splashAdDidClick(_ splashAd: BUSplashAd) {}
    nonisolated func splashAdWillShow(_ splashAd: BUSplashAd) {}
    nonisolated func splashAdViewControllerDidClose(_ splashAd: BUSplashAd) {}
    nonisolated func splashDidCloseOtherController(_ splashAd: BUSplashAd, interactionType: BUInteractionType) {}
}

// MARK: - Fullscreen Video (interstitial-as-splash) Bridge

final class CsjFullscreenDelegateBridge: NSObject, BUNativeExpressFullscreenVideoAdDelegate {

    static let shared = CsjFullscreenDelegateBridge()
    var onResult: ((Bool) -> Void)?
    var adRef: BUNativeExpressFullscreenVideoAd?

    private var dismissTimer: DispatchWorkItem?

    nonisolated func nativeExpressFullscreenVideoAdDidLoad(_ fullscreenVideoAd: BUNativeExpressFullscreenVideoAd) {
        DispatchQueue.main.async {
            adLog("[CsjFullscreen] loaded, showing…")
            guard let root = self.topViewController() else {
                adLog("[CsjFullscreen] no rootVC → false")
                self.onResult?(false)
                return
            }
            let shown = fullscreenVideoAd.show(fromRootViewController: root)
            adLog("[CsjFullscreen] show result=\(shown)")

            // 安全超时：15秒后如果广告还没关，自动 dismiss 并返回 true
            self.dismissTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in
                adLog("[CsjFullscreen] safety timeout → dismiss")
                root.dismiss(animated: true)
                self?.adRef = nil
                self?.onResult?(true)
                self?.onResult = nil
            }
            self.dismissTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timer)
        }
    }

    nonisolated func nativeExpressFullscreenVideoAd(_ fullscreenVideoAd: BUNativeExpressFullscreenVideoAd, didFailWithError error: Error?) {
        DispatchQueue.main.async {
            adLog("[CsjFullscreen] fail: \(error?.localizedDescription ?? "")")
            self.dismissTimer?.cancel()
            self.dismissTimer = nil
            self.adRef = nil
            self.onResult?(false)
            self.onResult = nil
        }
    }

    nonisolated func nativeExpressFullscreenVideoAdDidClose(_ fullscreenVideoAd: BUNativeExpressFullscreenVideoAd) {
        DispatchQueue.main.async {
            adLog("[CsjFullscreen] didClose → true")
            self.dismissTimer?.cancel()
            self.dismissTimer = nil
            self.adRef = nil
            self.onResult?(true)
            self.onResult = nil
        }
    }

    nonisolated func nativeExpressFullscreenVideoAdDidClick(_ fullscreenVideoAd: BUNativeExpressFullscreenVideoAd) {}

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

// MARK: - Rewarded Delegate Bridge

final class CsjRewardDelegateBridge: NSObject, BUNativeExpressRewardedVideoAdDelegate {

    static let shared = CsjRewardDelegateBridge()
    var onResult: ((Bool) -> Void)?
    var adRef: BUNativeExpressRewardedVideoAd?
    private var rewarded = false
    private var dispatched = false
    private var timeoutTimer: DispatchWorkItem?

    func reset() {
        rewarded = false
        dispatched = false
        timeoutTimer?.cancel()
        timeoutTimer = nil
        onResult = nil
    }

    /// 对齐 Android AtomicBoolean dispatched: 只分发一次结果
    private func dispatch(_ result: Bool) {
        guard !dispatched else { return }
        dispatched = true
        timeoutTimer?.cancel()
        timeoutTimer = nil
        adLog("[CsjRewarded] dispatch(\(result))")
        onResult?(result)
        onResult = nil
    }

    nonisolated func nativeExpressRewardedVideoAdDidLoad(_ ad: BUNativeExpressRewardedVideoAd) {
        DispatchQueue.main.async {
            adLog("[CsjRewarded] loaded, showing…")
            guard let root = self.topViewController() else {
                adLog("[CsjRewarded] no rootVC → false")
                self.dispatch(false)
                return
            }
            ad.show(fromRootViewController: root)
            adLog("[CsjRewarded] show called")

            // 对齐 Android 180s 硬超时 (诱导下载类激励最长 ~120s)
            let timer = DispatchWorkItem { [weak self] in
                adLog("[CsjRewarded] 180s safety timeout → dispatch(false)")
                self?.adRef = nil
                self?.dispatch(false)
            }
            self.timeoutTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 180, execute: timer)
        }
    }

    nonisolated func nativeExpressRewardedVideoAd(_ rewardedVideoAd: BUNativeExpressRewardedVideoAd, didFailWithError error: Error?) {
        DispatchQueue.main.async {
            adLog("[CsjRewarded] loadFail: \(error?.localizedDescription ?? "")")
            self.adRef = nil
            self.dispatch(false)
        }
    }

    /// 对齐 Android onRewardArrived: 奖励验证成功后立即 dispatch(true)
    nonisolated func nativeExpressRewardedVideoAdServerRewardDidSucceed(_ rewardedVideoAd: BUNativeExpressRewardedVideoAd, verify: Bool) {
        DispatchQueue.main.async {
            adLog("[CsjRewarded] rewardVerify=\(verify)")
            if verify {
                self.rewarded = true
                self.dispatch(true)
            }
        }
    }

    nonisolated func nativeExpressRewardedVideoAdDidClose(_ rewardedVideoAd: BUNativeExpressRewardedVideoAd) {
        DispatchQueue.main.async {
            adLog("[CsjRewarded] didClose rewarded=\(self.rewarded)")
            self.adRef = nil
            // 对齐 Android: close 时如果已 rewarded 但还没 dispatch, 兜底给奖励
            if self.rewarded { self.dispatch(true) } else { self.dispatch(false) }
        }
    }

    nonisolated func nativeExpressRewardedVideoAdDidClick(_ rewardedVideoAd: BUNativeExpressRewardedVideoAd) {
        DispatchQueue.main.async {
            adLog("[CsjRewarded] clicked")
        }
    }

    nonisolated func nativeExpressRewardedVideoAdDidPlayFinish(_ rewardedVideoAd: BUNativeExpressRewardedVideoAd, didFailWithError error: Error?) {
        DispatchQueue.main.async {
            adLog("[CsjRewarded] playFinish error=\(error?.localizedDescription ?? "none")")
        }
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}

#else

// 没 link BUAdSDK (e.g. simulator / 无穿山甲二进制) 时 CsjAdProvider 退化为 Stub
public actor CsjAdProvider: AdProvider {
    public let name = AdProviderName.csj
    public var isReady: Bool { false }
    public init() {}
    public func bootstrap(appId: String) async throws {
        throw NSError(domain: "CSJ", code: 99, userInfo: [NSLocalizedDescriptionKey: "BUAdSDK 未链接 (本地无穿山甲 SDK)"])
    }
    public func showSplash(posId: String) async -> Bool { false }
    public func showRewarded(posId: String) async -> Bool { false }
}

#endif
