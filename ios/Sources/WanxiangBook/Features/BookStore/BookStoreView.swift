//
//  BookStoreView.swift
//  万象书屋 iOS · 书城 (D-22 / D-23 — 1:1 对齐 Android BookStoreFragment)
//
//  对应 Android: io.legado.app.ui.main.bookstore.BookStoreFragment
//
//  布局 (跟 Android fragment_book_store.xml 同):
//   ┌──────────────────────────────────────┐
//   │  顶栏: [男生] [女生] [出版]   🔍       │
//   ├──────────────────────────────────────┤
//   │  Hero card  (月票第一 / 畅销第一 / 经典完本第一)
//   │  ┌─────────┬─────────┐
//   │  │ 排行榜  │ 完本书库 │   ← banner, 跳 RankDetailView
//   │  └─────────┴─────────┘
//   │  今日必读              换一批
//   │  [4×2 grid 8 本]
//   │  完本精选              换一批
//   │  [4×2 grid 8 本]
//   │  推荐榜                换一批
//   │  [4×2 grid 8 本, 带排名徽章]
//   └──────────────────────────────────────┘
//
//  D-22.2 板块映射 (按 channel 决定取哪个 RankType):
//   Male:    Yuepiao + HotReading + NewBook    + Recommend
//   Female:  Bestseller + NewAuthor + Sign     + Update
//   Publish: FinishClassic + FinishClassic + FinishBestSell + FinishMovie
//

import SwiftUI

struct BookStoreView: View {

    @StateObject private var vm = BookStoreViewModel()
    @State private var searchSeed: StoreSearchSeed?
    @State private var navTarget: NavTarget?
    /// 万象书屋 (M2.8): 点书后后台搜的中间态. 显示"正在查找..." HUD,
    /// 找到第一条命中就直跳详情, 失败兜底弹 search sheet.
    @State private var loadingDetailFor: String? = nil
    /// 后台搜命中的 (book, source), trigger navigationDestination push 详情
    @State private var detailTarget: BookDetailTarget?

