//
//  RankDetailView.swift
//  万象书屋 iOS · 完整榜单详情页 (D-22.1 / D-22.3 同 Android)
//
//  对应 Android: io.legado.app.ui.main.bookstore.RankDetailActivity
//
//  来源:
//   - mode = .rank: 走 m.qidian.com/rank/<path>?pageNum=N 单榜分页接口 (20+ 本)
//   - mode = .finish: 走 m.qidian.com/finish/, 把 4 完结榜合并展示
//
//  列表样式: 大封面 (左) + 书名 / 作者 / 分类 chip / 字数 / 简介 (右), 1-3 红徽章, 4+ 灰数字
//  点击书目: 跳 SearchView 用书名搜本地书源
//

import SwiftUI

struct RankDetailView: View {

    enum Mode: Hashable {
        case rank(QidianRankType)
        case finish

        var title: String {
            switch self {
            case .rank(let t): return t.title
            case .finish: return "完本书库"
            }
        }
    }

    let mode: Mode
    let titleOverride: String?

    @StateObject private var vm = RankDetailViewModel()
    @State private var searchKeyword: StoreSearchSeed?
    @Environment(\.dismiss) private var dismiss

    init(mode: Mode, title: String? = nil) {
        self.mode = mode
        self.titleOverride = title
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if vm.isLoading && vm.books.isEmpty {
                    ProgressView()
                        .padding(.top, 80)
                } else if vm.books.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(vm.books.enumerated()), id: \.offset) { idx, book in
                        Button {
                            searchKeyword = StoreSearchSeed(keyword: book.name)
                        } label: {
                            RankDetailRow(rank: idx + 1, book: book)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(WanxiangColors.background)
        .navigationTitle(titleOverride ?? mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load(mode: mode, force: true) }
        .task {
            if vm.books.isEmpty {
                await vm.load(mode: mode, force: false)
            }
        }
        // 万象书屋 (UX): 搜索改成 NavigationStack push 的全屏单独页, 不再用 sheet 弹框.
        .navigationDestination(item: $searchKeyword) { seed in
            SearchView(initialKeyword: seed.keyword, embedded: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.55))
            Text("加载失败,下拉重试").font(.subheadline).foregroundStyle(WanxiangColors.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

// MARK: - Row

private struct RankDetailRow: View {
    let rank: Int
    let book: QidianBook

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                BookCover(url: book.coverUrl, width: 72, height: 96, bookTitle: book.name)
                Text("\(rank)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(rankBadgeColor.clipShape(Capsule()))
                    .padding(4)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(book.name)
                    .font(.headline)
                    .foregroundStyle(WanxiangColors.textPrimary)
                    .lineLimit(1)
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
                    if !book.wordCount.isEmpty {
                        Text(book.wordCount)
                            .font(.caption2)
                            .foregroundStyle(WanxiangColors.textSecondary.opacity(0.85))
                    }
                }
                if !book.rankCount.isEmpty {
                    Text(book.rankCount)
                        .font(.caption2)
                        .foregroundStyle(WanxiangColors.accent)
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
        .padding(12)
        .background(WanxiangColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    private var rankBadgeColor: Color {
        switch rank {
        case 1: return Color(red: 0.92, green: 0.27, blue: 0.27)   // 红
        case 2: return Color(red: 0.95, green: 0.55, blue: 0.18)   // 橙
        case 3: return Color(red: 0.85, green: 0.69, blue: 0.20)   // 金
        default: return Color.black.opacity(0.45)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class RankDetailViewModel: ObservableObject {
    @Published var books: [QidianBook] = []
    @Published var isLoading = false

    /// 万象书屋 D-22.3: 目标加载本数. 50 本是起点 m 站 majax 3 页能稳拉的量.
    private let targetCount = 50

    /// 万象书屋 (perf 2026-05-11): 进程级 cache, mode → (books, 时间戳).
    /// 让 banner 跳进来时 vm.books 立即同步填充, 永远不闪 ProgressView.
    /// 跟 BookStoreViewModel.channelRankCache 同思路: `AppState.bootstrap` 后台预热.
    private static var cache: [CacheKey: (books: [QidianBook], at: Date)] = [:]
    private static let cacheTtl: TimeInterval = 5 * 60

    private enum CacheKey: Hashable {
        case rank(QidianRankType)
        case finish

        init(_ mode: RankDetailView.Mode) {
            switch mode {
            case .rank(let t): self = .rank(t)
            case .finish: self = .finish
            }
        }
    }

    func load(mode: RankDetailView.Mode, force: Bool) async {
        if !force && !books.isEmpty { return }

        // 命中进程级 cache: 同步填充, 完全跳过 isLoading
        if !force,
           let hit = Self.cache[CacheKey(mode)],
           Date().timeIntervalSince(hit.at) < Self.cacheTtl,
           !hit.books.isEmpty {
            books = hit.books
            return
        }

        isLoading = true
        defer { isLoading = false }

        switch mode {
        case .rank(let type):
            let result = await QidianRepository.shared.fetchRankPages(type: type, target: targetCount)
            books = result
            if !result.isEmpty {
                Self.cache[.rank(type)] = (result, Date())
            }
        case .finish:
            let result = await loadFinishLibrary()
            books = result
            if !result.isEmpty {
                Self.cache[.finish] = (result, Date())
            }
        }
    }

    /// 万象书屋: `AppState.bootstrap` 后台调一次. 预热「热门排行 (月票 TOP 50)」+「完本书库 50」,
    /// 用户从书城 banner 进 RankDetailView 时直接命中 cache, 跟 Android tab 切换秒开体感一致.
    /// 跟 BookSourceEngine / BookStoreViewModel 预热同步骤, fire-and-forget 失败静默 noop.
    static func prewarmInBackground() {
        Task.detached(priority: .utility) {
            async let yuepiao: [QidianBook] = await QidianRepository.shared.fetchRankPages(type: .yuepiao, target: 50)
            async let finish: [QidianBook] = await Self.computeFinishLibrary(target: 50)
            let yp = await yuepiao
            let fl = await finish
            await MainActor.run {
                let now = Date()
                if !yp.isEmpty {
                    RankDetailViewModel.cache[.rank(.yuepiao)] = (yp, now)
                }
                if !fl.isEmpty {
                    RankDetailViewModel.cache[.finish] = (fl, now)
                }
            }
        }
    }

    /// 万象书屋: 完本书库 50 本算法 (Finish 4 榜合并 + Yuepiao 大字数补足) — 拆成 nonisolated static
    /// 让 instance 和 prewarm 都可调.
    nonisolated static func computeFinishLibrary(target: Int) async -> [QidianBook] {
        var seen = Set<String>()
        var out: [QidianBook] = []
        if let ranks = try? await QidianRepository.shared.fetchFinishRanks() {
            let order: [QidianRankType] = [.finishClassic, .finishBestSell, .finishDs, .finishMovie]
            for rt in order {
                for b in ranks[rt] ?? [] where seen.insert(b.bookId).inserted {
                    out.append(b)
                }
            }
        }
        if out.count < target {
            let need = target - out.count
            let yuepiao = await QidianRepository.shared.fetchRankPages(type: .yuepiao, target: need * 2)
            let high = yuepiao.filter { parseWordCount($0.wordCount) >= 2_000_000 }
            let mid = yuepiao.filter {
                let w = parseWordCount($0.wordCount)
                return w >= 1_000_000 && w < 2_000_000
            }
            let rest = yuepiao.filter { parseWordCount($0.wordCount) < 1_000_000 }
            for b in high + mid + rest {
                if out.count >= target { break }
                if seen.insert(b.bookId).inserted { out.append(b) }
            }
        }
        return Array(out.prefix(target))
    }

    /// 万象书屋 D-22.3: 完本书库扩展到 50 本. 实际算法在 `computeFinishLibrary`, prewarm 共用.
    private func loadFinishLibrary() async -> [QidianBook] {
        await Self.computeFinishLibrary(target: targetCount)
    }

    /// "569.44万字" → 5_694_400; "27.39万字" → 273_900; 解析失败返 0
    nonisolated static func parseWordCount(_ s: String) -> Int64 {
        if s.isEmpty { return 0 }
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)\s*万"#),
              let m = regex.firstMatch(in: s, range: NSRange(0..<(s as NSString).length)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: s),
              let num = Double(s[r]) else {
            return 0
        }
        return Int64(num * 10000)
    }
}

// 万象书屋: StoreSearchSeed 在 BookStoreView.swift 顶层声明, 这里直接复用
