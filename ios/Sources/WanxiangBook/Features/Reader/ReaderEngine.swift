//
//  ReaderEngine.swift
//  万象书屋 iOS · 阅读会话引擎 (M2.5.1)
//
//  对应 Android: io.legado.app.model.ReadBook + ReadBook.loadOrUpContent
//
//  职责:
//   - 持有当前书 / 当前章节
//   - 章节正文 三层缓存:内存 LRU → SQLite (ChapterRepository) → 远端 (BookSourceEngine)
//   - 预拉策略:进当前章前 + 后各 1 章
//   - 异常时退化:HTTP 失败 → 显示空 + 重试按钮
//
//  M2.5.1 v1: 单书会话, 不支持多书并行
//

import Foundation

@MainActor
public final class ReaderEngine: ObservableObject {

    // MARK: - 当前会话状态

    @Published public private(set) var book: ShelfBook
    @Published public private(set) var chapters: [BookChapter] = []
    @Published public private(set) var currentChapterIndex: Int = 0
    @Published public private(set) var loadingChapter: Bool = false
    @Published public private(set) var lastError: String? = nil
    /// 万象书屋 (M2.8): 自动换源进行中标志, reader UI 显示"正在尝试其他源…"
    @Published public private(set) var autoFallbackInProgress: Bool = false

    /// 章节正文内存缓存 (key=chapterIndex, val=正文)
    private var contentCache: [Int: String] = [:]
    /// 进行中的拉取任务, 防止重复
    private var inflight: [Int: Task<String, Error>] = [:]

    /// 万象书屋 (P0 fix): source 必须可改 — 换源场景需要换 source 引用,
    /// 否则后续 fetchContent 还会用旧源
    private var source: BookSource?
    /// 万象书屋 (P1 fix bug 3): loadingChapter 用 currentChapterIndex 一致性而非全局
    /// 避免 prefetch 任务干扰主章 loading 状态
    private var loadingIndices: Set<Int> = []

    public init(book: ShelfBook, source: BookSource? = nil) {
        self.book = book
        self.source = source ?? BookSourceRegistry.shared.find(origin: book.origin)
        self.currentChapterIndex = max(0, book.durChapterIndex)
    }

    /// 万象书屋 (bug 3 fix): loadingChapter 只反映当前章
    private func updateLoadingState() {
        loadingChapter = loadingIndices.contains(currentChapterIndex)
    }

    private enum ChapterIndexResolution {
        /// 普通进入阅读器: 用书架 `durChapterIndex` 并夹在目录范围内.
        case shelfBookClamped
        /// 换源: 对齐 Android `Book.migrateTo` + `BookHelp.getDurChapter`.
        case migrateFromPreviousSource(oldIndex: Int, oldTitle: String?, oldListSize: Int)
    }

    // MARK: - 公共 API

    /// 启动: 拉/读目录, 拉首章.
    ///
    /// 万象书屋 (M2.6 perf · 对齐 Android `ReadBook.upChapterList` + `loadContent(true)`):
    ///   - bookshelf.add / saveToc / updateTotalChapters 全是写库, 不在用户感知路径上 →
    ///     `Task.detached` 后台 fire-and-forget, 不阻塞 loadChapter.
    ///   - 冷启动先全力拉**当前章**, 首屏后再 `prefetchAround` — 避免 ±1 与用户章并发
    ///     抢 HTTP/JSEngine 池 (默认各 8/4 连接), 拖慢「第一次打开第一章」体感.
    ///   - 用户翻章仍走 `goToChapter`: 当前章 await 完后立刻预热前后章 (对齐日常使用).
    public func bootstrap() async {
        await bootstrap(chapterResolution: .shelfBookClamped)
    }

