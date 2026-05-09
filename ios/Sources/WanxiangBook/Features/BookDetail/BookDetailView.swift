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

    let book: SearchBook
    /// 用于"加书架"时知道是哪个源 (源 URL = book.origin)
    let source: BookSource?

    @StateObject private var vm = BookDetailViewModel()
    @State private var addAlert: String? = nil
    @State private var tocSheet = false

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
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 万象书屋 (P0 fix · D-25):
            //   1) 刷新加架状态 (本来就有)
            //   2) 异步拉 fetchInfo 补齐 intro/kind/lastChapter/wordCount,
            //      避免详情页只能展示 SearchBook 的"摘要级"字段.
            //   3) 拉 toc 拿到章节总数 + 最新章, 给"开始阅读"和书架进度条用.
            await vm.refreshShelfStatus(bookUrl: book.bookUrl)
            await vm.loadDetails(book: book, source: source)
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
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            BookCover(url: displayedCover, width: 100, height: 140)

            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(WanxiangColors.textPrimary)
                Text(book.author)
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
                HStack(spacing: 6) {
                    Text("来源:\(book.originName)")
                        .font(.caption2)
                        .foregroundStyle(WanxiangColors.textSecondary)
                    if vm.isLoadingDetail {
                        ProgressView().scaleEffect(0.6)
                    }
                }
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
                ReaderView(book: shelfBookFromSearch(), source: source)
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
    private func shelfBookFromSearch() -> ShelfBook {
        ShelfBook(
            bookUrl: book.bookUrl,
            name: book.name,
            author: book.author,
            origin: book.origin,
            originName: book.originName,
            coverUrl: book.coverUrl,
            intro: book.intro,
            kind: book.kind,
            tocUrl: book.bookUrl
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
                    Task { await vm.loadDetails(book: book, source: source) }
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
            await vm.remove(bookUrl: book.bookUrl)
            addAlert = "已从书架移除"
        } else {
            await vm.addToShelf(book: book)
            addAlert = "已加入书架"
        }
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
        }
        await loadTask?.value
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
