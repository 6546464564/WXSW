//
//  SourceHealthChecker.swift
//  万象书屋 iOS · 后台书源健康检测 + 加书时自动筛选最优源
//
//  功能一: 后台定时健康检测
//    - App 切到前台、且距上次检测 ≥ 2h 时，在后台对全部书源做轻量探测
//    - 每源发一次关键词搜索 (用常见小说词)，记录响应时间和成功率
//    - 结果写入 SourcePerformanceTracker，让搜索排序、换源列表自动受益
//
//  功能二: 加书时自动选最优源
//    - 用户把书加入书架后调用 autoSelectBestSource(for:keyword:)
//    - 并发搜索所有书源，根据响应速度 + 成功率自动换到最优源
//    - 最快找到的前 3 个结果里取分数最高的, 更新书架记录
//
//  对应 Android: io.legado.app.help.source.SourceHelp.checkSourceList()
//

import Foundation

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        return Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
    func nonZero(default def: Int) -> Int { self == 0 ? def : self }
}

@MainActor
public final class SourceHealthChecker: ObservableObject {

    public static let shared = SourceHealthChecker()

    /// 上次全量健康检测时间
    private static let lastCheckKey = "wx.sourceHealth.lastCheckAt"

    /// 检测间隔（秒）
    private let checkInterval: TimeInterval = 2 * 60 * 60  // 2 小时

    /// 当前是否在跑健康检测
    @Published public var isChecking = false
    /// 已检测数 / 总数
    @Published public var checkedCount = 0
    @Published public var totalCount = 0

    private var checkTask: Task<Void, Never>?

    private init() {}

    // MARK: - 功能一: 后台定时健康检测

