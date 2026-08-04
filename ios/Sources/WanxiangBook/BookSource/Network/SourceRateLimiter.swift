//
//  SourceRateLimiter.swift
//  万象书屋 iOS · 书源并发限速
//
//  对应 Android: io.legado.app.help.ConcurrentRateLimiter
//
//  legado `concurrentRate` 字段语义 (yckceo 文档):
//   - "0" 或空 → 不限速
//   - "200" → 单值, 每次请求至少间隔 200ms (Token Bucket cap=1, refill=200ms)
//   - "5/1000" → 1000ms 滑动窗口内最多 5 次
//
//  为什么必须有限速:
//   - 多书源并发搜索 (16+ 源) 一次性打同一关键词, 每源 N 次同时请求
//   - 没限速 → 同一站点 1s 内 30+ 请求 → 立即被 Cloudflare/WAF 封 IP
//   - 用户体感: "iOS 搜书很多源结果是 0 / 报错", 实际是被 ban 了
//   - Android 默认每源 200ms 一次 (源 JSON 不写 concurrentRate 时), 所以从来不会出此问题
//
//  实现:
//   - actor 全局 SourceRateLimiter (每源一个 record)
//   - acquire() 阻塞当前协程直到可放行 (Task.sleep)
//   - 滑动窗口模式用环形 timestamp 数组判定
//

import Foundation

public actor SourceRateLimiter {

    public static let shared = SourceRateLimiter()

    /// 源级速率记录
    private struct Record {
        /// 单值模式: 上次放行时间戳 (ms since epoch)
        var lastFireMs: Int64 = 0
        /// 窗口模式: 最近 N 次放行时间 (ms since epoch), 长度 = capacity
        var ring: [Int64] = []
    }

    private var records: [String: Record] = [:]

    public init() {}

    /// 万象书屋: 阻塞协程直到可放行该源.
    /// 同源请求会按 concurrentRate 串行化 (跟 Android 行为对齐).
    /// 源未配置或解析失败时直接放行.
    public func acquire(source: BookSource) async {
        guard let rate = parseRate(source.concurrentRate) else { return }
        let key = source.bookSourceUrl
        switch rate {
        case .interval(let ms):
            await acquireInterval(key: key, intervalMs: ms)
        case .window(let count, let periodMs):
            await acquireWindow(key: key, capacity: count, periodMs: periodMs)
        }
    }

    // MARK: - 单值: 最小间隔

    private func acquireInterval(key: String, intervalMs: Int) async {
        // 万象书屋 (bug fix): actor 在 Task.sleep 期间挂起, 多个并发任务可能同时等待同一 key.
        // 唤醒后必须重新读取 records[key] 并循环校验 — 否则多个任务会在同一时刻通过限速器,
        // 实际打出 N×1 并发请求, 触发反爬封 IP.
        while true {
            if Task.isCancelled { return }
            let now = nowMs()
            var rec = records[key] ?? Record()
            let earliest = rec.lastFireMs + Int64(intervalMs)
            guard earliest > now else {
                // 时间窗已过, 可以放行
                rec.lastFireMs = now
                records[key] = rec
                return
            }
            // 需要等待: 先写回当前 snapshot 再 sleep (让其他 key 的并发任务不被我的 sleep 阻塞)
            records[key] = rec
            do {
                try await Task.sleep(nanoseconds: UInt64(earliest - now) * 1_000_000)
            } catch {
                // 任务被取消: 直接退出, 不再空转
                return
            }
            // 唤醒后循环重新检查 (期间可能有其他任务已更新 lastFireMs)
        }
    }

    // MARK: - X/Y 窗口: capacity 次每 periodMs

    private func acquireWindow(key: String, capacity: Int, periodMs: Int) async {
        guard capacity > 0 else { return }
        // 万象书屋 (bug fix): 同 acquireInterval — 唤醒后必须循环重新检查窗口状态
        while true {
            if Task.isCancelled { return }
            var rec = records[key] ?? Record()
            if rec.ring.capacity < capacity { rec.ring.reserveCapacity(capacity) }
            let now = nowMs()
            let cutoff = now - Int64(periodMs)
            rec.ring.removeAll(where: { $0 < cutoff })

            if rec.ring.count < capacity {
                // 窗口未满, 放行
                rec.ring.append(nowMs())
                records[key] = rec
                return
            }
            // 窗口已满: 等到最早一个 timestamp 出窗口后再循环重新检查
            let oldest = rec.ring.first ?? now
            let waitMs = max(1, oldest + Int64(periodMs) - now)
            records[key] = rec
            do {
                try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
            } catch {
                return
            }
        }
    }

    // MARK: - 解析 concurrentRate 字符串

    private enum Rate {
        case interval(ms: Int)
        case window(count: Int, periodMs: Int)
    }

    private nonisolated func parseRate(_ s: String?) -> Rate? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "0" else {
            return nil
        }
        if s.contains("/") {
            // X/Y 滑动窗口
            let parts = s.split(separator: "/")
            guard parts.count == 2,
                  let count = Int(parts[0]), count > 0,
                  let period = Int(parts[1]), period > 0 else { return nil }
            return .window(count: count, periodMs: period)
        }
        // 单值: 间隔 ms
        guard let ms = Int(s), ms > 0 else { return nil }
        return .interval(ms: ms)
    }

    private nonisolated func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
