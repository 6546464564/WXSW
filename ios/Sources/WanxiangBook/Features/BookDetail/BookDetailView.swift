//
//  BookDetailView.swift
//  万象书屋 iOS · 书籍详情页 (M2.4.8)
//
//  对应 Android: io.legado.app.ui.book.info.BookInfoActivity
//
//  M2.4.8 阶段交付:
//   - 封面 + 书名 + 作者 + 分类 + 简介 + 来源
//   - "加书架" / "已加书架" 按钮 (写入 BookshelfRepository)
//   - 占位的 "开始阅读" / "目录" 按钮 (M2.5 阅读器接)
//
//  待补 (M2 后续):
//   - 真实拉详情 (BookSourceEngine.fetchInfo) — 当前用 SearchBook 的字段就够展示
//   - 目录列表 (M2.4.x)
//   - 换源 ChangeBookSourceDialog (M2.5.5.1)
//

import SwiftUI

struct BookDetailView: View {

    /// 万象书屋: 入参的 book / source 是"初始展示用". 用户在详情页按"换源"切换后,
    /// 当前正在用的源会切到 `currentBook` / `currentSource`, 重新拉详情 + 目录.
    let book: SearchBook
    /// 用于"加书架"时知道是哪个源 (源 URL = book.origin)
    let source: BookSource?

    @StateObject private var vm = BookDetailViewModel()
    @StateObject private var downloader = BookDownloader.shared
    @State private var addAlert: String? = nil
    @State private var tocSheet = false
    @State private var changeSourceSheet = false
    /// 万象书屋 (debug arg `--AutoStartReading`): 详情拉完 toc 后自动 push 进 reader,
    /// 给 GUI 自动化测试用 (cliclick 不稳).
    @State private var autoStartReader = false
    /// 万象书屋 (M2.8 Gap 2): 章节范围下载 sheet
    @State private var downloadRangeSheet = false
    /// 万象书屋 (M2.5.5.1 补丁): 详情页里"当前正在用"的 SearchBook / BookSource.
    /// 初始 = 入参; 用户在换源 sheet 里点了候选后 = 候选.
    @State private var currentBook: SearchBook
    @State private var currentSource: BookSource?

    init(book: SearchBook, source: BookSource?) {
        self.book = book
        self.source = source
        self._currentBook = State(initialValue: book)
        self._currentSource = State(initialValue: source)
    }

