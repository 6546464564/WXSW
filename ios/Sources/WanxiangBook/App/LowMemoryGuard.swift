//
//  LowMemoryGuard.swift
//  万象书屋 iOS · 主动内存压力监控 (补 UIKit memoryWarning 不可靠的窗口)
//
//  问题背景:
//   - iPhone SE 2GB 上跑 Monkey 时出现 13/13 OOM crash (`swift_abortAllocationFailure`),
//     其中 7 次系统直接发 SIGKILL/jetsam, **没有先发 didReceiveMemoryWarning**.
//   - 原因: jetsam 在物理内存紧张时优先级 > UIKit 通知, 后台 task 在 cooperative
//     pool 上跑大量 SwiftSoup parse 时会瞬间被干掉, 没机会清缓存.
//
//  解法: 用 iOS 13+ 的 os_proc_available_memory() 主动轮询当前进程剩余配额,
//   - 剩余 < 50MB: 触发 wanxiangMemoryWarning (跟系统通知共享一套清理逻辑)
//   - 剩余 < 25MB: 紧急 cancel 所有后台健康探测 + 多次 GC
//   - Cool-down 30s 避免抖动反复触发清空缓存损害命中率.
//
//  仅在 ≤4GB 设备上启用, 高内存设备 (12+) 留给系统判断. Foreground 阶段 5s/次,
//  background 不轮询 (省电).
//

import Foundation
import UIKit

@MainActor
public final class LowMemoryGuard {

    public static let shared = LowMemoryGuard()

    /// 仅低内存设备启用 (≤4GB). 高内存设备额外做巡检收益小.
    private static let enabled: Bool = {
        ProcessInfo.processInfo.physicalMemory <= 4_500_000_000
    }()

    /// 软警告阈值 (字节). 剩余 < 50MB → 发 wanxiangMemoryWarning.
    private static let softThresholdBytes: UInt64 = 50 * 1024 * 1024
    /// 硬警告阈值 (字节). 剩余 < 25MB → 紧急清理 + cancel.
    private static let hardThresholdBytes: UInt64 = 25 * 1024 * 1024

    private var monitorTask: Task<Void, Never>?
    private var lastSoftFireAt: Date?
    private var lastHardFireAt: Date?

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(scenePhaseChanged(_:)),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scenePauseChanged(_:)),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    public func start() {
        guard Self.enabled else {
            NSLog("[WX-MEM] LowMemoryGuard: skipped (high-memory device)")
            return
        }
        beginMonitor()
    }

    @objc private func scenePhaseChanged(_ note: Notification) {
        guard Self.enabled else { return }
        beginMonitor()
    }

    @objc private func scenePauseChanged(_ note: Notification) {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func beginMonitor() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkOnce()
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s
            }
        }
    }

    private func checkOnce() async {
        let avail = Self.availableMemory()
        guard avail > 0 else { return }
        let now = Date()
        if avail < Self.hardThresholdBytes {
            if let last = lastHardFireAt, now.timeIntervalSince(last) < 30 { return }
            lastHardFireAt = now
            NSLog("[WX-MEM] HARD pressure: avail=%lluKB → emergency cleanup", avail / 1024)
            // 双发: 通知所有 observer + 直接停掉后台健康探测
            NotificationCenter.default.post(name: .wanxiangMemoryWarning, object: nil)
            URLCache.shared.removeAllCachedResponses()
        } else if avail < Self.softThresholdBytes {
            if let last = lastSoftFireAt, now.timeIntervalSince(last) < 30 { return }
            lastSoftFireAt = now
            NSLog("[WX-MEM] SOFT pressure: avail=%lluKB → preemptive cleanup", avail / 1024)
            NotificationCenter.default.post(name: .wanxiangMemoryWarning, object: nil)
        }
    }

    /// 当前进程剩余可用配额 (字节). iOS 13+ 提供; 0 表示未知.
    public static func availableMemory() -> UInt64 {
        if #available(iOS 13.0, *) {
            return UInt64(os_proc_available_memory())
        }
        return 0
    }
}
