package io.legado.app.ui.main.bookstore

import io.legado.app.help.WanxiangBackend

/**
 * 出版频道: 优先 mirror.ranksPublish (起点 m 站 catId=13100 实体书),
 * bookstore_feed 运营数据兜底.
 *
 * 四榜 key 与男/女频一致: fyRank / hotRank / newbRank / recRank
 */
object PublishBookstore {

    private val sectionToRank = linkedMapOf(
        "banner" to QidianRepository.RankType.Yuepiao,
        "hot" to QidianRepository.RankType.HotReading,
        "newbook" to QidianRepository.RankType.NewBook,
        "recommend" to QidianRepository.RankType.Recommend,
    )

    suspend fun fetchRanks(): Map<QidianRepository.RankType, List<QidianBook>> {
        val mirrorRanks = QidianRepository.fetchPublishMirrorRanks()
        if (mirrorRanks.isNotEmpty()) return mirrorRanks
        val picks = WanxiangBackend.fetchBookstoreFeed("publish")
        return picksToRanks(picks)
    }

    suspend fun fetchRankPages(type: QidianRepository.RankType, target: Int = 50): List<QidianBook> {
        val mirrorPages = QidianRepository.fetchPublishRankPages(type, target)
        if (mirrorPages.isNotEmpty()) return mirrorPages
        return fetchRanks()[type].orEmpty().take(target)
    }

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

    fun picksToRanks(picks: List<BookstoreFeedPick>): Map<QidianRepository.RankType, List<QidianBook>> {
        val bySection = picks.groupBy { it.section }
        val out = LinkedHashMap<QidianRepository.RankType, List<QidianBook>>()
        for ((section, rankType) in sectionToRank) {
            val books = bySection[section].orEmpty().mapIndexed { i, pick ->
                pick.toRankBook(rank = i + 1, rankType = rankType)
            }
            if (books.isNotEmpty()) out[rankType] = books
        }
        return out
    }
}

private fun BookstoreFeedPick.toRankBook(
    rank: Int,
    rankType: QidianRepository.RankType,
): QidianBook {
    val cat = book.category.ifBlank { book.subCategory }
    val intro = book.intro.ifBlank {
        listOf(book.author, cat).filter { it.isNotBlank() }.joinToString(" · ")
    }
    return book.copy(
        rank = rank,
        rankName = rankType.title,
        category = cat,
        intro = intro,
    )
}
