//
//  ChangeChapterSourceView.swift
//  万象书屋 iOS · 本章换源 (1:1 对齐 Android ChangeChapterSourceDialog)
//
//  对应 Android: io.legado.app.ui.book.changesource.ChangeChapterSourceDialog
//  - 共用 ChangeSourceViewModel + ChangeSourceCandidateRow + SourceScoreStore
//  - 整体 toolbar / 底栏 / 二次过滤 / 分组 / 加载字数 toggle 跟整书换源完全一致
//  - 唯一区别: row 点击不切整书源, 而是 push 进 `AlternateChapterPickScreen`
//    展示异源目录, 用户选某一节 → 拉正文 → onReplaceChapterBody 回写当前章.
//

import SwiftUI

public struct ChangeChapterSourceView: View {

    public let target: ChangeSourceView.Target
    public let chapterIndex: Int
    public let chapterTitle: String?
    public let onReplaceChapterBody: (String) -> Void

    @StateObject private var vm = ChangeSourceViewModel()
    @StateObject private var scoreStore = SourceScoreStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()
    @State private var screenFieldVisible: Bool = false
    @State private var scrollToken: UUID = UUID()
    @State private var jumpEdgeToken: JumpToken = JumpToken(kind: .none)

    public init(
        target: ChangeSourceView.Target,
        chapterIndex: Int,
        chapterTitle: String?,
        onReplaceChapterBody: @escaping (String) -> Void
    ) {
        self.target = target
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.onReplaceChapterBody = onReplaceChapterBody
    }

    public init(
        originalBook: ShelfBook,
        chapterIndex: Int,
        chapterTitle: String?,
        onReplaceChapterBody: @escaping (String) -> Void
    ) {
        self.init(
            target: ChangeSourceView.Target(
                name: originalBook.name,
                author: originalBook.author,
                currentOrigin: originalBook.origin
            ),
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            onReplaceChapterBody: onReplaceChapterBody
        )
    }

