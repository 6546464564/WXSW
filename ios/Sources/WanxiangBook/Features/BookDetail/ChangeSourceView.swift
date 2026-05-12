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
    /// 万象书屋 (UX): 用户点了当前源 / 评分按钮等 silent action 时, 顶部弹一条 1.5s 的提示,
    /// 避免"点了没反应"的困惑.
    @State private var transientHint: String? = nil
    @State private var transientHintTask: Task<Void, Never>? = nil
    /// 万象书屋 (perf 2026-05-11): screenFilter 输入 debounce → 触发二轮精准搜索任务.
    @State private var screenFilterDebounceTask: Task<Void, Never>? = nil

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
            .overlay(alignment: .top) {
                if let hint = transientHint {
                    Text(hint)
                        .font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.78)))
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("change-source-transient-hint")
                }
            }
            .task {
                if vm.candidates.isEmpty {
                    await vm.startSearch(target: target)
                }
                // 万象书屋 (perf 2026-05-11): 对话框打开同时自动起一轮"name + 作者"精准搜索,
                // 跟主搜并行跑 — 很多源 (番茄/晋江/起点系) 对 "name + 作者" 命中率比 "name" 高,
                // 能秒补一批主搜静默掉的真候选. author 为空时跳过.
                let author = target.author.trimmingCharacters(in: .whitespacesAndNewlines)
                if !author.isEmpty {
                    Task { await vm.startSecondaryRound(target: target, extraKeyword: author) }
                }
                runDebugAutoPick()
            }
        }
    }

    /// 万象书屋: 1.5s 自动消失的顶部提示气泡 (toast 等价)
    private func showTransientHint(_ msg: String) {
        transientHintTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) {
            transientHint = msg
        }
        transientHintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) {
                    transientHint = nil
                }
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
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                TextField("过滤 + 精准搜索 (如作者名)", text: $vm.screenFilter)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onChange(of: vm.screenFilter) { _, new in
                        scheduleSecondaryRound(extraKeyword: new)
                    }
                if !vm.screenFilter.isEmpty {
                    Button {
                        vm.screenFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 26)
                }
            }
            if let activeKey = vm.secondaryRoundActiveKey, !activeKey.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(WanxiangColors.accent)
                    Text("正在用 \"\(activeKey)\" 在所有源做精准搜索…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(WanxiangColors.card)
    }

    /// 万象书屋: 在 screenFilter 输入 600ms 静默后发起一轮"精准搜索".
    /// 同一个 (target, extraKey) 只发一次, 用户来回擦写不会重打源.
    private func scheduleSecondaryRound(extraKeyword: String) {
        screenFilterDebounceTask?.cancel()
        let kw = extraKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // 太短的 key 不发 (1 个字符基本是噪音)
        guard kw.count >= 2 else { return }
        screenFilterDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            await vm.startSecondaryRound(target: target, extraKeyword: kw)
        }
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
            // 万象书屋 (UX 2026-05-11): 不再无反馈早返. 用户点当前源, 给一条 toast
            // 解释"已经在使用此源", 并加触觉反馈, 避免"行不能点"的错觉.
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showTransientHint(vm.isSearching ? "已经是当前源, 其他候选搜索中…" : "已经是当前源")
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
    /// 万象书屋 (perf 2026-05-11): fetchInfo 并发提到 8 (原 4). info-fill 单源 8s timeout,
    /// 串行 4 个 slot 时 80 个候选最坏 160s. 提到 8 后基本能跟上 search stream.
    /// BookSourceEngine 有 4 个 infoParser pool, 8 个 in-flight 会 2:1 排队, 仍比之前快 2x.
    private let fetchInfoConcurrency = 8
    private var infoFillInflight = 0
    /// 万象书屋 (perf 2026-05-11): 提到 12. SearchView 已用 9, 但换源是单本场景, 用户更
    /// 期望"秒出多个源", 且 BookSourceEngine 已用 4 个 JSEngine pool + InfoCache, 12 不爆.
    private let searchConcurrency = 12

    /// 万象书屋 (perf 2026-05-11): 跨"主搜索"+"二轮精准搜索"共享的去重 key 集.
    /// 主搜 keyword=name, 二轮 keyword=name+作者 / name+screenFilter, 两端可能返同一本书,
    /// 用统一集合保证 candidates 不会出现重复.
    private var seenCandidateKeys: Set<String> = []

    /// 万象书屋: 二轮精准搜索任务 (跟主搜索独立, 并行跑)
    private var secondaryRoundTask: Task<Void, Never>? = nil
    /// 已经发过的二轮关键词, 同 key 不再重复发 (用户清空再输同样的词不会重打源)
    private var firedSecondaryKeys: Set<String> = []
    /// 二轮搜索当前关键词 (UI 显示用); nil = 没在跑二轮
    @Published var secondaryRoundActiveKey: String? = nil

    // MARK: - 搜索控制

    /// 启动一次搜索 (Android `ChangeBookSourceViewModel.startSearch`).
    /// 已经在搜就忽略.
    ///
    /// 万象书屋 (perf 2026-05-11): 仿 Android `searchDataFlow.callbackFlow` 双阶段:
    ///   1. **同步从磁盘 cache 拉历史候选** → 立即填 `candidates`, 列表不再空白.
    ///      (Android `getDbSearchBooks` 等价, 用文件 plist 替代 SQLite.)
    ///   2. 后台启动并发搜索, 增量 merge 新候选 + 写 cache.
    func startSearch(target: ChangeSourceView.Target) async {
        if isSearching { return }
        cancelInfoFill()
        // 万象书屋: 主搜启动时重置二轮状态 (用户重新打开换源 / 点刷新都从 0 开始)
        secondaryRoundTask?.cancel()
        secondaryRoundTask = nil
        secondaryRoundActiveKey = nil
        firedSecondaryKeys.removeAll()

        // 1) 同步加载磁盘 cache → 立即填. 跟 Android `getDbSearchBooks` 等价.
        let cached = ChangeSourceCandidateCache.shared.get(name: target.name, author: target.author) ?? []
        seenCandidateKeys.removeAll()
        candidates = []
        for c in cached {
            let key = "\(c.book.origin)::\(c.book.bookUrl)"
            guard seenCandidateKeys.insert(key).inserted else { continue }
            var cand = Candidate(book: c.book)
            cand.respondTimeMs = c.respondTimeMs
            // cache 里 lastChapter 应已经填好; 即便没填, 不再 fetchInfo (避免冷启动一窝蜂打网络)
            cand.isLoadingInfo = false
            self.insertCandidate(cand, currentOrigin: target.currentOrigin)
        }

        searchedCount = 0
        currentSearchingName = ""

        // 2) 排好序的源 list → 历史好源先发, 用户感知速度 ↑
        let rawSources = filteredSourcesForSearch()
        let sources = SourcePerformanceTracker.shared.sortByScore(rawSources)
        totalSourceCount = sources.count
        availableGroups = collectGroups()
        isSearching = true
        let t0 = Date()
        let concurrency = searchConcurrency
        let task = Task { [weak self] in
            guard let self else { return }
            let stream = await BookSourceEngine.shared.searchAll(
                in: sources, key: target.name,
                maxConcurrency: concurrency
            )
            for await (src, result) in stream {
                if Task.isCancelled { break }
                let dt = Int((Date().timeIntervalSince(t0)) * 1000)
                // 万象书屋: 记录 search perf, 让下次开换源时本源优先级动态调整.
                let okFlag: Bool
                if case .success(let arr) = result, !arr.isEmpty { okFlag = true } else { okFlag = false }
                SourcePerformanceTracker.shared.record(
                    sourceUrl: src.bookSourceUrl, ok: okFlag, durationMs: dt
                )
                await MainActor.run {
                    self.searchedCount += 1
                    self.currentSearchingName = src.bookSourceName
                }
                switch result {
                case .success(let books):
                    for b in books where self.matches(target: target, candidate: b) {
                        await MainActor.run {
                            self.tryInsertCandidate(SearchBook: b, target: target, respondTimeMs: dt)
                        }
                    }
                case .failure:
                    continue
                }
            }
            await MainActor.run {
                self.isSearching = false
                self.currentSearchingName = ""
                // 万象书屋: 搜索结束兜底一次写盘. info-fill 可能在搜索完后还在跑,
                // 那部分 lastChapter 补全由 performInfoFill 的最后一步另存.
                self.persistAllCandidatesToCache(target: target)
            }
        }
        searchTask = task
    }

    /// 万象书屋 (perf 2026-05-11): 二轮精准搜索.
    ///
    /// 主搜 keyword = `name` (例: "青山"), 用户在顶栏输入 "screenFilter" 后我们再拼一轮
    /// `"<name> <screenFilter>"` (例: "青山 会说话的肘子") 发给所有源. 很多源 (尤其
    /// 番茄/晋江/起点系) 对"书名 + 作者"的搜索 URL 命中率比单"书名"高得多, 能补回
    /// 一些只在主搜静默掉的真候选.
    ///
    /// 不清候选 / 不动 isSearching — 新结果 merge 进 candidates, 共享 `seenCandidateKeys`
    /// 去重. 同 extra key 不重复发. 主搜在跑 / 不在跑都可以发.
    func startSecondaryRound(target: ChangeSourceView.Target, extraKeyword: String) async {
        let trimmed = extraKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        // 太短 (<2) 容易把搜索打成单字符, 大量源响应内容大 + 命中率低, 不发
        guard trimmed.count >= 2 else { return }
        let combined = "\(target.name) \(trimmed)"
        let dedupeKey = combined.lowercased()
        if firedSecondaryKeys.contains(dedupeKey) { return }
        firedSecondaryKeys.insert(dedupeKey)

        secondaryRoundTask?.cancel()
        secondaryRoundActiveKey = combined

        let task = Task { [weak self] in
            guard let self else { return }
            let rawSources = await MainActor.run { self.filteredSourcesForSearch() }
            let sources = SourcePerformanceTracker.shared.sortByScore(rawSources)
            let stream = await BookSourceEngine.shared.searchAll(
                in: sources, key: combined,
                maxConcurrency: 12
            )
            let t0 = Date()
            for await (src, result) in stream {
                if Task.isCancelled { break }
                let dt = Int((Date().timeIntervalSince(t0)) * 1000)
                let okFlag: Bool
                if case .success(let arr) = result, !arr.isEmpty { okFlag = true } else { okFlag = false }
                SourcePerformanceTracker.shared.record(
                    sourceUrl: src.bookSourceUrl, ok: okFlag, durationMs: dt
                )
                switch result {
                case .success(let books):
                    // 万象书屋: 仍然用 `matches(target:candidate:)` 过滤 — 即使源对组合 key
                    // 命中, 也要确保返回的 SearchBook.name == target.name (避免源乱返).
                    for b in books where self.matches(target: target, candidate: b) {
                        await MainActor.run {
                            self.tryInsertCandidate(SearchBook: b, target: target, respondTimeMs: dt)
                        }
                    }
                case .failure:
                    continue
                }
            }
            await MainActor.run {
                if self.secondaryRoundActiveKey == combined {
                    self.secondaryRoundActiveKey = nil
                }
                self.persistAllCandidatesToCache(target: target)
            }
        }
        secondaryRoundTask = task
    }

    /// 万象书屋: 主搜 / 二轮共用的"插入候选"通道. seenCandidateKeys 去重 + insert + 调度 info-fill + 落盘.
    private func tryInsertCandidate(
        SearchBook b: SearchBook,
        target: ChangeSourceView.Target,
        respondTimeMs: Int
    ) {
        let key = "\(b.origin)::\(b.bookUrl)"
        guard seenCandidateKeys.insert(key).inserted else { return }
        var cand = Candidate(book: b)
        cand.respondTimeMs = respondTimeMs
        let alreadyHasLast = (b.lastChapter?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        cand.isLoadingInfo = !alreadyHasLast
        insertCandidate(cand, currentOrigin: target.currentOrigin)
        if !alreadyHasLast {
            scheduleInfoFill(for: key)
        }
        ChangeSourceCandidateCache.shared.upsert(
            name: target.name,
            author: target.author,
            candidate: ChangeSourceCandidateCache.CachedCandidate(
                book: b, respondTimeMs: respondTimeMs
            )
        )
    }

    /// 全量重写当前候选到磁盘 cache. info-fill 完成 / 搜索结束时调.
    private func persistAllCandidatesToCache(target: ChangeSourceView.Target) {
        let snapshot = candidates.map { c in
            ChangeSourceCandidateCache.CachedCandidate(book: c.book, respondTimeMs: c.respondTimeMs)
        }
        guard !snapshot.isEmpty else { return }
        ChangeSourceCandidateCache.shared.put(
            name: target.name, author: target.author, candidates: snapshot
        )
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
        // 强制刷新: 清磁盘 cache, 下面 startSearch 不会读到旧候选, 跟 Android 行为一致.
        ChangeSourceCandidateCache.shared.clear(name: target.name, author: target.author)
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
            // 万象书屋: 补完最新章后再写一次 cache (跟 Android `searchBookDao.insert` 等价).
            if let updated = candidates.first(where: { "\($0.book.origin)::\($0.book.bookUrl)" == key }) {
                ChangeSourceCandidateCache.shared.upsert(
                    name: updated.book.name,
                    author: updated.book.author,
                    candidate: ChangeSourceCandidateCache.CachedCandidate(
                        book: updated.book, respondTimeMs: updated.respondTimeMs
                    )
                )
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
