//
//  SearchView.swift
//  万象书屋 iOS · 搜索 (M2.4 骨架)
//
//  对应 Android: io.legado.app.ui.book.search.SearchActivity
//
//  M2.4 阶段交付:
//   - 关键词输入 + 防抖 (300ms)
//   - 多源并发抓取 (用 BookSourceEngine.searchAll → AsyncStream)
//   - 边出边渲染 (跟 Android `SearchModel.search` 行为对齐)
//   - 按 "书名+作者" 去重
//   - 搜索历史 (UserDefaults, 简化版; M2.4.5 SQLite 后做)
//   - 一键加书架 (M2.2 完整书架做; M2.4 占位 alert)
//
//  待补 (M2.4 后续):
//   - 范围筛选 SearchScopeDialog (M2.4.4)
//   - 异常源熔断 (M2.4.7)
//   - 详情页 (M2.4.8)
//   - 真正从 /api/sources 拉的 iOS 书源 (M0-B 后端 ready 后)
//

import SwiftUI
import Foundation

// 万象书屋: BookSource 模块跟本 target 在同一编译单元 (project.yml 把整个 Sources/WanxiangBook 加进去),
// 所以不需要 `import BookSource`. 类型直接可见.

struct SearchView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = SearchViewModel()
    @State private var keyword: String = ""
    @State private var debounceTask: Task<Void, Never>? = nil
    @FocusState private var inputFocused: Bool

    /// 万象书屋: 对齐 Android `PreferKey.precisionSearch` — 只保留书名或作者含关键词的结果.
    @AppStorage("wanxiang.search.precision") private var precisionSearch: Bool = false

    /// 万象书屋: 从书城点 stub 书时, 自动预填关键词 + 立即开搜
    let initialKeyword: String

    /// 万象书屋 (debug): 从 launch arg `--OpenSearchTopHit <key>` 进来时,
    /// 第一次拿到非空 results + 搜索结束时, 自动 push 到 #1 的详情页.
    /// (只为外部脚本/截图自动化用, 用户走交互路径感知不到这个 state.)
    @State private var autoTopHit: SearchBook? = nil
    @State private var autoNavigatedOnce = false

    init(initialKeyword: String = "") {
        self.initialKeyword = initialKeyword
        self._keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()

                if vm.isSearching && vm.results.isEmpty {
                    loading
                } else if !keyword.isEmpty && vm.results.isEmpty && !vm.isSearching {
                    empty
                } else if keyword.isEmpty {
                    historyList
                } else {
                    resultList
                }
            }
            .background(WanxiangColors.background.ignoresSafeArea())
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            // 万象书屋: PV 埋点 (跟 Android `SearchActivity` 自动 trackPageName 等价)
            .trackPageView("page_search")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("精准搜索", isOn: $precisionSearch)
                    } label: {
                        Image(systemName: precisionSearch ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                            .foregroundStyle(precisionSearch ? WanxiangColors.primary : WanxiangColors.textPrimary)
                    }
                    .accessibilityLabel("搜索选项")
                }
            }
            .onAppear {
                inputFocused = true
                if !initialKeyword.isEmpty && vm.results.isEmpty {
                    Task { await vm.search(key: initialKeyword, precisionSearch: precisionSearch) }
                }
            }
            .onChange(of: precisionSearch) { _, _ in
                guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task { await vm.search(key: keyword, precisionSearch: precisionSearch) }
            }
            // 万象书屋 (debug arg `--OpenSearchTopHit`): 搜索结束 + 有结果时, 自动 push 到 #1
            .onChange(of: vm.isSearching) { _, isSearching in
                guard !isSearching, !autoNavigatedOnce else { return }
                let args = ProcessInfo.processInfo.arguments
                let wants = args.contains("--OpenSearchTopHit") || args.contains("-OpenSearchTopHit")
                guard wants, let first = vm.results.first else { return }
                autoNavigatedOnce = true
                autoTopHit = first
            }
        }
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(WanxiangColors.textSecondary)
            TextField("书名 / 作者", text: $keyword)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .submitLabel(.search)
                .onChange(of: keyword) { _, new in
                    debounce(new)
                }
                .onSubmit {
                    Task { await vm.search(key: keyword, precisionSearch: precisionSearch) }
                }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    vm.results = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(WanxiangColors.textSecondary)
                }
            }
        }
        .padding(10)
        .background(WanxiangColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("\(vm.activeSources.count) 个书源搜索中…")
                .font(.caption)
                .foregroundStyle(WanxiangColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.6))
            Text("没有搜到「\(keyword)」")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textSecondary)
            if !vm.errors.isEmpty {
                Text("\(vm.errors.count) 个源失败")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        Group {
            if vm.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(WanxiangColors.textSecondary.opacity(0.4))
                    Text("输入关键词搜索")
                        .font(.subheadline)
                        .foregroundStyle(WanxiangColors.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(vm.history, id: \.self) { h in
                            Button {
                                keyword = h
                                Task { await vm.search(key: h, precisionSearch: precisionSearch) }
                            } label: {
                                HStack {
                                    Image(systemName: "clock")
                                        .foregroundStyle(WanxiangColors.textSecondary)
                                    Text(h)
                                        .foregroundStyle(WanxiangColors.textPrimary)
                                    Spacer()
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("搜索历史").font(.caption)
                            Spacer()
                            Button("清除") { vm.clearHistory() }
                                .font(.caption)
                                .foregroundStyle(WanxiangColors.primary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(WanxiangColors.background)
            }
        }
    }

    private var resultList: some View {
        let books = displayResults
        return List {
            Section {
                // 万象书屋 (D-25 fix): id 改用 listRowId — 用 origin+name+author+bookUrl
                // 避免某些源 (例: QQ浏览器柳树) bookUrl 因解析 bug 全相同时, SwiftUI
                // 把不同书识别成同一行, 用户体感"19 本书全是同一本".
                ForEach(books, id: \.listRowId) { book in
                    NavigationLink {
                        BookDetailView(book: book, source: BookSourceRegistry.shared.find(origin: book.origin))
                    } label: {
                        SearchResultRow(book: book)
                    }
                }
            } header: {
                HStack {
                    Text("\(books.count) 条结果")
                    Spacer()
                    if vm.isSearching {
                        ProgressView().scaleEffect(0.7)
                        Text("搜索中").font(.caption)
                    }
                    // 万象书屋: 显示"反爬源"统计 给用户提示
                    if vm.errors.count > 0 {
                        Text("\(vm.errors.count) 源被阻止")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(WanxiangColors.textSecondary)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background)
        .navigationDestination(item: $autoTopHit) { book in
            BookDetailView(book: book, source: BookSourceRegistry.shared.find(origin: book.origin))
        }
    }

    /// 万象书屋 (P0 修复): 渲染层不再做"按标题前 N 字"的全局去重.
    ///   - 旧版本 q.count >= 8 时把所有书塞到同一个全局 key, 导致"搜长名书全是同一本".
    ///   - 旧版本 q.count < 8 时按 title 前 10 字 dedupe, 把不同作者的同名书合一条.
    ///   - 现在只透传 ViewModel 已经按 (name+author) 去重过的 results, 保证
    ///     "捞尸人 / 陈十三", "捞尸人 / 纯洁滴小龙", "黄河捞尸人" 都正常显示.
    private var displayResults: [SearchBook] {
        return vm.results
    }

    // MARK: - 防抖

    private func debounce(_ text: String) {
        debounceTask?.cancel()
        guard !text.isEmpty else {
            vm.results = []
            return
        }
        let prec = precisionSearch
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            if !Task.isCancelled {
                await vm.search(key: text, precisionSearch: prec)
            }
        }
    }
}

// MARK: - Row

private struct SearchResultRow: View {
    let book: SearchBook

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 万象书屋 (P0 fix): 真加载 coverUrl, 没 URL 才用占位
            BookCover(url: book.coverUrl, width: 50, height: 70)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(WanxiangColors.textSecondary)
                    .lineLimit(1)
                if let intro = book.intro?.trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty {
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(book.originName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(WanxiangColors.primary.opacity(0.15))
                        .foregroundStyle(WanxiangColors.primary)
                        .clipShape(Capsule())
                    if book.distinctOriginCount > 1 {
                        Text("\(book.distinctOriginCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(minWidth: 18, minHeight: 18)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(WanxiangColors.primary.opacity(0.85)))
                            .accessibilityLabel("\(book.distinctOriginCount) 个书源")
                    }
                    if let last = book.lastChapter, !last.isEmpty {
                        Text(last)
                            .font(.caption2)
                            .foregroundStyle(WanxiangColors.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 对齐 Android SearchModel.mergeItems 的排序 (可单测)

/// 万象书屋: 完全照搬 Android `SearchModel.mergeItems` 的最终排序行为.
///
/// Android 真实规则只有两层 (`SearchModel.kt#mergeItems`):
///   1. 三档分桶: equal (name 或 author **等于** key) → contains (包含) → other (precision=true 时丢)
///   2. 每个桶**只**按 `origins.size` 降序; 相同源数时**保留输入顺序** (各源回包先后)
///
/// iOS 旧版还做了 `hasPrefix` / `name.count` / 字典序 三个次级排序键, 它们会盖过
/// `origins.size`, 让「8 个源都收录」的书反而被「书名以关键词开头但只有 1 个源」的书压下去.
/// 这次完全退化, 让两端列表观感一致.
enum SearchLegadoOrdering {
    /// - 0: 书名或作者**等于**关键词
    /// - 1: 书名或作者**包含**关键词
    /// - 2: 其余 (精准搜索时丢弃)
    static func relevanceTier(book: SearchBook, key: String) -> Int {
        if book.name == key || book.author == key { return 0 }
        if book.name.contains(key) || book.author.contains(key) { return 1 }
        return 2
    }

    static func sort(books: [SearchBook], key: String, precision: Bool) -> [SearchBook] {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return books }
        // Swift `Array.sort` 是 introsort, 不保证稳定. 用 enumerated index
        // 作为最后的 tie-breaker, 实现 Android `sortByDescending` 那种稳定排序.
        let indexed = books.enumerated().map { ($0.offset, $0.element) }
        var filtered = indexed
        if precision {
            filtered = indexed.filter { relevanceTier(book: $0.1, key: k) < 2 }
        }
        let sorted = filtered.sorted { lhs, rhs in
            let ta = relevanceTier(book: lhs.1, key: k)
            let tb = relevanceTier(book: rhs.1, key: k)
            if ta != tb { return ta < tb }
            let ca = lhs.1.distinctOriginCount
            let cb = rhs.1.distinctOriginCount
            if ca != cb { return ca > cb }
            return lhs.0 < rhs.0
        }
        return sorted.map { $0.1 }
    }
}

// MARK: - ViewModel

@MainActor
final class SearchViewModel: ObservableObject {

    @Published var results: [SearchBook] = []
    @Published var isSearching: Bool = false
    @Published var activeSources: [BookSource] = []
    @Published var errors: [(BookSource, Error)] = []
    @Published var history: [String] = []

    private static let kHistory = "wanxiang.search.history"
    private static let kMaxHistory = 20
    private var currentTask: Task<Void, Never>? = nil
    private var searchGeneration: Int = 0
    /// `androidStrictMergeKey` → `results` 下标, 同名同作者跨源合并为一行 (对齐 Android `addOrigin`).
    /// 用 Android 严格 `==` 等价 key, 不再 normalize, 行为与 Android 完全一致.
    private var dedupeRowIndex: [String: Int] = [:]
    /// 当前这次搜索的关键词 (用于对齐 Android 的相关性排序)
    private var activeSearchKey: String = ""
    /// 对齐 Android `precisionSearch`: 为 true 时丢弃书名/作者都不含关键词的条目
    private var activePrecision: Bool = false

    /// 万象书屋: 熔断器 (M2.4.7). 同一源连续超时 3 次 → 拉黑 1h
    /// key = source url, value = (failCount, blockedUntil)
    private var sourceFailures: [String: (Int, Date?)] = [:]
    private static let blockThreshold = 3
    private static let blockDuration: TimeInterval = 3600

    init() {
        loadHistory()
    }

    /// 检查源是否被拉黑 (M2.4.7)
    private func isBlocked(_ url: String) -> Bool {
        guard let entry = sourceFailures[url], let until = entry.1 else { return false }
        if Date() > until {
            sourceFailures[url] = (0, nil)
            return false
        }
        return true
    }

    private func recordFailure(_ url: String) {
        let entry = sourceFailures[url] ?? (0, nil)
        let count = entry.0 + 1
        if count >= Self.blockThreshold {
            sourceFailures[url] = (count, Date().addingTimeInterval(Self.blockDuration))
        } else {
            sourceFailures[url] = (count, nil)
        }
    }

    private func recordSuccess(_ url: String) {
        sourceFailures[url] = (0, nil)
    }

    func search(key: String, precisionSearch: Bool = false) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        currentTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        self.activeSearchKey = key
        self.activePrecision = precisionSearch

        // 1. 入历史
        addToHistory(key)

        // 2. 拉本地缓存的源 + 熔断过滤.
        //    万象书屋 (M2.4 perf): deeplink 跳过 splash 后, App 启动 1-2s 内
        //    BookSourceRegistry.bootstrap 还在拉源, enabledSources 此刻可能是空.
        //    死等 sources ready 最多 3s (bootstrap 通常 1s 内完成), 避免 search 立刻
        //    return 0 条把 UI 打到 empty state.
        results = []
        errors = []
        dedupeRowIndex.removeAll()
        isSearching = true
        let sources = await waitForSources(timeoutSec: 3)
        activeSources = sources

        // 3. 没源时直接 stub 一条提示
        guard !sources.isEmpty else {
            results = []
            isSearching = false
            return
        }

        currentTask = Task {
            // BookSourceEngine.searchAll 是 AsyncStream, 边出边渲染
            let stream = await BookSourceEngine.shared.searchAll(in: sources, key: key)
            for await (source, result) in stream {
                if Task.isCancelled || generation != self.searchGeneration { break }
                switch result {
                case .success(let books):
                    self.recordSuccess(source.bookSourceUrl)
                    for b in books {
                        if Task.isCancelled || generation != self.searchGeneration { break }
                        if self.activePrecision,
                           SearchLegadoOrdering.relevanceTier(book: b, key: self.activeSearchKey) >= 2 {
                            continue
                        }
                        // 万象书屋: 完全对齐 Android `SearchModel.mergeItems` —
                        //   `pBook.name == nBook.name && pBook.author == nBook.author` 严格比.
                        // 不再用 normalize 过的 dedupeKey, 否则会比 Android 多合并一些条目, 行数对不上.
                        let dk = b.androidStrictMergeKey
                        if let idx = self.dedupeRowIndex[dk] {
                            var row = self.results[idx]
                            var seen = Set<String>([row.origin])
                            seen.formUnion(row.mergedSourceURLs)
                            if !seen.contains(b.origin) {
                                row.mergedSourceURLs.append(b.origin)
                                row.mergedSourceNames.append(b.originName)
                            }
                            let rowIntroEmpty = row.intro.map {
                                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            } ?? true
                            if rowIntroEmpty,
                               let bi = b.intro?.trimmingCharacters(in: .whitespacesAndNewlines), !bi.isEmpty {
                                row.intro = b.intro
                            }
                            if (row.coverUrl?.isEmpty ?? true), let c = b.coverUrl, !c.isEmpty { row.coverUrl = c }
                            if (row.lastChapter?.isEmpty ?? true), let l = b.lastChapter, !l.isEmpty {
                                row.lastChapter = l
                            }
                            self.results[idx] = row
                        } else {
                            var first = b
                            first.mergedSourceURLs = []
                            first.mergedSourceNames = []
                            self.dedupeRowIndex[dk] = self.results.count
                            self.results.append(first)
                        }
                    }
                    // 万象书屋: 对齐 Android SearchModel.mergeItems 的最终展示顺序 —
                    // 先「书名或作者完全等于关键词」, 再「包含关键词」, 其余按非精准模式保留.
                    // iOS 之前按 AsyncStream 完成顺序追加, 导致同一关键词下与安卓列表顺序差很多
                    // (用户体感「搜青山两边不一样」).
                    self.applyLegadoStyleOrdering()
                case .failure(let err):
                    if generation != self.searchGeneration { break }
                    self.recordFailure(source.bookSourceUrl)
                    self.errors.append((source, err))
                }
            }
            if generation == self.searchGeneration {
                self.applyLegadoStyleOrdering()
                self.isSearching = false
            }
        }
    }

    private func applyLegadoStyleOrdering() {
        results = SearchLegadoOrdering.sort(
            books: results,
            key: activeSearchKey,
            precision: activePrecision
        )
    }

    // MARK: - 本地源 (M0-B 后端 platform=ios 后真拉远端)

    /// 万象书屋 (P1 fix): 走 BookSourceRegistry, 它启动时就从 /api/sources 拉了
    private func loadCachedSources() -> [BookSource] {
        return BookSourceRegistry.shared.enabledSources
    }

    /// 万象书屋 (M2.4 perf): 等 BookSourceRegistry 就绪 (`isLoaded=true`) 再返回 sources;
    /// 超时仍返回当前内存里的 (可能空). deeplink 跳过 splash 后用户立即触发搜索时关键 —
    /// bootstrap 拉源通常 < 1s, 用户感知不到这个等待.
    private func waitForSources(timeoutSec: Double) async -> [BookSource] {
        let registry = BookSourceRegistry.shared
        let allSources = registry.enabledSources
        if registry.isLoaded && !allSources.isEmpty {
            return allSources.filter { !isBlocked($0.bookSourceUrl) }
        }
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let s = registry.enabledSources
            if registry.isLoaded && !s.isEmpty {
                return s.filter { !isBlocked($0.bookSourceUrl) }
            }
            if Task.isCancelled { break }
        }
        return registry.enabledSources.filter { !isBlocked($0.bookSourceUrl) }
    }

    // MARK: - 历史

    private func loadHistory() {
        history = UserDefaults.standard.stringArray(forKey: Self.kHistory) ?? []
    }

    private func addToHistory(_ key: String) {
        var h = history.filter { $0 != key }
        h.insert(key, at: 0)
        if h.count > Self.kMaxHistory { h = Array(h.prefix(Self.kMaxHistory)) }
        history = h
        UserDefaults.standard.set(h, forKey: Self.kHistory)
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: Self.kHistory)
    }
}

#Preview {
    SearchView()
}
