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
    @ObservedObject private var scoreStore = SourceScoreStore.shared
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
            .accessibilityIdentifier("change-source-sheet")
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
                // 主搜结果不足时才自动二轮 (避免默认双倍全源扫描 OOM)
                let author = target.author.trimmingCharacters(in: .whitespacesAndNewlines)
                if !author.isEmpty, vm.candidates.count < 3 {
                    await vm.startSecondaryRound(target: target, extraKeyword: author)
                }
                runDebugAutoPick()
            }
            .onChange(of: vm.screenFilter) { _, _ in
                vm.rebuildDisplayList(currentOrigin: target.currentOrigin)
            }
            .onChange(of: vm.groupFilter) { _, _ in
                vm.rebuildDisplayList(currentOrigin: target.currentOrigin)
            }
            .onDisappear { vm.shutdown() }
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
        let display = vm.displayList
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
                ChangeSourceCandidatesList(
                    display: display,
                    header: "找到 \(vm.candidates.count) 个候选源 (显示 \(display.count))",
                    currentOrigin: target.currentOrigin,
                    scrollToken: scrollToken,
                    jumpEdgeToken: jumpEdgeToken
                ) { item in
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
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

    // MARK: - 底栏 (Android tvDur / ivTop / ivBottom / progress text)

    @State private var jumpEdgeToken: ChangeSourceJumpToken = ChangeSourceJumpToken(kind: .none)

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
                jumpEdgeToken = ChangeSourceJumpToken(kind: .top)
            } label: {
                Image(systemName: "arrow.up.to.line")
                    .font(.callout)
                    .foregroundStyle(WanxiangColors.textPrimary)
            }
            .buttonStyle(.borderless)
            Button {
                jumpEdgeToken = ChangeSourceJumpToken(kind: .bottom)
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
        /// 万象书屋 (crash fix): ForEach 唯一 id — 永不复用, 彻底规避 duplicate id 闪退.
        let stableId: UUID
        var book: SearchBook
        var isLoadingInfo: Bool = false
        var infoFailed: Bool = false
        /// 万象书屋: 该源 search 响应时间 (ms); < 0 表示未知 / 未到.
        var respondTimeMs: Int = -1
        var bookUrl: String { book.bookUrl }

        init(book: SearchBook, isLoadingInfo: Bool = false, infoFailed: Bool = false, respondTimeMs: Int = -1) {
            self.stableId = UUID()
            self.book = book
            self.isLoadingInfo = isLoadingInfo
            self.infoFailed = infoFailed
            self.respondTimeMs = respondTimeMs
        }

        /// 展示 / 去重用 (非 ForEach id)
        var listRowId: String {
            "\(book.origin)::\(book.bookUrl)::\(book.name)::\(book.author)"
        }
    }

    @Published var candidates: [Candidate] = []
    /// 过滤后的展示列表 (仅 candidates/筛选变化时更新, 与搜索进度解耦避免 graph 风暴)
    @Published private(set) var displayList: [Candidate] = []
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
    /// 搜索进行中暂缓 info-fill, 避免 search+fetchInfo 双负载 OOM / SwiftUI 频繁刷新闪退
    private var pendingInfoFillKeys: Set<String> = []
    /// merge 合并队列: 200ms 内多源命中只触发一次 @Published
    private var pendingMergeItems: [(book: SearchBook, respondTimeMs: Int)] = []
    private var pendingMergeTarget: ChangeSourceView.Target?
    private var mergeCoalesceTask: Task<Void, Never>?
    private static let maxCandidates = 80
    private static let mergeCoalesceNanos: UInt64 = 500_000_000
    private static let maxInfoFillAfterSearch = 24
    /// 进度节流: 内部计数 + 400ms 合并一次 @Published, 避免每搜完一个源就刷新整页 List
    private var progressSearchedCount = 0
    private var progressSearchingName = ""
    private var progressCoalesceTask: Task<Void, Never>?
    /// 搜索期间 cache 写入先入队, 结束后再批量落盘
    private var pendingCacheUpserts: [ChangeSourceCandidateCache.CachedCandidate] = []
    private var pendingCacheTarget: ChangeSourceView.Target?
    private var listCurrentOrigin: String?
    /// 万象书屋 (perf 2026-05-11): fetchInfo 并发按设备内存自适应, SE 等设备避免 OOM.
    private var fetchInfoConcurrency: Int {
        min(BookSourceEngine.adaptiveFetchInfoConcurrency, 3)
    }
    private var infoFillInflight = 0
    /// 换源搜索并发 — 专用低并发, 禁止跟全站搜索一样开到 9.
    private var searchConcurrency: Int { BookSourceEngine.changeSourceSearchConcurrency }

    /// 万象书屋 (perf 2026-05-11): 跨"主搜索"+"二轮精准搜索"共享的去重 key 集.
    /// 主搜 keyword=name, 二轮 keyword=name+作者 / name+screenFilter, 两端可能返同一本书,
    /// 用统一集合保证 candidates 不会出现重复.
    private var seenCandidateKeys: Set<String> = []

    /// 万象书屋: 二轮精准搜索 (必须在主搜结束后串行跑, 不可与主搜并行 — 否则双倍并发 OOM)
    private var secondaryRoundTask: Task<Void, Never>? = nil
    /// 已经发过的二轮关键词, 同 key 不再重复发 (用户清空再输同样的词不会重打源)
    private var firedSecondaryKeys: Set<String> = []
    /// 二轮搜索当前关键词 (UI 显示用); nil = 没在跑二轮
    @Published var secondaryRoundActiveKey: String? = nil

    /// 本章换源模式: 从阅读器打开, 与 prefetch 并存时更保守 (低并发 / 无 info-fill / 无二轮)
    var chapterChangeMode = false

    private var effectiveMaxCandidates: Int {
        chapterChangeMode ? 50 : Self.maxCandidates
    }
    private var effectiveSearchConcurrency: Int {
        chapterChangeMode ? min(2, searchConcurrency) : searchConcurrency
    }
    private var effectiveMaxInfoFill: Int {
        chapterChangeMode ? 0 : Self.maxInfoFillAfterSearch
    }

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
        SourceHealthChecker.shared.cancelHealthCheck()
        cancelInfoFill()
        pendingInfoFillKeys.removeAll()
        pendingMergeItems.removeAll()
        pendingCacheUpserts.removeAll()
        pendingCacheTarget = target
        mergeCoalesceTask?.cancel()
        mergeCoalesceTask = nil
        progressCoalesceTask?.cancel()
        progressCoalesceTask = nil
        // 万象书屋: 主搜启动时重置二轮状态 (用户重新打开换源 / 点刷新都从 0 开始)
        secondaryRoundTask?.cancel()
        secondaryRoundTask = nil
        secondaryRoundActiveKey = nil
        firedSecondaryKeys.removeAll()
        listCurrentOrigin = target.currentOrigin

        // 1) 同步加载磁盘 cache
        let cached = ChangeSourceCandidateCache.shared.get(name: target.name, author: target.author) ?? []
        seenCandidateKeys.removeAll()
        var batch: [Candidate] = []
        batch.reserveCapacity(cached.count)
        for c in cached {
            let key = "\(c.book.origin)::\(c.book.bookUrl)"
            guard seenCandidateKeys.insert(key).inserted else { continue }
            var cand = Candidate(book: c.book, respondTimeMs: c.respondTimeMs)
            cand.isLoadingInfo = false
            batch.append(cand)
        }
        candidates = Self.orderedCandidateList(from: batch, currentOrigin: target.currentOrigin)
        rebuildDisplayList(currentOrigin: target.currentOrigin)
        await Task.yield()

        searchedCount = 0
        progressSearchedCount = 0
        progressSearchingName = ""
        currentSearchingName = ""

        // 2) 排好序的源 list → 历史好源先发, 用户感知速度 ↑
        let rawSources = filteredSourcesForSearch()
        let sources = SourcePerformanceTracker.shared.sortByScore(rawSources)
        totalSourceCount = sources.count
        availableGroups = collectGroups()
        isSearching = true
        let t0 = Date()
        let concurrency = effectiveSearchConcurrency
        let task = Task { [weak self] in
            guard let self else { return }
            // 等 sheet 动画完成再并发打源, 避免与首帧列表渲染抢主线程 graph update.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
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
                    self.noteSearchProgress(searchedName: src.bookSourceName)
                }
                switch result {
                case .success(let books):
                    let matched = books.filter { self.matches(target: target, candidate: $0) }
                    if !matched.isEmpty {
                        await MainActor.run {
                            self.enqueueMergeSearchHits(matched, target: target, respondTimeMs: dt)
                        }
                    }
                case .failure:
                    continue
                }
            }
            await MainActor.run {
                self.flushCoalescedMergeHits()
                self.flushSearchProgress()
                self.isSearching = false
                self.currentSearchingName = ""
                self.flushPendingCacheWrites(target: target)
                self.persistAllCandidatesToCache(target: target)
                self.flushPendingInfoFillIfIdle()
            }
        }
        searchTask = task
        await task.value
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
        guard !chapterChangeMode else { return }
        let trimmed = extraKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        SourceHealthChecker.shared.cancelHealthCheck()
        let combined = "\(target.name) \(trimmed)"
        let dedupeKey = combined.lowercased()
        if firedSecondaryKeys.contains(dedupeKey) { return }
        firedSecondaryKeys.insert(dedupeKey)

        // 等主搜结束再开二轮, 禁止双路 searchAll 并行
        if let primary = searchTask {
            await primary.value
        }

        secondaryRoundTask?.cancel()
        secondaryRoundActiveKey = combined

        let task = Task { [weak self] in
            guard let self else { return }
            let rawSources = await MainActor.run { self.filteredSourcesForSearch() }
            let sources = SourcePerformanceTracker.shared.sortByScore(rawSources)
            let stream = await BookSourceEngine.shared.searchAll(
                in: sources, key: combined,
                maxConcurrency: BookSourceEngine.changeSourceSearchConcurrency
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
                    let matched = books.filter { self.matches(target: target, candidate: $0) }
                    if !matched.isEmpty {
                        await MainActor.run {
                            self.enqueueMergeSearchHits(matched, target: target, respondTimeMs: dt)
                        }
                    }
                case .failure:
                    continue
                }
            }
            await MainActor.run {
                self.flushCoalescedMergeHits()
                if self.secondaryRoundActiveKey == combined {
                    self.secondaryRoundActiveKey = nil
                }
                self.flushPendingCacheWrites(target: target)
                self.persistAllCandidatesToCache(target: target)
                self.flushPendingInfoFillIfIdle()
            }
        }
        secondaryRoundTask = task
        await task.value
    }

    /// 200ms 合并多源命中, 减少搜索过程中 List graph 刷新频率
    private func enqueueMergeSearchHits(
        _ books: [SearchBook],
        target: ChangeSourceView.Target,
        respondTimeMs: Int
    ) {
        pendingMergeTarget = target
        for b in books {
            pendingMergeItems.append((book: b, respondTimeMs: respondTimeMs))
        }
        mergeCoalesceTask?.cancel()
        mergeCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.mergeCoalesceNanos)
            guard !Task.isCancelled else { return }
            self?.flushCoalescedMergeHits()
        }
    }

    private func flushCoalescedMergeHits() {
        mergeCoalesceTask?.cancel()
        mergeCoalesceTask = nil
        guard let target = pendingMergeTarget, !pendingMergeItems.isEmpty else { return }
        let items = pendingMergeItems
        pendingMergeItems.removeAll()
        pendingMergeTarget = nil
        mergeSearchHits(items, target: target)
    }

    /// 主搜 / 二轮共用: 按批 merge, 单次 @Published; info-fill 延到搜索全结束
    private func mergeSearchHits(
        _ items: [(book: SearchBook, respondTimeMs: Int)],
        target: ChangeSourceView.Target
    ) {
        guard candidates.count < effectiveMaxCandidates else { return }
        var batch: [Candidate] = []
        batch.reserveCapacity(items.count)
        for item in items {
            let b = item.book
            let key = "\(b.origin)::\(b.bookUrl)"
            guard seenCandidateKeys.insert(key).inserted else { continue }
            var cand = Candidate(book: b, respondTimeMs: item.respondTimeMs)
            let alreadyHasLast = (b.lastChapter?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            cand.isLoadingInfo = !alreadyHasLast
            batch.append(cand)
            if !alreadyHasLast {
                deferInfoFill(for: key)
            }
            queueCacheUpsert(
                target: target,
                candidate: ChangeSourceCandidateCache.CachedCandidate(
                    book: b, respondTimeMs: item.respondTimeMs
                )
            )
            if candidates.count + batch.count >= effectiveMaxCandidates { break }
        }
        guard !batch.isEmpty else { return }
        candidates = Self.orderedCandidateList(
            from: candidates + batch,
            currentOrigin: target.currentOrigin
        )
        rebuildDisplayList(currentOrigin: target.currentOrigin)
    }

    private var isSearchPipelineActive: Bool {
        isSearching || secondaryRoundActiveKey != nil
    }

    private func deferInfoFill(for key: String) {
        guard effectiveMaxInfoFill > 0 else { return }
        pendingInfoFillKeys.insert(key)
    }

    private func flushPendingInfoFillIfIdle() {
        guard !isSearchPipelineActive else { return }
        var keys = Array(pendingInfoFillKeys)
        pendingInfoFillKeys.removeAll()
        if keys.count > effectiveMaxInfoFill {
            keys = Array(keys.prefix(effectiveMaxInfoFill))
        }
        for key in keys {
            enqueueInfoFill(for: key)
        }
    }

    /// 搜索进度节流 — 400ms 合并一次, 不触发 displayList 重建
    private func noteSearchProgress(searchedName: String) {
        progressSearchedCount += 1
        progressSearchingName = searchedName
        progressCoalesceTask?.cancel()
        progressCoalesceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flushSearchProgress()
        }
    }

    private func flushSearchProgress() {
        progressCoalesceTask?.cancel()
        progressCoalesceTask = nil
        searchedCount = progressSearchedCount
        currentSearchingName = progressSearchingName
    }

    private func queueCacheUpsert(
        target: ChangeSourceView.Target,
        candidate: ChangeSourceCandidateCache.CachedCandidate
    ) {
        pendingCacheTarget = target
        pendingCacheUpserts.append(candidate)
    }

    private func flushPendingCacheWrites(target: ChangeSourceView.Target) {
        guard pendingCacheTarget?.name == target.name,
              pendingCacheTarget?.author == target.author,
              !pendingCacheUpserts.isEmpty else { return }
        for c in pendingCacheUpserts {
            ChangeSourceCandidateCache.shared.upsert(
                name: target.name, author: target.author, candidate: c
            )
        }
        pendingCacheUpserts.removeAll()
    }

    /// 按 screenFilter / groupFilter / score 重建展示列表
    func rebuildDisplayList(currentOrigin: String?) {
        displayList = displayCandidates(currentOrigin: currentOrigin)
    }

    /// 旧签名保留给内部单批转换
    private func mergeSearchHits(
        _ books: [SearchBook],
        target: ChangeSourceView.Target,
        respondTimeMs: Int
    ) {
        mergeSearchHits(books.map { (book: $0, respondTimeMs: respondTimeMs) }, target: target)
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
        secondaryRoundTask?.cancel()
        secondaryRoundTask = nil
        secondaryRoundActiveKey = nil
        mergeCoalesceTask?.cancel()
        mergeCoalesceTask = nil
        progressCoalesceTask?.cancel()
        progressCoalesceTask = nil
        isSearching = false
        currentSearchingName = ""
    }

    /// sheet 关闭 / deinit: 停止全部搜索与 info-fill
    func shutdown() {
        stopSearch()
        cancelInfoFill()
        pendingInfoFillKeys.removeAll()
        pendingMergeItems.removeAll()
    }

    /// 刷新列表: 清掉所有候选, 重新搜 (Android `menu_refresh_list` → `startRefreshList`)
    func refreshList(target: ChangeSourceView.Target) async {
        stopSearch()
        pendingInfoFillKeys.removeAll()
        // 强制刷新: 清磁盘 cache, 下面 startSearch 不会读到旧候选, 跟 Android 行为一致.
        ChangeSourceCandidateCache.shared.clear(name: target.name, author: target.author)
        await startSearch(target: target)
    }

    // MARK: - 候选排序

    /// 置顶 (Android `topSource`)
    func topSource(_ cand: Candidate) {
        guard let idx = candidates.firstIndex(where: { $0.book.bookUrl == cand.book.bookUrl && $0.book.origin == cand.book.origin }) else { return }
        var next = candidates
        let c = next.remove(at: idx)
        next.insert(c, at: 0)
        candidates = next
        rebuildDisplayList(currentOrigin: listCurrentOrigin)
    }

    /// 置底 (Android `bottomSource`)
    func bottomSource(_ cand: Candidate) {
        guard let idx = candidates.firstIndex(where: { $0.book.bookUrl == cand.book.bookUrl && $0.book.origin == cand.book.origin }) else { return }
        var next = candidates
        let c = next.remove(at: idx)
        next.append(c)
        candidates = next
        rebuildDisplayList(currentOrigin: listCurrentOrigin)
    }

    // MARK: - 派生显示候选 (screenFilter + groupFilter + score 排序)

    /// 万象书屋: 过滤后的候选 (顶栏 screenFilter + groupFilter) + 按 score 二级排序.
    private func displayCandidates(currentOrigin: String?) -> [Candidate] {
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
        let withIdx = filtered.enumerated().map { (i, c) -> (Int, Int, Candidate) in
            let s = SourceScoreStore.shared.score(for: c.book)
            let bucket: Int
            if s == 1 { bucket = 0 } else if s == 0 { bucket = 1 } else { bucket = 2 }
            return (bucket, i, c)
        }
        let sorted = withIdx.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return lhs.1 < rhs.1
        }
        var seenRowIds = Set<String>()
        return sorted.compactMap { pair -> Candidate? in
            let c = pair.2
            guard seenRowIds.insert(c.listRowId).inserted else { return nil }
            return c
        }
    }

    /// 兼容旧调用 (带 score 闭包)
    func displayCandidates(score: (SearchBook) -> Int) -> [Candidate] {
        _ = score
        return displayList
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

    /// 当前源排最前 (批量加载 cache 时用, 单次 @Published 赋值).
    private static func orderedCandidateList(
        from items: [Candidate],
        currentOrigin: String?
    ) -> [Candidate] {
        var current: Candidate? = nil
        var rest: [Candidate] = []
        rest.reserveCapacity(items.count)
        for cand in items {
            if let cur = currentOrigin, cand.book.origin == cur {
                current = cand
            } else {
                rest.append(cand)
            }
        }
        if let c = current { return [c] + rest }
        return rest
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
        if isSearchPipelineActive {
            pendingInfoFillKeys.insert(key)
            return
        }
        enqueueInfoFill(for: key)
    }

    private func enqueueInfoFill(for key: String) {
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
        var next = candidates
        mut(&next[idx])
        candidates = next
        rebuildDisplayList(currentOrigin: listCurrentOrigin)
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
        secondaryRoundTask?.cancel()
        mergeCoalesceTask?.cancel()
        progressCoalesceTask?.cancel()
    }
}
