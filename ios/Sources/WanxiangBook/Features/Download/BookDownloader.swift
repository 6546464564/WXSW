//
//  BookDownloader.swift
//  万象书屋 iOS · 整书离线下载 (M2.8.x)
//
//  对应 Android: io.legado.app.service.CacheBookService
//
//  能力:
//   - 给 ShelfBook + chapters + source, 拉所有章节正文写 SQLite
//   - 支持断点续传 (跳过已 cache 的章节)
//   - 并发限制 (默认 3 个并发, 避免被服务端反爬)
//   - 进度回调 (Published progress / completed / total)
//   - 中断: 用户取消, 退出时停
//

import Foundation
import Combine

@MainActor
public final class BookDownloader: ObservableObject {

    public static let shared = BookDownloader()

    /// 当前正在下载的 books (key = bookUrl)
    @Published public private(set) var jobs: [String: Job] = [:]

    public struct Job: Identifiable, Sendable {
        public var id: String { bookUrl }
        public let bookUrl: String
        public let bookName: String
        public var total: Int
        public var completed: Int
        public var failed: Int
        public var status: Status

        public enum Status: String, Sendable {
            case running, paused, finished, error, cancelled
        }

        public var progress: Double {
            total == 0 ? 0 : Double(completed + failed) / Double(total)
        }
    }

    private var tasks: [String: Task<Void, Never>] = [:]
    public let concurrency: Int = 3

    private init() {}

    // MARK: - 公共 API

    /// 开始下载. 已有任务直接 noop (不重复跑)
    public func startDownload(book: ShelfBook, source: BookSource?) {
        if tasks[book.bookUrl] != nil { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDownload(book: book, source: source)
        }
        tasks[book.bookUrl] = task
    }

    /// 取消下载
    public func cancel(bookUrl: String) {
        tasks[bookUrl]?.cancel()
        tasks.removeValue(forKey: bookUrl)
        if var job = jobs[bookUrl] {
            job.status = .cancelled
            jobs[bookUrl] = job
        }
    }

    public func isDownloading(_ bookUrl: String) -> Bool {
        return jobs[bookUrl]?.status == .running
    }

    public func job(for bookUrl: String) -> Job? {
        jobs[bookUrl]
    }

    // MARK: - 实际下载

    private func runDownload(book: ShelfBook, source: BookSource?) async {
        // 1. 拿 chapters (优先本地 toc, 没就从 source 拉)
        var chapters: [BookChapter] = []
        if let local = try? await ChapterRepository.shared.loadToc(bookUrl: book.bookUrl), !local.isEmpty {
            chapters = local
        } else if let s = source {
            let info = BookInfo(
                bookUrl: book.bookUrl, name: book.name, author: book.author,
                coverUrl: book.coverUrl, tocUrl: book.tocUrl ?? book.bookUrl
            )
            if let toc = try? await BookSourceEngine.shared.fetchToc(of: info, in: s), !toc.isEmpty {
                try? await ChapterRepository.shared.saveToc(bookUrl: book.bookUrl, chapters: toc)
                chapters = toc
            }
        }
        guard !chapters.isEmpty else {
            jobs[book.bookUrl] = Job(
                bookUrl: book.bookUrl, bookName: book.name,
                total: 0, completed: 0, failed: 0, status: .error
            )
            tasks.removeValue(forKey: book.bookUrl)
            return
        }

        // 2. 初始化 job
        var job = Job(
            bookUrl: book.bookUrl, bookName: book.name,
            total: chapters.count, completed: 0, failed: 0, status: .running
        )
        jobs[book.bookUrl] = job

        // 3. 检测哪些章节已 cache → skip
        let pending: [BookChapter] = await checkPending(bookUrl: book.bookUrl, chapters: chapters)
        let alreadyDone = chapters.count - pending.count
        job.completed = alreadyDone
        jobs[book.bookUrl] = job

        // 4. 并发下载 (semaphore 控)
        guard let s = source else {
            // 没源(本地书已 cache 完): 直接 finished
            job.status = .finished
            jobs[book.bookUrl] = job
            tasks.removeValue(forKey: book.bookUrl)
            return
        }
        await downloadConcurrent(book: book, source: s, pending: pending, baseJob: &job)

        // 5. 收尾 — 必须从 jobs dict 重读最新 job (recordResult 一直写 jobs[bookUrl])
        // bug fix: 局部变量 job 已经过期, 用 dict 里的最新值判 status
        var finalJob = jobs[book.bookUrl] ?? job
        finalJob.status = Task.isCancelled ? .cancelled
            : (finalJob.failed > 0 && finalJob.completed == 0 ? .error : .finished)
        jobs[book.bookUrl] = finalJob
        tasks.removeValue(forKey: book.bookUrl)
    }

    private func checkPending(bookUrl: String, chapters: [BookChapter]) async -> [BookChapter] {
        var pending: [BookChapter] = []
        for c in chapters {
            let cached = try? await ChapterRepository.shared.loadContent(
                bookUrl: bookUrl, chapterIndex: c.chapterIndex
            )
            if cached == nil || cached?.isEmpty == true {
                pending.append(c)
            }
        }
        return pending
    }

    private func downloadConcurrent(book: ShelfBook, source: BookSource,
                                     pending: [BookChapter], baseJob: inout Job) async {
        // 万象书屋: 用 TaskGroup + 限速 semaphore
        // 每章独立 task, 一次最多 N 个并发, 避免被服务端反爬
        await withTaskGroup(of: Bool.self) { group in
            var inflight = 0
            var iterator = pending.makeIterator()
            while let chapter = iterator.next() {
                if Task.isCancelled { break }
                while inflight >= concurrency {
                    if let ok = await group.next() {
                        await self.recordResult(bookUrl: book.bookUrl, ok: ok)
                        inflight -= 1
                    }
                }
                inflight += 1
                let bookUrl = book.bookUrl
                group.addTask { [weak self] in
                    guard let self else { return false }
                    return await self.downloadOne(bookUrl: bookUrl, chapter: chapter, source: source)
                }
                // 万象书屋: 章节间 200ms 间隔 (友好礼貌, 防被服务端 block)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            // 等剩余 task 收尾
            for await ok in group {
                await self.recordResult(bookUrl: book.bookUrl, ok: ok)
            }
        }
    }

    private func recordResult(bookUrl: String, ok: Bool) async {
        guard var job = jobs[bookUrl] else { return }
        if ok {
            job.completed += 1
        } else {
            job.failed += 1
        }
        jobs[bookUrl] = job
    }

    private func downloadOne(bookUrl: String, chapter: BookChapter, source: BookSource) async -> Bool {
        // bug fix: 加 1 次自动 retry, 防瞬断
        for attempt in 0..<2 {
            if Task.isCancelled { return false }
            do {
                let cont = try await BookSourceEngine.shared.fetchContent(of: chapter, in: source)
                try? await ChapterRepository.shared.saveContent(
                    bookUrl: bookUrl, chapterIndex: chapter.chapterIndex, content: cont.content
                )
                return true
            } catch {
                if attempt == 0 {
                    // 第一次失败, 等 800ms 再试一次
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    continue
                }
                return false
            }
        }
        return false
    }
}
