//
//  BookStoreView.swift
//  万象书屋 iOS · 书城 / 发现 (M2.3 v2 — 仿 legado 安卓 ExploreFragment)
//
//  对应 Android: io.legado.app.ui.main.explore.ExploreFragment + ExploreAdapter
//
//  v2 设计:
//   - 列出所有启用的 book sources (按 group 排序)
//   - 每行一个 source: name + group tag + 展开/折叠 chevron
//   - 展开后显示该源的 exploreKinds (玄幻/都市/穿越... 流式 chip)
//   - 点 chip → ExploreShowView 拉该频道书列表 (带翻页)
//   - 顶部搜索框跳 SearchView
//

import SwiftUI

struct BookStoreView: View {

    @StateObject private var vm = ExploreViewModel()
    @State private var searchSeed: StoreSearchSeed? = nil
    @State private var searchKeyword = ""
    @State private var selectedChannel: StoreChannel = .male
    @State private var qidianBooks: [StoreChannel: [StoreBook]] = [:]
    @State private var qidianLoading = false

    var body: some View {
        NavigationStack {
            storeHome
                .background(WanxiangColors.background)
                .navigationTitle("书城")
                // 万象书屋: 改 inline — large 模式多吃 ~70pt 顶部空白, 加上 tabBar 上下 ~80pt 视觉太松
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            searchSeed = StoreSearchSeed(keyword: "")
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                }
                .sheet(item: $searchSeed) { seed in
                    NavigationStack {
                        SearchView(initialKeyword: seed.keyword)
                    }
                }
                .task { await vm.start() }
                .task(id: selectedChannel) {
                    await loadQidianBooks(for: selectedChannel)
                }
        }
    }

    @MainActor
    private func loadQidianBooks(for channel: StoreChannel) async {
        if qidianBooks[channel]?.isEmpty == false { return }
        qidianLoading = true
        let books = (try? await QidianBookstoreScraper.fetch(channel: channel)) ?? []
        qidianBooks[channel] = books
        qidianLoading = false
    }

    @ViewBuilder
    private var storeHome: some View {
        if vm.sources.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 14) {
                    channelBar
                    if qidianLoading {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.75)
                            Text("正在从起点抓取推荐内容…")
                                .font(.caption)
                                .foregroundStyle(WanxiangColors.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                    }
                    quickEntrances
                    featuredSection
                    banner
                    weeklySection
                    sourceDiscoverySection
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                // 万象书屋: 自定义底栏是 RootView 普通 VStack 子视图, 但 ScrollView 到底时
                // 最后一张卡片会贴到底栏太近; 多留一个 tabbar 高度的呼吸区。
                .padding(.bottom, 92)
            }
        }
    }

    private var channelBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(StoreChannel.allCases) { channel in
                    Button {
                        selectedChannel = channel
                    } label: {
                        Text(channel.title)
                            .font(.system(size: 16, weight: selectedChannel == channel ? .bold : .semibold))
                            .foregroundStyle(selectedChannel == channel ? WanxiangColors.textPrimary : WanxiangColors.textSecondary)
                            .overlay(alignment: .bottom) {
                                if selectedChannel == channel {
                                    Capsule()
                                        .fill(WanxiangColors.primary)
                                        .frame(width: 22, height: 3)
                                        .offset(y: 8)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 8)
        }
    }

    private var quickEntrances: some View {
        HStack(spacing: 10) {
            quickCard(title: "排行榜", subtitle: "高分必读", icon: "chart.bar.fill", keyword: "\(selectedChannel.title) 榜单")
            quickCard(title: "书库", subtitle: "\(vm.sources.count) 个好源", icon: "books.vertical.fill", keyword: selectedChannel.title)
        }
    }

    private func quickCard(title: String, subtitle: String, icon: String, keyword: String) -> some View {
        Button {
            searchSeed = StoreSearchSeed(keyword: keyword)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title + "›")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(WanxiangColors.textPrimary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary)
                }
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(WanxiangColors.primary.opacity(0.12))
                    Image(systemName: icon)
                        .foregroundStyle(WanxiangColors.primary)
                }
                .frame(width: 44, height: 44)
            }
            .padding(12)
            .background(WanxiangColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var featuredSection: some View {
        StoreSectionCard(title: "今日必读", actionTitle: selectedChannel.badgeText) {
            VStack(alignment: .leading, spacing: 12) {
                let first = selectedRecommendations[0]
                Button {
                    searchSeed = StoreSearchSeed(keyword: first.title)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        RecommendationCover(book: first, width: 84, height: 112)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 6) {
                                Text(first.title)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(WanxiangColors.textPrimary)
                                    .lineLimit(2)
                                if first.isVip { vipBadge }
                            }
                            Text(first.intro)
                                .font(.caption)
                                .foregroundStyle(WanxiangColors.textSecondary)
                                .lineLimit(3)
                            Text(first.meta)
                                .font(.caption2)
                                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.75))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(Array(selectedRecommendations.dropFirst().prefix(4))) { book in
                        recommendationMini(book)
                    }
                }
            }
        }
    }

    private var banner: some View {
        Button {
            searchSeed = StoreSearchSeed(keyword: "开局强娶柳二龙")
        } label: {
            ZStack(alignment: .leading) {
                LinearGradient(colors: [
                    Color(red: 0.78, green: 0.93, blue: 0.82),
                    Color(red: 0.96, green: 0.77, blue: 0.48)
                ], startPoint: .leading, endPoint: .trailing)
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("开局强娶")
                            .font(.title2.weight(.heavy))
                        Text("柳二龙")
                            .font(.title.weight(.heavy))
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.20), radius: 2, x: 0, y: 1)
                    Spacer()
                    Image(systemName: "flame.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.white.opacity(0.38))
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var weeklySection: some View {
        StoreSectionCard(title: "本周强推", actionTitle: "更多›") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                ForEach(weeklyBooks) { book in
                    recommendationMini(book)
                }
            }
        }
    }

    private var sourceDiscoverySection: some View {
        StoreSectionCard(title: "发现分类", actionTitle: "书源 \(filteredSources.count)") {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(WanxiangColors.textSecondary)
                    TextField("搜源 / 分组", text: $searchKeyword)
                        .textFieldStyle(.plain)
                    if !searchKeyword.isEmpty {
                        Button { searchKeyword = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(WanxiangColors.textSecondary)
                        }
                    }
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(WanxiangColors.background)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                ForEach(filteredSources.prefix(8), id: \.bookSourceUrl) { source in
                    SourceExploreRow(
                        source: source,
                        isExpanded: vm.expandedSourceUrl == source.bookSourceUrl,
                        kinds: vm.kindsCache[source.bookSourceUrl],
                        isLoading: vm.loadingKindsFor == source.bookSourceUrl,
                        onTap: { vm.toggleExpand(source: source) }
                    )
                }
            }
        }
    }

    private func recommendationMini(_ book: StoreBook) -> some View {
        Button {
            searchSeed = StoreSearchSeed(keyword: book.title)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    RecommendationCover(book: book, width: 72, height: 96)
                    if book.isVip { vipBadge.padding(4) }
                }
                Text(book.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WanxiangColors.textPrimary)
                    .lineLimit(2)
                    .frame(height: 34, alignment: .topLeading)
                Text(book.category)
                    .font(.caption2)
                    .foregroundStyle(WanxiangColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var vipBadge: some View {
        Text("会员")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(red: 0.74, green: 0.58, blue: 0.32)))
            .foregroundStyle(.white)
    }

    private var filteredSources: [BookSource] {
        let kw = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if kw.isEmpty { return vm.sources }
        return vm.sources.filter {
            $0.bookSourceName.localizedCaseInsensitiveContains(kw)
                || ($0.bookSourceGroup ?? "").localizedCaseInsensitiveContains(kw)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.4))
            Text("还没有书源")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textSecondary)
            Text("启动后会自动从后台拉取")
                .font(.caption)
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectedRecommendations: [StoreBook] {
        if let remote = qidianBooks[selectedChannel], remote.count >= 5 {
            return Array(remote.prefix(5))
        }
        switch selectedChannel {
        case .male:
            return [
                StoreBook(title: "满门忠烈，开局纳九房太太续香火", intro: "大魏皇朝，卫氏一族满门忠烈，九位兄长战死沙场。从小被寄养在道观的卫昭被迫撑起家门。", category: "玄幻", meta: "玄幻 · 连载 · 20.7万字 · 架空 · 权谋", seedColor: .orange, isVip: true),
                StoreBook(title: "开局五脏雷法，你说我是废物？", intro: "少年雷法入体，从废柴一路横推。", category: "斩妖除魔", meta: "热血", seedColor: .red, isVip: true),
                StoreBook(title: "取悦自己就变强：带老公所向披靡", intro: "现代都市奇遇，轻松逆袭。", category: "现代都市", meta: "都市", seedColor: .pink, isVip: true),
                StoreBook(title: "一级一词条，你说我没点胡？", intro: "词条系统降临，越级开挂。", category: "异能", meta: "系统", seedColor: .blue, isVip: true),
                StoreBook(title: "封神守关百年，我通疯了", intro: "一城一关，百年入圣。", category: "封神", meta: "神话", seedColor: .brown, isVip: true)
            ]
        case .female:
            return [
                StoreBook(title: "被读心后，满朝文武都疯了", intro: "穿书后只想摆烂，谁知心声被全朝听见。", category: "古言", meta: "古言 · 爽文 · 宫廷", seedColor: .pink, isVip: true),
                StoreBook(title: "嫁给病娇反派后我躺赢了", intro: "反派黑化前，她决定先下手为强。", category: "穿书", meta: "甜宠", seedColor: .purple, isVip: true),
                StoreBook(title: "重生八零：娇软美人搞钱忙", intro: "重回八零，事业爱情两手抓。", category: "年代", meta: "重生", seedColor: .orange, isVip: false),
                StoreBook(title: "夫人她马甲又掉了", intro: "全城都以为她是废柴。", category: "现言", meta: "马甲", seedColor: .blue, isVip: true),
                StoreBook(title: "小师妹今天也在装乖", intro: "修仙门派里最会藏拙的人。", category: "仙侠", meta: "群像", seedColor: .green, isVip: false)
            ]
        case .publish:
            return [
                StoreBook(title: "人类群星闪耀时", intro: "历史关键瞬间中的人性光辉。", category: "历史", meta: "出版 · 经典", seedColor: .indigo, isVip: false),
                StoreBook(title: "长安的荔枝", intro: "一骑红尘背后的职场困局。", category: "历史小说", meta: "马伯庸", seedColor: .orange, isVip: true),
                StoreBook(title: "三体", intro: "宇宙文明与黑暗森林。", category: "科幻", meta: "刘慈欣", seedColor: .blue, isVip: false),
                StoreBook(title: "明朝那些事儿", intro: "用现代语言讲明史。", category: "历史", meta: "经典", seedColor: .brown, isVip: false),
                StoreBook(title: "活着", intro: "苦难中活下去的力量。", category: "文学", meta: "余华", seedColor: .gray, isVip: false)
            ]
        default:
            return [
                StoreBook(title: "\(selectedChannel.title)热门榜第一", intro: "根据当前频道生成的热门推荐，点击即可全书源搜索。", category: selectedChannel.title, meta: "热门 · 连载", seedColor: .cyan, isVip: true),
                StoreBook(title: "\(selectedChannel.title)年度精选", intro: "本周读者正在追的高热作品。", category: selectedChannel.title, meta: "精选", seedColor: .mint, isVip: true),
                StoreBook(title: "\(selectedChannel.title)新作速递", intro: "新书冲榜，热度上涨。", category: selectedChannel.title, meta: "新书", seedColor: .teal, isVip: false),
                StoreBook(title: "\(selectedChannel.title)口碑佳作", intro: "评分稳定，适合长期追读。", category: selectedChannel.title, meta: "口碑", seedColor: .purple, isVip: false),
                StoreBook(title: "\(selectedChannel.title)完结必读", intro: "完结精品，一口气看完。", category: selectedChannel.title, meta: "完结", seedColor: .orange, isVip: true)
            ]
        }
    }

    private var weeklyBooks: [StoreBook] {
        if let remote = qidianBooks[selectedChannel], remote.count >= 9 {
            return Array(remote.dropFirst(5).prefix(4))
        }
        return [
            StoreBook(title: "斗破苍穹", intro: "莫欺少年穷。", category: "玄幻", meta: "经典", seedColor: .orange, isVip: true),
            StoreBook(title: "凡人修仙传", intro: "凡人踏入修仙世界。", category: "仙侠", meta: "修真", seedColor: .blue, isVip: true),
            StoreBook(title: "诡秘之主", intro: "蒸汽、机械与神秘。", category: "奇幻", meta: "克苏鲁", seedColor: .black, isVip: true),
            StoreBook(title: "大奉打更人", intro: "官场、江湖与修行。", category: "仙侠", meta: "轻松", seedColor: .brown, isVip: true)
        ]
    }
}