    private func bootstrap(chapterResolution: ChapterIndexResolution) async {
        loadingIndices.insert(currentChapterIndex)
        updateLoadingState()

        // 万象书屋 (M2.6 perf): bookshelf.add 后台跑, 不让 30ms SQLite write 拦在用户路径上.
        // idempotent: 多次调用安全, 后续 updateProgress 时也会顺便 ensure.
        let bookCopy = book
        Task.detached(priority: .utility) {
            try? await BookshelfRepository.shared.add(bookCopy)
        }

        // Step 1: 加载目录 (cache-first, 不能后台跑 — 后续 loadChapter 依赖 chapters).
        do {
            let cachedToc = try await ChapterRepository.shared.loadToc(bookUrl: book.bookUrl)
            if !cachedToc.isEmpty {
                self.chapters = cachedToc
            } else if let s = source {
                let info = BookInfo(
                    bookUrl: book.bookUrl, name: book.name, author: book.author,
                    coverUrl: book.coverUrl, tocUrl: book.tocUrl ?? book.bookUrl
                )
                let toc = try await BookSourceEngine.shared.fetchToc(of: info, in: s)
                self.chapters = toc
                // 万象书屋 (M2.6 perf): saveToc 后台跑, 不阻塞 loadChapter
                let bookUrl = book.bookUrl
                Task.detached(priority: .utility) {
                    try? await ChapterRepository.shared.saveToc(bookUrl: bookUrl, chapters: toc)
                }
            } else {
                // 对齐 Android ReadBookViewModel: bookSource == null 且开启自动换源时静默尝试其它源.
                if ReadingSettings.autoChangeSourceEnabled {
                    autoFallbackInProgress = true
                    defer { autoFallbackInProgress = false }
                    let recovered = await recoverMissingBookSourceAutoSwitch()
                    if recovered {
                        loadingIndices.removeAll()
                        updateLoadingState()
                        return
                    }
                }
                self.lastError = "找不到此书的源 \(book.origin),请在搜索/书城重新加入此书"
                loadingIndices.remove(currentChapterIndex)
                updateLoadingState()
                return
            }
        } catch {
            self.lastError = "目录加载失败:\(error.localizedDescription)"
            loadingIndices.remove(currentChapterIndex)
            updateLoadingState()
            return
        }
        guard !chapters.isEmpty else {
            self.lastError = "目录为空,该书可能不存在或源无法访问"
            loadingIndices.remove(currentChapterIndex)
            updateLoadingState()
            return
        }

        // 对齐 Android: 换源后映射章节索引并持久化进度 (migrateTo).
        switch chapterResolution {
        case .shelfBookClamped:
            let idx = max(0, min(book.durChapterIndex, chapters.count - 1))
            currentChapterIndex = idx
        case let .migrateFromPreviousSource(oldIdx, oldTitle, oldListSize):
            let mapped = BookChapterMigration.mappedDurChapterIndex(
                oldDurChapterIndex: oldIdx,
                oldDurChapterTitle: oldTitle,
                newChapters: chapters,
                oldChapterListSize: oldListSize
            )
            currentChapterIndex = mapped
            var b = book
            b.durChapterIndex = mapped
            b.durChapterTitle = chapters.indices.contains(mapped) ? chapters[mapped].title : oldTitle
            b.totalChapterNum = chapters.count
            self.book = b
            try? await BookshelfRepository.shared.updateProgress(
                bookUrl: b.bookUrl,
                chapterIndex: mapped,
                chapterTitle: b.durChapterTitle,
                chapterPos: b.durChapterPos
            )
        }

        // Step 2: 回写 totalChapterNum / latestChapterTitle (后台, 不阻塞).
        let latestTitle = chapters.last?.title
        let total = chapters.count
        let bookUrl = book.bookUrl
        Task.detached(priority: .utility) {
            try? await BookshelfRepository.shared.updateTotalChapters(
                bookUrl: bookUrl, total: total, latestTitle: latestTitle
            )
        }
        var refreshed = book
        refreshed.totalChapterNum = total
        refreshed.latestChapterTitle = latestTitle
        self.book = refreshed
        loadingIndices.remove(currentChapterIndex)
        updateLoadingState()

        // Step 3: 首章优先 — await 当前章后再批量 prefetch (目录页进阅读器 / 换源重启).
        let curr = currentChapterIndex
        await loadChapter(index: curr)
        prefetchAround(curr)
    }

    /// 切到某章 (用户点目录 / 进度条 / 上下章)
    public func goToChapter(_ index: Int) async {
        // 万象书屋 (P2 fix): 空目录时拒绝跳章, 避免假装跳到 0 实际什么都没有
        guard !chapters.isEmpty, index >= 0, index < chapters.count else { return }
        currentChapterIndex = index
        // 持久化阅读进度
        try? await BookshelfRepository.shared.updateProgress(
            bookUrl: book.bookUrl,
            chapterIndex: index,
            chapterTitle: chapters[safe: index]?.title,
            chapterPos: 0
        )
        await loadChapter(index: index)
        prefetchAround(index)
    }

    public func nextChapter() async {
        await goToChapter(currentChapterIndex + 1)
    }

    public func previousChapter() async {
        await goToChapter(currentChapterIndex - 1)
    }

    /// 获取章节正文 (同步从 cache, 没就异步拉)
    public func content(for index: Int) -> String? {
        contentCache[index]
    }

    /// 强制重拉 (用户点"重试")
    public func retryCurrentChapter() async {
        contentCache.removeValue(forKey: currentChapterIndex)
        inflight[currentChapterIndex]?.cancel()
        inflight.removeValue(forKey: currentChapterIndex)
        await loadChapter(index: currentChapterIndex)
    }

