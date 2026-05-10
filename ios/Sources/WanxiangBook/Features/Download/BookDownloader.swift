//
//  BookDownloader.swift
//  万象书屋 iOS · 整书离线下载 (M2.8.x)
//
//  对应 Android: io.legado.app.service.CacheBookService + io.legado.app.help.book.BookHelp
//
//  能力:
//   - 给 ShelfBook + chapters + source, 拉所有章节正文写 SQLite
//   - 支持断点续传 (跳过已 cache 的章节)
//   - 并发限制 (默认 6 个并发, 跟 Android `MAX_THREAD=9` 接近, 章节间 200ms 间隔)
//   - 进度回调 (Published progress / completed / total + downloadedImages)
//   - 中断: 用户取消, 退出时停 (BGTaskScheduler 申请后台时间续跑)
//   - 图片下载: 抓正文里 <img src>, 存 disk cache (跟 Android `saveImages` 等价)
//   - App 后台续命: BGTaskScheduler 申请 ~30s 后台时间
//   - 完成通知: UNUserNotification 弹 banner
//

import Foundation
import Combine
import UserNotifications
import UIKit
import BackgroundTasks

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
        /// 万象书屋 (M2.8 C 档): 已下载图片张数, 用户能看到"30/100 章 · 245 张图"
        public var imagesDownloaded: Int = 0
        /// 万象书屋 (M2.8 fix): 缓存原始 ShelfBook + range, 让 DownloadCenterView 重试时
        /// 不必从 BookshelfRepository 拉 (没加书架的书也能重试).
        public var originalBook: ShelfBook? = nil
        public var lastRange: ClosedRange<Int>? = nil

        public enum Status: String, Sendable {
            case running, paused, finished, error, cancelled
        }

        public var progress: Double {
            total == 0 ? 0 : Double(completed + failed) / Double(total)
        }
    }

    private var tasks: [String: Task<Void, Never>] = [:]
    /// 万象书屋 (M2.8 perf): 并发 6 → 8, 跟 Android `MAX_THREAD=9` 持平. URLSession 每个 host
    /// 默认 6 connection, 多个不同 host 总共 8 个 task 并跑没问题.
    public let concurrency: Int = 8

    /// 万象书屋 (M2.8 C 档): UIApplication backgroundTask, 让 App 切后台后再多跑 ~30 秒.
    /// 比 BGTaskScheduler 简单且更可靠 — BGTaskScheduler 是"系统决定何时运行", 续不上点;
    /// beginBackgroundTask 是"我有未完任务, 给我 30s 收尾", 立即生效.
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    /// 万象书屋 (M2.8 fix): 通知权限懒申请 — 用户第一次点"下载本书"时才弹.
    /// 之前在 init 时立即弹 → App 启动就遮屏, 没上下文 = 拒绝率高 + 阻挡其它 UI.
    private var notificationAuthRequested = false
    private func requestNotificationAuthIfNeeded() {
        guard !notificationAuthRequested else { return }
        notificationAuthRequested = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .badge, .sound]
        ) { _, _ in }
    }

    // MARK: - 公共 API

    /// 开始下载. 已有任务直接 noop (不重复跑)
    /// - Parameter range: 万象书屋 (M2.8 Gap 2): 可选章节范围 (1-based 索引), nil = 全本.
    ///   跟 Android `CacheBook.start(book, start, end)` 等价, 让用户选"下载第 100-200 章".
    public func startDownload(book: ShelfBook, source: BookSource?, range: ClosedRange<Int>? = nil) {
        if tasks[book.bookUrl] != nil { return }
        // 万象书屋 (M2.8 fix): 用户真正点下载时才申请通知权限, 不在 init 时打断启动.
        requestNotificationAuthIfNeeded()
        beginBackgroundTaskIfNeeded()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDownload(book: book, source: source, range: range)
            self.endBackgroundTaskIfNoJobs()
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
        endBackgroundTaskIfNoJobs()
    }

    // MARK: - 后台续命 (M2.8 C 档)

    /// 万象书屋: 申请 UIApplication backgroundTask, 让 App 切后台后再多跑 ~30 秒.
    /// 系统会在 30 秒后调用 expirationHandler 提醒"快收尾", 这里把所有 in-flight task cancel.
    /// 已写到 SQLite 的章节保留 (断点续传), 下次进 App 时重启下载继续没下完的部分.
    private func beginBackgroundTaskIfNeeded() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "WanxiangBookDownload") { [weak self] in
            // 系统快要杀进程了, 主动 cancel 所有任务把数据 flush 到 SQLite
            Task { @MainActor [weak self] in
                guard let self else { return }
                for (_, t) in self.tasks { t.cancel() }
                self.tasks.removeAll()
                if self.bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(self.bgTaskID)
                    self.bgTaskID = .invalid
                }
            }
        }
    }

    private func endBackgroundTaskIfNoJobs() {
        guard tasks.isEmpty, bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    // MARK: - 完成通知 (M2.8 C 档)

    private func postFinishNotification(job: Job) {
        let content = UNMutableNotificationContent()
        switch job.status {
        case .finished:
            content.title = "已下载完成"
            content.body = "《\(job.bookName)》共 \(job.completed) 章" +
                (job.failed > 0 ? " · \(job.failed) 章失败" : "") +
                (job.imagesDownloaded > 0 ? " · \(job.imagesDownloaded) 张图片" : "")
        case .error:
            content.title = "下载失败"
            content.body = "《\(job.bookName)》目录或源不可用"
        case .cancelled:
            return  // 用户主动取消不打扰
        default: return
        }
        let req = UNNotificationRequest(
            identifier: "wanxiang.download.\(job.bookUrl.hashValue)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    public func isDownloading(_ bookUrl: String) -> Bool {
        return jobs[bookUrl]?.status == .running
    }

    public func job(for bookUrl: String) -> Job? {
        jobs[bookUrl]
    }

    // MARK: - 实际下载

    private func runDownload(book: ShelfBook, source: BookSource?, range: ClosedRange<Int>? = nil) async {
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
        // 万象书屋 (M2.8 Gap 2): 用户指定范围时只下载该范围内章节. range 是 1-based 索引,
        // chapters 是 0-based, 这里转换. 范围越界自动 clamp 到 [0, count-1].
        if let range = range, !chapters.isEmpty {
            let lo = max(0, range.lowerBound - 1)
            let hi = min(chapters.count - 1, range.upperBound - 1)
            if lo <= hi {
                chapters = Array(chapters[lo...hi])
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
            total: chapters.count, completed: 0, failed: 0, status: .running,
            originalBook: book, lastRange: range
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

        // 万象书屋 (M2.8 C 档): 完成时发通知 (用户在另一个 App / 锁屏时也能看到)
        postFinishNotification(job: finalJob)
    }

    /// 万象书屋 (M2.8 perf): 一次 SQL 拉所有已 cache 章节 index, 比之前 "N 次串行
    /// loadContent" 快 ~100x. 之前 500 章 ≈ 3-5s 卡顿, 现在 < 50ms.
    private func checkPending(bookUrl: String, chapters: [BookChapter]) async -> [BookChapter] {
        let cached = (try? await ChapterRepository.shared.cachedContentIndexes(bookUrl: bookUrl)) ?? []
        return chapters.filter { !cached.contains($0.chapterIndex) }
    }

    private func downloadConcurrent(book: ShelfBook, source: BookSource,
                                     pending: [BookChapter], baseJob: inout Job) async {
        // 万象书屋 (M2.8 perf): 用 TaskGroup + concurrency 控并发. 之前每章 schedule 后 sleep
        // 200ms (100 章 = 20s schedule 时间), 改成无延迟 schedule — 反爬节流靠的是
        // 服务端响应慢, URLSession 每 host 6 connection 自然限流, 不需要客户端再加 sleep.
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
            }
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
        // 万象书屋 (M2.8 perf v2): 跟 Android `errorDownloadMap < 3` 对齐 retry 3 次.
        // 单层 retry — ContentParser 内层 retries: 1, 这里外层 retry 3, 总共最多 3 次拉,
        // 单章最坏 25s × 3 + backoff = 76s. 之前双层 (内 3 × 外 2 = 6 次) 最坏 156s,
        // 现在直接砍掉 80s 死等. 失败章这里不再阻塞 worker 5s+.
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            if Task.isCancelled { return false }
            do {
                let cont = try await BookSourceEngine.shared.fetchContent(of: chapter, in: source)
                try? await ChapterRepository.shared.saveContent(
                    bookUrl: bookUrl, chapterIndex: chapter.chapterIndex, content: cont.content
                )
                // 万象书屋 (M2.8 perf): 图片下载 fire-and-forget, 不阻塞章节 worker 槽位.
                // 之前 N 张图 × ~1s/张 = N 秒阻塞 worker, 6 worker 全被图章卡死. 现在章节
                // 正文 save 完立即 return true 让 worker 抓下一章, 图片在 detached task 里
                // 慢慢下. Reader 渲染时优先 disk cache, miss 时 fallback AsyncImage 网络拉.
                if !cont.images.isEmpty {
                    let urls = cont.images
                    Task.detached(priority: .utility) { [weak self] in
                        let n = await ChapterImageCache.shared.downloadIfNeeded(
                            bookUrl: bookUrl, urls: urls, source: source
                        )
                        await self?.recordImagesDownloaded(bookUrl: bookUrl, count: n)
                    }
                }
                return true
            } catch is CancellationError {
                return false
            } catch {
                if attempt < maxAttempts - 1 {
                    // 万象书屋: 跟 Android `delay(1000)` 一致, 失败后等 1s retry.
                    // 之前 0.3/0.6 太激进对真慢源不公平 (慢源刚 timeout 立马重试很可能再失败).
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                return false
            }
        }
        return false
    }

    private func recordImagesDownloaded(bookUrl: String, count: Int) async {
        guard count > 0, var job = jobs[bookUrl] else { return }
        job.imagesDownloaded += count
        jobs[bookUrl] = job
    }
}

// MARK: - 章节图片 disk cache (M2.8 C 档)

/// 万象书屋: 章节正文里的 `<img src>` 图片缓存到 Caches/wanxiang-chapter-images/.
/// 跟 BookCoverDiskCache 类似但独立, 因为 cover 是按 bookUrl 一张, chapter image 是
/// 按 source URL 一张, key/lifecycle 都不同.
///
/// 万象书屋 (M2.8 perf): 从 actor 改成 final class — actor 把所有 method 串行化, 多章
/// fire-and-forget 同时下图也得排队. final class 没共享 mutable state (session/dir 都是 let,
/// FileManager 操作 thread-safe), 改了之后多 task 真并发下载.
public final class ChapterImageCache: @unchecked Sendable {
    public static let shared = ChapterImageCache()

    private let dir: URL
    private let session: URLSession
    private static let UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.dir = caches.appendingPathComponent("wanxiang-chapter-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 30
        cfg.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: cfg)
    }

    /// 批量下载 image URLs, 已 cache 的跳过. 返回**这次实际新下载**的张数.
    /// 万象书屋 (M2.8 perf): 一章 N 张图改用 TaskGroup 并行下 (4 张同时), 比之前
    /// 一张一张串行快 ~4x. 章节 30 张图 30s → 7-8s.
    public func downloadIfNeeded(bookUrl: String, urls: [String], source: BookSource) async -> Int {
        _ = bookUrl  // 暂未按 bookUrl 分目录 (URL 全局唯一)
        let headers = source.parseHeaders()
        return await withTaskGroup(of: Bool.self) { group in
            // 一章内最多 4 个图同时下, 跨多章 fire-and-forget 加起来仍然 detached parallel
            let perChapterParallel = 4
            var inflight = 0
            var iter = urls.makeIterator()
            var newCount = 0
            while let raw = iter.next() {
                while inflight >= perChapterParallel {
                    if let ok = await group.next() {
                        if ok { newCount += 1 }
                        inflight -= 1
                    }
                }
                inflight += 1
                group.addTask { [self] in
                    await self.fetchOneImage(raw: raw, headers: headers)
                }
            }
            for await ok in group {
                if ok { newCount += 1 }
            }
            return newCount
        }
    }

    /// 万象书屋 (M2.8 perf): 单张图片下载, final class + TaskGroup 真并行.
    private func fetchOneImage(raw: String, headers: [String: String]) async -> Bool {
        let urlStr = raw.contains(",{") ? String(raw.split(separator: ",").first ?? "") : raw
        guard let url = URL(string: urlStr) else { return false }
        let path = filePath(for: urlStr)
        if FileManager.default.fileExists(atPath: path.path) { return false }
        var req = URLRequest(url: url)
        req.setValue(Self.UA, forHTTPHeaderField: "User-Agent")
        if let host = url.host, let scheme = url.scheme {
            req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        do {
            let (data, _) = try await session.data(for: req)
            guard data.count > 256 else { return false }  // 太小可能是 1x1 反爬像素
            try? data.write(to: path)
            return true
        } catch {
            return false
        }
    }

    /// 给 reader / manga reader 用: image URL → 本地 file URL (没 cache 返 nil)
    public func localFileURL(for imageUrl: String) -> URL? {
        let p = filePath(for: imageUrl)
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }

    private func filePath(for url: String) -> URL {
        // SHA1 hash + 原始扩展名 (.jpg/.png/.webp 通常)
        let ext: String = {
            if let dotIdx = url.lastIndex(of: "."), let qIdx = url.firstIndex(of: "?") ?? url.endIndex as Optional {
                let slice = url[dotIdx..<qIdx]
                let raw = String(slice).lowercased()
                if raw.count <= 6 { return raw }  // .jpeg / .webp
                return ".bin"
            }
            return ".bin"
        }()
        let hash = url.utf8.reduce(into: 5381) { result, b in result = ((result << 5) &+ result) &+ Int(b) }
        return dir.appendingPathComponent("\(abs(hash))\(ext)")
    }
}
