//
//  PublishBookstore.swift
//  出版频道: 优先 mirror.ranksPublish (起点 catId=13100), feed 兜底
//

import Foundation

enum PublishBookstore {

    private static let sectionToRank: [(String, QidianRankType)] = [
        ("banner", .yuepiao),
        ("hot", .hotReading),
        ("newbook", .newBook),
        ("recommend", .recommend),
    ]

    static func fetchRanks() async -> [QidianRankType: [QidianBook]] {
        let mirrorRanks = await QidianRepository.shared.fetchPublishMirrorRanks()
        if !mirrorRanks.isEmpty { return mirrorRanks }
        let items = (try? await WanxiangAPI.shared.fetchBookstoreFeed(channel: "publish")) ?? []
        let picks = items.compactMap { QidianBook.feedPick(from: $0) }
        return picksToRanks(picks)
    }

    static func fetchRankPages(type: QidianRankType, target: Int = 50) async -> [QidianBook] {
        let mirrorPages = await QidianRepository.shared.fetchPublishRankPages(type: type, target: target)
        if !mirrorPages.isEmpty { return mirrorPages }
        let ranks = await fetchRanks()
        return Array((ranks[type] ?? []).prefix(target))
    }

    /// 出版书库: 阅读/新书/推荐三榜合并, 不含月票 (热门排行已用 yuepiaoTop50Publish)
    static func fetchLibraryMerged(target: Int = 50) async -> [QidianBook] {
        let ranks = await fetchRanks()
        var seen = Set<String>()
        var out: [QidianBook] = []
        for rt in [QidianRankType.hotReading, .newBook, .recommend] {
            for b in ranks[rt] ?? [] {
                let key = b.bookId.isEmpty ? b.name : b.bookId
                if seen.insert(key).inserted { out.append(b) }
            }
        }
        return Array(out.prefix(target))
    }

    static func picksToRanks(_ picks: [BookstoreFeedPick]) -> [QidianRankType: [QidianBook]] {
        var bySection: [String: [BookstoreFeedPick]] = [:]
        for p in picks {
            bySection[p.section, default: []].append(p)
        }
        var out: [QidianRankType: [QidianBook]] = [:]
        for (section, rankType) in sectionToRank {
            let books = (bySection[section] ?? []).enumerated().map { i, pick in
                pick.toRankBook(rank: i + 1, rankType: rankType)
            }
            if !books.isEmpty { out[rankType] = books }
        }
        return out
    }
}

private extension BookstoreFeedPick {
    func toRankBook(rank: Int, rankType: QidianRankType) -> QidianBook {
        let cat = book.category.isEmpty ? book.subCategory : book.category
        let intro = book.intro.isEmpty && !book.author.isEmpty
            ? "\(book.author) · \(cat)"
            : book.intro
        return QidianBook(
            name: book.name,
            coverUrl: book.coverUrl,
            author: book.author,
            category: cat,
            subCategory: book.subCategory,
            wordCount: book.wordCount,
            bookId: book.bookId,
            rank: rank,
            rankName: rankType.title,
            rankCount: book.rankCount,
            intro: intro
        )
    }
}