private struct StoreSearchSeed: Identifiable {
    let id = UUID()
    let keyword: String
}

private enum StoreChannel: String, CaseIterable, Identifiable {
    case male, female, publish
    var id: String { rawValue }
    var title: String {
        switch self {
        case .male: return "男生"
        case .female: return "女生"
        case .publish: return "出版"
        }
    }
    var badgeText: String {
        switch self {
        case .male: return "连载专区›"
        case .female: return "甜宠专区›"
        case .publish: return "经典专区›"
        }
    }
}

private struct StoreBook: Identifiable {
    let id = UUID()
    let title: String
    let intro: String
    let category: String
    let meta: String
    let seedColor: Color
    let isVip: Bool
    let coverUrl: String?
    let qidianUrl: String?

    init(title: String, intro: String, category: String, meta: String, seedColor: Color, isVip: Bool, coverUrl: String? = nil, qidianUrl: String? = nil) {
        self.title = title
        self.intro = intro
        self.category = category
        self.meta = meta
        self.seedColor = seedColor
        self.isVip = isVip
        self.coverUrl = coverUrl
        self.qidianUrl = qidianUrl
    }
}

private struct StoreSectionCard<Content: View>: View {
    let title: String
    let actionTitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(WanxiangColors.textPrimary)
                Spacer()
                Text(actionTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WanxiangColors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(WanxiangColors.background))
            }
            content
        }
        .padding(12)
        .background(WanxiangColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 3)
    }
}

