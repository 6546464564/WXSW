//
//  BookSourceEngine.swift
//  万象书屋 iOS · 书源引擎统一入口
//
//  对应 Android: io.legado.app.model.webBook.WebBook
//
//  使用:
//    let engine = await BookSourceEngine.shared
//    let books = try await engine.search(in: source, key: "斗破苍穹")
//    let info  = try await engine.fetchInfo(of: books.first!, in: source)
//    let toc   = try await engine.fetchToc(of: info, in: source)
//    let cont  = try await engine.fetchContent(of: toc.first!, in: source)
//

import Foundation

/// 万象书屋: 改为 final class 让多源解析真正并发.
/// 之前 `actor` 让所有调用 (search/fetchInfo/fetchToc/fetchContent) 串行排队,
/// 32 个源搜索要 30-90s. 改后并发跑, 5-15s 跟 Android 持平.
/// 内部 6 个 parser 都是 final class, JSEngine 仍是 actor (JSContext 单线程必须),
/// 多线程对 BookSourceEngine 调用安全; 单源内 JS 仍串行限速.
public final class BookSourceEngine: @unchecked Sendable {

    public static let shared = BookSourceEngine()

    private let jsEngine: JSEngine
    private let dispatcher: SelectorDispatcher
    private let searchParser: SearchParser
    private let infoParser: BookInfoParser
    private let tocParser: TocParser
    private let contentParser: ContentParser
    private let exploreParser: ExploreParser

    /// 万象书屋 (M2.4 perf): JSEngine pool 让 32 源真并发跑.
    /// JSContext 自身单线程 (不能跨 thread 用同一 ctx), 但**多个独立 JSContext 实例**之间可真并发.
    /// 4 个池足够覆盖典型搜索负载, 注入 stdlib 一次性 cost ~200ms (App 启动期, 用户无感).
    /// 大于 4 收益递减: pool size > sourcesNeedingJS 时多余, JS 评估也不是瓶颈大头.
    /// 万象书屋: JS pool 大小. 默认 4 (4 个 JSEngine 实例真并发). CLI 批量探测时可通过
    /// 环境变量 `WX_JS_POOL_SIZE` 调大到 16+, 让 1500 源探测从 80min → 20min.
    private static let JS_POOL_SIZE: Int = {
        if let env = ProcessInfo.processInfo.environment["WX_JS_POOL_SIZE"],
           let n = Int(env), n > 0, n <= 64 {
            return n
        }
        let mem = ProcessInfo.processInfo.physicalMemory
        if mem <= 4_000_000_000 { return 1 }   // ≤3GB (实际 3.22GB)
        if mem <= 5_000_000_000 { return 2 }   // 4GB
        return 2
    }()
    private let searchParserPool: [SearchParser]
    private let poolCounter = ManagedAtomicLite()
    /// 万象书屋 (M2.8 perf): info/toc/content parser 也分 4 个 pool, 让 reader prefetch
    /// 15 章时 JS 真并发. 之前共用单个 jsEngine, 即使 prefetch 启 15 个 task, JS 评估
    /// 全在 1 个 actor 串行排队 — 后台预拉等于无效.
    private let infoParserPool: [BookInfoParser]
    private let tocParserPool: [TocParser]
    private let contentParserPool: [ContentParser]
    private let infoPoolCounter = ManagedAtomicLite()
    private let tocPoolCounter = ManagedAtomicLite()
    private let contentPoolCounter = ManagedAtomicLite()
    /// 所有 JSEngine 实例 (主 + pool extras), 内存警告时统一 evictAll
    private let allJSEngines: [JSEngine]

    /// 低内存设备 (≤4GB) 降低并发, 避免多路 HTML 解析 OOM
    /// 万象书屋 (2026-05-25): SE 2GB 实测 maxConcurrency=2 仍易 OOM (10/13 crash 是 OOM),
    /// 即便单源解析有 workPermit slots=1, 但 HTTP 响应/JSContext 缓冲仍并发占用,
    /// 进一步降到 1 — 牺牲一点搜索体感, 换稳定不闪退.
    public static let defaultSearchConcurrency: Int = {
        let mem = ProcessInfo.processInfo.physicalMemory
        if mem <= 4_000_000_000 { return 1 }    // ≤3GB — 串行避免线程饥饿
        if mem <= 5_000_000_000 { return 3 }    // 4GB
        return 4
    }()

