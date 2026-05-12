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
    // 万象书屋 (UX 2026-05-11): 移除"已加入书架/已从书架移除"alert. 用户反馈"不要弹出这个窗口" —
    // 按钮文案自身已经从「加书架 +」切到「已加书架 ✓」, 视觉反馈足够; 仅加触觉反馈, 不打断阅读流.
    @State private var tocSheet = false
    @State private var changeSourceSheet = false
    /// 万象书屋 (debug arg `--AutoStartReading`): 详情拉完 toc 后自动 push 进 reader,
    /// 给 GUI 自动化测试用 (cliclick 不稳).
    @State private var autoStartReader = false
    /// 万象书屋 (M2.5.5.1 补丁): 详情页里"当前正在用"的 SearchBook / BookSource.
    /// 初始 = 入参; 用户在换源 sheet 里点了候选后 = 候选.
    @State private var currentBook: SearchBook
    @State private var currentSource: BookSource?
    /// 万象书屋 (UX): stub 模式下后台找真源中. 找到后清零, "开始阅读"按钮可点.
    @State private var isResolvingSource = false
    /// 万象书屋 (UX 2026-05-11): stub 模式找源失败 (60 源 + 双关键词全 miss) → 显示失败兜底.
    @State private var resolveFailed = false

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
            // 万象书屋 (UX): 书城 stub 模式 (source=nil + origin 空) — 先后台找真源,
            // 找到后用 onSourceSwitched 走完整 loadDetails 路径.
            if currentSource == nil && currentBook.origin.isEmpty {
                await resolveSourceIfNeeded()
            } else {
                await vm.loadDetails(book: currentBook, source: currentSource)
            }
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
        .sheet(isPresented: $tocSheet) {
            // 复用阅读器的 TocView
            NavigationStack {
                TocView(
                    chapters: vm.chapters,
                    currentIndex: -1,
                    bookUrl: currentBook.bookUrl
                ) { _ in
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
        // 万象书屋 (2026-05-11): VM 在 TOC fallback 成功切换源时, 把新 origin / bookUrl 等
        // 通过 Notification 回推给 view, 同步 currentSource + currentBook @State, 让 UI 头部"来源:xxx"
        // 和阅读按钮 (用的是 currentBook.bookUrl) 都切到能用的源.
        .onReceive(NotificationCenter.default.publisher(for: .bookDetailAltSourceFound)) { note in
            guard let info = note.userInfo,
                  let origin = info["origin"] as? String,
                  let newSrc = BookSourceRegistry.shared.find(origin: origin) else { return }
            currentSource = newSrc
            currentBook.origin = newSrc.bookSourceUrl
            currentBook.originName = (info["originName"] as? String) ?? newSrc.bookSourceName
            if let url = info["bookUrl"] as? String, !url.isEmpty {
                currentBook.bookUrl = url
            }
            if let c = info["coverUrl"] as? String, !c.isEmpty,
               (currentBook.coverUrl?.isEmpty ?? true) {
                currentBook.coverUrl = c
            }
            if let i = info["intro"] as? String, !i.isEmpty,
               (currentBook.intro?.isEmpty ?? true) {
                currentBook.intro = i
            }
            if let l = info["lastChapter"] as? String, !l.isEmpty {
                currentBook.lastChapter = l
            }
            resolveFailed = false
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
            BookCover(url: displayedCover, width: 100, height: 140, bookTitle: currentBook.name)

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
                        Image(systemName: resolveFailed && currentSource == nil
                            ? "exclamationmark.triangle.fill"
                            : "arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(resolveFailed && currentSource == nil
                                ? .orange
                                : WanxiangColors.textSecondary)
                        // 万象书屋 (UX): stub 模式还在找源时, 来源行显示"查找中…",
                        // 让用户知道按钮置灰只是临时, 不需要在主按钮文案里塞这条信息.
                        Text(sourceLineText)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(resolveFailed && currentSource == nil
                                ? .orange
                                : WanxiangColors.textSecondary)
                        if currentBook.distinctOriginCount > 1 {
                            Text("\(currentBook.distinctOriginCount) 源")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(WanxiangColors.primary.opacity(0.18)))
                                .foregroundStyle(WanxiangColors.primary)
                        }
                        if vm.isLoadingDetail || (isResolvingSource && currentSource == nil) {
                            ProgressView().scaleEffect(0.6)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    /// 头部 "来源:..." 行的文案
    private var sourceLineText: String {
        if currentSource != nil {
            return "来源:\(currentBook.originName)"
        }
        if isResolvingSource { return "来源:查找中…" }
        if resolveFailed { return "暂未找到此书源, 点此换源" }
        return "来源:\(currentBook.originName)"
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

            // 万象书屋 (UX 2026-05-11): 找源失败 (resolveFailed=true) 时, "开始阅读"按钮变成
            // 一个直接打开换源 sheet 的入口, 避免用户卡在禁用按钮上不知道怎么继续.
            if resolveFailed && currentSource == nil {
                Button {
                    changeSourceSheet = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("手动选源")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(WanxiangColors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else {
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
                    .background(currentSource == nil
                        ? WanxiangColors.accent.opacity(0.55)
                        : WanxiangColors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(currentSource == nil)
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
            // 万象书屋: 与安卓一致 — 点「下载本书」直接全本开下，不弹范围 sheet / 不借机申请通知权限.
            Button {
                if canDownload { triggerDownload() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                    Text(downloadButtonTitle(chapterCount: chapterCount))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !canDownload {
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
        // 找源进行中 (source==nil) 仍然显示"开始阅读" — 按钮文案不变, 通过 disabled + 半透明
        // 表达不可点; 找源状态用头部 source 行的小 spinner 兜底, 不在主行动按钮里塞过长文案.
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
            // 万象书屋 (M2.8 perf): toc 加载中也立刻给反馈 — 显示 search 阶段已经带过来的
            // lastChapter (最新章名) 让用户感觉详情页第一时间有内容. 之前一片"正在加载目录…"
            // 给人感觉啥都没有.
            HStack(spacing: 12) {
                Image(systemName: "list.bullet")
                    .foregroundStyle(WanxiangColors.primary.opacity(0.6))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("目录")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(WanxiangColors.textPrimary)
                        ProgressView().scaleEffect(0.6)
                    }
                    if let last = currentBook.lastChapter, !last.isEmpty {
                        Text("最新: \(last)")
                            .font(.caption)
                            .foregroundStyle(WanxiangColors.textSecondary)
                            .lineLimit(1)
                    } else {
                        Text("正在加载章节信息…")
                            .font(.caption)
                            .foregroundStyle(WanxiangColors.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(12)
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
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            await vm.addToShelf(book: currentBook)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// 万象书屋 (M2.5.5.1): 用户在换源 sheet 选了新源 → 切换 + 重新拉详情/目录.
    /// 行为对齐 Android `ChangeBookSourceDialog.callBack.changeTo(newSearchBook)`:
    ///   1. 切换 origin / bookUrl / originName / coverUrl 等"显示用"字段
    ///   2. 清掉 vm.info / vm.chapters, 走一次完整 loadDetails
    ///   3. 同步刷加架状态 (新源 bookUrl 在书架里可能不存在)
    /// 万象书屋 (UX 2026-05-11): 书城 stub 模式自动找源 (双关键词并行).
    ///   - 候选池: SourcePerformanceTracker 排序后前 60 (原 12 — 起点原创书在通用源命中率低,
    ///     12 个里全 miss 时用户一直看到 "查找中...", 没有兜底)
    ///   - 两条并发 stream:
    ///       * 流 A: key = name           (常规)
    ///       * 流 B: key = "name 作者"    (作者非空时 — 番茄/晋江/起点系命中率显著更高)
    ///   - 任意一条流先命中 → 取消另一条 → 切源
    ///   - 两条都 drain 完没命中 → 报失败, 让用户走"换源"sheet 手动选
    ///   - 命中后保留 stub 里的 cover/intro/kind (起点封面质量更好), 切到真源 + onSourceSwitched
    private func resolveSourceIfNeeded() async {
        guard currentSource == nil else { return }
        await MainActor.run { isResolvingSource = true }

        let allSources = BookSourceRegistry.shared.sources
        let sorted = SourcePerformanceTracker.shared.sortByScore(allSources)
        let candidates = Array(sorted.prefix(60))
        guard !candidates.isEmpty else {
            await MainActor.run { isResolvingSource = false }
            return
        }

        let bookName = currentBook.name
        let bookAuthor = currentBook.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let stubCover = currentBook.coverUrl
        let stubIntro = currentBook.intro
        let stubKind = currentBook.kind

        // 万象书屋: TaskGroup 同时跑两条 search stream, 各自挑首个 name/author 匹配后回报.
        let result: (SearchBook, BookSource)? = await withTaskGroup(of: (SearchBook, BookSource)?.self) { group in
            // 流 A: 只用书名搜
            group.addTask {
                let stream = await BookSourceEngine.shared.searchAll(
                    in: candidates, key: bookName,
                    maxConcurrency: 10, perSourceTimeoutSec: 8
                )
                for await (src, r) in stream {
                    if Task.isCancelled { return nil }
                    guard case .success(let books) = r else { continue }
                    if let match = books.first(where: {
                        $0.name == bookName && (bookAuthor.isEmpty || $0.author == bookAuthor)
                    }) {
                        return (match, src)
                    }
                }
                return nil
            }
            // 流 B: 书名 + 作者, 作者非空时才跑
            if !bookAuthor.isEmpty {
                group.addTask {
                    let combined = "\(bookName) \(bookAuthor)"
                    let stream = await BookSourceEngine.shared.searchAll(
                        in: candidates, key: combined,
                        maxConcurrency: 10, perSourceTimeoutSec: 8
                    )
                    for await (src, r) in stream {
                        if Task.isCancelled { return nil }
                        guard case .success(let books) = r else { continue }
                        if let match = books.first(where: {
                            $0.name == bookName && (bookAuthor.isEmpty || $0.author == bookAuthor)
                        }) {
                            return (match, src)
                        }
                    }
                    return nil
                }
            }
            // 任一流先返非 nil → 拿到; 取消所有其他流
            for await r in group {
                if let r = r {
                    group.cancelAll()
                    return r
                }
            }
            return nil
        }

        if let (match, src) = result {
            var merged = match
            if merged.coverUrl?.isEmpty != false, let c = stubCover, !c.isEmpty {
                merged.coverUrl = c
            }
            if merged.intro?.isEmpty != false, let i = stubIntro, !i.isEmpty {
                merged.intro = i
            }
            if merged.kind?.isEmpty != false, let k = stubKind, !k.isEmpty {
                merged.kind = k
            }
            await onSourceSwitched(to: merged, source: src)
            await MainActor.run { isResolvingSource = false }
        } else {
            // 60 源 × 双关键词 都 miss → 失败. 让 UI 显示"未找到源, 试试换源" + 可点的换源入口.
            await MainActor.run {
                isResolvingSource = false
                resolveFailed = true
            }
        }
    }

    private func onSourceSwitched(to newBook: SearchBook, source newSource: BookSource) async {
        // 把合并源信息 (mergedSourceURLs / mergedSourceNames) 透传过来,
        // 用户切到 B 源后, 头部 "N 源" 角标仍然能看到一共还有几个源.
        var b = newBook
        b.mergedSourceURLs = currentBook.mergedSourceURLs
        b.mergedSourceNames = currentBook.mergedSourceNames
        currentBook = b
        currentSource = newSource
        // 万象书屋: 用户在换源 sheet 选了一个源, 或自动解析成功 → 清除 stub 失败状态.
        resolveFailed = false
        vm.resetForSourceSwitch()
        await vm.refreshShelfStatus(bookUrl: b.bookUrl)
        await vm.loadDetails(book: b, source: newSource)
    }
}

extension Notification.Name {
    /// 万象书屋: BookDetailView 用 mergedSourceURLs 兜底拉 TOC 成功后, viewModel 发这个通知,
    /// 让 BookDetailView 的 @State currentSource 同步切到 alt 源. userInfo["origin"] = 新源 URL.
    static let bookDetailAltSourceFound = Notification.Name("wanxiang.bookDetail.altSourceFound")
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

    /// 万象书屋 (P0 fix · D-25): 拉详情 + 拉目录, 让详情页不再"只用 SearchBook 的浅信息".
    /// 万象书屋 (M2.8 perf): fetchInfo + fetchToc 改并行, 之前串行用户等两个网络完成才能
    /// 点"开始阅读" (~4-6s), 现在两个同时发 (~2-3s) 进 reader 路径快一倍.
    func loadDetails(book: SearchBook, source: BookSource?) async {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }

            self.isLoadingDetail = source != nil
            self.isLoadingToc = true
            self.infoError = nil
            self.tocError = nil

            // Step A: SQLite toc cache 优先 — 已加架 / 之前打开过的书 0.05s 命中
            if let cached = try? await ChapterRepository.shared.loadToc(bookUrl: book.bookUrl),
               !cached.isEmpty {
                if Task.isCancelled { return }
                self.chapters = cached
                self.isLoadingToc = false
            }

            // Step B: 顺序拉 fetchInfo → fetchToc(用 info.tocUrl).
            //
            // 万象书屋 (2026-05-11 critical fix): 之前并行拉 fetchInfo + fetchToc(tocUrl=bookUrl)
            // — 对很多源 (例: 晴天小说5.0 的 tocUrl 模板 `/catalog?book_id={{$.book_id}}...`)
            // 用 bookUrl 当 tocUrl 是错的端点, 永远拉不到 → 详情页"目录加载失败".
            // 改成 Android `WebBook.getChapterListAwait` 一样的语义:
            //   1. fetchInfo 先把 ruleBookInfo.tocUrl 模板渲染成真 tocUrl
            //   2. fetchToc 用 info.tocUrl 拉真目录
            // 性能代价: 串行 1+1 ~ 3-5s (并行 ~2-3s). 但正确性 / 跟 Android 一致是头等优先级.
            let cacheHit = !self.chapters.isEmpty
            var detail: BookInfo? = nil
            if let s = source {
                detail = try? await BookSourceEngine.shared.fetchInfo(of: book, in: s)
            }
            if Task.isCancelled { return }
            self.info = detail
            if detail == nil, source != nil {
                self.infoError = "详情加载失败"
            }
            self.isLoadingDetail = false

            var fetchedToc: [BookChapter]? = nil
            if !cacheHit, let s = source {
                // 用 fetchInfo 解出来的真 BookInfo (含真 tocUrl); fetchInfo 失败时 fallback 到
                // search 数据 + bookUrl 当 tocUrl (这种 fallback 适配 ruleBookInfo.tocUrl 为空的源)
                let infoForToc = detail ?? BookInfo(
                    bookUrl: book.bookUrl, name: book.name, author: book.author,
                    intro: book.intro, kind: book.kind, coverUrl: book.coverUrl,
                    tocUrl: book.bookUrl, lastChapter: book.lastChapter,
                    updateTime: book.updateTime, wordCount: book.wordCount
                )
                fetchedToc = try? await BookSourceEngine.shared.fetchToc(of: infoForToc, in: s)
            }
            if Task.isCancelled { return }
            if let toc = fetchedToc, !toc.isEmpty {
                self.chapters = toc
                let bookUrl = book.bookUrl
                Task.detached(priority: .utility) {
                    try? await ChapterRepository.shared.saveToc(bookUrl: bookUrl, chapters: toc)
                }
            } else if self.chapters.isEmpty {
                // TOC 失败 → 用 SearchVariantsCache 里的其它源变体兜底, 每个变体都走完整
                // fetchInfo → fetchToc 链路.
                let altSwitched = await self.tryAlternativeSources(
                    forBook: book, source: source
                )
                if !altSwitched, self.chapters.isEmpty {
                    self.tocError = "目录加载失败"
                }
            }
            self.isLoadingToc = false

            // Step C: 后台预拉用户即将打开的章节正文
            //   用户停留详情页 1-3s, 期间 prefetch 一章 ~ 1-2s, 点"开始阅读"时已经在 SQLite.
            //   ReaderEngine.bootstrap 命中 cache 秒开.
            await self.prefetchTargetChapterContent(book: book, source: source)
        }
        await loadTask?.value
    }

    /// 万象书屋 (2026-05-11 真修): TOC 失败时, 用搜索时记录的"同书所有源变体"依次试.
    /// **每个变体用它自己的 bookUrl**, 不再跨源用主 row 的 bookUrl (那样备用源永远拉不到 TOC).
    /// 命中第一个能拉 TOC 的就切过去 (写 currentBook/currentSource + 后台落盘).
    ///
    /// - returns: true 表示找到了能用的源已切; false 表示全部 alt 也失败.
    @MainActor
    private func tryAlternativeSources(forBook book: SearchBook, source failedSource: BookSource?) async -> Bool {
        let dk = book.dedupeKey
        let allVariants = SearchVariantsCache.shared.get(key: dk)
        guard !allVariants.isEmpty else { return false }

        let failedUrl = failedSource?.bookSourceUrl ?? ""
        let failedBookUrl = book.bookUrl

        // 万象书屋: 过滤掉已经失败过的源 (主源 + 同 bookUrl 的同 origin); 剩下的按 SourcePerformanceTracker
        // 历史响应分降序试, 命中率最高的优先.
        let stats = SourcePerformanceTracker.shared.allStats()
        let candidates = allVariants
            .filter { v in
                if v.origin == failedUrl && v.bookUrl == failedBookUrl { return false }
                return BookSourceRegistry.shared.find(origin: v.origin) != nil
            }
            .sorted { lhs, rhs in
                let ls = stats[lhs.origin]?.score ?? 50
                let rs = stats[rhs.origin]?.score ?? 50
                return ls > rs
            }

        for variant in candidates {
            if Task.isCancelled { return false }
            guard let altSrc = BookSourceRegistry.shared.find(origin: variant.origin) else { continue }
            // 万象书屋 (2026-05-11 critical fix): 先 fetchInfo 把 ruleBookInfo.tocUrl 模板
            // 渲染成真 tocUrl, 再 fetchToc — 否则用 variant.bookUrl 当 tocUrl 调多数源会失败.
            let altInfo = (try? await BookSourceEngine.shared.fetchInfo(of: variant, in: altSrc))
                ?? BookInfo(
                    bookUrl: variant.bookUrl, name: variant.name, author: variant.author,
                    intro: variant.intro, kind: variant.kind, coverUrl: variant.coverUrl,
                    tocUrl: variant.bookUrl, lastChapter: variant.lastChapter,
                    updateTime: variant.updateTime, wordCount: variant.wordCount
                )
            let toc = (try? await BookSourceEngine.shared.fetchToc(of: altInfo, in: altSrc)) ?? []
            if !toc.isEmpty {
                if Task.isCancelled { return false }
                self.chapters = toc
                // 注意 saveToc 用**变体的 bookUrl** (跟 reader / ChapterRepository 后续读取一致),
                // 不是主 row 的. ReaderEngine 通过 ShelfBook.bookUrl 找 chapters.
                let altBookUrl = variant.bookUrl
                Task.detached(priority: .utility) {
                    try? await ChapterRepository.shared.saveToc(bookUrl: altBookUrl, chapters: toc)
                }
                // 通知 View 同步 currentSource + currentBook (新 bookUrl/origin/originName).
                NotificationCenter.default.post(
                    name: .bookDetailAltSourceFound,
                    object: nil,
                    userInfo: [
                        "origin": altSrc.bookSourceUrl,
                        "originName": altSrc.bookSourceName,
                        "bookUrl": variant.bookUrl,
                        "coverUrl": variant.coverUrl ?? "",
                        "intro": variant.intro ?? "",
                        "lastChapter": variant.lastChapter ?? ""
                    ]
                )
                return true
            }
        }
        return false
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
