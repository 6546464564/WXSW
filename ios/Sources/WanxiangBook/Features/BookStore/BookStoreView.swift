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
//   Male/Female: Yuepiao + HotReading + NewBook + Recommend
//   Publish: 同上结构, 优先 mirror.ranksPublish (起点 catId=13100)
//

import SwiftUI

struct BookStoreView: View {

    @StateObject private var vm = BookStoreViewModel()
    @State private var searchSeed: StoreSearchSeed?
    @State private var navTarget: NavTarget?
    /// 万象书屋 (UX): 书城点书 → 立即 push 到 BookDetailView (stub: source=nil + 起点元信息),
    /// 详情页内部后台找真源 + 拉详情/目录. 用户视角"点书秒进详情, 看到封面/简介, 阅读按钮短暂置灰".
    @State private var detailTarget: BookDetailTarget?

    var body: some View {
        NavigationStack {
            content
                .background(WanxiangColors.background.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                // 万象书屋 (UX): 搜索改成 NavigationStack push 的全屏单独页, 不再用 sheet 弹框.
                .navigationDestination(isPresented: Binding(
                    get: { searchSeed != nil },
                    set: { if !$0 { searchSeed = nil } }
                )) {
                    if let seed = searchSeed {
                        SearchView(initialKeyword: seed.keyword, embedded: true)
                    }
                }
                .navigationDestination(isPresented: Binding(
                    get: { navTarget != nil },
                    set: { if !$0 { navTarget = nil } }
                )) {
                    if let target = navTarget {
                        switch target {
                        case .rank(let type, let title):
                            RankDetailView(mode: .rank(type), title: title, channel: vm.currentChannel)
                        case .finish(let title):
                            RankDetailView(mode: .finish, title: title, channel: vm.currentChannel)
                        }
                    }
                }
                .navigationDestination(isPresented: Binding(
                    get: { detailTarget != nil },
                    set: { if !$0 { detailTarget = nil } }
                )) {
                    if let t = detailTarget {
                        BookDetailView(book: t.book, source: t.source)
                    }
                }
                .task(id: vm.currentChannel) { await vm.loadIfNeeded(force: false) }
                .task { await vm.refreshShelfKeys() }
                .onChange(of: detailTarget) { new in
                    if new == nil { Task { await vm.refreshShelfKeys() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: .wanxiangBookshelfChanged)) { _ in
                    Task { await vm.refreshShelfKeys() }
                }
        }
    }

    private func tapBookCell(_ qidianBook: QidianBook) {
        detailTarget = BookDetailTarget(book: qidianBook.toSearchStub(), source: nil)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                LazyVStack(spacing: 16) {
                    if vm.isLoading && vm.allBooks.isEmpty {
                        skeletonPlaceholder
                    } else if vm.allBooks.isEmpty {
                        loadFailedPlaceholder
                    } else {
                        if let hero = vm.heroBook {
                            heroCard(hero)
                        }
                        bannerRow
                        sectionGrid(
                            title: vm.mustReadType.title,
                            rankType: vm.mustReadType,
                            books: vm.mustReadBooks,
                            onSwap: { vm.swap(.mustRead) }
                        )
                        sectionGrid(
                            title: vm.completeType.title,
                            rankType: vm.completeType,
                            books: vm.completeBooks,
                            onSwap: { vm.swap(.complete) }
                        )
                        sectionRanked(
                            title: vm.recommendType.title,
                            rankType: vm.recommendType,
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
            .accessibilityIdentifier("bookstore.search")
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
        .accessibilityIdentifier("bookstore.channel.\(channel.rawValue)")
        .accessibilityLabel(channel.title)
    }

    // MARK: - Hero

    private func heroCard(_ book: QidianBook) -> some View {
        Button {
            tapBookCell(book)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    BookCover(url: book.coverUrl.replacingOccurrences(of: "/180", with: "/300"), width: 96, height: 128, bookTitle: book.name)
                    if vm.isOnShelf(book) {
                        shelfBadge
                    }
                    publishSourceChip
                }
                .frame(width: 96, height: 128)
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
                subtitle: "\(vm.heroType.title) TOP 50",
                icon: "flame.fill",
                gradient: [
                    Color(red: 0.96, green: 0.50, blue: 0.32),
                    Color(red: 0.94, green: 0.30, blue: 0.30),
                ]
            ) {
                navTarget = .rank(vm.heroType, vm.heroType.title)
            }
            bannerCard(
                title: vm.currentChannel == .publish ? "出版书库" : "完本书库",
                subtitle: vm.currentChannel == .publish ? "阅读 · 新书 · 推荐" : "经典完结 50 本",
                icon: "books.vertical.fill",
                gradient: [
                    Color(red: 0.78, green: 0.92, blue: 0.83),
                    Color(red: 0.96, green: 0.78, blue: 0.50),
                ]
            ) {
                let libraryTitle = vm.currentChannel == .publish ? "出版书库" : "完本书库"
                navTarget = .finish(libraryTitle)
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
        rankType: QidianRankType,
        books: [QidianBook],
        onSwap: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title, rankType: rankType, onSwap: onSwap)
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
        rankType: QidianRankType,
        books: [QidianBook],
        onSwap: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title: title, rankType: rankType, onSwap: onSwap)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                ForEach(Array(books.enumerated()), id: \.element.id) { idx, book in
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

    private func sectionHeader(title: String, rankType: QidianRankType, onSwap: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(WanxiangColors.textPrimary)
            Spacer()
            Button {
                navTarget = .rank(rankType, title)
            } label: {
                HStack(spacing: 2) {
                    Text("全部")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(WanxiangColors.textSecondary)
            }
            .buttonStyle(.plain)
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
                BookCover(url: book.coverUrl, width: 80, height: 107, bookTitle: book.name)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(3.0/4.0, contentMode: .fit)
                if book.rank == 1 {
                    badge(text: "榜首", color: Color(red: 0.92, green: 0.27, blue: 0.27))
                } else if book.rank == 2 || book.rank == 3 {
                    badge(text: "TOP\(book.rank)", color: Color(red: 0.85, green: 0.69, blue: 0.20))
                }
                if vm.isOnShelf(book) {
                    shelfBadge
                }
                publishSourceChip
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
                BookCover(url: book.coverUrl, width: 80, height: 107, bookTitle: book.name)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(3.0/4.0, contentMode: .fit)
                Text("\(displayRank)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(rankColor(for: displayRank).clipShape(Circle()))
                    .padding(4)
                if vm.isOnShelf(book) {
                    shelfBadge
                }
                publishSourceChip
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

    private var shelfBadge: some View {
        Text("已在书架")
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color.black.opacity(0.55).clipShape(Capsule()))
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    /// 跟 Android grid `tvSource` 对齐: 出版频道封面左下角「出版」标签
    @ViewBuilder
    private var publishSourceChip: some View {
        if vm.currentChannel == .publish {
            Text("出版")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.black.opacity(0.55).clipShape(Capsule()))
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
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

    private var skeletonPlaceholder: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 18)
                .fill(WanxiangColors.card)
                .frame(height: 156)
                .overlay { skeletonShimmer }
            HStack(spacing: 12) {
                skeletonBanner
                skeletonBanner
            }
            skeletonSection
            skeletonSection
            skeletonSection
        }
        .padding(.top, 4)
    }

    private var skeletonBanner: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(WanxiangColors.card)
            .frame(maxWidth: .infinity, minHeight: 84)
            .overlay { skeletonShimmer }
    }

    private var skeletonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(WanxiangColors.textSecondary.opacity(0.12))
                .frame(width: 100, height: 20)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 14) {
                ForEach(0..<8, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(WanxiangColors.textSecondary.opacity(0.10))
                            .aspectRatio(3.0/4.0, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(WanxiangColors.textSecondary.opacity(0.08))
                            .frame(height: 10)
                    }
                }
            }
        }
        .padding(12)
        .background(WanxiangColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var skeletonShimmer: some View {
        LinearGradient(
            colors: [
                WanxiangColors.textSecondary.opacity(0.06),
                WanxiangColors.textSecondary.opacity(0.14),
                WanxiangColors.textSecondary.opacity(0.06),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .opacity(0.9)
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

/// 万象书屋 (UX): 书城点书 → push BookDetailView 用; stub 模式下 source=nil, BookDetailView 内自动找源.
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
///   * channelRankCache: 频道维度 24h cache, 切 Tab 来回不重发请求
///   * extendedRanks: 各 section 榜单 lazy 扩展到 50 本, 「换一批」在同榜内翻页
///   * swapPage*: 三个 section 独立翻页计数, 越界回 0
@MainActor
final class BookStoreViewModel: ObservableObject {

    @Published var currentChannel: QidianChannel = .male
    @Published var isLoading = false
    @Published var allBooks: [QidianBook] = []
    @Published var shelfDedupeKeys: Set<String> = []

    private var ranks: [QidianRankType: [QidianBook]] = [:]
    private var extendedRanks: [QidianRankType: [QidianBook]] = [:]

    /// 万象书屋 D-22 perf (2026-05-11): 频道维度短时缓存改成**进程级**单例.
    private static var channelRankCache: [QidianChannel: (ranks: [QidianRankType: [QidianBook]], at: Date)] = [:]
    private static let cacheTtl: TimeInterval = 24 * 60 * 60   // 1 天

    /// 频道级 extendedRanks 缓存: 避免切频道/切 Tab 后重复网络请求导致 grid 先显示 5 本再跳到 8 本
    private static var channelExtendedCache: [QidianChannel: [QidianRankType: [QidianBook]]] = {
        return ExtendedRanksDiskCache.load() ?? [:]
    }()

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
        case .male, .female, .publish: return .yuepiao
        }
    }
    var mustReadType: QidianRankType {
        switch currentChannel {
        case .male, .female, .publish: return .hotReading
        }
    }
    var completeType: QidianRankType {
        switch currentChannel {
        case .male, .female, .publish: return .newBook
        }
    }
    var recommendType: QidianRankType {
        switch currentChannel {
        case .male, .female, .publish: return .recommend
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

    /// 优先取 extendedRanks (50本) → ranks (5本) → allBooks 兜底补足到 count 本.
    /// page > 0 时在同榜单 extendedRanks 池内循环切片 (换一批).
    private func sectionBooks(
        type: QidianRankType,
        page: Int,
        slotOffset: Int,
        count: Int
    ) -> [QidianBook] {
        let pool = rankPool(for: type)
        guard !pool.isEmpty else { return [] }
        if page == 0 {
            var result = Array(pool.prefix(count))
            if result.count < count {
                var seen = Set(result.map { $0.bookId.isEmpty ? $0.name : $0.bookId })
                for book in allBooks where result.count < count {
                    let key = book.bookId.isEmpty ? book.name : book.bookId
                    if seen.insert(key).inserted {
                        result.append(book)
                    }
                }
            }
            return result
        }
        let start = ((page * count) + slotOffset + 1) % pool.count
        return (0..<count).map { pool[(start + $0) % pool.count] }
    }

    private func rankPool(for type: QidianRankType) -> [QidianBook] {
        if let ext = extendedRanks[type], !ext.isEmpty { return ext }
        return ranks[type] ?? []
    }

    func isOnShelf(_ book: QidianBook) -> Bool {
        shelfDedupeKeys.contains(book.toSearchStub().dedupeKey)
    }

    func refreshShelfKeys() async {
        let list = (try? await BookshelfRepository.shared.listAll()) ?? []
        shelfDedupeKeys = Set(list.map {
            SearchBook(
                origin: "", originName: "", name: $0.name, author: $0.author, bookUrl: ""
            ).dedupeKey
        })
    }

    // MARK: - Public API

    /// 切频道: 取消旧任务, 优先从 static 缓存恢复 (含 extendedRanks), 避免 grid 闪跳
    func switchChannel(to ch: QidianChannel) {
        guard ch != currentChannel else { return }
        loadTask?.cancel()
        currentChannel = ch
        swapPageMustRead = 0
        swapPageComplete = 0
        swapPageRanked = 0
        if let hit = Self.channelRankCache[ch],
           Date().timeIntervalSince(hit.at) < Self.cacheTtl {
            apply(ranks: hit.ranks, channel: ch)
            return
        }
        ranks = [:]
        allBooks = []
        extendedRanks = [:]
        isLoading = true
    }

    private var lastAppliedChannel: QidianChannel?

    /// 加载当前 channel 的 9 + 4 榜单
    func loadIfNeeded(force: Bool) async {
        // #region agent log
        DebugActivityTracker.shared.begin("storeLoad")
        defer { DebugActivityTracker.shared.end("storeLoad") }
        // #endregion
        let ch = currentChannel

        // 已加载且非强制刷新时跳过 (避免 pop back 重复触发)
        if !force && lastAppliedChannel == ch && !allBooks.isEmpty {
            return
        }

        loadTask?.cancel()

        if !force,
           let hit = Self.channelRankCache[ch],
           Date().timeIntervalSince(hit.at) < Self.cacheTtl {
            apply(ranks: hit.ranks, channel: ch)
            return
        }

        if allBooks.isEmpty { isLoading = true }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if force {
                _ = await BookstoreMirror.shared.fetch(forceRefresh: true)
            }
            let result: [QidianRankType: [QidianBook]]
            switch ch {
            case .publish:
                result = await PublishBookstore.fetchRanks()
            case .female:
                result = (try? await QidianRepository.shared.fetchAllRanks(gender: .female)) ?? [:]
            case .male:
                result = (try? await QidianRepository.shared.fetchAllRanks(gender: .male)) ?? [:]
            }
            if Task.isCancelled { return }
            guard self.currentChannel == ch else { return }
            self.isLoading = false
            if !result.values.contains(where: { !$0.isEmpty }) {
                if let stale = Self.channelRankCache[ch]?.ranks,
                   stale.values.contains(where: { !$0.isEmpty }) {
                    apply(ranks: stale, channel: ch)
                    return
                }
                if self.currentChannel == ch {
                    self.ranks = [:]
                    self.allBooks = []
                    self.extendedRanks = [:]
                }
                return
            }
            Self.channelRankCache[ch] = (result, Date())
            self.apply(ranks: result, channel: ch)
        }
        loadTask = task
        await task.value
        if currentChannel == ch && isLoading {
            isLoading = false
        }
    }

    private func ensureExtendedRanks(for types: [QidianRankType], channel: QidianChannel) async {
        var didChange = false
        for type in types {
            if (extendedRanks[type]?.count ?? 0) >= 20 { continue }
            let full: [QidianBook]
            if channel == .publish {
                full = await PublishBookstore.fetchRankPages(type: type, target: 50)
            } else {
                full = await QidianRepository.shared.fetchRankPages(type: type, target: 50, gender: channel)
            }
            guard !full.isEmpty else { continue }
            guard currentChannel == channel else { return }
            extendedRanks[type] = full
            didChange = true
        }
        if didChange {
            Self.channelExtendedCache[channel] = extendedRanks
            swapVersion += 1
        }
    }

    /// 万象书屋: App 启动时在后台预灌三频道 mirror 榜单 cache + extendedRanks.
    static func prewarmInBackground() {
        Task.detached(priority: .utility) {
            _ = await BookstoreMirror.shared.fetch(forceRefresh: false)
            async let male: [QidianRankType: [QidianBook]] = (try? await QidianRepository.shared.fetchAllRanks(gender: .male)) ?? [:]
            async let female: [QidianRankType: [QidianBook]] = (try? await QidianRepository.shared.fetchAllRanks(gender: .female)) ?? [:]
            async let publish: [QidianRankType: [QidianBook]] = PublishBookstore.fetchRanks()
            let m = await male
            let f = await female
            let p = await publish
            // 预加载默认频道(男生)首屏封面
            let maleCoverUrls = m.values.flatMap { $0.prefix(8) }.map(\.coverUrl)
            await BookCoverPreloader.preload(urls: Array(Set(maleCoverUrls).prefix(24)))

            await MainActor.run {
                let now = Date()
                if m.values.contains(where: { !$0.isEmpty }) {
                    BookStoreViewModel.channelRankCache[.male] = (m, now)
                }
                if f.values.contains(where: { !$0.isEmpty }) {
                    BookStoreViewModel.channelRankCache[.female] = (f, now)
                }
                if p.values.contains(where: { !$0.isEmpty }) {
                    BookStoreViewModel.channelRankCache[.publish] = (p, now)
                }
            }
            // 预拉三频道的 extendedRanks (每榜 50 本, 三频道并发)
            let extTypes: [QidianRankType] = [.hotReading, .newBook, .recommend]
            async let _m: Void = prewarmExtended(channel: .male, types: extTypes)
            async let _f: Void = prewarmExtended(channel: .female, types: extTypes)
            async let _p: Void = prewarmExtended(channel: .publish, types: extTypes)
            _ = await (_m, _f, _p)
        }
    }

    private static func prewarmExtended(channel: QidianChannel, types: [QidianRankType]) async {
        var ext: [QidianRankType: [QidianBook]] = [:]
        await withTaskGroup(of: (QidianRankType, [QidianBook]).self) { group in
            for type in types {
                group.addTask {
                    let full: [QidianBook]
                    if channel == .publish {
                        full = await PublishBookstore.fetchRankPages(type: type, target: 50)
                    } else {
                        full = await QidianRepository.shared.fetchRankPages(type: type, target: 50, gender: channel)
                    }
                    return (type, full)
                }
            }
            for await (type, full) in group where !full.isEmpty {
                ext[type] = full
            }
        }
        guard !ext.isEmpty else { return }
        let coverUrls = ext.values.flatMap { $0.prefix(8) }.map(\.coverUrl)
        await BookCoverPreloader.preload(urls: Array(Set(coverUrls).prefix(24)))
        await MainActor.run {
            channelExtendedCache[channel] = ext
            ExtendedRanksDiskCache.save(channelExtendedCache)
        }
    }

    func swap(_ target: SwapTarget) {
        switch target {
        case .mustRead:
            swapPageMustRead += 1
            swapVersion += 1
        case .complete:
            swapPageComplete += 1
            swapVersion += 1
        case .recommend:
            swapPageRanked += 1
            swapVersion += 1
        }
    }

    /// 触发 section books 重算的版本号 (比 objectWillChange 更精确)
    @Published private(set) var swapVersion: Int = 0

    // MARK: - Private

    private func apply(ranks: [QidianRankType: [QidianBook]], channel: QidianChannel) {
        self.ranks = ranks
        self.extendedRanks = Self.channelExtendedCache[channel] ?? [:]
        self.allBooks = mergeAllRanks(ranks)
        self.swapPageMustRead = 0
        self.swapPageComplete = 0
        self.swapPageRanked = 0
        self.isLoading = false
        self.lastAppliedChannel = channel
        let types = [mustReadType, completeType, recommendType]
        Task { await ensureExtendedRanks(for: types, channel: channel) }
        Self.preResolveBookstoreBooks(allBooks)
    }

    /// 后台预搜索书城书籍, 结果缓存到 SearchVariantsCache,
    /// 用户点进详情页时 resolveSourceIfNeeded 能秒命中.
    private static var preResolveTask: Task<Void, Never>?

    static func preResolveBookstoreBooks(_ books: [QidianBook]) {
        preResolveTask?.cancel()
        preResolveTask = Task.detached(priority: .utility) {
            await BookSourceRegistry.shared.waitUntilEnabledSourcesNonEmpty(timeout: 8)
            let sources = await BookSourceRegistry.shared.enabledSources
            guard !sources.isEmpty else { return }

            var seen = Set<String>()
            var stubs: [SearchBook] = []
            for b in books.prefix(20) {
                let stub = b.toSearchStub()
                guard seen.insert(stub.dedupeKey).inserted else { continue }
                guard SearchVariantsCache.shared.get(key: stub.dedupeKey).isEmpty else { continue }
                stubs.append(stub)
            }
            guard !stubs.isEmpty else { return }

            let cap = min(sources.count, 3)
            await withTaskGroup(of: Void.self) { group in
                var inflight = 0
                for stub in stubs {
                    if Task.isCancelled { return }
                    while inflight >= 4 { _ = await group.next(); inflight -= 1 }
                    inflight += 1
                    group.addTask {
                        for src in sources.prefix(cap) {
                            guard !Task.isCancelled else { return }
                            guard let results = try? await BookSourceEngine.shared.search(in: src, key: stub.name) else { continue }
                            let author = stub.author.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let match = results.first(where: {
                                $0.name == stub.name && (author.isEmpty || $0.author == author)
                            }) {
                                SearchVariantsCache.shared.set(key: stub.dedupeKey, variants: [match])
                                return
                            }
                        }
                    }
                }
            }
        }
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
}

// MARK: - ExtendedRanks Disk Cache

private enum ExtendedRanksDiskCache {
    private static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("com.wanxiang.reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("extended_ranks_cache.json")
    }()

    static func save(_ cache: [QidianChannel: [QidianRankType: [QidianBook]]]) {
        Task.detached(priority: .background) {
            var root: [String: [String: [[String: Any]]]] = [:]
            for (channel, ranks) in cache {
                var channelDict: [String: [[String: Any]]] = [:]
                for (type, books) in ranks {
                    channelDict[type.rawValue] = books.map { bookToDict($0) }
                }
                root[channel.rawValue] = channelDict
            }
            guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    static func load() -> [QidianChannel: [QidianRankType: [QidianBook]]]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: [[String: Any]]]] else {
            return nil
        }
        var result: [QidianChannel: [QidianRankType: [QidianBook]]] = [:]
        for (chRaw, ranksDict) in root {
            guard let channel = QidianChannel(rawValue: chRaw) else { continue }
            var channelRanks: [QidianRankType: [QidianBook]] = [:]
            for (typeRaw, booksArr) in ranksDict {
                guard let type = QidianRankType(rawValue: typeRaw) else { continue }
                channelRanks[type] = booksArr.compactMap { dictToBook($0) }
            }
            result[channel] = channelRanks
        }
        return result.isEmpty ? nil : result
    }

    private static func bookToDict(_ b: QidianBook) -> [String: Any] {
        ["n": b.name, "c": b.coverUrl, "a": b.author, "ca": b.category,
         "sc": b.subCategory, "wc": b.wordCount, "bi": b.bookId,
         "r": b.rank, "rn": b.rankName, "rc": b.rankCount, "i": b.intro]
    }

    private static func dictToBook(_ d: [String: Any]) -> QidianBook? {
        guard let name = d["n"] as? String, !name.isEmpty else { return nil }
        return QidianBook(
            name: name,
            coverUrl: d["c"] as? String ?? "",
            author: d["a"] as? String ?? "",
            category: d["ca"] as? String ?? "",
            subCategory: d["sc"] as? String ?? "",
            wordCount: d["wc"] as? String ?? "",
            bookId: d["bi"] as? String ?? "",
            rank: d["r"] as? Int ?? 0,
            rankName: d["rn"] as? String ?? "",
            rankCount: d["rc"] as? String ?? "",
            intro: d["i"] as? String ?? ""
        )
    }
}

// MARK: - Preview

#Preview {
    BookStoreView()
}
