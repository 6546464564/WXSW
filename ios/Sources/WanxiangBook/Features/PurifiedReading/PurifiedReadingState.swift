//
//  PurifiedReadingState.swift
//  万象书屋 iOS · 纯净阅读解锁状态 (M2.1.5 / M2.5.8 整套)
//
//  对应 Android: io.legado.app.ad.AdRateLimiter
//
//  M2.1 阶段只是骨架, 实际解锁/广告/计时逻辑在 M2.5.8 (阅读器付费墙) 接入.
//  M2.1 阶段先暴露:
//   - unlockedUntil: Date?    解锁有效期截止
//   - remainingSeconds: 给我的页卡片显示倒计时
//

import Foundation
import Combine

@MainActor
final class PurifiedReadingState: ObservableObject {

    static let shared = PurifiedReadingState()

    @Published private(set) var unlockedUntil: Date? = nil
    @Published private(set) var remainingSeconds: Int = 0

    private var timer: Timer? = nil
    private static let kUnlockUntil = "wanxiang.purified.unlock_until"

    private init() {
        // 万象书屋: 启动时从 UserDefaults 恢复
        let ts = UserDefaults.standard.double(forKey: Self.kUnlockUntil)
        if ts > 0 {
            let d = Date(timeIntervalSince1970: ts)
            if d > Date() { self.unlockedUntil = d }
        }
        startTimer()
    }

    /// M2.5.8 由 RewardedAd 回调调; M2.1 暴露给我的页卡片做 mock
    func extendUnlock(byMinutes minutes: Int) {
        let now = Date()
        let base = (unlockedUntil ?? now) > now ? unlockedUntil! : now
        let next = base.addingTimeInterval(TimeInterval(minutes * 60))
        unlockedUntil = next
        UserDefaults.standard.set(next.timeIntervalSince1970, forKey: Self.kUnlockUntil)
        tick()
    }

    /// 万象书屋: 注销账号时清空 (M2.10.8)
    func wipe() {
        unlockedUntil = nil
        remainingSeconds = 0
        UserDefaults.standard.removeObject(forKey: Self.kUnlockUntil)
    }

    var isActive: Bool { remainingSeconds > 0 }

    /// "12:34" 格式
    var formattedRemaining: String {
        let s = max(remainingSeconds, 0)
        let m = s / 60
        let sec = s % 60
        return String(format: "%02d:%02d", m, sec)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    private func tick() {
        guard let until = unlockedUntil else {
            remainingSeconds = 0
            return
        }
        let remain = Int(until.timeIntervalSince(Date()))
        if remain <= 0 {
            remainingSeconds = 0
            unlockedUntil = nil
            UserDefaults.standard.removeObject(forKey: Self.kUnlockUntil)
        } else {
            remainingSeconds = remain
        }
    }
}
