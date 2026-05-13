//
//  AdProvider.swift
//  万象书屋 iOS · 广告 SDK 抽象 (M3.1-3)
//
//  对应 Android: io.legado.app.ad.AdProvider 接口 + CsjProvider/YlhProvider/StubAdProvider
//
//  M3 v1: 只实现 StubAdProvider (开发期), Pangle/GDT iOS SDK 接入留 M3.1-2 真做
//

import Foundation
import SwiftUI

public enum AdPlacement: String, Sendable {
    case splash = "splash"
    case rewardedReadingUnlock = "rewardedReadingUnlock"
    case banner = "banner"
}

public enum AdProviderName: String, Sendable {
    case csj = "csj"      // 穿山甲 (BUAdSDK)
    case ylh = "ylh"      // 优量汇 (GDTMobSDK)
    case stub = "stub"    // 占位 (开发期 / 审核期)
}

/// 广告提供方接口 (CSJ / YLH / Stub 各实现一份)
public protocol AdProvider: Sendable {
    var name: AdProviderName { get }
    /// SDK 是否已 init
    var isReady: Bool { get async }
    /// 异步 init (拿到隐私同意后才调)
    func bootstrap(appId: String) async throws
    /// 显示开屏广告 (返回是否成功展示); posId 从 /api/ad-config 下发
    func showSplash(posId: String) async -> Bool
    /// 显示激励视频, 用户看完返回 true (= 解锁); posId 从 /api/ad-config 下发
    func showRewarded(posId: String) async -> Bool
}

// MARK: - Stub 实现 (开发/审核期默认)

public actor StubAdProvider: AdProvider {

    public let name = AdProviderName.stub
    public var isReady: Bool { true }

    public init() {}

    public func bootstrap(appId: String) async throws {
        // no-op
    }

    public func showSplash(posId: String) async -> Bool {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return false
    }

    public func showRewarded(posId: String) async -> Bool {
        try? await Task.sleep(nanoseconds: 500_000_000)
        return true
    }
}
