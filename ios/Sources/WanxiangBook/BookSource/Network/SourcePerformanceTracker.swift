//
//  SourcePerformanceTracker.swift
//  万象书屋 iOS · 源历史成功率 / 响应时间记录, 让搜索按好坏排序
//
//  问题: 84 源里很多源是「死站 / 反爬 / 间歇 fail」, 用户每次搜索都要等所有源
//  超时才能看完整结果. 而事实上 60% 结果来自 ~10 个稳定源.
//
//  方案: 记录每源最近 20 次 search 的"成功率 + 平均耗时", 搜索前用这个做排序键
//  让稳定源先返结果, 慢/差的排后面. 用户感知速度 + 信号质量都提升.
//
//  跟 Android Legado `BookSource.respondTime` 思路一致 (Legado 也按响应时间排).
//
//  数据格式: Caches/wanxiang-source-stats.plist
//   {
//     "<sourceUrl>": {
//       "samples": [{ok: true, ms: 1234, ts: 1700000000}, ...]   # 最近 20 个
//     }
//   }
//

import Foundation

public final class SourcePerformanceTracker: @unchecked Sendable {
    public static let shared = SourcePerformanceTracker()

    public struct Sample: Sendable, Codable {
        public let ok: Bool
        public let ms: Int       // 响应耗时 (毫秒)
        public let ts: Int       // 记录时间 (秒)
        /// 最近一次失败标签（对齐 Android "搜索失效" / "js失效" / "校验超时" 等）
        public let failTag: String?

        public init(ok: Bool, ms: Int, ts: Int, failTag: String? = nil) {
            self.ok = ok; self.ms = ms; self.ts = ts; self.failTag = failTag
        }
    }

    public struct Stats: Sendable, Codable {
        public var samples: [Sample] = []

        /// 最近成功率 (0.0 - 1.0). 没数据时返 0.5 (中性, 不优先也不歧视新源).
        public var successRate: Double {
            guard !samples.isEmpty else { return 0.5 }
            let okCount = samples.filter { $0.ok }.count
            return Double(okCount) / Double(samples.count)
        }

        /// 最近成功 search 的平均耗时 (毫秒). 没成功记录返 INT_MAX.
        public var avgSuccessMs: Int {
            let oks = samples.filter { $0.ok }
            guard !oks.isEmpty else { return Int.max }
            return oks.map { $0.ms }.reduce(0, +) / oks.count
        }

        /// 综合排序分: 越大越好. 100% 成功率 + 1s 响应 = ~100 分.
        /// 算法: successRate * 100  -  avgSuccessMs / 100  (1s = -10 分, 5s = -50 分)
        public var score: Double {
            let s = successRate * 100
            let p = avgSuccessMs == Int.max ? 50.0 : Double(avgSuccessMs) / 100.0
            return s - p
        }

        /// 最近一次失败的标签（对齐 Android source group "搜索失效" / "js失效" 等）
        /// 最新失败 sample 的 failTag; 如果最近一次 ok=true 则返 nil (已恢复)
        public var lastFailTag: String? {
            guard let last = samples.last, !last.ok else { return nil }
            return last.failTag
        }
    }

    private let lock = NSLock()
    private var stats: [String: Stats] = [:]
    private let storeURL: URL
    private let maxSamples = 20      // 每源最多保留最近 20 次

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.storeURL = caches.appendingPathComponent("wanxiang-source-stats.plist")
        loadFromDisk()
    }

    // MARK: - 记录

    /// 一次 search 完成后调用. ok=false 时 ms 用 timeout 值.
    /// - parameter failTag: 对齐 Android group 标签，如 "搜索失效" / "js失效" / "校验超时"
    public func record(sourceUrl: String, ok: Bool, durationMs: Int, failTag: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = Int(Date().timeIntervalSince1970)
        var s = stats[sourceUrl] ?? Stats()
        s.samples.append(Sample(ok: ok, ms: durationMs, ts: now, failTag: ok ? nil : failTag))
        if s.samples.count > maxSamples {
            s.samples.removeFirst(s.samples.count - maxSamples)
        }
        stats[sourceUrl] = s
    }

    /// 给 SearchView 用: 把 sources 按 score 降序排.
    /// score 高的 (历史成功率高 + 响应快) 先 search → AsyncStream 先返结果, 用户感知更快.
    public func sortByScore(_ sources: [BookSource]) -> [BookSource] {
        lock.lock()
        let snapshot = stats
        lock.unlock()
        return sources.sorted { a, b in
            let sa = snapshot[a.bookSourceUrl]?.score ?? 50.0  // 新源给中性 50
            let sb = snapshot[b.bookSourceUrl]?.score ?? 50.0
            return sa > sb
        }
    }

    /// 当前每源 stats (给 source 健康度 UI 用).
    public func allStats() -> [String: Stats] {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    public func stats(for sourceUrl: String) -> Stats? {
        lock.lock(); defer { lock.unlock() }
        return stats[sourceUrl]
    }

    // MARK: - 持久化

    public func persistToDisk() {
        lock.lock()
        let snapshot = stats
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: Stats].self, from: data) else {
            return
        }
        self.stats = decoded
    }

    /// 测试 / 用户主动清空
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        stats.removeAll()
        try?  FileManager.default.removeItem(at: storeURL)
    }
}
