//
//  ChangeSourceView.swift
//  万象书屋 iOS · 换源 (M2.5.5 + 1:1 对齐 Android ChangeBookSourceDialog)
//
//  对应 Android: io.legado.app.ui.book.changesource.ChangeBookSourceDialog
//
//  1:1 对齐功能集:
//   - 整体: 顶栏书名 + 副标题作者, 启停搜索, 刷新列表, 关闭
//   - 顶栏二次过滤 (Android menu_screen SearchView): 按源名/作者/最新章过滤候选行
//   - 顶栏分组筛选 (Android menu_group): 按 BookSource.bookSourceGroup 子串匹配
//   - 顶栏 toggle: 加载字数+响应时间 (Android menu_load_word_count)
//   - 候选行: 源名/作者/书名/最新章 + 字数/响应时间 + 👍👎 + 长按置顶/置底
//   - 底栏: 当前源胶囊 (点击 → 滚到当前) + 跳顶 + 跳底 + 进度文字
//   - 选中候选: 校验后回调 → 重读 toc + 切源
//

import SwiftUI

public struct ChangeSourceView: View {

    /// 万象书屋: 换源对话框无关"书架"还是"搜索"来源, 只关心 (name, author, currentOrigin?).
    /// `currentOrigin` 用来在列表里把当前正在用的源高亮 / 排前 (与 Android 行为一致).
    public struct Target {
        public let name: String
        public let author: String
        public let currentOrigin: String?
        public init(name: String, author: String, currentOrigin: String? = nil) {
            self.name = name; self.author = author; self.currentOrigin = currentOrigin
        }
    }

    public let target: Target
    /// callback: 用户选了新源, 拿到新 SearchBook + 新 BookSource
    public let onSelect: (SearchBook, BookSource) -> Void

    @StateObject private var vm = ChangeSourceViewModel()
    @StateObject private var scoreStore = SourceScoreStore.shared
    @Environment(\.dismiss) private var dismiss

    /// 顶栏二次过滤是否展开 (Android menu_screen SearchView 同样是按需展开)
    @State private var screenFieldVisible: Bool = false
    /// 让候选行可滚动到 "当前源" (Android `tvDur.click → scrollToDurSource`)
    @State private var scrollToken: UUID = UUID()
    /// 用户主动点了候选 → push 哪个 anchor 给 caller (默认 instant, 但有 confirm alert 时延后)
    @State private var pendingPick: ChangeSourceViewModel.Candidate? = nil

    public init(target: Target,
                onSelect: @escaping (SearchBook, BookSource) -> Void) {
        self.target = target
        self.onSelect = onSelect
    }

    /// 兼容入口: 书架场景 (用 ShelfBook)
    public init(originalBook: ShelfBook,
                onSelect: @escaping (SearchBook, BookSource) -> Void) {
        self.init(
            target: Target(name: originalBook.name,
                           author: originalBook.author,
                           currentOrigin: originalBook.origin),
            onSelect: onSelect
        )
    }

