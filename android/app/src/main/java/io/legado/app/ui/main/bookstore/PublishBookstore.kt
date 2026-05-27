package io.legado.app.ui.main.bookstore

/**
 * 出版频道: mirror.ranksPublish → 直抓 (三频道统一 mirror→直抓)
 *
 * 四榜 key 与男/女频一致: fyRank / hotRank / newbRank / recRank
 */
object PublishBookstore {

    suspend fun fetchRanks(): Map<QidianRepository.RankType, List<QidianBook>> =
        QidianRepository.fetchPublishMirrorRanks()

    suspend fun fetchRankPages(type: QidianRepository.RankType, target: Int = 50): List<QidianBook> =
        QidianRepository.fetchPublishRankPages(type, target)

    /** 出版书库: 阅读/新书/推荐三榜合并, 不含月票 (热门排行已用 yuepiaoTop50Publish) */
    suspend fun fetchLibraryMerged(target: Int = 50): List<QidianBook> {
        val ranks = fetchRanks()
        val seen = LinkedHashSet<String>()
        val out = ArrayList<QidianBook>(target)
        for (rt in listOf(
            QidianRepository.RankType.HotReading,
            QidianRepository.RankType.NewBook,
            QidianRepository.RankType.Recommend,
        )) {
            ranks[rt]?.forEach { b ->
                val key = b.bookId.ifEmpty { b.name }
                if (seen.add(key)) out.add(b)
            }
        }
        return out.take(target)
    }
}