    /// 换源页专用搜索并发 (比全站搜索更保守, 避免多路 HTML/JS 解析 OOM)
    public static let changeSourceSearchConcurrency: Int = {
        let mem = ProcessInfo.processInfo.physicalMemory
        if mem <= 4_000_000_000 { return 1 }    // ≤3GB
        if mem <= 5_000_000_000 { return 2 }    // 4GB
        return 2
    }()

    /// 换源 info-fill 并发 (fetchInfo 比 search 更吃内存)
    public static let adaptiveFetchInfoConcurrency: Int = {
        let mem = ProcessInfo.processInfo.physicalMemory
        if mem <= 4_000_000_000 { return 1 }    // ≤3GB
        if mem <= 5_000_000_000 { return 4 }    // 4GB
        return 8
    }()

    /// 搜索时最多使用的源数量（按设备内存动态调整，防止低内存设备 OOM）
    public static let maxSearchSourceCount: Int = {
        let mem = ProcessInfo.processInfo.physicalMemory
        if mem <= 4_000_000_000 { return 5 }    // ≤3GB (SE)
        if mem <= 5_000_000_000 { return 10 }   // 4GB (iPhone 11, XR)
        if mem <= 7_000_000_000 { return 15 }   // 6GB (iPhone 12 Pro, 13 Pro)
        return 20                                // 8GB+ (iPhone 14 Pro+)
    }()

    /// 详情页 TOC fallback 等窄场景搜索并发
    public static let adaptiveResolveSearchConcurrency: Int = {
        let mem = ProcessInfo.processInfo.physicalMemory
        if mem <= 4_000_000_000 { return 1 }    // ≤3GB
        if mem <= 5_000_000_000 { return 4 }
        return 6
    }()

    private var memoryWarningObserver: Any?

