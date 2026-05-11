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

    /// UserDefaults key: 历史版本曾把书源写进 SQLite `book_sources`, 只需清一次.
    private static let legacySqliteSourcesClearedKey = "wx.legacy_book_sources_table_cleared_v4"

    /// 应用启动时调一次 (idempotent). 直接拉远端到内存, 不再持久化到 SQLite.
    ///
    /// 万象书屋: 设计上**只在内存**保留 sources, 杀进程后下次冷启动重新拉远端.
    /// 用户离线时, 已下载的章节正文仍可读 (ChapterRepository); 未下载的章节因为没源
    /// 解析规则就拉不到 → 鼓励用户主动"下载本书" (BookDownloader) 离线读.
    /// 同时这步顺手把历史遗留的 SQLite book_sources 表清掉, 让升级用户也回到 in-memory only.
    public func bootstrap() async {
        // 万象书屋 (perf): **不要**每次冷启都 `DELETE FROM book_sources` — 源多时 SQLite 事务
        // + VACUUM 压力白白浪费几十～几百 ms. 迁移清库只做一次即可.
        if !UserDefaults.standard.bool(forKey: Self.legacySqliteSourcesClearedKey) {
            try? await DB.shared.replaceAllBookSources([])
            UserDefaults.standard.set(true, forKey: Self.legacySqliteSourcesClearedKey)
        }

        // 拉远端 → 内存
        await refresh()

        // 远端拉失败 + 内存仍空时, 退到 bundle fallback (App 包内置 JSON, 不算用户态 cache).
        // 不入 SQLite, 仅放内存 — 重启再拉远端.
        if self.sources.isEmpty {
            await loadBundleFallbackInMemory()
        }
    }

    /// 万象书屋: bundle 兜底, 只放内存, **不**入 SQLite (跟"本地不保存源"的设计对齐).
    private func loadBundleFallbackInMemory() async {
        guard let url = Bundle.main.url(forResource: "bookSources",
                                        withExtension: "json",
                                        subdirectory: "defaultData"),
              let data = try? Data(contentsOf: url) else {
            print("[BookSourceRegistry] bundle fallback missing")
            return
        }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return }
        let parsed = await Self.parseSourcesOffMainActor(arr)
        guard !parsed.isEmpty else { return }
        self.sources = parsed
        self.isLoaded = true
        print("[BookSourceRegistry] in-memory bundle fallback: \(parsed.count) sources (offline mode)")
    }

    /// 上次 200 命中时拿到的 ETag, 给下次 If-None-Match 用.
    /// 内存 only — 跟 sources 一起重启就重置, 跟"本地不保存源"政策对齐.
    private var lastSourcesEtag: String? = nil
    /// 防止收到重复 etag 通知后并发触发多次 refresh
    private var refreshInflight: Task<Void, Never>? = nil

    /// 万象书屋 (方案 G' 客户端): 任何 API 响应 header 里的 `X-Sources-Etag` 都会被
    /// `WanxiangAPI.httpData` sniff 后调到这里. 只有 etag 真变了才发起 refresh, 一致就完全不动.
    /// 不阻塞调用方; 业务请求拿到 data, 这里在后台静默把 sources 同步到最新.
    public func noteServerSourcesEtag(_ remoteEtag: String) {
        guard !remoteEtag.isEmpty else { return }
        // 冷启时 bootstrap 会自己 refresh, 这里不抢跑 (避免和 bootstrap.refresh 并发拉同一份 sources)
        if !isLoaded { return }
        // 已经是最新, 不动
        if lastSourcesEtag == remoteEtag { return }
        // 已经在跑一次 refresh, 不重复
        if refreshInflight != nil, refreshInflight?.isCancelled == false { return }
        print("[BookSourceRegistry] etag drift detected (local=\(lastSourcesEtag ?? "nil") server=\(remoteEtag)), refreshing")
        refreshInflight = Task { [weak self] in
            await self?.refresh()
            await MainActor.run { self?.refreshInflight = nil }
        }
    }

    /// 万象书屋 (方案 G'): 切前台时如果不知道当前服务端 etag, 主动发一次 304 探测.
    /// 通常用户切回前台一两秒内一定会有 ping/event/feed 之类的请求把 etag 顺路捎回来,
    /// 这里只是个兜底, 防"用户切回前台后 30 秒内任何接口都没动"的极端情况.
    public func refreshOnBecameActive() {
        Task { [weak self] in await self?.refresh() }
    }

    public func refresh() async {
        do {
            // 万象书屋: 带上次的 etag, server 304 时直接走"内存继续用"分支, 1KB 流量 0 RTT.
            var result = try await WanxiangAPI.shared.fetchSources(ifNoneMatch: lastSourcesEtag)

            // ── 守护 1: 304 命中 → server 说"你的还是最新", 不动内存
            //   `fetchSources` 在 304 时返回 `([], etag)`, 不能误把空数组当真实结果替进 self.sources.
            if !sources.isEmpty, result.sources.isEmpty, lastSourcesEtag != nil {
                if let e = result.etag { self.lastSourcesEtag = e }
                print("[BookSourceRegistry] etag 304 hit, keep \(sources.count) in-memory sources")
                return
            }

            // 万象书屋 (perf P0): 极端冷启动场景 — URLSession disk cache 兜了一个旧 If-None-Match
            //   去 server, server 返 304 (空 body), 但 lastSourcesEtag 是 nil (进程刚启动) →
            //   sources 仍是空. 之前会走到 bundle fallback 拿 32 条, 而不是后端 1889 条.
            //   修法: 再发一次显式不带 etag 的请求, 强制拿 200 body.
            //   (现在 WanxiangAPI.session.urlCache=nil 后 URLSession 不该自动加 If-None-Match
            //   了, 这层属于二保险.)
            if result.sources.isEmpty, sources.isEmpty, lastSourcesEtag == nil {
                print("[BookSourceRegistry] cold start 304 with empty cache, refetch w/o etag")
                result = try await WanxiangAPI.shared.fetchSources(ifNoneMatch: nil)
            }

            let remote = await Self.parseSourcesOffMainActor(result.sources)

            // ── 守护 2: 远端 200 但 0 条 → 多半是后端短暂故障 (DB 故障 / 中间件 panic 返空).
            //   不能拿这个误清掉用户的内存 cache, 否则用户突然没源可搜.
            //   只有当远端**给了非空**时才替换.
            if remote.isEmpty && !sources.isEmpty {
                print("[BookSourceRegistry] remote returned 0 sources, keep \(sources.count) in-memory (likely transient backend issue)")
                return
            }

            // 正常路径: 远端给了内容 (或者是冷启第一次 sources 本来就空, 此时空也合理)
            self.sources = remote
            self.isLoaded = true
            self.lastSourcesEtag = result.etag
            print("[BookSourceRegistry] in-memory loaded \(remote.count) sources from backend (etag=\(result.etag ?? "n/a"))")
        } catch {
            // 网络/超时/401/任何 throw → 不动内存, 让用户继续用现有源
            print("[BookSourceRegistry] refresh failed (keeping \(sources.count) in-memory): \(error)")
        }
    }

    /// 从 legado 导出的 JSON 文件合并导入 (数组或 `{sources:[]}`). 返回成功条数.
    /// 万象书屋: in-memory only, **不**写 SQLite. 重启 App 这些源就没了 — 跟"本地不保存源"政策一致.
    /// 用户重启后想接着用就再次导入. (这个 trade-off 是用户主动接受的: 换来"远端权威, 升级/撤源立刻生效")
    public func importFromLocalJson(data: Data) async throws -> Int {
        let obj = try JSONSerialization.jsonObject(with: data)
        let rawArr: [Any]
        if let arr = obj as? [Any] { rawArr = arr }
        else if let dict = obj as? [String: Any], let arr = dict["sources"] as? [Any] { rawArr = arr }
        else {
            throw NSError(domain: "BookSource", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "JSON 须为书源数组或 {\"sources\":[...]}"])
        }
        let parsed = await Self.parseSourcesOffMainActor(rawArr)
        guard !parsed.isEmpty else {
            throw NSError(domain: "BookSource", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "没有解析出任何书源"])
        }
        // 内存合并: 用 url 去重, 新导入的覆盖同 url 旧条
        var byUrl: [String: BookSource] = [:]
        for s in self.sources { byUrl[normalize(s.bookSourceUrl)] = s }
        for s in parsed { byUrl[normalize(s.bookSourceUrl)] = s }
        self.sources = Array(byUrl.values)
        self.isLoaded = true
        print("[BookSourceRegistry] in-memory imported \(parsed.count) sources from local JSON (not persisted)")
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

    /// 等到远端/bootstrap 写入启用源或超时. 搜索首帧用: 比固定 100ms 轮询更快接上 `isLoaded`.
    public func waitUntilEnabledSourcesNonEmpty(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isLoaded, !enabledSources.isEmpty { return }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    // MARK: - 解析

    /// 冷启拉源常见 1000～3000 条: 在 MainActor 上轮询 `JSONDecoder` 会卡住首屏交互.
    /// 先打成 JSON Data (Sendable), 再在后台线程解码, 最后回到 MainActor 赋值.
    private static func parseSourcesOffMainActor(_ raw: [Any]) async -> [BookSource] {
        guard !raw.isEmpty else { return [] }
        guard JSONSerialization.isValidJSONObject(raw),
              let blob = try? JSONSerialization.data(withJSONObject: raw) else {
            return parseSourcesFromRawIsolated(raw)
        }
        return await Task.detached(priority: .userInitiated) {
            guard let arr = try? JSONSerialization.jsonObject(with: blob) as? [Any] else {
                return []
            }
            return Self.parseSourcesFromRawIsolated(arr)
        }.value
    }

    /// `nonisolated` — 可在任意 executor 上跑 (仅供 `parseSourcesOffMainActor` / detached 调用).
    nonisolated private static func parseSourcesFromRawIsolated(_ raw: [Any]) -> [BookSource] {
        var out: [BookSource] = []
        out.reserveCapacity(raw.count)
        for item in raw {
            var dict: [String: Any]? = nil
            if let d = item as? [String: Any] {
                dict = d
            } else if let s = item as? String,
                      let data = s.data(using: .utf8),
                      let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                dict = d
            }
            guard let d = dict else { continue }
            do {
                let data = try JSONSerialization.data(withJSONObject: d)
                let bs = try JSONDecoder().decode(BookSource.self, from: data)
                out.append(bs)
            } catch {
                print("[BookSourceRegistry] skip 1 invalid source: \(error.localizedDescription)")
            }
        }
        return out
    }
}
