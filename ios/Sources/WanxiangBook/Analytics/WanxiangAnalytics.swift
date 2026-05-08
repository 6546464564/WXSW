//
//  WanxiangAnalytics.swift
//  万象书屋 iOS · 自建埋点 SDK (替代友盟/神策)
//
//  对应 Android: io.legado.app.help.WanxiangAnalytics
//
//  能力 1:1 对齐 Android:
//   - 内存队列 (actor 串行化, 多线程 track() 不阻塞调用方)
//   - 触发 flush 条件:
//       a) 队列 >= 20 条
//       b) 距上次 flush >= 30 秒 (定时器)
//       c) 切后台 / 进程退出时强制 flush
//   - 单次最多 100 条 / 请求 (后端限制)
//   - 失败 batch 进 retryQueue (单独, 不污染主队列顺序)
//   - 指数退避: 1s / 2s / 4s ... 60s 上限
//   - 队列上限 500 条溢出丢最早的
//   - PIPL 一致性: AdManager.consented = false 时 track() 静默丢弃
//
//  用法:
//   WanxiangAnalytics.shared.track("btn_search", type: "click")
//   WanxiangAnalytics.shared.track("page_main", type: "pv",
//                                   params: ["from": "splash"])
//   await WanxiangAnalytics.shared.flush()  // 切后台时调
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif
import os

/// 跟 Android `WanxiangAnalytics.kt` 1:1 对齐的 actor 实现
public actor WanxiangAnalytics {

    public static let shared = WanxiangAnalytics()

    // MARK: - Constants (跟 Android 同款)

    private static let maxQueue = 500
    private static let flushThreshold = 20
    private static let flushIntervalSec: TimeInterval = 30
    private static let maxPerRequest = 100
    private static let maxRetryQueue = 200
    private static let maxBackoffMs: UInt64 = 60_000
    private static let path = "/api/events"

    // MARK: - State

    private var queue: [Event] = []
    private var retryQueue: [Event] = []
    private var flushing: Bool = false
    private var consecutiveFails: Int = 0
    private var lastFlushAt: Date = .distantPast
    private var periodicTask: Task<Void, Never>?
    private var started: Bool = false

    /// 客户端会话 ID. 进程存活期内固定; 进程重启换新.
    private let sessionId: String = {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let rand = Int.random(in: 0...9999)
        return "s\(ts)-\(rand)"
    }()

    private let log = Logger(subsystem: "com.wanxiang.reader", category: "Analytics")

    private init() {}

    // MARK: - Public API

    /// 启动周期性 flush. 应在 `WanxiangBookApp.init` / `RootView.task` 调一次.
    public func start() {
        guard !started else { return }
        started = true
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.flushIntervalSec) * 1_000_000_000)
                await self?.flushIfNeeded()
            }
        }
        log.debug("init done, sessionId=\(self.sessionId)")
    }

    /// 上报一个事件 (高频调用, 入队不阻塞业务)
    public nonisolated func track(_ name: String, type: String = "custom", params: [String: Any]? = nil) {
        guard !name.isEmpty else { return }
        Task { await self._track(name: name, type: type, params: params) }
    }

    private func _track(name: String, type: String, params: [String: Any]?) async {
        // PIPL: 用户撤回同意 → 不再采集
        let consented = await MainActor.run { AdManager.shared.consented }
        guard consented else { return }

        if queue.count >= Self.maxQueue {
            queue.removeFirst()   // 溢出丢最早的, 让出空间
        }
        let event = Event(
            ts: Int(Date().timeIntervalSince1970 * 1000),
            type: type,
            name: name,
            params: params,
            sessionId: sessionId
        )
        queue.append(event)
        if queue.count >= Self.flushThreshold {
            await flush()
        }
    }

    /// 强制立即上报. 切后台 / 退出时调.
    public func flush() async {
        guard !queue.isEmpty || !retryQueue.isEmpty else { return }
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }

        // 优先发 retry batch
        var batch: [Event] = []
        batch.reserveCapacity(Self.maxPerRequest)
        while batch.count < Self.maxPerRequest, !retryQueue.isEmpty {
            batch.append(retryQueue.removeFirst())
        }
        // retry 装不满时再从主队列取
        while batch.count < Self.maxPerRequest, !queue.isEmpty {
            batch.append(queue.removeFirst())
        }
        if batch.isEmpty { return }

        let ok = await sendBatch(batch)
        if ok {
            consecutiveFails = 0
            lastFlushAt = Date()
            log.debug("flush ok, sent \(batch.count), remaining \(self.queue.count)+retry=\(self.retryQueue.count)")
            // 主队列还有 ≥ 阈值, 继续 flush (大批量场景)
            if queue.count >= Self.flushThreshold {
                Task { await self.flush() }
            }
        } else {
            consecutiveFails += 1
            // 失败 batch 进 retryQueue (有限容量, 满了丢最早)
            for e in batch {
                if retryQueue.count >= Self.maxRetryQueue {
                    retryQueue.removeFirst()
                }
                retryQueue.append(e)
            }
            // 1s, 2s, 4s ... 64s, cap 60s
            let shift = min(consecutiveFails - 1, 6)
            let backoffMs = min(UInt64(1000) << shift, Self.maxBackoffMs)
            log.debug("flush fail #\(self.consecutiveFails), retry size=\(self.retryQueue.count), backoff=\(backoffMs)ms")
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
                await self?.flush()
            }
        }
    }

    // MARK: - Private

    private func flushIfNeeded() async {
        guard !queue.isEmpty || !retryQueue.isEmpty else { return }
        await flush()
    }

    /// 发送 batch 到 `/api/events`. 复用 `WanxiangAPI.shared.request` 自动带 X-Platform: ios + token
    private func sendBatch(_ batch: [Event]) async -> Bool {
        let payload = buildPayload(batch)
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var req = WanxiangAPI.shared.request(path: Self.path, method: "POST")
        req.httpBody = data
        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return false
            }
            // 后端约定 {"ok":true}
            let body = String(data: respData, encoding: .utf8) ?? ""
            return body.contains("\"ok\":true")
        } catch {
            log.debug("sendBatch error: \(error.localizedDescription)")
            return false
        }
    }

    private func buildPayload(_ batch: [Event]) -> [String: Any] {
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        var events: [[String: Any]] = []
        events.reserveCapacity(batch.count)
        for e in batch {
            var dict: [String: Any] = [
                "ts": e.ts,
                "type": e.type,
                "name": e.name,
            ]
            if let p = e.params, !p.isEmpty {
                dict["params"] = sanitizeParams(p)
            }
            events.append(dict)
        }
        return [
            "sessionId": sessionId,
            "appVer": appVer,
            "events": events,
        ]
    }

    /// 仅允许 String / Number / Bool / null 进 params; 其它转 String, 防止 JSONSerialization 抛
    private func sanitizeParams(_ p: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in p {
            switch v {
            case let s as String: out[k] = s
            case let n as NSNumber: out[k] = n
            case let b as Bool: out[k] = b
            case is NSNull: out[k] = NSNull()
            default: out[k] = String(describing: v)
            }
        }
        return out
    }

    /// 给单测 / 注销账号用: 清队列 (跟 Android `AdRateLimiter.reset` 风格)
    public func wipe() {
        queue.removeAll()
        retryQueue.removeAll()
        consecutiveFails = 0
    }

    // MARK: - Event struct

    private struct Event {
        let ts: Int
        let type: String
        let name: String
        let params: [String: Any]?
        let sessionId: String
    }
}
