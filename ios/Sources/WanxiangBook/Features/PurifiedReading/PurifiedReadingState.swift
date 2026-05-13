//
//  PurifiedReadingState.swift
//  万象书屋 iOS · 纯净阅读解锁状态
//
//  对应 Android: io.legado.app.ad.AdRateLimiter
//
//  跟 Android 对齐的能力:
//   - unlockedUntil: 解锁有效期截止 (KEY_UNLOCK_UNTIL_MS)
//   - lastRewardedAt: 上次成功兑现激励的时间 (KEY_LAST_REWARDED_MS, 给冷却倒计时用)
//   - markRewardedSuccess(unlockMinutes:maxAccumulatedMinutes:):
//       累加 (而非覆盖) 解锁时长, 受 cap 限制
//   - secondsUntilNextRewardedAllowed(cooldownSec:):
//       距下次允许看广告还剩多少秒 (0=可看)
//   - canShowRewardedAdNow(cooldownSec:): 同 Android, true=可看
//   - chaptersOpenedThisSession / shouldRequireUnlock: 章节级付费墙 (对齐 Android)
//   - recordAdFailureAndCheckGrace: 连续失败兜底 (对齐 Android)
//

import Foundation
import Combine

@MainActor
final class PurifiedReadingState: ObservableObject {

    static let shared = PurifiedReadingState()

    // MARK: - 跟 Android AdRateLimiter 对齐的默认参数
    /// Android `rwd.unlockMinutes` (后端 ad-config 配置, 默认 30)
    static let defaultUnlockMinutes: Int = 30
    /// Android `rwd.cooldownSec` (默认 180 = 3 分钟)
    static let defaultCooldownSec: Int = 180
    /// Android markRewardedSuccess 默认 cap (1440 分钟 = 24 小时)
    static let defaultMaxAccumulatedMinutes: Int = 1440
    /// 连续广告加载失败 N 次后触发兜底解锁 (对齐 Android AD_FAILURE_GRACE_THRESHOLD)
    static let adFailureGraceThreshold: Int = 3
    /// 兜底解锁时长 (对齐 Android AD_FAILURE_GRACE_MINUTES)
    static let adFailureGraceMinutes: Int = 5

    @Published private(set) var unlockedUntil: Date? = nil
    @Published private(set) var remainingSeconds: Int = 0
    /// 万象书屋: 距下次允许看广告还剩秒数 (0=可看). 跟 Android `secondsUntilNextRewardedAllowed` 对齐.
    @Published private(set) var cooldownSecondsRemaining: Int = 0
    /// 上次成功 reward 时间戳; 用于冷却计算
    @Published private(set) var lastRewardedAt: Date? = nil

    // MARK: - 章节级付费墙 (对齐 Android chaptersOpenedThisSession)
    /// 本次冷启动累计已读章节数 (内存计数, 进程重启清零)
    private(set) var chaptersOpenedThisSession: Int = 0
    private var seenChapterKeys: Set<String> = []

    // MARK: - 广告失败兜底 (对齐 Android consecutiveAdFailures)
    private var consecutiveAdFailures: Int = 0

    private var timer: Timer? = nil
    private static let kUnlockUntil = "wanxiang.purified.unlock_until"
    private static let kLastRewarded = "wanxiang.purified.last_rewarded_at"

    private init() {
        let ts = UserDefaults.standard.double(forKey: Self.kUnlockUntil)
        if ts > 0 {
            let d = Date(timeIntervalSince1970: ts)
            if d > Date() { self.unlockedUntil = d }
        }
        let lr = UserDefaults.standard.double(forKey: Self.kLastRewarded)
        if lr > 0 {
            self.lastRewardedAt = Date(timeIntervalSince1970: lr)
        }
        if unlockedUntil != nil || lastRewardedAt != nil {
            ensureTimerRunning()
        }
        tick()
    }

    // MARK: - 兑现成功 (跟 Android `markRewardedSuccess` 1:1 对齐)