    /// 万象书屋: 换源 (用户在 ChangeSourceView 选了别的源同名书)
    /// 对齐 Android `ReadBookViewModel.changeTo` + `Book.migrateTo`: 映射章节进度后再加载.
    public func changeSource(to newBook: SearchBook, source newSource: BookSource) async {
        let oldIdx = chapters.isEmpty ? book.durChapterIndex : currentChapterIndex
        let oldTitle: String? = (oldIdx >= 0 && oldIdx < chapters.count) ? chapters[oldIdx].title : book.durChapterTitle
        let oldListSize = max(chapters.count, book.totalChapterNum)

        let oldBookUrl = book.bookUrl
        var updated = book
        updated.bookUrl = newBook.bookUrl
        updated.tocUrl = newBook.bookUrl
        updated.origin = newBook.origin
        updated.originName = newBook.originName
        updated.coverUrl = newBook.coverUrl ?? updated.coverUrl
        try? await BookshelfRepository.shared.changeBookUrl(oldUrl: oldBookUrl, newBook: updated)
        try? await ChapterRepository.shared.clearAllForBook(bookUrl: oldBookUrl)
        try? await ChapterRepository.shared.clearAllForBook(bookUrl: updated.bookUrl)
        contentCache.removeAll()
        inflight.values.forEach { $0.cancel() }
        inflight.removeAll()
        loadingIndices.removeAll()
        self.book = updated
        self.chapters = []
        self.source = newSource
        self.lastError = nil
        await bootstrap(chapterResolution: .migrateFromPreviousSource(
            oldIndex: oldIdx,
            oldTitle: oldTitle,
            oldListSize: oldListSize
        ))
    }

    // MARK: - 内部加载