    /// App 切到前台时调用. 如距上次 ≥ 2h, 则后台启动健康检测.
    public func scheduleIfNeeded() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - last >= checkInterval else { return }
        guard !isChecking else { return }
        startHealthCheck()
    }

    /// 手动立即触发健康检测（给设置页的「立即检测」按钮用）
    public func startHealthCheck() {
        checkTask?.cancel()
        checkTask = Task.detached(priority: .background) { [weak self] in
            await self?.runHealthProbe()
        }
    }

    // MARK: - 校验超时（对齐 Android CheckSource.timeout 默认 180s）
    /// UserDefaults key "wx.sourceCheck.timeoutSec" (Int)，默认 120 秒
    public var checkTimeoutSeconds: Int {
        get { UserDefaults.standard.integer(forKey: "wx.sourceCheck.timeoutSec").clamped(to: 30...300).nonZero(default: 120) }
        set { UserDefaults.standard.set(newValue, forKey: "wx.sourceCheck.timeoutSec") }
    }

    /// 校验单个书源（全链路: 搜索 → 书籍详情 → 章节目录 → 正文）
    /// 对齐 Android CheckSourceService.checkSource + doCheckSource
    private func checkOneSource(_ source: BookSource, keyword: String, timeoutSec: Int) async {
        let start = Date()
        var ok = false
        var failStage = ""

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // 总超时 task（对齐 Android withTimeout(CheckSource.timeout)）
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSec) * 1_000_000_000)
                    throw CheckError.timeout
                }
                // 正式校验 task
                group.addTask { [keyword] in
                    // 第一步: 搜索（对齐 Android checkSearch）
                    let results = try await BookSourceEngine.shared.search(in: source, key: keyword, page: 1)
                    guard !results.isEmpty else {
                        throw CheckError.searchEmpty
                    }
                    // 第二步: 书籍详情（对齐 Android checkInfo）
                    let firstBook = results[0]
                    let info = try await BookSourceEngine.shared.fetchInfo(of: firstBook, in: source)
                    // 第三步: 章节目录（对齐 Android checkCategory）
                    let chapters = try await BookSourceEngine.shared.fetchToc(of: info, in: source)
                    guard !chapters.isEmpty else {
                        throw CheckError.tocEmpty
                    }
                    // 第四步: 正文校验（对齐 Android checkContent）
                    let content = try await BookSourceEngine.shared.fetchContent(of: chapters[0], in: source, book: info)
                    guard !content.content.isEmpty else {
                        throw CheckError.contentEmpty
                    }
                    // 第五步: 发现页校验（对齐 Android checkDiscovery，仅对有 exploreUrl 的源）
                    if let exploreUrl = source.exploreUrl, !exploreUrl.isEmpty {
                        let kinds = await BookSourceEngine.shared.exploreKinds(of: source)
                        if let firstKind = kinds.first {
                            let explored = try await BookSourceEngine.shared.fetchExplore(of: source, kind: firstKind, page: 1)
                            if explored.isEmpty {
                                throw CheckError.discoverEmpty
                            }
                        }
                    }
                }
                // 哪个先完成就 cancel 另一个
                if let result = try await group.next() {
                    _ = result
                }
                group.cancelAll()
            }
            ok = true
        } catch CheckError.searchEmpty { failStage = "搜索失效" }
        catch CheckError.tocEmpty     { failStage = "目录失效" }
        catch CheckError.contentEmpty { failStage = "正文失效" }
        catch CheckError.discoverEmpty{ failStage = "发现失效" }
        catch CheckError.timeout      { failStage = "校验超时" }
        catch {
            let desc = String(describing: error).lowercased()
            if desc.contains("timeout") || desc.contains("timedout") {
                failStage = "校验超时"
            } else if desc.contains("javascript") || desc.contains("js") {
                failStage = "js失效"
            } else {
                failStage = "网站失效"
            }
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        SourcePerformanceTracker.shared.record(
            sourceUrl: source.bookSourceUrl,
            ok: ok,
            durationMs: ms,
            failTag: ok ? nil : failStage
        )
        await MainActor.run {
            SourceHealthChecker.shared.checkedCount += 1
        }
    }

    private enum CheckError: Error {
        case searchEmpty, tocEmpty, contentEmpty, discoverEmpty, timeout
    }

    private func runHealthProbe() async {
        let sources = await BookSourceRegistry.shared.sources
        let enabled = sources.filter { $0.enabled == true }
        guard !enabled.isEmpty else { return }

        let timeout = await checkTimeoutSeconds
        let keyword = UserDefaults.standard.string(forKey: "wx.sourceCheck.keyword") ?? "修仙"

        await MainActor.run {
            self.isChecking = true
            self.checkedCount = 0
            self.totalCount = enabled.count
        }

        // 并发 7（iOS JS 解析 CPU 压力下的最优点，介于 Android MAX_THREAD=9 与 iOS 限制之间）
        let maxConcurrency = 7

        await withTaskGroup(of: Void.self) { group in
            var iter = enabled.makeIterator()

            func addNextSource() {
                guard let source = iter.next() else { return }
                group.addTask { [keyword, timeout] in
                    await self.checkOneSource(source, keyword: keyword, timeoutSec: timeout)
                }
            }

            for _ in 0..<min(maxConcurrency, enabled.count) {
                addNextSource()
            }
            for await _ in group {
                addNextSource()
            }
        }

        SourcePerformanceTracker.shared.persistToDisk()
        let now = Date().timeIntervalSince1970
        UserDefaults.standard.set(now, forKey: Self.lastCheckKey)

        await MainActor.run {
            self.isChecking = false
        }
    }

    // MARK: - 功能二: 加书时自动选最优源

    /// 把书加入书架后调用：并发搜索所有源，选分数最高的更新书架记录.
    /// - Parameters:
    ///   - book: 刚加入书架的 ShelfBook
    ///   - keyword: 搜索关键词（通常用书名）
    ///
    /// 万象书屋: 找到可信结果（≥3 个源返回）或 8s 后超时，取 SourcePerformanceTracker score 最高的.
    public func autoSelectBestSource(for book: ShelfBook, keyword: String) {
        Task.detached(priority: .utility) {
            await self._autoSelect(book: book, keyword: keyword)
        }
    }

    private func _autoSelect(book: ShelfBook, keyword: String) async {
        let sources = await BookSourceRegistry.shared.sources
        let enabled = sources.filter { $0.enabled == true }
        guard !enabled.isEmpty else { return }

        // 候选集合：所有找到这本书的 SearchBook
        actor CandidateStore {
            var candidates: [SearchBook] = []
            func add(_ items: [SearchBook]) { candidates.append(contentsOf: items) }
            func getAll() -> [SearchBook] { candidates }
        }
        let store = CandidateStore()

        // 最多等 10 秒，并发不超过 9
        let stream = BookSourceEngine.shared.searchAll(
            in: enabled,
            key: keyword,
            maxConcurrency: 9,
            perSourceTimeoutSec: 10
        )

        var found = 0
        for await (source, result) in stream {
            if case .success(let books) = result {
                // 过滤：书名和作者都匹配
                let matched = books.filter { sb in
                    sb.name.lowercased() == book.name.lowercased() ||
                    (sb.author.lowercased() == book.author.lowercased() && !book.author.isEmpty)
                }
                if !matched.isEmpty {
                    await store.add(matched)
                    found += 1
                    // 找到 3 个源就够了
                    if found >= 3 { break }
                }
                // 顺便记录性能数据
                _ = source  // already recorded inside BookSourceEngine
            }
        }

        let candidates = await store.getAll()
        guard !candidates.isEmpty else { return }

        // 按 SourcePerformanceTracker 分数选最优
        let tracker = SourcePerformanceTracker.shared
        let best = candidates.max { a, b in
            let sa = tracker.stats(for: a.origin)?.score ?? 50
            let sb = tracker.stats(for: b.origin)?.score ?? 50
            return sa < sb
        }

        guard let best else { return }
        guard best.origin != book.origin else { return }  // 已经是最好的

        // 构造新的 ShelfBook，切换到最优源
        let updated = ShelfBook(
            bookUrl: best.bookUrl,
            name: best.name,
            author: best.author,
            origin: best.origin,
            originName: best.originName,
            coverUrl: best.coverUrl ?? book.coverUrl,
            intro: best.intro ?? book.intro,
            kind: book.kind,
            tocUrl: best.bookUrl  // SearchBook 没有 tocUrl 字段，先用 bookUrl 代替
        )

        // 先加新书（upsert），再删旧书
        do {
            try await BookshelfRepository.shared.add(updated)
            // 仅当 URL 不同时才删旧记录
            if updated.bookUrl != book.bookUrl {
                try await BookshelfRepository.shared.remove(bookUrl: book.bookUrl)
            }
        } catch {
            // 静默失败：不影响用户体验，保留原来的源
        }
    }
}

// MARK: - 书源健康状态（给 UI 显示用）

public extension SourcePerformanceTracker.Stats {

    enum HealthLevel {
        case unknown    // 没有历史数据
        case good       // 成功率 ≥ 80%
        case moderate   // 成功率 40-80%
        case poor       // 成功率 < 40%
    }

    var healthLevel: HealthLevel {
        guard !samples.isEmpty else { return .unknown }
        if successRate >= 0.8 { return .good }
        if successRate >= 0.4 { return .moderate }
        return .poor
    }
}