    /// 用户成功看完激励视频, **累加** [unlockMinutes] 分钟解锁 (而非覆盖).
    ///
    /// 累加逻辑 (Android 同款):
    ///   - 当前剩余 25 分 + 看 1 次广告 → 25 + 30 = 55 分钟
    ///   - 当前剩余 0 分钟 + 看 1 次广告 → 30 分钟
    ///   - 上限 [maxAccumulatedMinutes] (默认 1440 = 24 小时), 防恶意刷量
    func markRewardedSuccess(
        unlockMinutes: Int = defaultUnlockMinutes,
        maxAccumulatedMinutes: Int = defaultMaxAccumulatedMinutes
    ) {
        let now = Date()
        let base = (unlockedUntil ?? now) > now ? unlockedUntil! : now
        let delta = TimeInterval(max(unlockMinutes, 1) * 60)
        let cap = now.addingTimeInterval(TimeInterval(max(maxAccumulatedMinutes, 1) * 60))
        let newUntil = min(base.addingTimeInterval(delta), cap)
        unlockedUntil = newUntil
        lastRewardedAt = now
        UserDefaults.standard.set(newUntil.timeIntervalSince1970, forKey: Self.kUnlockUntil)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.kLastRewarded)
        consecutiveAdFailures = 0
        ensureTimerRunning()
        tick()
    }

    /// 旧 API — 兼容 mock / 调试. 正式入口应该用 `markRewardedSuccess`.
    func extendUnlock(byMinutes minutes: Int) {
        markRewardedSuccess(unlockMinutes: minutes)
    }

    // MARK: - 章节计数 (对齐 Android `markChapterOpened` / `shouldRequireUnlock`)

    /// 用户进入新章节时调一次, 同一章节多次进入只算一次 (内存去重)
    /// - Parameter uniqueKey: "\(bookUrl)|\(chapterIndex)" 之类
    func markChapterOpened(uniqueKey: String) {
        if !seenChapterKeys.contains(uniqueKey) {
            seenChapterKeys.insert(uniqueKey)
            chaptersOpenedThisSession += 1
        }
    }

    /// 是否需要触发"付费墙" (拦截阅读, 强制看广告)
    /// - Parameter freeChapters: 头 N 章免费 (从后台 chapterUnlock.freeChapters 取)
    func shouldRequireUnlock(freeChapters: Int) -> Bool {
        if isActive { return false }
        return chaptersOpenedThisSession > max(freeChapters, 0)
    }

    // MARK: - 广告失败兜底 (对齐 Android `recordAdFailureAndCheckGrace`)

    /// 广告加载失败 +1. 连续达到阈值 → 触发兜底解锁
    /// - Returns: true = 触发了兜底解锁
    @discardableResult
    func recordAdFailureAndCheckGrace() -> Bool {
        consecutiveAdFailures += 1
        if consecutiveAdFailures >= Self.adFailureGraceThreshold {
            let now = Date()
            let until = now.addingTimeInterval(TimeInterval(Self.adFailureGraceMinutes * 60))
            unlockedUntil = until
            UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.kUnlockUntil)
            consecutiveAdFailures = 0
            ensureTimerRunning()
            tick()
            return true
        }
        return false
    }

    /// 广告成功后重置失败计数
    func resetAdFailures() {
        consecutiveAdFailures = 0
    }

    // MARK: - 冷却查询 (跟 Android 对齐)

    /// 现在能否看广告续期 (受冷却限制). 锁屏路径不受此限制, 只对主动入口生效.
    func canShowRewardedAdNow(cooldownSec: Int = defaultCooldownSec) -> Bool {
        guard let last = lastRewardedAt else { return true }
        return Date().timeIntervalSince(last) >= TimeInterval(cooldownSec)
    }

    /// 距下次允许看广告还剩多少秒 (0=已可看). 给 UI 倒计时用.
    func secondsUntilNextRewardedAllowed(cooldownSec: Int = defaultCooldownSec) -> Int {
        guard let last = lastRewardedAt else { return 0 }
        let next = last.addingTimeInterval(TimeInterval(cooldownSec))
        return max(0, Int(next.timeIntervalSinceNow))
    }

    // MARK: - 注销 / 重置

    /// 万象书屋: 注销账号时清空 (M2.10.8) — 跟 Android `AdRateLimiter.reset()` 对齐
    func wipe() {
        unlockedUntil = nil
        remainingSeconds = 0
        cooldownSecondsRemaining = 0
        lastRewardedAt = nil
        chaptersOpenedThisSession = 0
        seenChapterKeys.removeAll()
        consecutiveAdFailures = 0
        UserDefaults.standard.removeObject(forKey: Self.kUnlockUntil)
        UserDefaults.standard.removeObject(forKey: Self.kLastRewarded)
    }

    // MARK: - 衍生属性

    var isActive: Bool { remainingSeconds > 0 }

    /// "MM:SS" 格式 (旧 UI 使用)
    var formattedRemaining: String {
        let s = max(remainingSeconds, 0)
        let m = s / 60
        let sec = s % 60
        return String(format: "%02d:%02d", m, sec)
    }

    /// "HH:MM:SS" 或 "MM:SS" 格式 — 对齐 Android `MyFragment.formatHms`.
    /// 解锁时长 ≥ 1 小时显示三段, < 1 小时显示两段.
    var formattedRemainingHms: String {
        let total = max(remainingSeconds, 0)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// 冷却 "MM:SS" — 对齐 Android `MyFragment.formatMs`
    var formattedCooldown: String {
        let s = max(cooldownSecondsRemaining, 0)
        let m = s / 60
        let sec = s % 60
        return String(format: "%02d:%02d", m, sec)
    }

    // MARK: - Timer (1s 一次, 跟 Android `startUnlockCardUpdater` 对齐)

    private func ensureTimerRunning() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimerIfIdle() {
        if unlockedUntil == nil && lastRewardedAt == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        if let until = unlockedUntil {
            let remain = Int(until.timeIntervalSince(Date()))
            if remain <= 0 {
                remainingSeconds = 0
                unlockedUntil = nil
                UserDefaults.standard.removeObject(forKey: Self.kUnlockUntil)
            } else {
                remainingSeconds = remain
            }
        } else {
            remainingSeconds = 0
        }
        cooldownSecondsRemaining = secondsUntilNextRewardedAllowed()
        stopTimerIfIdle()
    }
}