private struct RecommendationCover: View {
    let book: StoreBook
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Group {
            if let cover = book.coverUrl, !cover.isEmpty {
                BookCover(url: cover, width: width, height: height)
            } else {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [
                        book.seedColor.opacity(0.92),
                        WanxiangColors.primary.opacity(0.82)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: width * 0.34, weight: .bold))
                        .foregroundStyle(.white.opacity(0.24))
                        .offset(x: width * 0.26, y: -height * 0.20)
                    Text(book.title)
                        .font(.system(size: max(10, width * 0.14), weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .minimumScaleFactor(0.72)
                        .padding(7)
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .shadow(color: book.seedColor.opacity(0.22), radius: 5, x: 0, y: 3)
    }
}

// MARK: - 起点移动站抓取

private enum QidianBookstoreScraper {
    static func fetch(channel: StoreChannel) async throws -> [StoreBook] {
        let url = URL(string: urlString(for: channel))!
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        let html = String(data: data, encoding: .utf8) ?? ""
        let books = parseBooks(from: html, channel: channel)
        // 起点部分频道会返回反爬空壳, 直接空数组走本地兜底.
        return Array(books.prefix(16))
    }

    private static func urlString(for channel: StoreChannel) -> String {
        switch channel {
        case .male:
            return "https://m.qidian.com/"
        case .female:
            // 当前 female 移动页偶尔返回 WAF 空壳, 失败时 UI 自动走兜底.
            return "https://m.qidian.com/female/"
        case .publish:
            // 起点移动站出版频道无稳定公开路径, 分类页至少能抓到站内推荐/书单.
            return "https://m.qidian.com/category/"
        }
    }

    private static func parseBooks(from html: String, channel: StoreChannel) -> [StoreBook] {
        var result: [StoreBook] = []
        var seen = Set<String>()
        // 典型结构:
        // <li class="_bookItem..."><a href="//m.qidian.com/book/1047731139/" title="...在线阅读"...>
        //   <img ... data-src="//bookcover.yuewen.com/qdbimg/349573/1047731139/180">
        // </a><figcaption><h2>书名</h2></figcaption><p>作者</p></li>
        let pattern = #"<li[^>]*_bookItem[^>]*>[\s\S]*?<a[^>]+href=\"([^\"]*/book/\d+/[^\"]*)\"[^>]*title=\"([^\"]*)\"[^>]*>[\s\S]*?<img[^>]*(?:data-src|src)=\"([^\"]*)\"[\s\S]*?</a>[\s\S]*?<h2[^>]*>([\s\S]*?)</h2>[\s\S]*?<p[^>]*>([\s\S]*?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(0..<ns.length))
        let colors: [Color] = [.orange, .red, .blue, .brown, .purple, .green, .teal, .indigo]
        for (idx, m) in matches.enumerated() {
            guard m.numberOfRanges >= 6 else { continue }
            let href = absolutize(ns.substring(with: m.range(at: 1)))
            let rawTitle = clean(ns.substring(with: m.range(at: 4)))
            let title = rawTitle.isEmpty
                ? clean(ns.substring(with: m.range(at: 2))).replacingOccurrences(of: "在线阅读", with: "")
                : rawTitle
            let author = clean(ns.substring(with: m.range(at: 5)))
            let cover = absolutize(ns.substring(with: m.range(at: 3)))
            let key = title.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(StoreBook(
                title: title,
                intro: author.isEmpty ? "来自起点中文网的实时推荐，点击可全书源搜索。" : "\(author) · 来自起点中文网实时推荐",
                category: channel.title,
                meta: author.isEmpty ? "起点中文网" : "起点 · \(author)",
                seedColor: colors[idx % colors.count],
                isVip: idx % 3 == 0,
                coverUrl: cover,
                qidianUrl: href
            ))
        }
        return result
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func absolutize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("//") { s = "https:" + s }
        if s.hasPrefix("/") { s = "https://m.qidian.com" + s }
        return s
    }
}

// MARK: - Row

private struct SourceExploreRow: View {
    let source: BookSource
    let isExpanded: Bool
    let kinds: [ExploreParser.Kind]?
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行
            Button(action: onTap) {
                HStack(spacing: 12) {
                    sourceIcon
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(source.bookSourceName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(WanxiangColors.textPrimary)
                                .lineLimit(1)
                            if source.enabledExplore {
                                Image(systemName: "sparkles")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(WanxiangColors.primary.opacity(0.85))
                            }
                        }
                        HStack(spacing: 6) {
                            Text(sourceHost)
                                .font(.caption2)
                                .foregroundStyle(WanxiangColors.textSecondary)
                                .lineLimit(1)
                            if let g = source.bookSourceGroup, !g.isEmpty {
                                Text(g)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(WanxiangColors.primary.opacity(0.10)))
                                    .foregroundStyle(WanxiangColors.primary)
                            }
                        }
                    }
                    Spacer()
                    if isLoading {
                        ProgressView().scaleEffect(0.7)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WanxiangColors.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 展开内容: chip 流式布局
            if isExpanded, let kinds = kinds, !kinds.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("发现分类")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(WanxiangColors.textSecondary)
                    FlowLayout(spacing: 8) {
                        ForEach(Array(kinds.enumerated()), id: \.offset) { _, kind in
                            NavigationLink {
                                ExploreShowView(source: source, kind: kind)
                            } label: {
                                Text(kind.title)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(Capsule().fill(WanxiangColors.primary.opacity(0.12)))
                                    .foregroundStyle(WanxiangColors.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 12)
            } else if isExpanded, kinds?.isEmpty == true {
                HStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.caption)
                    Text("此源没有发现分类")
                        .font(.caption)
                }
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.72))
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(WanxiangColors.card.opacity(isExpanded ? 1 : 0.92))
                .shadow(color: .black.opacity(isExpanded ? 0.08 : 0.035),
                        radius: isExpanded ? 10 : 5,
                        x: 0,
                        y: isExpanded ? 4 : 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isExpanded ? WanxiangColors.primary.opacity(0.18) : Color.black.opacity(0.045), lineWidth: 0.8)
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    private var sourceIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WanxiangColors.primary.opacity(0.12))
            Image(systemName: "book.pages.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(WanxiangColors.primary)
        }
        .frame(width: 42, height: 42)
    }

