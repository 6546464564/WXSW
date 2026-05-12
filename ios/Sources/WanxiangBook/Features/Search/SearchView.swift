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

/// 万象书屋 (M2.8): 搜索结果二次过滤选项. 跟 Android Legado 搜索结果页的 sortFilter chips 对齐.
public enum SearchResultFilter: String, Hashable {
    case all
    case multiSource    // 源数 ≥ 2 (被多个源收录, 通常质量高)
    case longBook       // 字数 ≥ 100 万
    case recentUpdate   // 30 天内更新过

    public func apply(to books: [SearchBook]) -> [SearchBook] {
        switch self {
        case .all:
            return books
        case .multiSource:
            return books.filter { $0.distinctOriginCount >= 2 }
        case .longBook:
            return books.filter { Self.parseWords($0.wordCount ?? "") >= 1_000_000 }
        case .recentUpdate:
            let cutoff = Date().addingTimeInterval(-30 * 86400)
            return books.filter { Self.parseUpdateDate($0.updateTime ?? "") >= cutoff }
        }
    }

    /// "327.2 万字" / "1234 字" / "327.2万" → Int 字数估算
    private static func parseWords(_ s: String) -> Int {
        let t = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "字", with: "")
        // 形如 "327.2万" / "327万"
        if t.contains("万") {
            let head = t.replacingOccurrences(of: "万", with: "")
            if let n = Double(head) { return Int(n * 10_000) }
        }
        if let n = Int(t) { return n }
        return 0
    }

    /// "2024-09-01 10:23" / "2024-09-01" / "10-28 12:46:37" → Date 估算
    private static func parseUpdateDate(_ s: String) -> Date {
        let formats = [
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd",
            "MM-dd HH:mm:ss", "MM-dd HH:mm"
        ]
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: trimmed) { return d }
        }
        return .distantPast
    }
}

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
    @State private var autoNavigatedOnce = false

    /// 万象书屋 (M2.4 perf): 用 NavigationStack(path:) 取代 navigationDestination(item:).
    /// 后者跟"sheet 内嵌套"一起用时, SwiftUI 偶发把 binding 自动 reset 到 nil 让 push 被 pop —
    /// 这是阻止"sheet→nav→sheet"三层链路自动化的根因. NavigationStack(path:) 由我们自己控制
    /// 数组, 不会被 ancestor sheet 切换状态影响.
    ///
    /// 万象书屋 (UX): 当 `embedded == true` 时, SearchView 被外部 NavigationStack push 进来,
    /// 不再自包 NavigationStack — 用外部 stack 的 path; `navPath` 仅在 embedded=false (deepLink
    /// sheet 入口) 时启用.
    @State private var navPath: [SearchBook] = []
    /// 万象书屋: embedded 模式下用 navigationDestination(item:) 触发 auto push (debug).
    @State private var autoNavBook: SearchBook? = nil

    /// 万象书屋 (M2.8): 搜索结果二次过滤. 默认全部, 用户点 chip 切换.
    @State private var resultFilter: SearchResultFilter = .all

    /// 万象书屋 (UX): 是否被外部 NavigationStack push 进来. 默认 false (兼容 sheet/旧调用).
    /// 书架/书城/排行榜入口都传 true → SearchView 走外部 stack, 顶部为系统返回 ← 而非"取消".
    let embedded: Bool

    init(initialKeyword: String = "", embedded: Bool = false) {
        self.initialKeyword = initialKeyword
        self.embedded = embedded
        self._keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        // 万象书屋 (UX bug fix): row 用 closure-form NavigationLink (见 `resultList`),
        // 不再依赖 `.navigationDestination(for: SearchBook.self)` 全局注册 — 后者在
        // SearchView 自己也是被 push 进来的子节点时, SwiftUI 经常忽视嵌套层的注册.
        // 这里只保留 auto-push (debug 用) 的 item-based destination, 显式不冲突.
        Group {
            if embedded {
                screenBody
            } else {
                NavigationStack(path: $navPath) {
                    screenBody
                }
            }
        }
        .navigationDestination(item: $autoNavBook) { book in
            BookDetailView(book: book, source: BookSourceRegistry.shared.find(origin: book.origin))
        }
    }

    /// 万象书屋: SearchView 内部 UI — 不含 NavigationStack 自身, embedded / 独立两种模式共用.
    private var screenBody: some View {
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
                filterChipsBar
                resultList
            }
        }
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        // 万象书屋: PV 埋点 (跟 Android `SearchActivity` 自动 trackPageName 等价)
        .trackPageView("page_search")
        .toolbar {
            if !embedded {
                // 万象书屋 (UX): 仅在 sheet 模式下提供"取消"; embedded push 模式下走系统返回 ←
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
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
            if embedded {
                autoNavBook = first
            } else {
                navPath = [first]
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

    /// 万象书屋 (M2.8): 搜索结果二次过滤. 84 源搜热门词常返 100+ 条, 加 chips
    /// 让用户快速聚焦. 跟 Android Legado 搜索结果页的 sortFilter chips 对齐.
    @ViewBuilder
    private var filterChipsBar: some View {
        if !vm.results.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(.all, label: "全部")
                    filterChip(.multiSource, label: "多源 (≥2)")
                    filterChip(.longBook, label: "百万字+")
                    filterChip(.recentUpdate, label: "近期更新")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(WanxiangColors.background)
        }
    }

    @ViewBuilder
    private func filterChip(_ f: SearchResultFilter, label: String) -> some View {
        let selected = resultFilter == f
        Button {
            resultFilter = f
        } label: {
            Text(label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected
                    ? WanxiangColors.primary.opacity(0.18)
                    : WanxiangColors.divider.opacity(0.5)))
                .foregroundStyle(selected ? WanxiangColors.primary : WanxiangColors.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private var resultList: some View {
        let books = displayResults
        return List {
            Section {
                // 万象书屋 (D-25 fix): id 改用 listRowId — 用 origin+name+author+bookUrl
                // 避免某些源 (例: QQ浏览器柳树) bookUrl 因解析 bug 全相同时, SwiftUI
                // 把不同书识别成同一行, 用户体感"19 本书全是同一本".
                ForEach(books, id: \.listRowId) { book in
                    // 万象书屋 (UX bug fix · push 重构): SearchView 既可能被外部 stack push
                    // 进来 (embedded), 也可能自包 NavigationStack (sheet/deepLink). 两种
                    // 模式下都要能 push 到详情 → 用 closure-form NavigationLink (destination
                    // 闭包绑定 NavigationLink 自身) 不依赖 `.navigationDestination(for:)` 全局
                    // 注册, 避免嵌套场景 SwiftUI 丢失注册的 known issue.
                    NavigationLink {
                        // 万象书屋 (2026-05-11 best-source pick): 把"第一个回来"的源换成
                        // "数据质量评分最高"的源进 detail. pickBestSource 看 lastChapter / intro /
                        // wordCount / cover / 历史响应分综合挑. fallback: row.origin 找不到时 nil.
                        let pick = vm.pickBestSource(for: book)
                        BookDetailView(book: pick?.book ?? book, source: pick?.source)
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

    /// 万象书屋 (P0 修复): 渲染层不再做"按标题前 N 字"的全局去重.
    ///   - 旧版本 q.count >= 8 时把所有书塞到同一个全局 key, 导致"搜长名书全是同一本".
    ///   - 旧版本 q.count < 8 时按 title 前 10 字 dedupe, 把不同作者的同名书合一条.
    ///   - 现在只透传 ViewModel 已经按 (name+author) 去重过的 results, 保证
    ///     "捞尸人 / 陈十三", "捞尸人 / 纯洁滴小龙", "黄河捞尸人" 都正常显示.
    /// 万象书屋 (M2.8): 加 resultFilter 二次过滤.
    private var displayResults: [SearchBook] {
        return resultFilter.apply(to: vm.results)
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

    /// 对齐 Android `BaseBook.getKindList`: 先字数, 再 kind 按分隔符拆开.
    private var kindTags: [String] {
        var tags: [String] = []
        var seen = Set<String>()
        func push(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t) else { return }
            seen.insert(t)
            tags.append(t)
        }
        if let w = book.wordCount, !w.isEmpty {
            push(Self.formatWordCount(w))
        }
        if let raw = book.kind?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let parts = raw.split { ch in
                ",，、|｜/\n".contains(ch)
            }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for p in parts { push(p) }
        }
        return tags
    }

    /// 万象书屋 (2026-05-11): 字数显示规范化, 跟 Android `BookSourceConfig.formatWordCount` 一致.
    ///   "2188581" → "218万字"
    ///   "12345"   → "1.2万字"  (一万以上做万化, 保留 1 位)
    ///   "9999"    → "9999字"
    ///   "218万字" / "1.2万" / "218万"  → 原样输出 (已是人类可读)
    static func formatWordCount(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        if s.contains("万") || s.contains("字") || s.contains("k") || s.contains("K") {
            // 已经带单位, 不动
            return s
        }
        // 纯数字 (含千分位逗号) 才走 format
        let cleaned = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard let n = Int(cleaned) else { return s }
        if n >= 10_000 {
            let wan = Double(n) / 10_000
            // ≥100 万取整数, <100 万保留 1 位
            if wan >= 100 {
                return "\(Int(wan))万字"
            } else {
                return String(format: "%.1f万字", wan)
            }
        }
        return "\(n)字"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookCover(url: book.coverUrl, width: 56, height: 78, bookTitle: book.name)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(book.name)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundStyle(WanxiangColors.textPrimary)
                    Spacer(minLength: 4)
                    // 万象书屋: 多源徽章始终显示, 跟 Android `BadgeView.setBadgeCount(origins.size)`
                    // 行为完全一致 — 数字就是同名同作者跨多少个书源被收录到. 1 也照常显示.
                    Text("\(book.distinctOriginCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(WanxiangColors.primary.opacity(0.82)))
                        .accessibilityLabel("\(book.distinctOriginCount) 个书源收录")
                }

                Text(Self.authorLine(book.author))
                    .font(.caption)
                    .foregroundStyle(WanxiangColors.textSecondary)
                    .lineLimit(1)

                if !kindTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(kindTags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(WanxiangColors.divider.opacity(0.55))
                                    .foregroundStyle(WanxiangColors.textSecondary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }

                if let last = book.lastChapter?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
                    Text("最新：\(last)")
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary)
                        .lineLimit(1)
                }

                if let intro = book.intro?.trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty {
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary.opacity(0.92))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        // 万象书屋 (UX 2026-05-11): NavigationLink 默认只在 label 的"实际像素"上响应点击,
        // 行右侧的 Spacer / 角标周边空白不算 → 用户戳右上角"1"附近没反应.
        // contentShape 把整行 bounding box 全设为点击区, 跟 List row 默认全行可点的预期一致.
        .contentShape(Rectangle())
    }

    private static func authorLine(_ author: String) -> String {
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? "作者：未知" : "作者：\(a)"
    }
}

// MARK: - 对齐 Android SearchModel.mergeItems 的排序 (可单测)

/// 万象书屋: 在 Legado `SearchModel.mergeItems` 的分桶之上做小幅增强 (更可感知的相关性).
///
/// 与 Android 一致的部分:
///   1. 三档分桶: equal (书名或作者 **trim 后等于** key) → contains → other (precision=true 时丢)
///   2. 桶内仍优先按 `distinctOriginCount` (≈ origins.size) 降序, 再用稳定序打破平局.
///
/// iOS 额外细化 (不影响跨平台「同名同作者合并」, 只影响展示顺序):
///   - equal 桶: 书名精确命中优先于「仅作者名等于关键词」.
///   - contains 桶: 优先书名命中关键词; 书名均命中时关键词出现位置越靠前越好, 其次书名更短优先.
enum SearchLegadoOrdering {
    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// - 0: 书名或作者**等于**关键词 (trim 后比较, 避免解析多出空格导致误判进包含桶)
    /// - 1: 书名或作者**包含**关键词
    /// - 2: 其余 (精准搜索时丢弃)
    static func relevanceTier(book: SearchBook, key: String) -> Int {
        let k = trimmed(key)
        guard !k.isEmpty else { return 2 }
        let n = trimmed(book.name)
        let a = trimmed(book.author)
        if n == k || a == k { return 0 }
        if n.contains(k) || a.contains(k) { return 1 }
        return 2
    }

    /// 关键词在书名中的首次出现位置 (越靠前越相关). 书名不含关键词时用极大值占位.
    private static func keywordLeadingIndexInName(book: SearchBook, key k: String) -> Int {
        let n = trimmed(book.name)
        guard let r = n.range(of: k) else { return Int.max / 4 }
        return n.distance(from: n.startIndex, to: r.lowerBound)
    }

    /// 万象书屋 (2026-05-11): SearchBook.wordCount 字段归一化为 Int 字数估算.
    /// 用作 tier 内的"热度"代理 — 大字数书通常是连载/完结的热门书, 应排在前面.
    /// 对齐 Android `BookSourceConfig.changeSourceLoadWordCount` 排序意图.
    /// 解析失败 / 无字段返 0 (排到字数有数据的书后面, 不打破已有 tie-breaker).
    /// "421万字" / "1.2万" / "12000" / "421万" 都支持.
    static func wordCountInt(_ book: SearchBook) -> Int {
        guard let raw = book.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return 0 }
        let t = raw.replacingOccurrences(of: " ", with: "")
                   .replacingOccurrences(of: "字", with: "")
        if t.contains("万") {
            let head = t.replacingOccurrences(of: "万", with: "")
            if let n = Double(head) { return Int(n * 10_000) }
        }
        if let n = Int(t) { return n }
        // 提取首段连续数字 (例如 "12,345" / "12,345章" 这类)
        if let regex = try? NSRegularExpression(pattern: #"\d+"#),
           let m = regex.firstMatch(in: t, range: NSRange(0..<(t as NSString).length)),
           let r = Range(m.range, in: t),
           let n = Int(t[r]) {
            return n
        }
        return 0
    }

    static func sort(books: [SearchBook], key: String, precision: Bool) -> [SearchBook] {
        let k = trimmed(key)
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

            // 完全匹配桶内: 书名精确命中优先于「仅作者名恰好等于关键词」.
            if ta == 0 {
                let ln = trimmed(lhs.1.name) == k
                let rn = trimmed(rhs.1.name) == k
                if ln != rn { return ln && !rn }
            }

            // 包含桶内 (对齐 Legado 大桶 + iOS 增强): 优先书名命中; 均书名命中时关键词越靠前越好,
            // 再比较书名长度 (短标题通常更「直指」). Android 仅按 origins.size + 稳定序,
            // 这里多两步缓解「临圣」搜出一堆书名中段命中却把完整书名顶下去」的体感问题.
            if ta == 1 {
                let lName = trimmed(lhs.1.name)
                let rName = trimmed(rhs.1.name)
                let lTitleHit = lName.contains(k)
                let rTitleHit = rName.contains(k)
                if lTitleHit != rTitleHit { return lTitleHit && !rTitleHit }

                if lTitleHit && rTitleHit {
                    let li = keywordLeadingIndexInName(book: lhs.1, key: k)
                    let ri = keywordLeadingIndexInName(book: rhs.1, key: k)
                    if li != ri { return li < ri }
                    if lName.count != rName.count { return lName.count < rName.count }
                }
            }

            // 万象书屋 (2026-05-11): tier 0/1 内的"热度"代理 — 字数大的书优先,
            // 跟 Android `wordCountComparator` 思路一致 (大字数 → 老 IP / 连载到位).
            // 用户搜"青山", 三本同名: "青山(421万字)" vs "青山(无)" vs "青山(无)",
            // 让 421 万字的那本先冒出来; 体感跟 Android 第一名一致.
            // 只在 tier 2 (其他) 不参与 — 那本身就快被淘汰了, 字数无意义.
            if ta < 2 {
                let lw = wordCountInt(lhs.1)
                let rw = wordCountInt(rhs.1)
                if lw != rw { return lw > rw }
            }

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
    /// `dedupeKey` (normalized name+author) → `results` 下标, 同名同作者跨源合并为一行
    /// (对齐 Android `addOrigin`). 2026-05-11 起从 `androidStrictMergeKey` (严格 ==) 切换到
    /// `dedupeKey` — 跨源 (name, author) 因空白/标点差异不能 byte-相等导致合并失败,
    /// 切换后合并率显著提高.
    private var dedupeRowIndex: [String: Int] = [:]
    /// 万象书屋 (2026-05-11 best-source pick): 每个 dedupeKey 对应的所有源变体 SearchBook.
    /// 用户点 row → `pickBestSource` 按数据质量评分挑一个进 detail, 不再用"第一个回来的"作为
    /// 默认源 — 解决"七猫小说返 1970 / 目录加载失败"这类垃圾源被随机选中的问题.
    private var rowVariants: [String: [SearchBook]] = [:]
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
        enrichmentTask?.cancel()
        enrichedKeys.removeAll()
        rowVariants.removeAll()
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
        let rawSources = await waitForSources(timeoutSec: 3)
        // 万象书屋 (M2.8): 按历史成功率 + 平均响应时间排序源, 让稳定快的源先返结果.
        // 84 源里很多反爬/死站, 没排序时用户得等所有源 timeout. 排序后头几条结果
        // 通常是历史好源, 用户感知速度显著提升.
        let sources = SourcePerformanceTracker.shared.sortByScore(rawSources)
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
                // 万象书屋 (M2.8): 记录单源 search 表现给 SourcePerformanceTracker.
                // 没记 ms (BookSourceEngine.searchAll 没暴露 per-source duration);
                // 用一个粗粒度估计 — 命中=快返 1500ms, 0 命中=可能慢=4000ms, 失败=8000ms.
                let estMs: Int
                let okFlag: Bool
                switch result {
                case .success(let books):
                    okFlag = true
                    estMs = books.isEmpty ? 4000 : 1500
                case .failure:
                    okFlag = false
                    estMs = 8000
                }
                SourcePerformanceTracker.shared.record(
                    sourceUrl: source.bookSourceUrl, ok: okFlag, durationMs: estMs
                )
                switch result {
                case .success(let books):
                    self.recordSuccess(source.bookSourceUrl)
                    for b in books {
                        if Task.isCancelled || generation != self.searchGeneration { break }
                        if self.activePrecision,
                           SearchLegadoOrdering.relevanceTier(book: b, key: self.activeSearchKey) >= 2 {
                            continue
                        }
                        // 万象书屋 (2026-05-11): 合并 key 从 `androidStrictMergeKey` (严格 ==)
                        // 改成 `dedupeKey` (normalized: trim + 半角化 + lowercase + 去"作者:"前缀
                        // + 只留字母数字汉字). 1800+ 源里同一本书的 name/author 经常因为
                        // `\u3000` 全角空格 / " 著"后缀 / 标点不同 等原因不能 byte-相等, 导致
                        // 多源命中无法合并, "源数" 永远是 1. dedupeKey 容错后, 同名同作者的不同源
                        // 才能真正合并成"N 源" — 用户看到的多源徽章才有意义.
                        let dk = b.dedupeKey
                        // 万象书屋 (best-source pick): 把这本书的当前源变体存进 rowVariants,
                        // 用户点 row 时 pickBestSource 从所有变体里挑数据最完整的源.
                        var bForVariant = b
                        bForVariant.mergedSourceURLs = []
                        bForVariant.mergedSourceNames = []
                        self.rowVariants[dk, default: []].append(bForVariant)
                        // 万象书屋 (2026-05-11): 同时落进程级 cache, 让 BookDetailView 在 TOC fallback
                        // 时能拿到每个备用源**自己的 bookUrl**, 而不是用主 row 的 bookUrl 跨源乱用.
                        SearchVariantsCache.shared.set(key: dk, variants: self.rowVariants[dk] ?? [])
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
                            if (row.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                               let w = b.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty {
                                row.wordCount = b.wordCount
                            }
                            if (row.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                               let kd = b.kind?.trimmingCharacters(in: .whitespacesAndNewlines), !kd.isEmpty {
                                row.kind = b.kind
                            }
                            if (row.updateTime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                               let u = b.updateTime?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
                                row.updateTime = b.updateTime
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
                // 万象书屋 (M2.8): 把这次 search 的 stats 落盘, 下次启动也能用上排序.
                SourcePerformanceTracker.shared.persistToDisk()
                // 万象书屋 (2026-05-11): 搜索结束后给前 12 行做一轮 info 富化, 给那些
                // 搜索接口没返 cover/kind/wordCount 的源补全字段. Android 之所以"全有真封面"
                // 是因为 searchBookDao 里历史数据也帮充, 加上很多源 search 接口本身就带 cover;
                // iOS 这里靠主动 fetchInfo 在背景补完, 不阻塞主流程.
                self.scheduleResultEnrichment(generation: generation)
            }
        }
    }

    private func applyLegadoStyleOrdering() {
        results = SearchLegadoOrdering.sort(
            books: results,
            key: activeSearchKey,
            precision: activePrecision
        )
        // 万象书屋 (2026-05-11 critical bug fix): 排序后 results 顺序变, dedupeRowIndex 里
        // 记的 idx 全部漂移 — 下次新源命中同一本书时拿到错误 idx, 要么合并到错误的行, 要么
        // 新建一行 → 永远显示 "1 源". Android 不必处理这个因为它的列表数据结构是 mutable List
        // 不靠 idx 索引. iOS 用 Dictionary[dedupeKey: Int], 排序后必须重建.
        dedupeRowIndex.removeAll(keepingCapacity: true)
        for (i, book) in results.enumerated() {
            dedupeRowIndex[book.dedupeKey] = i
        }
    }

    // MARK: - 结果富化 (cover / kind / wordCount fill-in)

    /// 万象书屋: 已经发起过 enrichment 的 (origin, bookUrl) 集, 避免重复打.
    private var enrichedKeys: Set<String> = []
    private var enrichmentTask: Task<Void, Never>? = nil

    private func scheduleResultEnrichment(generation: Int) {
        enrichmentTask?.cancel()
        // 取前 12 行里 cover/kind/wordCount 任一缺失的 (origin, bookUrl) 作为 target
        let targets: [(SearchBook, BookSource)] = results.prefix(12).compactMap { b in
            let key = "\(b.origin)::\(b.bookUrl)"
            guard !enrichedKeys.contains(key) else { return nil }
            let missingCover = (b.coverUrl?.isEmpty ?? true)
            let missingKind = (b.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let missingWords = (b.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard missingCover || missingKind || missingWords else { return nil }
            guard let src = BookSourceRegistry.shared.find(origin: b.origin) else { return nil }
            return (b, src)
        }
        guard !targets.isEmpty else { return }
        for (b, _) in targets {
            enrichedKeys.insert("\(b.origin)::\(b.bookUrl)")
        }
        enrichmentTask = Task { [weak self] in
            await self?.runEnrichment(targets: targets, generation: generation)
        }
    }

    /// 万象书屋: 4 个 in-flight 并发跑 fetchInfo, 每个 6s timeout (硬性, 慢源直接放弃).
    /// 命中后 merge 进对应 row, applyLegadoStyleOrdering 重排.
    private func runEnrichment(
        targets: [(SearchBook, BookSource)], generation: Int
    ) async {
        await withTaskGroup(of: (SearchBook, BookInfo)?.self) { group in
            var iter = targets.makeIterator()
            let cap = min(4, targets.count)

            @discardableResult
            func addNext() -> Bool {
                guard let t = iter.next() else { return false }
                group.addTask {
                    let (b, src) = t
                    return await Self.fetchInfoWithTimeout(book: b, source: src, timeoutSec: 6)
                }
                return true
            }
            for _ in 0..<cap { _ = addNext() }
            while let r = await group.next() {
                if Task.isCancelled || generation != self.searchGeneration { break }
                if let (b, info) = r {
                    self.mergeInfoIntoRow(book: b, info: info)
                }
                addNext()
            }
        }
        if generation == self.searchGeneration {
            self.applyLegadoStyleOrdering()
        }
    }

    private nonisolated static func fetchInfoWithTimeout(
        book: SearchBook, source: BookSource, timeoutSec: TimeInterval
    ) async -> (SearchBook, BookInfo)? {
        await withTaskGroup(of: BookInfo?.self) { inner -> (SearchBook, BookInfo)? in
            inner.addTask {
                return try? await BookSourceEngine.shared.fetchInfo(of: book, in: source)
            }
            inner.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                return nil
            }
            for await v in inner {
                inner.cancelAll()
                if let v { return (book, v) }
                // 第一个 race 结束但没拿到 info → 超时/失败, 跳过
                return nil
            }
            return nil
        }
    }

    /// 万象书屋 (2026-05-11): 用户点 row → 从所有源变体里挑数据质量最高的源 (book + source) 进 detail.
    ///
    /// 旧逻辑: BookDetailView 用 `BookSourceRegistry.find(origin: row.origin)`, row.origin 是
    /// "第一个回来的源" — 如果这个源数据质量糟 (lastChapter='1970'/目录加载失败), 用户得手动换源.
    ///
    /// 新逻辑: 评分所有变体 (含主 origin + mergedSourceURLs 对应的 SearchBook), 选分最高的.
    /// 评分维度:
    ///   +50  lastChapter 像真章节 (含 "第" / "章" / "卷")
    ///   +20  intro ≥10 字符 (剔除 "暂无简介")
    ///   +10  wordCount 含数字
    ///   +5   coverUrl 非空
    ///   +SourcePerformanceTracker.score (0..100 区间, 历史快源加分)
    ///   −100 source not blocked but search failed history
    ///
    /// row 来自磁盘 cache / 历史 (没参与本次 search) 时 rowVariants 空 → fallback 到原逻辑.
    func pickBestSource(for row: SearchBook) -> (book: SearchBook, source: BookSource)? {
        let dk = row.dedupeKey
        let variants = rowVariants[dk] ?? []
        if variants.isEmpty {
            // 历史 row / 磁盘 cache → 仍按 row.origin 找
            if let src = BookSourceRegistry.shared.find(origin: row.origin) {
                return (row, src)
            }
            return nil
        }
        let stats = SourcePerformanceTracker.shared.allStats()
        var scored: [(score: Double, book: SearchBook, source: BookSource)] = []
        for v in variants {
            guard let src = BookSourceRegistry.shared.find(origin: v.origin) else { continue }
            var s: Double = 0
            // lastChapter 像真章节
            if let lc = v.lastChapter?.trimmingCharacters(in: .whitespacesAndNewlines), !lc.isEmpty {
                if lc.contains("章") || lc.contains("卷") || lc.contains("第") || lc.contains("话") || lc.contains("回") {
                    s += 50
                } else if Int(lc) == nil {
                    // 至少不是纯数字垃圾 (例如 "1970")
                    s += 20
                }
            }
            if let intro = v.intro?.trimmingCharacters(in: .whitespacesAndNewlines), intro.count >= 10 {
                s += 20
            }
            if let wc = v.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines),
               !wc.isEmpty,
               wc.rangeOfCharacter(from: .decimalDigits) != nil {
                s += 10
            }
            if let cv = v.coverUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !cv.isEmpty {
                s += 5
            }
            // 历史源响应分 (新源中性 50)
            s += stats[src.bookSourceUrl]?.score ?? 50
            scored.append((s, v, src))
        }
        guard !scored.isEmpty else { return nil }
        // 按分降序; 同分时保留输入顺序 (Swift 排序非稳定, 加 index tiebreak)
        let withIdx = scored.enumerated().map { ($0.offset, $0.element) }
        let sorted = withIdx.sorted { lhs, rhs in
            if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
            return lhs.0 < rhs.0
        }
        let best = sorted[0].1
        return (best.book, best.source)
    }

    private func mergeInfoIntoRow(book: SearchBook, info: BookInfo) {
        guard let idx = results.firstIndex(where: {
            $0.origin == book.origin && $0.bookUrl == book.bookUrl
        }) else { return }
        var r = results[idx]
        if (r.coverUrl?.isEmpty ?? true), let c = info.coverUrl, !c.isEmpty {
            r.coverUrl = c
        }
        if (r.intro?.isEmpty ?? true), let i = info.intro, !i.isEmpty {
            r.intro = i
        }
        if (r.kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let k = info.kind?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            r.kind = info.kind
        }
        if (r.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let w = info.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty {
            r.wordCount = info.wordCount
        }
        if (r.lastChapter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let l = info.lastChapter?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty {
            r.lastChapter = info.lastChapter
        }
        if (r.updateTime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let u = info.updateTime?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
            r.updateTime = info.updateTime
        }
        results[idx] = r
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
        if registry.isLoaded, !registry.enabledSources.isEmpty {
            return registry.enabledSources.filter { !isBlocked($0.bookSourceUrl) }
        }
        await registry.waitUntilEnabledSourcesNonEmpty(timeout: timeoutSec)
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
