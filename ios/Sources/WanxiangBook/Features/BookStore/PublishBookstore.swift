//
//  PublishBookstore.swift
//  出版频道: mirror.ranksPublish → 直抓 (三频道统一 mirror→直抓)
//

import Foundation

enum PublishBookstore {

    static func fetchRanks() async -> [QidianRankType: [QidianBook]] {
        await QidianRepository.shared.fetchPublishMirrorRanks()
    }

    static func fetchRankPages(type: QidianRankType, target: Int = 50) async -> [QidianBook] {
        await QidianRepository.shared.fetchPublishRankPages(type: type, target: target)
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
}