    private init() {
        let js = JSEngine()
        let dispatcher = SelectorDispatcher(js: js)
        self.jsEngine = js
        self.dispatcher = dispatcher
        self.searchParser = SearchParser(dispatcher: dispatcher, jsEngine: js)
        self.infoParser = BookInfoParser(dispatcher: dispatcher)
        self.tocParser = TocParser(dispatcher: dispatcher)
        self.contentParser = ContentParser(dispatcher: dispatcher)
        self.exploreParser = ExploreParser(dispatcher: dispatcher, jsEngine: js)

        // 万象书屋 (M2.4 perf): 多 SearchParser 实例池. 第 0 个复用上面的 searchParser (不浪费).
        var sPool: [SearchParser] = [self.searchParser]
        var iPool: [BookInfoParser] = [self.infoParser]
        var tPool: [TocParser] = [self.tocParser]
        var cPool: [ContentParser] = [self.contentParser]
        var jsPool: [JSEngine] = [js]
        for _ in 1..<Self.JS_POOL_SIZE {
            let extraJS = JSEngine()
            let extraDispatcher = SelectorDispatcher(js: extraJS)
            sPool.append(SearchParser(dispatcher: extraDispatcher, jsEngine: extraJS))
            iPool.append(BookInfoParser(dispatcher: extraDispatcher))
            tPool.append(TocParser(dispatcher: extraDispatcher))
            cPool.append(ContentParser(dispatcher: extraDispatcher))
            jsPool.append(extraJS)
        }
        self.searchParserPool = sPool
        self.infoParserPool = iPool
        self.tocParserPool = tPool
        self.contentParserPool = cPool
        self.allJSEngines = jsPool

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: .wanxiangMemoryWarning, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.handleMemoryWarning() }
        }
    }

    deinit {
        if let obs = memoryWarningObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func handleMemoryWarning() async {
        await infoCache.clearAll()
        HTTPFetcher.shared.clearResponseCache()
        JSEngineCache.shared.clearAll()
        await LegadoRuleEngine.shared.resetPutStore()
        // 万象书屋 (2026-05-25): SE crash 报告显示 OOM 主因是后台健康探测 + 用户搜索叠加,
        // 收到内存警告时立刻取消进行中的源探测, 把 cooperative pool 让给前台.
        await MainActor.run {
            SourceHealthChecker.shared.cancelHealthCheck()
        }
        // 万象书屋 (2026-05-25): 主动 GC 所有 JSEngine 实例, 释放番茄/起点等长 init
        // 脚本残留的 JS 堆对象. JSCore incremental GC 不会立刻回收, 必须显式触发.
        for engine in allJSEngines {
            await engine.evictAll()
        }
        NSLog("[WX-MEM] BookSourceEngine: cleared caches + cancelled healthCheck + GC %d JSEngines", allJSEngines.count)
    }

    private func pickInfoParser() -> BookInfoParser {
        let i = infoPoolCounter.fetchAdd(1)
        return infoParserPool[i % infoParserPool.count]
    }
    private func pickTocParser() -> TocParser {
        let i = tocPoolCounter.fetchAdd(1)
        return tocParserPool[i % tocParserPool.count]
    }
    private func pickContentParser() -> ContentParser {
        let i = contentPoolCounter.fetchAdd(1)
        return contentParserPool[i % contentParserPool.count]
    }

    // MARK: - 4 大主流程

    public func search(in source: BookSource, key: String, page: Int = 1) async throws -> [SearchBook] {
        // 万象书屋 (M2.4 perf): 多源并发搜索时 round-robin 选 SearchParser, 让 JS evaluation 真并发.
        // 各 parser 内部 jsEngine 仍 actor (JSContext 单线程必须), 但多 actor 之间真并发.
        let parser = pickSearchParser()
        do {
            let r = try await parser.search(in: source, key: key, page: page)
            if r.isEmpty {
                Self.reportHealth(source: source, stage: "search", status: "zero",
                                  errorMessage: "0 results", keyword: key)
            }
            return r
        } catch {
            Self.reportHealth(source: source, stage: "search", status: Self.classifyStatus(error),
                              errorMessage: String(describing: error), keyword: key)
            throw error
        }
    }

    private func pickSearchParser() -> SearchParser {
        let i = poolCounter.fetchAdd(1)
        return searchParserPool[i % searchParserPool.count]
    }

    /// 多源并发搜索. 边出边返回 (AsyncStream).
    ///
    /// 万象书屋 (M2.4 perf · 完全对齐 Android `SearchModel.startSearch`):
    /// - parser 已从 actor 改为 final class, 真并发不再串行排队
    /// - **并发数 9** = Android `MAX_THREAD = AppConst.MAX_THREAD` (`mapParallelSafe(threadCount=9)`).
    ///   产线滚动模型: 始终保持 9 个 in-flight, 一个完成立即让位下一个源.
    ///   之前 32 个全 fire 看似激进, 实际让 4 个 JSEngine pool 8:1 排队 + 慢源占着 task slot
    ///   不退, TaskGroup 等所有 task 才 finish. 改 9 后慢源不阻塞其他源进入.
    /// - **单源 30s 硬超时** = Android `withTimeout(30000L)`. 之前 12s 太激进, 一些慢但合法
    ///   的源 (8-15s 抓页面) 被误杀.
    public func searchAll(in sources: [BookSource], key: String,
                          maxConcurrency: Int = BookSourceEngine.defaultSearchConcurrency,
                          perSourceTimeoutSec: TimeInterval = 30) -> AsyncStream<(BookSource, Result<[SearchBook], Error>)> {
        AsyncStream { continuation in
            let innerTask = Task {
                // #region agent log
                DebugActivityTracker.shared.begin("searchAll(\(sources.count)s)")
                defer { DebugActivityTracker.shared.end("searchAll(\(sources.count)s)") }
                // #endregion
                await withTaskGroup(of: (BookSource, Result<[SearchBook], Error>).self) { group in
                    var iter = sources.makeIterator()
                    let cap = max(1, min(maxConcurrency, sources.count))

                    @discardableResult
                    func addNext() -> Bool {
                        guard !Task.isCancelled, let s = iter.next() else { return false }
                        group.addTask { [weak self] in
                            guard let self else { return (s, .success([])) }
                            return await Self.searchWithTimeout(
                                engine: self, source: s, key: key,
                                timeoutSec: perSourceTimeoutSec
                            )
                        }
                        return true
                    }

                    for _ in 0..<cap { _ = addNext() }

                    while let r = await group.next() {
                        if Task.isCancelled { break }
                        continuation.yield(r)
                        addNext()
                    }
                    group.cancelAll()
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in innerTask.cancel() }
        }
    }

    /// 全局搜索执行信号量: 限制跨所有 searchAll 实例同时在做 HTTP+JS 阻塞操作的源数量。
    /// 防止快速连续搜索(如用户快速换关键词)导致多个旧搜索的 SyncHTTP 同时阻塞协作线程池。
    private static let globalSearchGate: AsyncSemaphore = {
        let mem = ProcessInfo.processInfo.physicalMemory
        if mem <= 4_000_000_000 { return AsyncSemaphore(value: 1) }   // ≤3GB: 全局只允许1个源执行
        if mem <= 5_000_000_000 { return AsyncSemaphore(value: 2) }   // 4GB
        return AsyncSemaphore(value: 3)                                // 6GB+
    }()

    /// 单源搜索 + 硬超时. 超时 = 失败 (上报 health timeout), 不阻塞其他源.
    private static func searchWithTimeout(
        engine: BookSourceEngine, source: BookSource, key: String, timeoutSec: TimeInterval
    ) async -> (BookSource, Result<[SearchBook], Error>) {
        // 全局门控: 确保跨多个 searchAll 调用，同时阻塞线程的源数不超过安全值
        await globalSearchGate.wait()
        defer { globalSearchGate.signal() }

        guard !Task.isCancelled else {
            return (source, .failure(CancellationError()))
        }

        let t0 = Date()
        let result = await withTaskGroup(of: (BookSource, Result<[SearchBook], Error>)?.self) { inner -> (BookSource, Result<[SearchBook], Error>) in
            inner.addTask {
                do {
                    let r = try await engine.search(in: source, key: key)
                    return (source, .success(r))
                } catch {
                    return (source, .failure(error))
                }
            }
            inner.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                return (source, .failure(BookSourceEngineError.httpFailed("单源搜索超时 \(Int(timeoutSec))s")))
            }
            for await r in inner {
                inner.cancelAll()
                if let r = r { return r }
            }
            return (source, .failure(BookSourceEngineError.httpFailed("unknown")))
        }
        let dt = Date().timeIntervalSince(t0)
        if dt > 1.0 || ProcessInfo.processInfo.environment["WX_LOG_PER_SOURCE"] != nil {
            let status: String
            switch result.1 { case .success(let arr): status = "ok(\(arr.count))"; case .failure(let e): status = "err(\(e.localizedDescription.prefix(40)))" }
            print(String(format: "[search] %.2fs %@ %@", dt, source.bookSourceName, status))
        }
        return result
    }

    /// 万象书屋 (M2.8 perf): fetchInfo 5 分钟内 LRU cache, 同书短时间反复进详情页 0 网络.
    /// 用户场景: 看完详情进 reader 读两章, 退出后又点同书 — 之前每次都重新 fetchInfo.
    private let infoCache = InfoCache()
    private actor InfoCache {
        private var cache: [String: (info: BookInfo, ts: Date)] = [:]
        private let ttl: TimeInterval = 300  // 5 分钟
        func get(_ key: String) -> BookInfo? {
            guard let entry = cache[key], Date().timeIntervalSince(entry.ts) < ttl else { return nil }
            return entry.info
        }
        func set(_ key: String, _ info: BookInfo) {
            cache[key] = (info, Date())
            // 简单 size cap, 60 条够用 (一次会话不会看 60 本书)
            if cache.count > 60 {
                let oldest = cache.min(by: { $0.value.ts < $1.value.ts })?.key
                if let k = oldest { cache.removeValue(forKey: k) }
            }
        }
        func clearAll() {
            cache.removeAll()
        }
    }

    public func fetchInfo(of book: SearchBook, in source: BookSource) async throws -> BookInfo {
        // 万象书屋 (M2.8 perf): cache 命中直接返, 跳过网络 + JS
        let cacheKey = source.bookSourceUrl + "::" + book.bookUrl
        if let cached = await infoCache.get(cacheKey) {
            return cached
        }
        // 万象书屋 (M2.8 perf): round-robin 选 infoParser, 让多个 fetchInfo 真并发.
        let parser = pickInfoParser()
        do {
            let info = try await parser.fetchInfo(of: book, in: source)
            await infoCache.set(cacheKey, info)
            return info
        } catch {
            Self.reportHealth(source: source, stage: "info", status: Self.classifyStatus(error),
                              errorMessage: String(describing: error), sampleUrl: book.bookUrl)
            throw error
        }
    }

    public func fetchToc(of info: BookInfo, in source: BookSource) async throws -> [BookChapter] {
        let parser = pickTocParser()
        do {
            let chapters = try await parser.fetchToc(of: info, in: source)
            if chapters.isEmpty {
                Self.reportHealth(source: source, stage: "toc", status: "zero",
                                  errorMessage: "0 chapters", sampleUrl: info.tocUrl ?? info.bookUrl)
            }
            return chapters
        } catch {
            Self.reportHealth(source: source, stage: "toc", status: Self.classifyStatus(error),
                              errorMessage: String(describing: error), sampleUrl: info.tocUrl ?? info.bookUrl)
            throw error
        }
    }

    /// 万象书屋: 正文抓取入口
    /// - parameter book: 当前书的详情 (用于 JS 规则里 `book.*` 模板). 上层有
    ///   `BookInfo` 时务必透传; 一些源 (~七星阁/百合会等) 正文规则会用
    ///   `<js>java.ajax(book.bookUrl)</js>` 之类, 不传 book 会拿到空值导致正文断裂.
    public func fetchContent(of chapter: BookChapter,
                             in source: BookSource,
                             book: BookInfo? = nil,
                             nextChapterUrl: String? = nil) async throws -> ChapterContent {
        // 万象书屋 (M2.8 perf): round-robin contentParser, 让 reader prefetch 15 章 JS 真并发.
        // 之前共用单个 contentParser, 即使 prefetch 启 15 个 task, JS 评估都被 actor 串行化.
        let parser = pickContentParser()
        do {
            let content = try await parser.fetchContent(
                of: chapter, in: source, book: book, nextChapterUrl: nextChapterUrl
            )
            if content.content.isEmpty {
                Self.reportHealth(source: source, stage: "content", status: "zero",
                                  errorMessage: "empty content", sampleUrl: chapter.chapterUrl)
            }
            return content
        } catch {
            Self.reportHealth(source: source, stage: "content", status: Self.classifyStatus(error),
                              errorMessage: String(describing: error), sampleUrl: chapter.chapterUrl)
            throw error
        }
    }

    // MARK: - Health 上报

    /// 把 Swift Error 归类成后端 status enum (ok/zero/error/timeout/skip).
    private nonisolated static func classifyStatus(_ error: Error) -> String {
        if error is CancellationError { return "timeout" }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain {
            switch nsErr.code {
            case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet:
                return "timeout"
            default:
                return "error"
            }
        }
        let msg = String(describing: error).lowercased()
        if msg.contains("timeout") || msg.contains("cancel") { return "timeout" }
        return "error"
    }

    private nonisolated static func reportHealth(
        source: BookSource,
        stage: String,
        status: String,
        errorMessage: String? = nil,
        keyword: String? = nil,
        sampleUrl: String? = nil
    ) {
        // 万象书屋: 调试构建/CLI 可不注入 sink, 解析失败时静默不上报.
        if ProcessInfo.processInfo.environment["WX_DISABLE_HEALTH_REPORT"] != nil { return }
        guard let sink = SourceHealthSinkRegistry.shared.sink else { return }
        sink.reportSourceHealth(
            sourceUrl: source.bookSourceUrl,
            sourceName: source.bookSourceName,
            stage: stage,
            status: status,
            errorMessage: errorMessage,
            sampleKeyword: keyword,
            sampleUrl: sampleUrl
        )
    }

    /// 解析源的发现频道 (无网络)
    public func exploreKinds(of source: BookSource) async -> [ExploreParser.Kind] {
        await exploreParser.parseExploreKinds(of: source)
    }

    public func fetchExplore(of source: BookSource, kind: ExploreParser.Kind, page: Int = 1) async throws -> [SearchBook] {
        try await exploreParser.fetchExplore(of: source, kind: kind, page: page)
    }
}

// MARK: - Source health sink

/// 万象书屋: 解析器健康上报 sink. App target 用 WanxiangAPI 实现并注册;
/// CLI / 单元测试不注册时静默 noop, BookSource 模块不依赖 App 层网络栈.
public protocol SourceHealthSink: Sendable {
    func reportSourceHealth(
        sourceUrl: String,
        sourceName: String,
        stage: String,
        status: String,
        errorMessage: String?,
        sampleKeyword: String?,
        sampleUrl: String?
    )
}

/// 万象书屋: 轻量原子计数器 (round-robin pool 选择用), 不引第三方 dependency.
final class ManagedAtomicLite: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func fetchAdd(_ delta: Int = 1) -> Int {
        lock.lock(); defer { lock.unlock() }
        let r = value
        value &+= delta
        return r
    }
}

public final class SourceHealthSinkRegistry: @unchecked Sendable {
    public static let shared = SourceHealthSinkRegistry()
    private let queue = DispatchQueue(label: "wx.sourceHealthSink")
    private var _sink: SourceHealthSink?

    public var sink: SourceHealthSink? {
        queue.sync { _sink }
    }

    public func register(_ sink: SourceHealthSink?) {
        queue.sync { _sink = sink }
    }
}