    private var sourceHost: String {
        guard let url = URL(string: source.bookSourceUrl),
              let host = url.host,
              !host.isEmpty else {
            return source.bookSourceUrl
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

// MARK: - 流式布局 (FlexBox alternative)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var rows: [[CGSize]] = [[]]
        var rowWidth: CGFloat = 0
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        for size in sizes {
            if rowWidth + size.width > width {
                rows.append([size])
                rowWidth = size.width + spacing
            } else {
                rows[rows.count - 1].append(size)
                rowWidth += size.width + spacing
            }
        }
        let totalHeight = rows.reduce(0) { acc, row in
            acc + (row.map(\.height).max() ?? 0) + spacing
        }
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowMaxH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + width {
                x = bounds.minX
                y += rowMaxH + spacing
                rowMaxH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowMaxH = max(rowMaxH, size.height)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ExploreViewModel: ObservableObject {

    @Published var sources: [BookSource] = []
    @Published var expandedSourceUrl: String? = nil
    @Published var kindsCache: [String: [ExploreParser.Kind]] = [:]
    @Published var loadingKindsFor: String? = nil

    /// 万象书屋: 启动时订阅 Registry 的 sources 变化, 一旦后端拉到新数据自动 refresh
    /// (bug 5 fix): 不用 subscribed flag block — for-await 在 view disappear 时会被 task cancel,
    /// 下次进 view start 重新订阅
    func start() async {
        refresh()
        for await new in BookSourceRegistry.shared.$sources.values {
            if Task.isCancelled { break }
            self.sources = new
                .filter { $0.enabled }
                .sorted { ($0.bookSourceGroup ?? "") < ($1.bookSourceGroup ?? "") }
        }
    }

    func refresh() {
        sources = BookSourceRegistry.shared.enabledSources
            .sorted { ($0.bookSourceGroup ?? "") < ($1.bookSourceGroup ?? "") }
    }

    func toggleExpand(source: BookSource) {
        if expandedSourceUrl == source.bookSourceUrl {
            // 收起
            expandedSourceUrl = nil
            return
        }
        expandedSourceUrl = source.bookSourceUrl
        if kindsCache[source.bookSourceUrl] != nil { return }
        // 异步拉 explore kinds
        loadingKindsFor = source.bookSourceUrl
        Task { @MainActor [weak self] in
            guard let self else { return }
            let kinds = await BookSourceEngine.shared.exploreKinds(of: source)
            self.kindsCache[source.bookSourceUrl] = kinds
            if self.loadingKindsFor == source.bookSourceUrl {
                self.loadingKindsFor = nil
            }
        }
    }
}

#Preview {
    BookStoreView()
}