    /// 万象书屋: SearchBook 字段优先用 fetchInfo 拿到的真实详情, 没拿到时 fallback
    private var displayedIntro: String {
        let fromInfo = vm.info?.intro?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromInfo.isEmpty { return fromInfo }
        return book.intro?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var displayedKind: String {
        let fromInfo = vm.info?.kind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fromInfo.isEmpty { return fromInfo }
        return book.kind ?? ""
    }
    private var displayedCover: String? {
        if let c = vm.info?.coverUrl, !c.isEmpty { return c }
        return book.coverUrl
    }
    private var displayedLastChapter: String? {
        if let l = vm.info?.lastChapter, !l.isEmpty { return l }
        return book.lastChapter
    }
    private var displayedUpdateTime: String? {
        if let u = vm.info?.updateTime, !u.isEmpty { return u }
        return book.updateTime
    }
    private var displayedWordCount: String? {
        if let w = vm.info?.wordCount, !w.isEmpty { return w }
        return book.wordCount
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionRow
                downloadRow
                if !displayedIntro.isEmpty {
                    introBlock(displayedIntro)
                }
                metaBlock
                tocPreview
                Spacer().frame(height: 40)
            }
            .padding()
        }
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle(currentBook.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    changeSourceSheet = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .accessibilityLabel("换源")
            }
        }
        .task {
            // 万象书屋 (P0 fix · D-25):
            //   1) 刷新加架状态 (本来就有)
            //   2) 异步拉 fetchInfo 补齐 intro/kind/lastChapter/wordCount,
            //      避免详情页只能展示 SearchBook 的"摘要级"字段.
            //   3) 拉 toc 拿到章节总数 + 最新章, 给"开始阅读"和书架进度条用.
            await vm.refreshShelfStatus(bookUrl: currentBook.bookUrl)
            await vm.loadDetails(book: currentBook, source: currentSource)
            // 万象书屋 (debug arg `--AutoChangeSource`): 进详情页后立即弹换源 sheet,
            // 给外部 GUI 自动化做演示用.
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--AutoChangeSource") || args.contains("-AutoChangeSource") {
                try? await Task.sleep(nanoseconds: 800_000_000)
                changeSourceSheet = true
            }
            // 万象书屋 (debug arg `--AutoStartReading`): 详情拉完后自动 push 进 reader.
            if args.contains("--AutoStartReading") || args.contains("-AutoStartReading") {
                try? await Task.sleep(nanoseconds: 600_000_000)
                autoStartReader = true
            }
        }
        .alert(item: Binding(
            get: { addAlert.map { AlertText(text: $0) } },
            set: { _ in addAlert = nil })
        ) { item in
            Alert(title: Text(item.text))
        }
        .sheet(isPresented: $tocSheet) {
            // 复用阅读器的 TocView
            NavigationStack {
                TocView(chapters: vm.chapters, currentIndex: -1) { _ in
                    tocSheet = false
                }
                .navigationTitle("目录 (\(vm.chapters.count))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("关闭") { tocSheet = false }
                    }
                }
            }
        }
        .sheet(isPresented: $changeSourceSheet) {
            ChangeSourceView(searchBook: currentBook) { newBook, newSource in
                Task { await onSourceSwitched(to: newBook, source: newSource) }
            }
        }
        // 万象书屋 (M2.8 Gap 2): 章节范围下载 sheet
        .sheet(isPresented: $downloadRangeSheet) {
            DownloadRangeSheet(
                bookName: currentBook.name,
                totalChapters: vm.chapters.count,
                currentChapter: vm.shelfDurChapterIndex >= 0 ? vm.shelfDurChapterIndex + 1 : nil
            ) { range in
                downloader.startDownload(
                    book: shelfBookFromSearch(),
                    source: currentSource,
                    range: range
                )
            }
        }
        // 万象书屋 (debug arg `--AutoStartReading`): 让 autoStartReader 触发 push reader.
        // 这是 NavigationLink 的姐妹形式, 共用同一个 destination 让自动化路径跟用户路径完全等价.
        .navigationDestination(isPresented: $autoStartReader) {
            ReaderView(book: shelfBookFromSearch(), source: currentSource)
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            BookCover(url: displayedCover, width: 100, height: 140)

            VStack(alignment: .leading, spacing: 6) {
                Text(currentBook.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(WanxiangColors.textPrimary)
                Text(currentBook.author)
                    .font(.subheadline)
                    .foregroundStyle(WanxiangColors.textSecondary)
                if !displayedKind.isEmpty {
                    Text(displayedKind)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(WanxiangColors.primary.opacity(0.15))
                        .foregroundStyle(WanxiangColors.primary)
                        .clipShape(Capsule())
                }
                Spacer(minLength: 4)
                // 万象书屋 (M2.5.5.1): 来源行做成可点的胶囊, 显示当前源 + 合并源数,
                // 一秒就能看出"这本书一共几个源, 现在用的是哪个", 点开就能换.
                Button {
                    changeSourceSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                        Text("来源:\(currentBook.originName)")
                            .font(.caption2)
                            .lineLimit(1)
                        if currentBook.distinctOriginCount > 1 {
                            Text("\(currentBook.distinctOriginCount) 源")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(WanxiangColors.primary.opacity(0.18)))
                                .foregroundStyle(WanxiangColors.primary)
                        }
                        if vm.isLoadingDetail {
                            ProgressView().scaleEffect(0.6)
                        }
                    }
                    .foregroundStyle(WanxiangColors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await onAddOrRemove() }
            } label: {
                HStack {
                    Image(systemName: vm.isInShelf ? "checkmark" : "plus")
                    Text(vm.isInShelf ? "已加书架" : "加书架")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(vm.isInShelf ? WanxiangColors.divider : WanxiangColors.primary)
                .foregroundStyle(vm.isInShelf ? WanxiangColors.textPrimary : .white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(vm.isWorking)

            NavigationLink {
                // 万象书屋 (P0 fix · D-25):
                //   ReaderView 内部 bootstrap 会自动 ensure 书在书架, 这里不再
                //   依赖详情页先点"加书架". 直接进阅读 = 隐式加架.
                // 万象书屋 (M2.5.5.1): 用 `currentBook` / `currentSource` (换源后已切换)
                ReaderView(book: shelfBookFromSearch(), source: currentSource)
            } label: {
                HStack {
                    Image(systemName: "book.fill")
                    Text(readActionTitle)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(WanxiangColors.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// 万象书屋 (M2.8 详情页下载): 让用户搜索完直接在详情页一键下载本书.
    /// - 不依赖"先加书架"; 因为 ReaderEngine bootstrap 已经做了隐式加架, 这里也走相同心智模型.
    /// - 下载中显示进度条 + 取消; 完成后切到"已下载"; 失败提供"重试".
    /// - 章节正文持久化在 ChapterRepository (SQLite) — 跟"本地不保存源"政策不矛盾, 因为存的是**内容**而非源.
    @ViewBuilder
    private var downloadRow: some View {
        let job = downloader.job(for: currentBook.bookUrl)
        let chapterCount = vm.chapters.count
        let canDownload = chapterCount > 0 && currentSource != nil

        if let job = job, job.status == .running {
            // 下载中: 进度条 + 取消按钮
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(WanxiangColors.primary)
                        Text("下载中 \(job.completed + job.failed) / \(job.total)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(job.progress * 100))%")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(WanxiangColors.textSecondary)
                    }
                    ProgressView(value: job.progress)
                        .tint(WanxiangColors.primary)
                }
                Button {
                    downloader.cancel(bookUrl: currentBook.bookUrl)
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(WanxiangColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if let job = job, job.status == .finished {
            // 已下载: 简短提示
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("已下载 \(job.completed)/\(job.total) 章")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WanxiangColors.textPrimary)
                if job.failed > 0 {
                    Text("\(job.failed) 章失败")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("重新下载") {
                    triggerDownload()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(WanxiangColors.primary)
            }
            .padding(12)
            .background(WanxiangColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if let job = job, job.status == .error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("下载失败")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("重试") { triggerDownload() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WanxiangColors.primary)
            }
            .padding(12)
            .background(WanxiangColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            // 万象书屋 (M2.8 fix UX): 跟 Android BaseReadBookActivity.showDownloadDialog 一致 —
            // 点"下载本书"**先弹范围 sheet** 让用户选起止章再确认下载, 不再短按立即整本下.
            // 用户反馈: "我下载要我主动点击下载, 而不是不问我过就下载".
            Button {
                if canDownload { downloadRangeSheet = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                    Text(downloadButtonTitle(chapterCount: chapterCount))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if canDownload {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(WanxiangColors.primary.opacity(0.6))
                    } else {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .padding(.vertical, 11).padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .background(canDownload ? WanxiangColors.card : WanxiangColors.divider.opacity(0.4))
                .foregroundStyle(canDownload ? WanxiangColors.primary : WanxiangColors.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(!canDownload)
        }
    }

    private func downloadButtonTitle(chapterCount: Int) -> String {
        if currentSource == nil { return "等待源加载…" }
        if chapterCount == 0 { return "等待目录加载…" }
        return "下载本书 (\(chapterCount) 章)"
    }

    private func triggerDownload() {
        downloader.startDownload(book: shelfBookFromSearch(), source: currentSource)
    }

    private var tocSubtitle: String {
        let count = vm.chapters.count
        if let last = vm.chapters.last?.title, !last.isEmpty {
            return "共 \(count) 章 · \(last)"
        }
        return "共 \(count) 章"
    }

    private var readActionTitle: String {
        // 万象书屋: 已加架且有进度 → "继续阅读 X/N"; 否则 → "开始阅读"
        if vm.isInShelf, vm.shelfDurChapterIndex >= 0, vm.chapters.count > 0 {
            let cur = min(vm.shelfDurChapterIndex + 1, vm.chapters.count)
            return "继续阅读 \(cur)/\(vm.chapters.count)"
        }
        return "开始阅读"
    }

    /// 从 SearchBook 构造一个 ShelfBook (用于阅读器入参)
    /// 万象书屋 (M2.5.5.1): 始终使用 `currentBook` (换源后已切换), 不要回退到入参 `book`,
    /// 否则用户换了源点"开始阅读"还会用旧源拉章节.
    private func shelfBookFromSearch() -> ShelfBook {
        ShelfBook(
            bookUrl: currentBook.bookUrl,
            name: currentBook.name,
            author: currentBook.author,
            origin: currentBook.origin,
            originName: currentBook.originName,
            coverUrl: currentBook.coverUrl,
            intro: currentBook.intro,
            kind: currentBook.kind,
            tocUrl: currentBook.bookUrl
        )
    }

    private func introBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("简介")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WanxiangColors.textPrimary)
            Text(text)
                .font(.body)
                .foregroundStyle(WanxiangColors.textPrimary)
                .lineSpacing(4)
        }
    }

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let last = displayedLastChapter, !last.isEmpty {
                metaLine(label: "最新章节", value: last)
            }
            if let upd = displayedUpdateTime, !upd.isEmpty {
                metaLine(label: "更新时间", value: upd)
            }
            if let wc = displayedWordCount, !wc.isEmpty {
                metaLine(label: "字数", value: wc)
            }
        }
    }

    /// 万象书屋 (P0 fix · D-25): 详情页直接展示总章节数 + 入口看完整目录
    @ViewBuilder
    private var tocPreview: some View {
        if !vm.chapters.isEmpty {
            Button {
                tocSheet = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(WanxiangColors.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("目录")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WanxiangColors.textPrimary)
                        Text(tocSubtitle)
                            .font(.caption)
                            .foregroundStyle(WanxiangColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WanxiangColors.textSecondary)
                }
                .padding(12)
                .background(WanxiangColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        } else if vm.isLoadingToc {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("正在加载目录…")
                    .font(.caption)
                    .foregroundStyle(WanxiangColors.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(WanxiangColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if vm.tocError != nil {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("目录加载失败")
                    .font(.caption)
                    .foregroundStyle(WanxiangColors.textSecondary)
                Spacer()
                Button("重试") {
                    Task { await vm.loadDetails(book: currentBook, source: currentSource) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(WanxiangColors.primary)
            }
            .padding(12)
            .background(WanxiangColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func metaLine(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(WanxiangColors.textSecondary)
            Text(value).font(.caption).foregroundStyle(WanxiangColors.textPrimary)
        }
    }

    // MARK: - 业务

    private func onAddOrRemove() async {
        if vm.isInShelf {
            await vm.remove(bookUrl: currentBook.bookUrl)
            addAlert = "已从书架移除"
        } else {
            await vm.addToShelf(book: currentBook)
            addAlert = "已加入书架"
        }
    }

    /// 万象书屋 (M2.5.5.1): 用户在换源 sheet 选了新源 → 切换 + 重新拉详情/目录.
    /// 行为对齐 Android `ChangeBookSourceDialog.callBack.changeTo(newSearchBook)`:
    ///   1. 切换 origin / bookUrl / originName / coverUrl 等"显示用"字段
    ///   2. 清掉 vm.info / vm.chapters, 走一次完整 loadDetails
    ///   3. 同步刷加架状态 (新源 bookUrl 在书架里可能不存在)
    private func onSourceSwitched(to newBook: SearchBook, source newSource: BookSource) async {
        // 把合并源信息 (mergedSourceURLs / mergedSourceNames) 透传过来,
        // 用户切到 B 源后, 头部 "N 源" 角标仍然能看到一共还有几个源.
        var b = newBook
        b.mergedSourceURLs = currentBook.mergedSourceURLs
        b.mergedSourceNames = currentBook.mergedSourceNames
        currentBook = b
        currentSource = newSource
        vm.resetForSourceSwitch()
        await vm.refreshShelfStatus(bookUrl: b.bookUrl)
        await vm.loadDetails(book: b, source: newSource)
    }
}

private struct AlertText: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
final class BookDetailViewModel: ObservableObject {

    @Published var isInShelf = false
    @Published var isWorking = false

    /// 万象书屋 (P0 fix · D-25): 真实的详情/目录数据
    @Published var info: BookInfo? = nil
    @Published var chapters: [BookChapter] = []
    @Published var isLoadingDetail = false
    @Published var isLoadingToc = false
    @Published var infoError: String? = nil
    @Published var tocError: String? = nil
    /// 书架中的当前阅读章节索引 (-1 = 未在书架 / 未读)
    @Published var shelfDurChapterIndex: Int = -1

    private var loadTask: Task<Void, Never>? = nil

    func refreshShelfStatus(bookUrl: String) async {
        let shelf = (try? await BookshelfRepository.shared.get(bookUrl: bookUrl))
        isInShelf = shelf != nil
        shelfDurChapterIndex = shelf?.durChapterIndex ?? -1
    }

    /// 万象书屋 (M2.5.5.1): 换源时把上一份源的详情/目录数据彻底清掉, 防止 UI 闪一下旧数据.
    func resetForSourceSwitch() {
        loadTask?.cancel()
        info = nil
        chapters = []
        infoError = nil
        tocError = nil
        isLoadingDetail = false
        isLoadingToc = false
    }

    /// 万象书屋 (P0 fix · D-25): 拉详情 + 拉目录, 让详情页不再"只用 SearchBook 的浅信息"
    func loadDetails(book: SearchBook, source: BookSource?) async {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            // Step 1: fetchInfo (有源才能拉; 无源只 fallback SearchBook)
            if let s = source {
                self.isLoadingDetail = true
                self.infoError = nil
                do {
                    let detail = try await BookSourceEngine.shared.fetchInfo(of: book, in: s)
                    if Task.isCancelled { return }
                    self.info = detail
                } catch {
                    if Task.isCancelled { return }
                    self.infoError = error.localizedDescription
                }
                self.isLoadingDetail = false
            }
            // Step 2: 拉 toc — 优先看 SQLite cache, 没就调源
            if Task.isCancelled { return }
            self.isLoadingToc = true
            self.tocError = nil
            do {
                let cached = try await ChapterRepository.shared.loadToc(bookUrl: book.bookUrl)
                if !cached.isEmpty {
                    self.chapters = cached
                } else if let s = source {
                    let infoForToc = self.info ?? BookInfo(
                        bookUrl: book.bookUrl, name: book.name, author: book.author,
                        intro: book.intro, kind: book.kind, coverUrl: book.coverUrl,
                        tocUrl: book.bookUrl, lastChapter: book.lastChapter,
                        updateTime: book.updateTime, wordCount: book.wordCount
                    )
                    let toc = try await BookSourceEngine.shared.fetchToc(of: infoForToc, in: s)
                    if Task.isCancelled { return }
                    try? await ChapterRepository.shared.saveToc(bookUrl: book.bookUrl, chapters: toc)
                    self.chapters = toc
                }
            } catch {
                if Task.isCancelled { return }
                self.tocError = error.localizedDescription
            }
            self.isLoadingToc = false

            // 万象书屋 (M2.6 perf): 详情页拉到 toc 后, 后台默默预拉用户即将打开的章节正文.
            // 用户在详情页一般停留 1-3 秒看简介, 这段时间足够拉一章 content (1-2 秒).
            // 用户点"开始阅读" → ReaderEngine 走 SQLite cache hit 秒开 (0 网络).
            // 跟 Android `BookInfoActivity` 不同 — Android 靠 `ReadBook` 全局单例 + 三章
            // 并发 cover, iOS 没单例, 用预拉 cache 达到等价"秒开"效果.
            await self.prefetchTargetChapterContent(book: book, source: source)
        }
        await loadTask?.value
    }

    /// 后台预拉用户即将打开的章节正文 (durChapterIndex, 默认 0).
    /// 写 ChapterRepository SQLite, 后续 ReaderEngine.loadChapter 直接 cache hit.
    private func prefetchTargetChapterContent(book: SearchBook, source: BookSource?) async {
        guard let s = source, !chapters.isEmpty else { return }
        let targetIdx = max(0, min(shelfDurChapterIndex, chapters.count - 1))
        // 已经 cache 了就跳过
        if let cached = try? await ChapterRepository.shared.loadContent(
            bookUrl: book.bookUrl, chapterIndex: targetIdx
        ), cached != nil {
            return
        }
        guard targetIdx >= 0, targetIdx < chapters.count else { return }
        let chapter = chapters[targetIdx]
        // detached + utility prio: 不抢主路径资源, 拉到也不更新 UI (写 SQLite 即可).
        let bookUrl = book.bookUrl
        Task.detached(priority: .utility) {
            do {
                let cont = try await BookSourceEngine.shared.fetchContent(of: chapter, in: s)
                try? await ChapterRepository.shared.saveContent(
                    bookUrl: bookUrl, chapterIndex: targetIdx, content: cont.content
                )
            } catch {
                // 预拉失败无所谓, 用户真点开始阅读时会再拉一次
            }
        }
    }

    func addToShelf(book: SearchBook) async {
        isWorking = true
        defer { isWorking = false }
        let shelf = ShelfBook(
            bookUrl: book.bookUrl,
            name: book.name,
            author: book.author,
            origin: book.origin,
            originName: book.originName,
            coverUrl: info?.coverUrl ?? book.coverUrl,
            intro: info?.intro ?? book.intro,
            kind: info?.kind ?? book.kind,
            tocUrl: info?.tocUrl ?? book.bookUrl
        )
        try? await BookshelfRepository.shared.add(shelf)
        // 已经知道章节数, 顺便回写 totalChapterNum
        if !chapters.isEmpty {
            try? await BookshelfRepository.shared.updateTotalChapters(
                bookUrl: book.bookUrl,
                total: chapters.count,
                latestTitle: chapters.last?.title
            )
        }
        isInShelf = true
    }

    func remove(bookUrl: String) async {
        isWorking = true
        defer { isWorking = false }
        try? await BookshelfRepository.shared.remove(bookUrl: bookUrl)
        isInShelf = false
        shelfDurChapterIndex = -1
    }
}
