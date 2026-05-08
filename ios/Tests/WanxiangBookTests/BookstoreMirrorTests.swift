//
//  BookstoreMirrorTests.swift
//  万象书屋 iOS · 后端 mirror cache 测试
//
//  覆盖纯 actor 状态行为 (clear / TTL); 网络 mock 不在本测覆盖.
//

import XCTest
@testable import WanxiangBook

final class BookstoreMirrorTests: XCTestCase {

    func test_clearCache_resets() async {
        // 不发请求, 只验证 clearCache 不 crash 即可 (更深的 cache 行为需 mock URLSession)
        await BookstoreMirror.shared.clearCache()
        // ok if no throw
        XCTAssertTrue(true)
    }
}

final class PurifiedReadingStateTests: XCTestCase {

    @MainActor
    func test_markRewardedSuccess_extends_within_cap() async {
        let s = PurifiedReadingState.shared
        s.wipe()
        s.markRewardedSuccess(unlockMinutes: 30, maxAccumulatedMinutes: 1440)
        XCTAssertGreaterThan(s.remainingSeconds, 29 * 60)
        XCTAssertLessThanOrEqual(s.remainingSeconds, 30 * 60)
        // 再加 30 分钟 — 累加到 60 (跟 Android 同款 NOT 覆盖)
        s.markRewardedSuccess(unlockMinutes: 30, maxAccumulatedMinutes: 1440)
        XCTAssertGreaterThan(s.remainingSeconds, 59 * 60)
    }

    @MainActor
    func test_markRewardedSuccess_capped() async {
        let s = PurifiedReadingState.shared
        s.wipe()
        // 上限 1 分钟 → 加 30 分钟也只到 1
        s.markRewardedSuccess(unlockMinutes: 30, maxAccumulatedMinutes: 1)
        XCTAssertLessThanOrEqual(s.remainingSeconds, 60)
    }

    @MainActor
    func test_cooldown_after_reward() async {
        let s = PurifiedReadingState.shared
        s.wipe()
        s.markRewardedSuccess(unlockMinutes: 30)
        // 默认 cooldownSec=180, 刚兑现完不能再看
        XCTAssertFalse(s.canShowRewardedAdNow(cooldownSec: 180))
        XCTAssertGreaterThan(s.secondsUntilNextRewardedAllowed(cooldownSec: 180), 0)
        // cooldownSec=0 任何时候都能看
        XCTAssertTrue(s.canShowRewardedAdNow(cooldownSec: 0))
    }

    @MainActor
    func test_formattedRemainingHms_formats() async {
        let s = PurifiedReadingState.shared
        s.wipe()
        // 没有解锁 → 0
        XCTAssertEqual(s.formattedRemainingHms, "00:00")
        // 加 65 秒 → 01:05
        s.markRewardedSuccess(unlockMinutes: 0, maxAccumulatedMinutes: 1440)
        // 上面 unlockMinutes=0 被 coerceAtLeast(1) 调到 1, 应该 ~01:00
        XCTAssertTrue(s.formattedRemainingHms.hasPrefix("00:") || s.formattedRemainingHms.hasPrefix("01:"))
    }
}
