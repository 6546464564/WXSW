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

public actor BookSourceEngine {

    public static let shared = BookSourceEngine()

    private let jsEngine: JSEngine
    private let dispatcher: SelectorDispatcher
    private let searchParser: SearchParser
    private let infoParser: BookInfoParser
    private let tocParser: TocParser
    private let contentParser: ContentParser
    private let exploreParser: ExploreParser

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
    }

    // MARK: - 4 大主流程

    public func search(in source: BookSource, key: String, page: Int = 1) async throws -> [SearchBook] {
        do {
            let r = try await searchParser.search(in: source, key: key, page: page)
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

    /// 多源并发搜索. 边出边返回 (AsyncStream)
    public func searchAll(in sources: [BookSource], key: String) -> AsyncStream<(BookSource, Result<[SearchBook], Error>)> {
        AsyncStream { continuation in
            Task {
                await withTaskGroup(of: (BookSource, Result<[SearchBook], Error>).self) { group in
                    for source in sources {
                        group.addTask { [weak self] in
                            guard let self else { return (source, .success([])) }
                            do {
                                let r = try await self.search(in: source, key: key)
                                return (source, .success(r))
                            } catch {
                                // 万象书屋: search() 内部已上报 health, 这里不再重复.
                                return (source, .failure(error))
                            }
                        }
                    }
                    for await result in group {
                        continuation.yield(result)
                    }
                    continuation.finish()
                }
            }
        }
    }

    public func fetchInfo(of book: SearchBook, in source: BookSource) async throws -> BookInfo {
        do {
            return try await infoParser.fetchInfo(of: book, in: source)
        } catch {
            Self.reportHealth(source: source, stage: "info", status: Self.classifyStatus(error),
                              errorMessage: String(describing: error), sampleUrl: book.bookUrl)
            throw error
        }
    }

    public func fetchToc(of info: BookInfo, in source: BookSource) async throws -> [BookChapter] {
        do {
            let chapters = try await tocParser.fetchToc(of: info, in: source)
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
                             book: BookInfo? = nil) async throws -> ChapterContent {
        do {
            let content = try await contentParser.fetchContent(of: chapter, in: source, book: book)
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
    public nonisolated func exploreKinds(of source: BookSource) async -> [ExploreParser.Kind] {
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