    public var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                headerBar
                if screenFieldVisible { screenField }
                Divider()
                candidatesList
                Divider()
                bottomBar
            }
            .navigationTitle("本章换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: AlternatePickAnchor.self) { anchor in
                AlternateChapterPickScreen(
                    anchor: anchor,
                    readerChapterIndex: chapterIndex,
                    readerChapterTitle: chapterTitle,
                    onReplaceChapterBody: { body in
                        onReplaceChapterBody(body)
                        dismiss()
                    }
                )
            }
            .task {
                if vm.candidates.isEmpty {
                    await vm.startSearch(target: target)
                }
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.subheadline.weight(.semibold))
                if let t = chapterTitle, !t.isEmpty {
                    Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(target.author).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if vm.isSearching {
                ProgressView().scaleEffect(0.75)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var screenField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("按源名 / 作者 / 最新章过滤候选", text: $vm.screenFilter)
                .textFieldStyle(.plain)
                .submitLabel(.search)
            if !vm.screenFilter.isEmpty {
                Button { vm.screenFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(WanxiangColors.card)
    }

    // MARK: - Candidates list

    private var candidatesList: some View {
        let display = vm.displayCandidates(score: { scoreStore.score(for: $0) })
        return Group {
            if display.isEmpty && !vm.isSearching {
                VStack(spacing: 6) {
                    Spacer()
                    Text(emptyStateText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        Section {
                            ForEach(display, id: \.book.bookUrl) { item in
                                Button {
                                    guard let source = vm.sourceFor(origin: item.book.origin) else { return }
                                    path.append(AlternatePickAnchor(book: item.book, source: source))
                                } label: {
                                    ChangeSourceCandidateRow(
                                        candidate: item,
                                        isCurrent: target.currentOrigin == item.book.origin,
                                        showWordCountAndRespond: vm.showWordCountAndRespond,
                                        onTop: { vm.topSource(item) },
                                        onBottom: { vm.bottomSource(item) },
                                        onScoreChanged: { newScore in
                                            scoreStore.set(score: newScore, for: item.book)
                                        },
                                        score: scoreStore.score(for: item.book)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(rowAnchor(for: item))
                            }
                        } header: {
                            Text("找到 \(vm.candidates.count) 个候选源 (显示 \(display.count)) · 点选异源查目录")
                                .font(.caption)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: scrollToken) { _, _ in
                        if let cur = currentRowAnchor() {
                            withAnimation { proxy.scrollTo(cur, anchor: .center) }
                        }
                    }
                    .onChange(of: jumpEdgeToken) { _, tok in
                        let anchors = display.map { rowAnchor(for: $0) }
                        guard !anchors.isEmpty else { return }
                        if tok.kind == .top, let first = anchors.first {
                            withAnimation { proxy.scrollTo(first, anchor: .top) }
                        } else if tok.kind == .bottom, let last = anchors.last {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    private var emptyStateText: String {
        if !vm.screenFilter.isEmpty || vm.groupFilter != nil {
            return "当前过滤条件下没有候选, 试试清空筛选"
        }
        return "没找到此书的其它源"
    }

    private func rowAnchor(for item: ChangeSourceViewModel.Candidate) -> String {
        "row::\(item.book.origin)::\(item.book.bookUrl)"
    }

    private func currentRowAnchor() -> String? {
        guard let cur = target.currentOrigin else { return nil }
        if let hit = vm.candidates.first(where: { $0.book.origin == cur }) {
            return rowAnchor(for: hit)
        }
        return nil
    }

    // MARK: - Bottom bar

    private struct JumpToken: Equatable {
        enum Kind { case none, top, bottom }
        let kind: Kind
        let id = UUID()
        static func == (l: JumpToken, r: JumpToken) -> Bool { l.id == r.id }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                scrollToken = UUID()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "target").font(.caption2)
                    Text(currentSourceLabel).font(.caption2).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(WanxiangColors.primary.opacity(0.15)))
                .foregroundStyle(WanxiangColors.primary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            if vm.isSearching {
                Text(progressText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Button {
                jumpEdgeToken = JumpToken(kind: .top)
            } label: {
                Image(systemName: "arrow.up.to.line").font(.callout)
                    .foregroundStyle(WanxiangColors.textPrimary)
            }
            .buttonStyle(.borderless)
            Button {
                jumpEdgeToken = JumpToken(kind: .bottom)
            } label: {
                Image(systemName: "arrow.down.to.line").font(.callout)
                    .foregroundStyle(WanxiangColors.textPrimary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(WanxiangColors.card)
    }

    private var currentSourceLabel: String {
        if let cur = target.currentOrigin,
           let hit = vm.candidates.first(where: { $0.book.origin == cur }) {
            return "当前: \(hit.book.originName)"
        }
        return "当前: \(target.currentOrigin ?? "—")"
    }

    private var progressText: String {
        if vm.totalSourceCount == 0 { return "搜索中…" }
        if !vm.currentSearchingName.isEmpty {
            return "已 \(vm.searchedCount)/\(vm.totalSourceCount) · \(vm.currentSearchingName)"
        }
        return "已 \(vm.searchedCount)/\(vm.totalSourceCount)"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("关闭") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task {
                    if vm.isSearching { vm.stopSearch() }
                    else { await vm.startSearch(target: target) }
                }
            } label: {
                Image(systemName: vm.isSearching ? "stop.circle" : "arrow.clockwise")
            }
            Button {
                withAnimation { screenFieldVisible.toggle() }
                if !screenFieldVisible { vm.screenFilter = "" }
            } label: {
                Image(systemName: screenFieldVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
            }
            Menu {
                Section("源分组") {
                    Button {
                        vm.groupFilter = nil
                    } label: {
                        HStack { Text("全部分组"); Spacer()
                            if vm.groupFilter == nil { Image(systemName: "checkmark") }
                        }
                    }
                    ForEach(vm.availableGroups, id: \.self) { g in
                        Button {
                            vm.groupFilter = g
                        } label: {
                            HStack { Text(g); Spacer()
                                if vm.groupFilter == g { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section {
                    Toggle("显示字数 / 响应时间", isOn: $vm.showWordCountAndRespond)
                }
                Section {
                    Button {
                        Task { await vm.refreshList(target: target) }
                    } label: {
                        Label("刷新列表", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Navigation anchor

private struct AlternatePickAnchor: Hashable {
    let book: SearchBook
    let source: BookSource
}

// MARK: - 异源目录 + 选章

private struct AlternateChapterPickScreen: View {

    let anchor: AlternatePickAnchor
    let readerChapterIndex: Int
    let readerChapterTitle: String?
    let onReplaceChapterBody: (String) -> Void

    @State private var toc: [BookChapter] = []
    @State private var tocLoadError: String?
    @State private var chapterFetchError: String?
    @State private var loadingToc = true
    @State private var fetchingIndex: Int?

    private var searchBook: SearchBook { anchor.book }
    private var source: BookSource { anchor.source }

    private var suggestedIndex: Int {
        guard !toc.isEmpty else { return 0 }
        let raw = BookChapterMigration.mappedDurChapterIndex(
            oldDurChapterIndex: readerChapterIndex,
            oldDurChapterTitle: readerChapterTitle,
            newChapters: toc,
            oldChapterListSize: 0
        )
        return min(max(0, raw), toc.count - 1)
    }

    var body: some View {
        Group {
            if loadingToc {
                ProgressView("加载目录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = tocLoadError {
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let ce = chapterFetchError {
                        Section {
                            Text(ce).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Section {
                        ForEach(Array(toc.enumerated()), id: \.offset) { idx, chapter in
                            let isPick = (fetchingIndex == idx)
                            Button {
                                chapterFetchError = nil
                                Task { await fetchAndReplace(index: idx, chapter: chapter) }
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chapter.title)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        if chapter.isVolume {
                                            Text("卷")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if idx == suggestedIndex {
                                        Text("推荐")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(WanxiangColors.accent.opacity(0.2)))
                                            .foregroundStyle(WanxiangColors.accent)
                                    }
                                    if isPick {
                                        ProgressView().scaleEffect(0.75)
                                    }
                                }
                            }
                            .disabled(fetchingIndex != nil)
                        }
                    } header: {
                        Text("选用一节替换当前阅读章正文 · \(searchBook.originName)")
                            .font(.caption)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("目录")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: searchBook.bookUrl) {
            await loadToc()
        }
    }

    private func loadToc() async {
        loadingToc = true
        tocLoadError = nil
        chapterFetchError = nil
        toc = []
        defer { loadingToc = false }
        let info = BookInfo(
            bookUrl: searchBook.bookUrl,
            name: searchBook.name,
            author: searchBook.author,
            coverUrl: searchBook.coverUrl,
            tocUrl: searchBook.bookUrl
        )
        do {
            let list = try await BookSourceEngine.shared.fetchToc(of: info, in: source)
            if Task.isCancelled { return }
            if list.isEmpty {
                tocLoadError = "该源目录为空"
            } else {
                toc = list
            }
        } catch {
            tocLoadError = "目录加载失败:\(error.localizedDescription)"
        }
    }

    private func fetchAndReplace(index: Int, chapter: BookChapter) async {
        fetchingIndex = index
        defer { fetchingIndex = nil }
        do {
            let content = try await BookSourceEngine.shared.fetchContent(of: chapter, in: source)
            if Task.isCancelled { return }
            let body = content.content
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run {
                    chapterFetchError = "正文为空,请换一章或其它源"
                }
                return
            }
            await MainActor.run {
                onReplaceChapterBody(body)
            }
        } catch is CancellationError {
            // ignore
        } catch {
            await MainActor.run {
                chapterFetchError = "正文加载失败:\(error.localizedDescription)"
            }
        }
    }
}