    /// - Parameter silent: 万象书屋 (M2.8 A2): prefetch 路径传 true, fail 不写 lastError —
    ///   避免后台预拉前后章失败把用户当前正在读的章节屏幕替换成 errorState.
    private func loadChapter(index: Int, silent: Bool = false) async {
        guard index >= 0 else { return }
        if contentCache[index] != nil { return }
        // 万象书屋 (bug 2 fix): 已被 cancel 的 task 不复用, 直接清掉新建
        if let task = inflight[index] {
            if task.isCancelled {
                inflight.removeValue(forKey: index)
            } else {
                do { _ = try await task.value } catch {}
                return
            }
        }
        loadingIndices.insert(index)
        updateLoadingState()
        defer {
            loadingIndices.remove(index)
            updateLoadingState()
        }
        do {
            let task = Task<String, Error> { [book, source, chapters] in
                // 1. 本地 SQLite
                if let local = try await ChapterRepository.shared.loadContent(bookUrl: book.bookUrl, chapterIndex: index) {
                    return local
                }
                // 2. 远端 — 没源/没章就报真错, 不返伪正文 (P1 fix)
                guard let s = source else {
                    throw NSError(domain: "Reader", code: 11,
                        userInfo: [NSLocalizedDescriptionKey: "找不到书源 \(book.origin), 请在搜索/书城重新加入此书"])
                }
                guard let chapter = chapters[safe: index] else {
                    throw NSError(domain: "Reader", code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "目录还没加载, 下拉刷新试试"])
                }
                let cont = try await BookSourceEngine.shared.fetchContent(of: chapter, in: s)
                // 3. 写回缓存
                try? await ChapterRepository.shared.saveContent(
                    bookUrl: book.bookUrl,
                    chapterIndex: index,
                    content: cont.content
                )
                return cont.content
            }
            inflight[index] = task
            // 万象书屋 (bug 2 fix): 不管成功失败 / 取消都清 inflight, 避免 stale task 卡住
            defer { inflight.removeValue(forKey: index) }
            let body = try await task.value
            contentCache[index] = body
            self.lastError = nil
        } catch is CancellationError {
            // 用户切走了, 忽略 (defer 已清 inflight)
        } catch {
            // 万象书屋 (M2.8 A2): silent prefetch 不写 lastError 避免 UI 闪错
            if !silent {
                // 万象书屋 (M2.8 自动换源 fallback): 当前章 fail 时, 不立刻显示 errorState,
                // 先后台静默尝试其他源. 找到能用的源就 changeSource(); 都不行才显示错误.
                // 用户体感是"轻微卡顿后内容出来" 而不是 "目录为空" 错误页.
                if index == currentChapterIndex, ReadingSettings.autoChangeSourceEnabled {
                    Task { await tryAutoChangeSource(failedAt: index) }
                }
                self.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - 自动换源 (对齐 Android ReadBookViewModel.autoChangeSource)

    /// 正文失败或 registry 无源时: 搜索同名书 → 验目录与正文 → `changeSource`.
    private func pickVerifiedAlternateSource(
        excludingOrigin: String?,
        verifyChapterIndex: Int,
        bookName: String,
        bookAuthor: String,
        candidateCap: Int
    ) async -> (SearchBook, BookSource)? {
        let raw = BookSourceRegistry.shared.enabledSources.filter { src in
            guard let ex = excludingOrigin else { return true }
            return src.bookSourceUrl != ex
        }
        guard !raw.isEmpty else { return nil }
        let sorted = SourcePerformanceTracker.shared.sortByScore(raw)
        let candidates = Array(sorted.prefix(candidateCap))

        let stream = await BookSourceEngine.shared.searchAll(
            in: candidates, key: bookName, maxConcurrency: 5, perSourceTimeoutSec: 8
        )
        for await (src, result) in stream {
            if Task.isCancelled { break }
            guard case .success(let books) = result else { continue }
            guard let match = books.first(where: { $0.name == bookName && $0.author == bookAuthor }) else { continue }

            let info = BookInfo(
                bookUrl: match.bookUrl, name: match.name, author: match.author,
                coverUrl: match.coverUrl, tocUrl: match.bookUrl
            )
            guard let toc = try? await BookSourceEngine.shared.fetchToc(of: info, in: src), !toc.isEmpty else { continue }
            let idx = min(max(0, verifyChapterIndex), toc.count - 1)
            guard let chap = toc[safe: idx] else { continue }
            guard let _ = try? await BookSourceEngine.shared.fetchContent(of: chap, in: src) else { continue }
            return (match, src)
        }
        return nil
    }

    /// `ReadBook.bookSource == null` 且开启自动换源 (对齐 Android 初始化路径).
    private func recoverMissingBookSourceAutoSwitch() async -> Bool {
        guard let picked = await pickVerifiedAlternateSource(
            excludingOrigin: book.origin,
            verifyChapterIndex: book.durChapterIndex,
            bookName: book.name,
            bookAuthor: book.author,
            candidateCap: 24
        ) else { return false }
        await changeSource(to: picked.0, source: picked.1)
        return true
    }

    /// 当前章 pull 失败时的静默换源.
    private func tryAutoChangeSource(failedAt failIndex: Int) async {
        guard ReadingSettings.autoChangeSourceEnabled else { return }
        guard !autoFallbackInProgress else { return }
        autoFallbackInProgress = true
        defer { autoFallbackInProgress = false }

        guard let picked = await pickVerifiedAlternateSource(
            excludingOrigin: book.origin,
            verifyChapterIndex: failIndex,
            bookName: book.name,
            bookAuthor: book.author,
            candidateCap: 16
        ) else { return }

        await changeSource(to: picked.0, source: picked.1)
    }

    /// 万象书屋 (M2.8): preDownload — 跟 Android `ReadBook.preDownload` (默认
    /// `preDownloadNum=10`) 对齐. 之前只预拉 ±1 章, 翻 3 章就走网络. 现在前 5 + 后 10
    /// 全后台预拉, SQLite cache 命中后翻页秒级.
    /// 关键 invariants:
    ///   - silent=true 让失败不写 lastError (后台预拉失败别打扰前台读)
    ///   - 跳过已 cache / inflight 的章, 避免重复请求
    ///   - 用 .utility QoS, 不抢用户当前章主线程资源
    private static let preDownloadAhead = 10
    private static let preDownloadBehind = 5

    private func prefetchAround(_ index: Int) {
        // 1. 优先邻近 (±1) — 用户大概率下一秒就翻到, 高优先级
        for offset in [1, -1] {
            let target = index + offset
            guard target >= 0, target < chapters.count,
                  contentCache[target] == nil, inflight[target] == nil else {
                continue
            }
            Task(priority: .userInitiated) { await loadChapter(index: target, silent: true) }
        }
        // 2. 后续 N 章 (用户顺序读时, 翻页前已经在 SQLite)
        for offset in 2...Self.preDownloadAhead {
            let target = index + offset
            guard target >= 0, target < chapters.count,
                  contentCache[target] == nil, inflight[target] == nil else {
                continue
            }
            Task(priority: .utility) { await loadChapter(index: target, silent: true) }
        }
        // 3. 前 N 章 (用户回看上文时也命中)
        for offset in 2...Self.preDownloadBehind {
            let target = index - offset
            guard target >= 0, target < chapters.count,
                  contentCache[target] == nil, inflight[target] == nil else {
                continue
            }
            Task(priority: .utility) { await loadChapter(index: target, silent: true) }
        }
    }
}

// MARK: - 安全数组下标

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
