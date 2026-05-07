//
//  CsjAdProvider.swift
//  万象书屋 iOS · 穿山甲 (Pangle / BUAdSDK) 实现
//
//  对应 Android: io.legado.app.ad.provider.CsjProvider
//
//  接口:
//   - bootstrap(appId): BUAdSDKConfiguration + start
//   - showSplash: 当前简化为 no-op + 等 1 秒 (开屏需要嵌入 SplashAdActivity 全屏容器, M3.x 后续接)
//   - showRewarded: BUNativeExpressRewardedVideoAd 加载 + 展示 + 回调
//
//  M3 v1: 真接 BUAdSDK, 但开屏走轻量化 (避免 root view controller 注入). 激励视频是核心.
//

import Foundation
import UIKit
import SwiftUI
import BUAdSDK

public actor CsjAdProvider: AdProvider {

    public let name = AdProviderName.csj
    public private(set) var isReady: Bool = false

    /// 当前激励视频 task 的 continuation (回调驱动)
    private var pendingReward: CheckedContinuation<Bool, Never>?

    public init() {}

    public func bootstrap(appId: String) async throws {
        guard !isReady else { return }
        // 万象书屋: appId 必须传, 否则后端没下发就先用 stub
        guard !appId.isEmpty else { throw NSError(domain: "CSJ", code: 1, userInfo: [NSLocalizedDescriptionKey: "appId required"]) }

        let cfg = BUAdSDKConfiguration()
        cfg.appID = appId
        cfg.useMediation = false
        cfg.debugLog = 0
        // 万象书屋: BUAdSDK 7.6 的隐私 API 通过 BUAdSDKManager 单独设, 不是 cfg.privacyConf
        // (历史上 5.x/6.x 版本曾经有 privacyConf, 7.x 已经改了)

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

    public func showSplash(in container: some View) async -> Bool {
        // 万象书屋 v1: 开屏需要 UIViewController 容器, 这里简化为 false (走 SplashView 默认 1.5s)
        // M3.x 后续: 在 SplashView 内嵌 BUSplashAdView, 配 codeID
        return false
    }

    public func showRewarded() async -> Bool {
        guard isReady else { return false }
        // 真广告位 codeID 在 ad-config 下发; 这里取占位
        let codeId = "REPLACE_ME_WITH_REAL_CODE_ID"
        guard codeId != "REPLACE_ME_WITH_REAL_CODE_ID" else {
            print("[CsjProvider] codeId 未配置, fallback")
            return false
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.pendingReward = cont
            // 在主线程加载 (BUAdSDK 要求 UI 操作 main)
            DispatchQueue.main.async {
                let model = BURewardedVideoModel()
                model.userId = "wanxiang"
                let ad = BUNativeExpressRewardedVideoAd(slotID: codeId, rewardedVideoModel: model)
                ad.delegate = CsjRewardDelegateBridge.shared
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

// 万象书屋: BUAdSDK delegate 必须 NSObject + 主线程, 用单例桥接到 actor
final class CsjRewardDelegateBridge: NSObject, BUNativeExpressRewardedVideoAdDelegate {

    static let shared = CsjRewardDelegateBridge()
    var onResult: ((Bool) -> Void)?
    private var rewarded = false

    func nativeExpressRewardedVideoAdDidLoad(_ ad: BUNativeExpressRewardedVideoAd) {
        guard let root = topViewController() else { onResult?(false); return }
        ad.show(fromRootViewController: root)
    }

    func nativeExpressRewardedVideoAd(_ rewardedVideoAd: BUNativeExpressRewardedVideoAd, didFailWithError error: Error?) {
        onResult?(false); rewarded = false
    }

    func nativeExpressRewardedVideoAdServerRewardDidSucceed(_ rewardedVideoAd: BUNativeExpressRewardedVideoAd, verify: Bool) {
        rewarded = verify
    }

    func nativeExpressRewardedVideoAdDidClose(_ rewardedVideoAd: BUNativeExpressRewardedVideoAd) {
        onResult?(rewarded); rewarded = false
    }

    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}
