//
//  BookSourceRegistry.swift
//  万象书屋 iOS · 书源全局注册中心 (M2.4 / M2.5 桥接)
//
//  对应 Android: io.legado.app.help.source.SourceHelp + BookSourceDao
//
//  职责:
//   - 应用启动时从 /api/sources 拉远端书源 → 入 SQLite book_sources
//   - 内存缓存 [BookSource], 按 origin URL 索引, 各 View 用 `find(origin:)` 拿源
//   - 解决: SearchView/BookDetailView/ReaderView 此前 source: nil 的 P1 bug
//

import Foundation

@MainActor
public final class BookSourceRegistry: ObservableObject {

    public static let shared = BookSourceRegistry()

    @Published public private(set) var sources: [BookSource] = []
    @Published public private(set) var isLoaded = false

    private init() {}

    /// 应用启动时调一次 (idempotent). 先读 SQLite cache, 然后异步刷新.
    public func bootstrap() async {
        // 1. 立即从 SQLite cache 加载 (启动 fast path)
        if let cached = try? await DB.shared.loadAllBookSources() {
            self.sources = cached
            self.isLoaded = true
        }
        // 2. 万象书屋: 首次安装且没拉过远端时, SQLite 是空的; 用 bundle 内置 fallback
        //    避免"全新设备 + 后端不可达"时 App 完全没书源能用.
        //    跟 Android `assets/defaultData/bookSources.json` 同源 (backend/seed/ 维护权威版本).
        if self.sources.isEmpty {
            await loadBundleFallback()
        }
        // 3. 异步从后端拉新, 入库 + 替换内存
        await refresh()
    }

    /// 万象书屋: 从 bundle 读 defaultData/bookSources.json, 入库 + 内存
    private func loadBundleFallback() async {
        guard let url = Bundle.main.url(forResource: "bookSources",
                                        withExtension: "json",
                                        subdirectory: "defaultData"),
              let data = try? Data(contentsOf: url) else {
            print("[BookSourceRegistry] bundle fallback missing")
            return
        }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return }
        let parsed = Self.parseSources(arr)
        guard !parsed.isEmpty else { return }
        try? await DB.shared.replaceAllBookSources(parsed)
        self.sources = parsed
        self.isLoaded = true
        print("[BookSourceRegistry] loaded \(parsed.count) sources from bundle fallback")
    }

    public func refresh() async {
        do {
            let result = try await WanxiangAPI.shared.fetchSources()
            let remote = Self.parseSources(result.sources)
            // 万象书屋: 远端同步时保留「仅本地导入」的书源 (URL 不在远端列表里)
            let remoteKeys = Set(remote.map { normalize($0.bookSourceUrl) })
            let existing = (try? await DB.shared.loadAllBookSources()) ?? []
            let localOnly = existing.filter { !remoteKeys.contains(normalize($0.bookSourceUrl)) }
            let merged = remote + localOnly
            try? await DB.shared.replaceAllBookSources(merged)
            self.sources = merged
            self.isLoaded = true
            print("[BookSourceRegistry] loaded \(remote.count) from backend, +\(localOnly.count) local-only → \(merged.count) total")
        } catch {
            print("[BookSourceRegistry] refresh failed: \(error)")
            // 失败了 cache 里的还能用, 不抛
        }
    }

    /// 从 legado 导出的 JSON 文件合并导入 (数组或 `{sources:[]}`). 返回成功条数.
    public func importFromLocalJson(data: Data) async throws -> Int {
        let obj = try JSONSerialization.jsonObject(with: data)
        let rawArr: [Any]
        if let arr = obj as? [Any] { rawArr = arr }
        else if let dict = obj as? [String: Any], let arr = dict["sources"] as? [Any] { rawArr = arr }
        else {
            throw NSError(domain: "BookSource", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "JSON 须为书源数组或 {\"sources\":[...]}"])
        }
        let parsed = Self.parseSources(rawArr)
        guard !parsed.isEmpty else {
            throw NSError(domain: "BookSource", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "没有解析出任何书源"])
        }
        try await DB.shared.mergeBookSources(parsed)
        self.sources = try await DB.shared.loadAllBookSources()
        self.isLoaded = true
        print("[BookSourceRegistry] merged \(parsed.count) sources from local JSON")
        return parsed.count
    }

    /// 按 origin (即 bookSourceUrl) 找源. ShelfBook.origin 存的就是这个值
    /// 万象书屋 (P1 fix): URL 末尾斜线 / 大小写不影响匹配 (后端可能存"http://x.com" 客户端旧数据可能有"http://x.com/")
    public func find(origin: String) -> BookSource? {
        let target = normalize(origin)
        return sources.first { normalize($0.bookSourceUrl) == target }
    }

    private func normalize(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 启用的源 (UI 展示 / 搜索用)
    public var enabledSources: [BookSource] {
        sources.filter { $0.enabled }
    }

    // MARK: - 解析

    /// 后端 /api/sources 返回的 `sources: [Any]` 解析成 [BookSource]
    private static func parseSources(_ raw: [Any]) -> [BookSource] {
        var out: [BookSource] = []
        for item in raw {
            // item 可能是 [String: Any] 已 parse, 也可能是 String JSON. 兼容两种
            var dict: [String: Any]? = nil
            if let d = item as? [String: Any] {
                dict = d
            } else if let s = item as? String,
                      let data = s.data(using: .utf8),
                      let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                dict = d
            }
            guard let d = dict else { continue }
            // BookSource 是 Decodable, 通过 JSON 二次 encode/decode 走它的逻辑
            do {
                let data = try JSONSerialization.data(withJSONObject: d)
                let bs = try JSONDecoder().decode(BookSource.self, from: data)
                out.append(bs)
            } catch {
                // 个别源解析失败不影响整体
                print("[BookSourceRegistry] skip 1 invalid source: \(error.localizedDescription)")
            }
        }
        return out
    }
}