    /// 新增入口: 搜索 / 详情场景 (用 SearchBook)
    public init(searchBook: SearchBook,
                onSelect: @escaping (SearchBook, BookSource) -> Void) {
        self.init(
            target: Target(name: searchBook.name,
                           author: searchBook.author,
                           currentOrigin: searchBook.origin),
            onSelect: onSelect
        )
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                if screenFieldVisible { screenField }
                Divider()
                candidatesList
                Divider()
                bottomBar
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task {
                if vm.candidates.isEmpty {
                    await vm.startSearch(target: target)
                }
                runDebugAutoPick()
            }
        }
    }

    // MARK: - Header (书名 · 作者 + 进度)

    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name).font(.subheadline.weight(.semibold))
                Text(target.author).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if vm.isSearching {
                ProgressView().scaleEffect(0.75)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - 顶栏二次过滤输入框 (Android menu_screen SearchView)

    private var screenField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
            TextField("按源名 / 作者 / 最新章过滤候选", text: $vm.screenFilter)
                .textFieldStyle(.plain)
                .submitLabel(.search)
            if !vm.screenFilter.isEmpty {
                Button {
                    vm.screenFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(WanxiangColors.card)
    }

    // MARK: - 候选列表 (Android RecyclerView)

    private var candidatesList: some View {
        let display = vm.displayCandidates(score: { scoreStore.score(for: $0) })
        return Group {
            if display.isEmpty && !vm.isSearching {
                VStack(spacing: 6) {
                    Spacer()
                    Text(emptyStateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        Section {
                            ForEach(display, id: \.book.bookUrl) { item in
                                Button {
                                    handlePick(item)
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
                            Text("找到 \(vm.candidates.count) 个候选源 (显示 \(display.count))")
                                .font(.caption)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: scrollToken) { _, _ in
                        if let target = currentRowAnchor() {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
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

    // MARK: - 底栏 (Android tvDur / ivTop / ivBottom / progress text)

    @State private var jumpEdgeToken: JumpToken = JumpToken(kind: .none)

    private struct JumpToken: Equatable {
        enum Kind { case none, top, bottom }
        let kind: Kind
        let id = UUID()
        static func == (l: JumpToken, r: JumpToken) -> Bool { l.id == r.id }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // 当前源胶囊 — 点击 → 滚动到当前源
            Button {
                scrollToken = UUID()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "target")
                        .font(.caption2)
                    Text(currentSourceLabel)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(WanxiangColors.primary.opacity(0.15)))
                .foregroundStyle(WanxiangColors.primary)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 6)

            // 进度文字 (Android `change_source_progress`)
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
                Image(systemName: "arrow.up.to.line")
                    .font(.callout)
                    .foregroundStyle(WanxiangColors.textPrimary)
            }
            .buttonStyle(.borderless)
            Button {
                jumpEdgeToken = JumpToken(kind: .bottom)
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.callout)
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("关闭") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // 启动 / 停止搜索 (Android menu_start_stop)
            Button {
                Task {
                    if vm.isSearching { vm.stopSearch() }
                    else { await vm.startSearch(target: target) }
                }
            } label: {
                Image(systemName: vm.isSearching ? "stop.circle" : "arrow.clockwise")
            }
            // 顶栏二次过滤展开 (Android menu_screen)
            Button {
                withAnimation { screenFieldVisible.toggle() }
                if !screenFieldVisible { vm.screenFilter = "" }
            } label: {
                Image(systemName: screenFieldVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
            }
            // 杂项菜单 (Android menu_group + menu_load_word_count + menu_refresh_list + menu_close)
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

    // MARK: - 候选行点击 → 校验 + 回调

    private func handlePick(_ item: ChangeSourceViewModel.Candidate) {
        guard let source = vm.sourceFor(origin: item.book.origin) else { return }
        if target.currentOrigin == item.book.origin {
            // 已经是当前源, 不做任何动作 (跟 Android `bookUrl == oldBookUrl` 早返 一致)
            return
        }
        onSelect(item.book, source)
        dismiss()
    }

    // MARK: - 自动化 / debug

    private func runDebugAutoPick() {
        let args = ProcessInfo.processInfo.arguments
        for key in ["--AutoPickSource", "-AutoPickSource"] {
            if let i = args.firstIndex(of: key), i + 1 < args.count {
                let needle = args[i + 1]
                if let hit = vm.candidates.first(where: { $0.book.originName.contains(needle) }),
                   let src = vm.sourceFor(origin: hit.book.origin) {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        onSelect(hit.book, src)
                        dismiss()
                    }
                }
                break
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ChangeSourceViewModel: ObservableObject {

    struct Candidate: Sendable, Equatable {
        var book: SearchBook
        var isLoadingInfo: Bool = false
        var infoFailed: Bool = false
        /// 万象书屋: 该源 search 响应时间 (ms); < 0 表示未知 / 未到.
        /// 跟 Android `tvRespondTime` 等价.
        var respondTimeMs: Int = -1
        var bookUrl: String { book.bookUrl }
    }

    @Published var candidates: [Candidate] = []
    @Published var isSearching = false
    /// 顶栏关键词二次过滤 (Android `menu_screen` SearchView)
    @Published var screenFilter: String = ""
    /// 按源分组过滤 (Android `menu_group`); nil = 全部分组
    @Published var groupFilter: String? = nil
    /// 显示字数 / 响应时间 (Android `menu_load_word_count`)
    @Published var showWordCountAndRespond: Bool = true
    /// 进度信息 (Android `change_source_progress`)
    @Published var searchedCount: Int = 0
    @Published var totalSourceCount: Int = 0
    @Published var currentSearchingName: String = ""
    /// 可用分组列表 (Android `appDb.bookSourceDao.flowEnabledGroups`)
    @Published var availableGroups: [String] = []

    private var searchTask: Task<Void, Never>? = nil
    private var infoFillTasks: [Task<Void, Never>] = []
    private let fetchInfoConcurrency = 4
    private var infoFillInflight = 0

    // MARK: - 搜索控制

    /// 启动一次搜索 (Android `ChangeBookSourceViewModel.startSearch`).
    /// 已经在搜就忽略.
    func startSearch(target: ChangeSourceView.Target) async {
        if isSearching { return }
        cancelInfoFill()
        candidates = []
        searchedCount = 0
        currentSearchingName = ""
        let sources = filteredSourcesForSearch()
        totalSourceCount = sources.count
        availableGroups = collectGroups()
        isSearching = true
        let t0 = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            let stream = await BookSourceEngine.shared.searchAll(in: sources, key: target.name)
            var seen = Set<String>()
            for await (src, result) in stream {
                if Task.isCancelled { break }
                let dt = Int((Date().timeIntervalSince(t0)) * 1000)
                await MainActor.run {
                    self.searchedCount += 1
                    self.currentSearchingName = src.bookSourceName
                }
                switch result {
                case .success(let books):
                    for b in books where self.matches(target: target, candidate: b) {
                        let key = "\(b.origin)::\(b.bookUrl)"
                        if seen.insert(key).inserted {
                            var cand = Candidate(book: b)
                            cand.respondTimeMs = dt
                            let alreadyHasLast = (b.lastChapter?
                                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                            cand.isLoadingInfo = !alreadyHasLast
                            await MainActor.run {
                                self.insertCandidate(cand, currentOrigin: target.currentOrigin)
                                if !alreadyHasLast {
                                    self.scheduleInfoFill(for: key)
                                }
                            }
                        }
                    }
                case .failure:
                    continue
                }
            }
            await MainActor.run {
                self.isSearching = false
                self.currentSearchingName = ""
            }
        }
        searchTask = task
    }

    func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        currentSearchingName = ""
    }

    /// 刷新列表: 清掉所有候选, 重新搜 (Android `menu_refresh_list` → `startRefreshList`)
    func refreshList(target: ChangeSourceView.Target) async {
        stopSearch()
        await startSearch(target: target)
    }

    // MARK: - 候选排序

    /// 置顶 (Android `topSource`)
    func topSource(_ cand: Candidate) {
        guard let idx = candidates.firstIndex(where: { $0.book.bookUrl == cand.book.bookUrl && $0.book.origin == cand.book.origin }) else { return }
        let c = candidates.remove(at: idx)
        candidates.insert(c, at: 0)
    }

    /// 置底 (Android `bottomSource`)
    func bottomSource(_ cand: Candidate) {
        guard let idx = candidates.firstIndex(where: { $0.book.bookUrl == cand.book.bookUrl && $0.book.origin == cand.book.origin }) else { return }
        let c = candidates.remove(at: idx)
        candidates.append(c)
    }

    // MARK: - 派生显示候选 (screenFilter + groupFilter + score 排序)

    /// 万象书屋: 过滤后的候选 (顶栏 screenFilter + groupFilter) + 按 score 二级排序.
    ///   - score=1 (推荐) 排最前
    ///   - score=0 (默认) 中间, 顺序保持 candidates 原始顺序
    ///   - score=-1 (屏蔽) 沉底
    ///   - 当前源始终插队最前
    func displayCandidates(score: (SearchBook) -> Int) -> [Candidate] {
        let q = screenFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = candidates.filter { c in
            if let g = groupFilter, !g.isEmpty {
                let bg = sourceFor(origin: c.book.origin)?.bookSourceGroup ?? ""
                if !bg.contains(g) { return false }
            }
            if !q.isEmpty {
                let hay = "\(c.book.originName) \(c.book.author) \(c.book.lastChapter ?? "")".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
        // 稳定排序: keep relative order within same bucket
        let withIdx = filtered.enumerated().map { (i, c) -> (Int, Int, Candidate) in
            let s = score(c.book)
            let bucket: Int
            if s == 1 { bucket = 0 } else if s == 0 { bucket = 1 } else { bucket = 2 }
            return (bucket, i, c)
        }
        let sorted = withIdx.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        return sorted.map { $0.2 }
    }

    // MARK: - private helpers

    private func filteredSourcesForSearch() -> [BookSource] {
        BookSourceRegistry.shared.enabledSources
    }

    /// 收集启用源的去重分组列表 (Android `flowEnabledGroups`).
    /// 一个源可能 group 是 "-(02)📚普通,A,B" 多个用逗号分隔, 拆开. 跳过空字符串.
    private func collectGroups() -> [String] {
        var set = Set<String>()
        for s in BookSourceRegistry.shared.enabledSources {
            guard let g = s.bookSourceGroup else { continue }
            for piece in g.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }) {
                let t = piece.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { set.insert(String(t)) }
            }
        }
        return set.sorted()
    }

    private func insertCandidate(_ cand: Candidate, currentOrigin: String?) {
        if let cur = currentOrigin, cand.book.origin == cur {
            candidates.insert(cand, at: 0)
        } else {
            candidates.append(cand)
        }
    }

    private func matches(target: ChangeSourceView.Target, candidate: SearchBook) -> Bool {
        let n1 = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let n2 = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n1 == n2 else { return false }
        let a1 = target.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let a2 = candidate.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return a1.isEmpty || a2.isEmpty || a1 == a2
    }

    func sourceFor(origin: String) -> BookSource? {
        BookSourceRegistry.shared.find(origin: origin)
    }

    // MARK: - 异步 fetchInfo (补 lastChapter)

    private func scheduleInfoFill(for key: String) {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.acquireSlot()
            defer { Task { await self.releaseSlot() } }
            await self.performInfoFill(forKey: key)
        }
        infoFillTasks.append(task)
    }

    private func performInfoFill(forKey key: String) async {
        guard let cand = candidates.first(where: { "\($0.book.origin)::\($0.book.bookUrl)" == key }) else { return }
        guard let source = sourceFor(origin: cand.book.origin) else {
            updateCandidate(forKey: key) { $0.isLoadingInfo = false; $0.infoFailed = true }
            return
        }
        do {
            let info: BookInfo = try await withThrowingTaskGroup(of: BookInfo.self) { group in
                group.addTask {
                    return try await BookSourceEngine.shared.fetchInfo(of: cand.book, in: source)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    throw CancellationError()
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
            if Task.isCancelled { return }
            updateCandidate(forKey: key) { c in
                c.isLoadingInfo = false
                c.infoFailed = false
                if let last = info.lastChapter?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
                    c.book.lastChapter = last
                }
                if c.book.intro?.isEmpty != false, let intro = info.intro { c.book.intro = intro }
                if c.book.coverUrl?.isEmpty != false, let cv = info.coverUrl { c.book.coverUrl = cv }
                if c.book.wordCount?.isEmpty != false, let wc = info.wordCount { c.book.wordCount = wc }
            }
        } catch {
            updateCandidate(forKey: key) { c in
                c.isLoadingInfo = false
                c.infoFailed = true
            }
        }
    }

    private func updateCandidate(forKey key: String, _ mut: (inout Candidate) -> Void) {
        guard let idx = candidates.firstIndex(where: { "\($0.book.origin)::\($0.book.bookUrl)" == key }) else { return }
        mut(&candidates[idx])
    }

    private func acquireSlot() async {
        while infoFillInflight >= fetchInfoConcurrency {
            try? await Task.sleep(nanoseconds: 80_000_000)
            if Task.isCancelled { return }
        }
        infoFillInflight += 1
    }
    private func releaseSlot() {
        infoFillInflight = max(0, infoFillInflight - 1)
    }

    private func cancelInfoFill() {
        for t in infoFillTasks { t.cancel() }
        infoFillTasks.removeAll()
        infoFillInflight = 0
    }

    deinit {
        for t in infoFillTasks { t.cancel() }
        searchTask?.cancel()
    }
}
