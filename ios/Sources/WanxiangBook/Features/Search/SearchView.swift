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

    /// 万象书屋: 从书城点 stub 书时, 自动预填关键词 + 立即开搜
    let initialKeyword: String

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
            }
            .onAppear {
                inputFocused = true
                if !initialKeyword.isEmpty && vm.results.isEmpty {
                    Task { await vm.search(key: initialKeyword) }
                }
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
                    Task { await vm.search(key: keyword) }
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
                                Task { await vm.search(key: h) }
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
                ForEach(books, id: \.bookUrl) { book in
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
    }

    /// 万象书屋: 渲染层最终去重。
    /// 搜索是多源并发流式追加, 即便 ViewModel 层做了 generation/Set 防重,
    /// 仍可能因为旧 AsyncStream 的回调或源自身重复导致同名书刷屏。
    /// 这里按 titleDedupeKey 再兜底, 保证 UI 永远只显示唯一书名。
    private var displayResults: [SearchBook] {
        var seen = Set<String>()
        var out: [SearchBook] = []
        out.reserveCapacity(vm.results.count)
        for b in vm.results {
            let k = uiDedupeKey(for: b, query: keyword)
            if seen.insert(k).inserted {
                out.append(b)
            }
        }
        return out
    }

    private func uiDedupeKey(for book: SearchBook, query: String) -> String {
        let title = uiDedupeKey(book.name)
        let q = uiDedupeKey(query)
        if q.count >= 8 {
            // 长书名精确搜索: 只保留响应最快/排序最前的一条。
            // 这比猜测各源返回的脏 title 更稳定, 也符合用户输入完整书名时的预期。
            return "long-query-single-result"
        }
        // 其它场景按标题前 10 个有效字符全局去重。
        return "global::\(String(title.prefix(10)))"
    }

    private func uiDedupeKey(_ raw: String) -> String {
        let cleaned = raw
            .lowercased()
            .unicodeScalars
            .filter { scalar in
                // CJK Unified Ideographs + ASCII letters/digits. 丢弃零宽、标点、emoji、空白等一切不可见差异。
                (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
                    || (scalar.value >= 0x3400 && scalar.value <= 0x4DBF)
                    || (scalar.value >= 0x30 && scalar.value <= 0x39)
                    || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            }
            .map(String.init)
            .joined()
        return String(cleaned.prefix(12))
    }

    // MARK: - 防抖

    private func debounce(_ text: String) {
        debounceTask?.cancel()
        guard !text.isEmpty else {
            vm.results = []
            return
        }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            if !Task.isCancelled {
                await vm.search(key: text)
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
    private var resultKeys = Set<String>()
    private var resultTitleKeys = Set<String>()

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

    func search(key: String) async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        currentTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration

        // 1. 入历史
        addToHistory(key)

        // 2. 拉本地缓存的源 + 熔断过滤
        let allSources = loadCachedSources()
        let sources = allSources.filter { !isBlocked($0.bookSourceUrl) }
        activeSources = sources
        results = []
        errors = []
        resultKeys.removeAll()
        resultTitleKeys.removeAll()
        isSearching = true

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
                        let titleKey = b.titleDedupeKey
                        // 万象书屋: UI 层强去重。正常按 name+author 合并;
                        // 如果同一标题已出现, 后续重复条丢弃, 防止截图那种同一本刷屏。
                        if self.resultKeys.contains(b.dedupeKey) || self.resultTitleKeys.contains(titleKey) { continue }
                        self.resultKeys.insert(b.dedupeKey)
                        self.resultTitleKeys.insert(titleKey)
                        self.results.append(b)
                    }
                case .failure(let err):
                    if generation != self.searchGeneration { break }
                    self.recordFailure(source.bookSourceUrl)
                    self.errors.append((source, err))
                }
            }
            if generation == self.searchGeneration {
                self.isSearching = false
            }
        }
    }

    // MARK: - 本地源 (M0-B 后端 platform=ios 后真拉远端)

    /// 万象书屋 (P1 fix): 走 BookSourceRegistry, 它启动时就从 /api/sources 拉了
    private func loadCachedSources() -> [BookSource] {
        return BookSourceRegistry.shared.enabledSources
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
