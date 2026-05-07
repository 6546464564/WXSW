//
//  AutoReadController.swift
//  万象书屋 iOS · 自动翻页 / 自动滚动
//
//  对应 Android: io.legado.app.ui.book.read.config.AutoRead
//
//  - 模式 1: 翻页式 — 每隔 N 秒自动翻下一页
//  - 模式 2: 滚动式 — ScrollView 持续匀速滚动 (M2.x 后续接)
//  - 速度档: 5/10/15/20/25/30 秒/页
//  - 暂停 / 恢复 / 取消
//  - App 切到后台自动暂停 (iOS 后台 Timer 也走不了)
//

import SwiftUI
import Combine

@MainActor
public final class AutoReadController: ObservableObject {

    public static let shared = AutoReadController()

    @Published public private(set) var isRunning: Bool = false
    @Published public var secondsPerPage: Double = 15   // 5...60
    /// 倒计时, UI 显示"还有 X 秒翻页"
    @Published public private(set) var countdown: Double = 0

    private var timer: Task<Void, Never>? = nil
    private var onTurnPage: (() -> Void)? = nil

    private init() {}

    /// 开始自动翻页. onTurn 是翻页 callback (触发下一页)
    public func start(onTurn: @escaping () -> Void) {
        self.onTurnPage = onTurn
        guard !isRunning else { return }
        isRunning = true
        countdown = secondsPerPage
        timer = Task { [weak self] in
            await self?.tick()
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
        countdown = 0
    }

    public func toggle(onTurn: @escaping () -> Void) {
        if isRunning {
            stop()
        } else {
            start(onTurn: onTurn)
        }
    }

    public func setSpeed(_ seconds: Double) {
        secondsPerPage = max(3, min(60, seconds))
        if isRunning { countdown = secondsPerPage }
    }

    /// 用户手动翻页/操作时, 重置倒计时
    public func resetCountdown() {
        if isRunning { countdown = secondsPerPage }
    }

    private func tick() async {
        let interval: TimeInterval = 0.1   // 100ms 滴答, 平滑 UI 倒计时
        while !Task.isCancelled, isRunning {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { break }
            countdown -= interval
            if countdown <= 0 {
                onTurnPage?()
                countdown = secondsPerPage
            }
        }
    }
}
