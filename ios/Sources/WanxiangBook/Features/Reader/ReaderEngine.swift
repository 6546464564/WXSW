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

    // MARK: - 公共 API

    /// 启动: 拉/读目录, 拉首章
    public func bootstrap() async {
        loadingIndices.insert(currentChapterIndex)
        updateLoadingState()
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
                try await ChapterRepository.shared.saveToc(bookUrl: book.bookUrl, chapters: toc)
                self.chapters = toc
            } else {
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
        loadingIndices.remove(currentChapterIndex)
        updateLoadingState()
        await loadChapter(index: currentChapterIndex)
        prefetchAround(currentChapterIndex)
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
    public func changeSource(to newBook: SearchBook, source newSource: BookSource) async {
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
        self.currentChapterIndex = 0
        // 万象书屋 (P0 fix bug 1): source 现在是 var, 真正写新 source
        self.source = newSource
        self.lastError = nil
        // 用新 source 重新 bootstrap
        await bootstrap()
    }

    // MARK: - 内部加载

    private func loadChapter(index: Int) async {
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
            self.lastError = error.localizedDescription
        }
    }

    private func prefetchAround(_ index: Int) {
        for offset in [-1, 1] {
            let target = index + offset
            guard target >= 0, target < chapters.count, contentCache[target] == nil, inflight[target] == nil else {
                continue
            }
            Task { await loadChapter(index: target) }
        }
    }
}

// MARK: - 安全数组下标

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
