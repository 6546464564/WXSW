//
//  ChangeSourceCandidateCache.swift
//  万象书屋 iOS · 换源候选磁盘缓存 (2026-05-11)
//
//  对应 Android: `appDb.searchBookDao.changeSourceByGroup(name, author, group)`
//
//  问题: iOS 之前换源每次打开都从 0 搜 1800+ 源, 用户先看到空列表再等候选缓慢冒出.
//  Android 因为每个 searchSuccess 都写 SQLite, 下次打开换源对话框先从 DB 加载,
//  毫秒级填充候选, 然后再后台跑 startSearch 刷新.
//
//  方案: 用文件 plist 持久化每个 (name+author) 的候选列表 (只存数据字段, 不存
//  parser state). TTL 7 天. 重新打开换源时同步加载, 然后启动后台搜索 merge 新结果.
//
//  跟 SourceScoreStore / SourcePerformanceTracker 同款单例 + 文件存储模式.
//

import Foundation

/// 万象书屋: 换源候选磁盘缓存 (`Caches/wanxiang-change-source-cache.plist`).
///
/// thread-safe via NSLock; 写盘批量异步, 读盘走内存索引 0 IO.
public final class ChangeSourceCandidateCache: @unchecked Sendable {

    public static let shared = ChangeSourceCandidateCache()

    /// 单条候选 — 只保留 SearchBook 字段 + 响应时间; parser state 不持久化.
    public struct CachedCandidate: Codable, Sendable {
        public var book: SearchBook
        public var respondTimeMs: Int
    }

    public struct Entry: Codable, Sendable {
        public var candidates: [CachedCandidate]
        /// 写盘时间戳 (秒)
        public var ts: Int
    }

    private let lock = NSLock()
    private var memCache: [String: Entry] = [:]
    private let storeURL: URL
    private let ttlSec: TimeInterval = 7 * 86400   // 7 天

    /// 写盘节流: 多次 save 合并到一个异步任务里, 避免每个候选 insert 都打 disk.
    private var dirty: Bool = false
    private var flushScheduled: Bool = false

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.storeURL = caches.appendingPathComponent("wanxiang-change-source-cache.plist")
        loadFromDisk()
    }

    // MARK: - 公开 API

    /// 取出 (name, author) 对应的候选; TTL 过期或不存在返 nil.
    /// 不区分大小写不归一化 — 直接按 Android 习惯用原始字段, 命中率以多键存储弥补.
    public func get(name: String, author: String) -> [CachedCandidate]? {
        let key = Self.makeKey(name: name, author: author)
        lock.lock(); defer { lock.unlock() }
        guard let entry = memCache[key] else { return nil }
        if TimeInterval(Int(Date().timeIntervalSince1970) - entry.ts) > ttlSec {
            memCache.removeValue(forKey: key)
            scheduleFlush()
            return nil
        }
        return entry.candidates
    }

    /// 写一份候选 (整体覆盖). 调用时机: 换源搜索结束 / 用户主动刷新.
    public func put(name: String, author: String, candidates: [CachedCandidate]) {
        guard !candidates.isEmpty else { return }
        let key = Self.makeKey(name: name, author: author)
        lock.lock()
        memCache[key] = Entry(candidates: candidates, ts: Int(Date().timeIntervalSince1970))
        lock.unlock()
        scheduleFlush()
    }

    /// 增量追加单条 (search 过程中实时增量保存, 跟 Android `searchBookDao.insert` 对齐).
    /// 同 origin+bookUrl 已存在则更新.
    public func upsert(name: String, author: String, candidate: CachedCandidate) {
        let key = Self.makeKey(name: name, author: author)
        lock.lock()
        var entry = memCache[key] ?? Entry(candidates: [], ts: Int(Date().timeIntervalSince1970))
        if let idx = entry.candidates.firstIndex(where: {
            $0.book.origin == candidate.book.origin && $0.book.bookUrl == candidate.book.bookUrl
        }) {
            entry.candidates[idx] = candidate
        } else {
            entry.candidates.append(candidate)
        }
        entry.ts = Int(Date().timeIntervalSince1970)
        memCache[key] = entry
        lock.unlock()
        scheduleFlush()
    }

    /// 测试 / 异常排查用: 清空指定书或全部.
    public func clear(name: String, author: String) {
        let key = Self.makeKey(name: name, author: author)
        lock.lock()
        memCache.removeValue(forKey: key)
        lock.unlock()
        scheduleFlush()
    }

    public func clearAll() {
        lock.lock()
        memCache.removeAll()
        lock.unlock()
        scheduleFlush()
    }

    // MARK: - 私有

    private static func makeKey(name: String, author: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(n)|\(a)"
    }

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoded = try PropertyListDecoder().decode([String: Entry].self, from: data)
            self.memCache = decoded
        } catch {
            #if DEBUG
            print("[ChangeSourceCandidateCache] load failed: \(error)")
            #endif
        }
    }

    /// 节流写盘: 300ms 内多次 dirty 合并成一次落盘.
    private func scheduleFlush() {
        lock.lock()
        dirty = true
        if flushScheduled { lock.unlock(); return }
        flushScheduled = true
        let snapshot = memCache
        lock.unlock()

        // 用 detached, 避免被 caller 取消
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            self.flushToDisk(snapshot: snapshot)
        }
    }

    private func flushToDisk(snapshot: [String: Entry]) {
        // 拿最新快照 (节流期内可能又有新写入)
        lock.lock()
        let latest = memCache
        flushScheduled = false
        dirty = false
        lock.unlock()
        let toSave = latest.isEmpty ? snapshot : latest
        do {
            let data = try PropertyListEncoder().encode(toSave)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[ChangeSourceCandidateCache] flush failed: \(error)")
            #endif
        }
    }
}
