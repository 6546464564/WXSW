//
//  PublishBookstore.swift
//  出版频道: 后端 bookstore_feed 独立书单 → 与男/女生相同四榜 UI
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
        let items = (try? await WanxiangAPI.shared.fetchBookstoreFeed(channel: "publish")) ?? []
        let picks = items.compactMap { QidianBook.feedPick(from: $0) }
        return picksToRanks(picks)
    }

    static func fetchRankPages(type: QidianRankType, target: Int = 50) async -> [QidianBook] {
        let ranks = await fetchRanks()
        return Array((ranks[type] ?? []).prefix(target))
    }

    static func fetchEditorPicks() async -> [BookstoreFeedPick] {
        let items = (try? await WanxiangAPI.shared.fetchBookstoreFeed(channel: "publish")) ?? []
        return items.compactMap { QidianBook.feedPick(from: $0) }
            .filter { $0.section == "editor" }
    }

    static func fetchLibraryMerged(target: Int = 50) async -> [QidianBook] {
        let ranks = await fetchRanks()
        var seen = Set<String>()
        var out: [QidianBook] = []
        for rt in [QidianRankType.yuepiao, .hotReading, .newBook, .recommend] {
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