    var body: some View {
        NavigationStack {
            content
                .background(WanxiangColors.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                // 万象书屋 (UX): 搜索改成 NavigationStack push 的全屏单独页, 不再用 sheet 弹框.
                .navigationDestination(item: $searchSeed) { seed in
                    SearchView(initialKeyword: seed.keyword, embedded: true)
                }
                .navigationDestination(item: $navTarget) { target in
                    switch target {
                    case .rank(let type, let title):
                        RankDetailView(mode: .rank(type), title: title)
                    case .finish(let title):
                        RankDetailView(mode: .finish, title: title)
                    }
                }
                .navigationDestination(item: $detailTarget) { t in
                    BookDetailView(book: t.book, source: t.source)
                }
                .overlay(alignment: .center) {
                    if loadingDetailFor != nil {
                        bookstoreLoadingHUD
                    }
                }
                .task(id: vm.currentChannel) { await vm.loadIfNeeded(force: false) }
        }
    }

    /// 万象书屋 (M2.8): 书城点书改为"后台静默搜 → 直跳详情" — 不再弹 SearchView 让用户重搜.
    /// 流程:
    ///   1. 显示 HUD "正在查找..."
    ///   2. 按 SourcePerformanceTracker 排序拿前 8 个最稳源, 并发搜 book.name
    ///   3. 第一个 (name == name) 命中 → push 到 BookDetailView (只用真书源!)
    ///   4. 5 秒内没结果 → 兜底弹 SearchView 让用户手动选源
    /// 这里做"后台搜"的好处: 用户不必看一长串结果, 直接进详情读. 跟 Android Legado
    /// 书城点书行为一致.
    private func tapBookCell(_ qidianBook: QidianBook) {
        let key = qidianBook.name
        let token = key + "::" + UUID().uuidString
        loadingDetailFor = token

        Task {
            // 1. 拿排序后的前 8 个源
            let allSources = BookSourceRegistry.shared.sources
            let sorted = SourcePerformanceTracker.shared.sortByScore(allSources)
            let candidates = Array(sorted.prefix(8))
            guard !candidates.isEmpty else {
                fallbackToSearch(key: key, token: token)
                return
            }
            // 2. 并发搜, 拿到第一个名字精确匹配的
            let stream = await BookSourceEngine.shared.searchAll(
                in: candidates, key: key, maxConcurrency: 5, perSourceTimeoutSec: 5
            )
            var found: (SearchBook, BookSource)? = nil
            for await (src, result) in stream {
                if loadingDetailFor != token { return }    // 用户取消 / 切走
                guard case .success(let books) = result else { continue }
                if let m = books.first(where: { $0.name == key }) {
                    found = (m, src)
                    break
                }
            }
            await MainActor.run {
                guard loadingDetailFor == token else { return }
                if let (book, source) = found {
                    self.loadingDetailFor = nil
                    self.detailTarget = BookDetailTarget(book: book, source: source)
                } else {
                    self.fallbackToSearch(key: key, token: token)
                }
            }
        }
    }

    private func fallbackToSearch(key: String, token: String) {
        Task { @MainActor in
            guard loadingDetailFor == token else { return }
            loadingDetailFor = nil
            searchSeed = StoreSearchSeed(keyword: key)
        }
    }

    /// 万象书屋 (M2.8): 简单 HUD overlay. 点 cancel 中断后台搜, 让用户手动搜.
    private var bookstoreLoadingHUD: some View {
        VStack(spacing: 14) {
            ProgressView().scaleEffect(1.2)
            Text("正在查找最佳书源…")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textPrimary)
            Button("跳过, 手动搜") {
                if let token = loadingDetailFor {
                    fallbackToSearch(
                        key: String(token.split(separator: "::").first ?? ""),
                        token: token
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(WanxiangColors.primary)
        }
        .padding(28)
        .background(WanxiangColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                LazyVStack(spacing: 16) {
                    if vm.isLoading && vm.allBooks.isEmpty {
                        loadingPlaceholder
                    } else if vm.allBooks.isEmpty {
                        loadFailedPlaceholder
                    } else {
                        if let hero = vm.heroBook {
                            heroCard(hero)
                        }
                        bannerRow
                        sectionGrid(
                            title: vm.mustReadType.title,
                            books: vm.mustReadBooks,
                            onSwap: { vm.swap(.mustRead) }
                        )
                        sectionGrid(
                            title: vm.completeType.title,
                            books: vm.completeBooks,
                            onSwap: { vm.swap(.complete) }
                        )
                        sectionRanked(
                            title: vm.recommendType.title,
                            books: vm.recommendBooks,
                            onSwap: { vm.swap(.recommend) }
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 92)
            }
            .refreshable { await vm.loadIfNeeded(force: true) }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            ForEach(QidianChannel.allCases) { channel in
                tabButton(channel: channel)
            }
            Spacer()
            Button {
                searchSeed = StoreSearchSeed(keyword: "")
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(WanxiangColors.textPrimary)
                    .padding(10)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            // 跟 Android bg_cosmic_top_bar 类似的渐变 (玻璃质感顶栏)
            LinearGradient(
                colors: [WanxiangColors.background, WanxiangColors.card],
                startPoint: .top, endPoint: .bottom
            )
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.05)).frame(height: 0.5)
            }
            .ignoresSafeArea(edges: .top)
        )
    }

    private func tabButton(channel: QidianChannel) -> some View {
        let active = (vm.currentChannel == channel)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                vm.switchChannel(to: channel)
            }
        } label: {
            VStack(spacing: 4) {
                Text(channel.title)
                    .font(.system(size: active ? 20 : 17, weight: active ? .bold : .regular))
                    .foregroundStyle(active ? WanxiangColors.textPrimary : WanxiangColors.textSecondary)
                Capsule()
                    .fill(active ? WanxiangColors.primary : .clear)
                    .frame(width: 22, height: 3)
            }
            .padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero

    private func heroCard(_ book: QidianBook) -> some View {
        Button {
            tapBookCell(book)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                BookCover(url: book.coverUrl, width: 96, height: 128)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("榜首")
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(red: 0.92, green: 0.27, blue: 0.27)))
                            .foregroundStyle(.white)
                        Text(book.rankName)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WanxiangColors.primary)
                    }
                    Text(book.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(WanxiangColors.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if !book.author.isEmpty {
                            Text(book.author)
                                .font(.caption)
                                .foregroundStyle(WanxiangColors.textSecondary)
                        }
                        let tag = book.subCategory.isEmpty ? book.category : book.subCategory
                        if !tag.isEmpty {
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(WanxiangColors.primary.opacity(0.10)))
                                .foregroundStyle(WanxiangColors.primary)
                        }
                    }
                    if !book.intro.isEmpty {
                        Text(book.intro)
                            .font(.caption)
                            .foregroundStyle(WanxiangColors.textSecondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(WanxiangColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Banner

    private var bannerRow: some View {
        HStack(spacing: 12) {
            bannerCard(
                title: "热门排行",
                subtitle: "月票 TOP 50",
                icon: "flame.fill",
                gradient: [
                    Color(red: 0.96, green: 0.50, blue: 0.32),
                    Color(red: 0.94, green: 0.30, blue: 0.30),
                ]
            ) {
                WanxiangAnalytics.shared.track("bs_banner_rank", type: "click")
                navTarget = .rank(.yuepiao, "热门排行")
            }
            bannerCard(
                title: "完本书库",
                subtitle: "经典完结 50 本",
                icon: "books.vertical.fill",
                gradient: [
                    Color(red: 0.78, green: 0.92, blue: 0.83),
                    Color(red: 0.96, green: 0.78, blue: 0.50),
                ]
            ) {
                WanxiangAnalytics.shared.track("bs_banner_library", type: "click")
                navTarget = .finish("完本书库")
            }
        }
    }

    private func bannerCard(
        title: String, subtitle: String, icon: String,
        gradient: [Color], action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    Spacer()
                    Image(systemName: icon)
                        .font(.system(size: 30))
                        .foregroundStyle(.white.opacity(0.42))
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sections

    /// 普通 grid (今日必读 / 完本精选): 4×2 = 8 本, 封面 + 名 + 作者 + tag, 部分带 TOP1/2/3 徽章
    private func sectionGrid(
        title: String,
        books: [QidianBook],
        onSwap: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title, onSwap: onSwap)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                ForEach(books, id: \.id) { book in
                    Button {
                        tapBookCell(book)
                    } label: {
                        gridCell(book: book)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(WanxiangColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    /// 推荐榜 grid: 跟普通 grid 一样布局, 但徽章用真排名 (1 红 2/3 金 4+ 灰)
    private func sectionRanked(
        title: String,
        books: [QidianBook],
        onSwap: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title, onSwap: onSwap)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                ForEach(Array(books.enumerated()), id: \.offset) { idx, book in
                    Button {
                        tapBookCell(book)
                    } label: {
                        rankedCell(book: book, displayRank: idx + 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(WanxiangColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
    }

    private func sectionHeader(title: String, onSwap: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(WanxiangColors.textPrimary)
            Spacer()
            Button(action: onSwap) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                    Text("换一批")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(WanxiangColors.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(WanxiangColors.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)
        }
    }

    private func gridCell(book: QidianBook) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                GeometryReader { geo in
                    let h = geo.size.width * 4.0 / 3
                    BookCover(url: book.coverUrl, width: geo.size.width, height: h)
                }
                .aspectRatio(3.0/4.0, contentMode: .fit)
                if book.rank == 1 {
                    badge(text: "榜首", color: Color(red: 0.92, green: 0.27, blue: 0.27))
                } else if book.rank == 2 || book.rank == 3 {
                    badge(text: "TOP\(book.rank)", color: Color(red: 0.85, green: 0.69, blue: 0.20))
                }
            }
            Text(book.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(WanxiangColors.textPrimary)
                .lineLimit(1)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.caption2)
                    .foregroundStyle(WanxiangColors.textSecondary)
                    .lineLimit(1)
            }
            let tag = book.subCategory.isEmpty ? book.category : book.subCategory
            if !tag.isEmpty {
                Text(tag)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(WanxiangColors.primary.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankedCell(book: QidianBook, displayRank: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                GeometryReader { geo in
                    let h = geo.size.width * 4.0 / 3
                    BookCover(url: book.coverUrl, width: geo.size.width, height: h)
                }
                .aspectRatio(3.0/4.0, contentMode: .fit)
                Text("\(displayRank)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(rankColor(for: displayRank).clipShape(Circle()))
                    .padding(4)
            }
            Text(book.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(WanxiangColors.textPrimary)
                .lineLimit(1)
            if !book.author.isEmpty {
                Text(book.author)
                    .font(.caption2)
                    .foregroundStyle(WanxiangColors.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.clipShape(Capsule()))
            .padding(4)
    }

    private func rankColor(for rank: Int) -> Color {
        switch rank {
        case 1: return Color(red: 0.92, green: 0.27, blue: 0.27)
        case 2: return Color(red: 0.95, green: 0.55, blue: 0.18)
        case 3: return Color(red: 0.85, green: 0.69, blue: 0.20)
        default: return Color.black.opacity(0.45)
        }
    }

    // MARK: - Placeholders

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            ProgressView()
            Text("正在加载书城…")
                .font(.caption)
                .foregroundStyle(WanxiangColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var loadFailedPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer().frame(height: 60)
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.6))
            Text("加载失败,下拉重试")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textSecondary)
            Button("重试") { Task { await vm.loadIfNeeded(force: true) } }
                .buttonStyle(.borderedProminent)
                .tint(WanxiangColors.primary)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Search seed

/// 跟 RankDetailView 共享; 顶层非 private 类型
struct StoreSearchSeed: Identifiable, Hashable {
    let id = UUID()
    let keyword: String

    static func == (lhs: StoreSearchSeed, rhs: StoreSearchSeed) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 万象书屋 (M2.8): 书城点书后, 后台搜命中的目标 — 直跳详情页用.
struct BookDetailTarget: Identifiable, Hashable {
    let id = UUID()
    let book: SearchBook
    let source: BookSource?

    static func == (lhs: BookDetailTarget, rhs: BookDetailTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Navigation target

private enum NavTarget: Hashable {
    case rank(QidianRankType, String)
    case finish(String)

    static func == (lhs: NavTarget, rhs: NavTarget) -> Bool {
        switch (lhs, rhs) {
        case (.rank(let a, _), .rank(let b, _)): return a == b
        case (.finish, .finish): return true
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .rank(let t, _): hasher.combine(0); hasher.combine(t)
        case .finish: hasher.combine(1)
        }
    }
}

// MARK: - ViewModel

/// 万象书屋: 跟 Android `BookStoreFragment` 的状态管理 1:1 对齐.
///
/// 关键 invariant:
///   * channelRankCache: 频道维度 5 分钟 cache, 切 Tab 来回不重发请求
///   * allBooks: 9 榜单合并去重的池, 「换一批」基于此做循环切片
///   * swapPage*: 三个 section 独立翻页计数, 越界回 0
@MainActor
final class BookStoreViewModel: ObservableObject {

    @Published var currentChannel: QidianChannel = .male
    @Published var isLoading = false
    @Published var allBooks: [QidianBook] = []

    private var ranks: [QidianRankType: [QidianBook]] = [:]

    /// 万象书屋 D-22: 频道维度短时缓存 (整张榜单 map + 时间戳).
    private var channelRankCache: [QidianChannel: (ranks: [QidianRankType: [QidianBook]], at: Date)] = [:]
    private let cacheTtl: TimeInterval = 5 * 60

    /// 「换一批」翻页偏移, 跟 Android swapPageMustRead/Complete/Ranked 对齐
    private var swapPageMustRead = 0
    private var swapPageComplete = 0
    private var swapPageRanked = 0

    private var loadTask: Task<Void, Never>?

    enum SwapTarget { case mustRead, complete, recommend }

    // MARK: - Channel-driven RankType

    /// D-22.2 板块映射 (按 channel 决定取哪个 RankType)
    var heroType: QidianRankType {
        switch currentChannel {
        case .male: return .yuepiao
        case .female: return .bestseller
        case .publish: return .finishClassic
        }
    }
    var mustReadType: QidianRankType {
        switch currentChannel {
        case .male: return .hotReading
        case .female: return .newAuthor
        case .publish: return .finishClassic
        }
    }
    var completeType: QidianRankType {
        switch currentChannel {
        case .male: return .newBook
        case .female: return .sign
        case .publish: return .finishBestSell
        }
    }
    var recommendType: QidianRankType {
        switch currentChannel {
        case .male: return .recommend
        case .female: return .update
        case .publish: return .finishMovie
        }
    }

    // MARK: - Derived books

    var heroBook: QidianBook? {
        ranks[heroType]?.first ?? allBooks.first
    }

    var mustReadBooks: [QidianBook] {
        sectionBooks(type: mustReadType, page: swapPageMustRead, slotOffset: 0, count: 8)
    }

    var completeBooks: [QidianBook] {
        sectionBooks(type: completeType, page: swapPageComplete, slotOffset: 8, count: 8)
    }

    var recommendBooks: [QidianBook] {
        sectionBooks(type: recommendType, page: swapPageRanked, slotOffset: 16, count: 8)
    }

    /// 跟 Android `bindGridFromRank` 一致: 优先取 ranks[type] 的 5 本, 不足 8 本时
    /// 从 allBooks 顺序兜底 (跳过已展示 bookId).
    /// page > 0 时基于 allBooks 做循环切片 (换一批).
    private func sectionBooks(
        type: QidianRankType,
        page: Int,
        slotOffset: Int,
        count: Int
    ) -> [QidianBook] {
        if page == 0 {
            let primary = ranks[type] ?? []
            var seen = Set(primary.map(\.bookId))
            let padding = primary.count >= count ? [] :
                allBooks.filter { seen.insert($0.bookId).inserted }.prefix(count - primary.count)
            return Array((primary + padding).prefix(count))
        }
        // 换一批: 基于 allBooks 循环切片
        guard !allBooks.isEmpty else { return [] }
        let offsetSeed = slotOffset + 1
        let start = ((page * count) + offsetSeed) % allBooks.count
        return (0..<count).map { allBooks[(start + $0) % allBooks.count] }
    }

    // MARK: - Public API

    /// 切频道 (跟 Android `switchChannel`):
    ///   * 取消旧任务避免脏数据写回
    ///   * 切完之后下次 task 触发会按新 channel 重新加载
    func switchChannel(to ch: QidianChannel) {
        guard ch != currentChannel else { return }
        loadTask?.cancel()
        currentChannel = ch
        // 清当前书目, 让 UI 显示 loading; 命中 cache 时 loadIfNeeded 会立即填回
        ranks = [:]
        allBooks = []
        swapPageMustRead = 0
        swapPageComplete = 0
        swapPageRanked = 0
    }

    /// 加载当前 channel 的 9 + 4 榜单
    func loadIfNeeded(force: Bool) async {
        let ch = currentChannel
        loadTask?.cancel()

        if !force,
           let hit = channelRankCache[ch],
           Date().timeIntervalSince(hit.at) < cacheTtl {
            apply(ranks: hit.ranks, channel: ch)
            return
        }

        isLoading = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let result: [QidianRankType: [QidianBook]]
            switch ch {
            case .publish:
                result = (try? await QidianRepository.shared.fetchFinishRanks()) ?? [:]
            default:
                result = (try? await QidianRepository.shared.fetchAllRanks()) ?? [:]
            }
            if Task.isCancelled { return }
            guard self.currentChannel == ch else { return }
            self.isLoading = false
            if !result.values.contains(where: { !$0.isEmpty }) {
                return
            }
            self.channelRankCache[ch] = (result, Date())
            self.apply(ranks: result, channel: ch)
        }
        loadTask = task
        await task.value
        if currentChannel == ch && isLoading {
            isLoading = false
        }
    }

    func swap(_ target: SwapTarget) {
        switch target {
        case .mustRead: swapPageMustRead += 1
        case .complete: swapPageComplete += 1
        case .recommend: swapPageRanked += 1
        }
        // 触发 @Published 更新
        objectWillChange.send()
    }

    // MARK: - Private

    private func apply(ranks: [QidianRankType: [QidianBook]], channel: QidianChannel) {
        self.ranks = ranks
        var pool = mergeAllRanks(ranks)
        if channel == .female {
            // 女生 tab: 言情/恋爱主题书优先排到前面
            pool.sort { Self.isLikelyFemale($0) && !Self.isLikelyFemale($1) }
        }
        self.allBooks = pool
        self.swapPageMustRead = 0
        self.swapPageComplete = 0
        self.swapPageRanked = 0
    }

    /// 万象书屋 D-22: 把 9 (or 4) 榜单的所有书去重合并成一个池, 给"换一批"用.
    private func mergeAllRanks(_ ranks: [QidianRankType: [QidianBook]]) -> [QidianBook] {
        var seen = Set<String>()
        var out: [QidianBook] = []
        out.reserveCapacity(64)
        for list in ranks.values {
            for book in list {
                let key = book.bookId.isEmpty ? book.name : book.bookId
                if seen.insert(key).inserted {
                    out.append(book)
                }
            }
        }
        return out
    }

    /// 万象书屋 D-22.1: 启发式判断"像女频" — 用 cat/subCat 关键词命中
    private static func isLikelyFemale(_ book: QidianBook) -> Bool {
        let text = "\(book.category) \(book.subCategory)"
        let keywords = ["言情", "恋爱", "古言", "宫廷", "宅斗", "爱情", "玄幻言情", "现代言情"]
        return keywords.contains(where: { text.contains($0) })
    }
}

// MARK: - Preview

#Preview {
    BookStoreView()
}
