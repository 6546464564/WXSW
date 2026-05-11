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
                BookCover(url: book.coverUrl, width: 72, height: 96)
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

    func load(mode: RankDetailView.Mode, force: Bool) async {
        if !force && !books.isEmpty { return }
        isLoading = true
        defer { isLoading = false }

        switch mode {
        case .rank(let type):
            let result = await QidianRepository.shared.fetchRankPages(type: type, target: targetCount)
            books = result
        case .finish:
            books = await loadFinishLibrary()
        }
    }

    /// 万象书屋 D-22.3: 完本书库扩展到 50 本.
    /// /finish/ 23 本经典完本 + Yuepiao 月票榜大字数书 (200 万字+ 多为完本) 凑 50 本.
    private func loadFinishLibrary() async -> [QidianBook] {
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

        // 月票榜大字数补足
        if out.count < targetCount {
            let need = targetCount - out.count
            let yuepiaoBooks = await QidianRepository.shared.fetchRankPages(type: .yuepiao, target: need * 2)
            let highWord = yuepiaoBooks.filter { Self.parseWordCount($0.wordCount) >= 2_000_000 }
            let midWord = yuepiaoBooks.filter {
                let w = Self.parseWordCount($0.wordCount)
                return w >= 1_000_000 && w < 2_000_000
            }
            let rest = yuepiaoBooks.filter { Self.parseWordCount($0.wordCount) < 1_000_000 }
            for b in highWord + midWord + rest {
                if out.count >= targetCount { break }
                if seen.insert(b.bookId).inserted { out.append(b) }
            }
        }
        return Array(out.prefix(targetCount))
    }

    /// "569.44万字" → 5_694_400; "27.39万字" → 273_900; 解析失败返 0
    private static func parseWordCount(_ s: String) -> Int64 {
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
