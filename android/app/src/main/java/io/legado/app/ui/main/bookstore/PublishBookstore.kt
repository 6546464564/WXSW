package io.legado.app.ui.main.bookstore

import io.legado.app.help.WanxiangBackend

/**
 * 出版频道: 后端 [bookstore_feed] 独立书单 → 与男/女生相同的四榜 UI.
 *
 * section 映射:
 *   banner    → 月票榜 (Hero)
 *   hot       → 阅读榜
 *   newbook   → 新书榜
 *   recommend → 推荐榜
 *   editor    → 编辑精选横滑 (不进四榜)
 */
object PublishBookstore {

    private val sectionToRank = linkedMapOf(
        "banner" to QidianRepository.RankType.Yuepiao,
        "hot" to QidianRepository.RankType.HotReading,
        "newbook" to QidianRepository.RankType.NewBook,
        "recommend" to QidianRepository.RankType.Recommend,
    )

    suspend fun fetchRanks(): Map<QidianRepository.RankType, List<QidianBook>> {
        val picks = WanxiangBackend.fetchBookstoreFeed("publish")
        return picksToRanks(picks)
    }

    suspend fun fetchRankPages(type: QidianRepository.RankType, target: Int = 50): List<QidianBook> {
        return fetchRanks()[type].orEmpty().take(target)
    }

    suspend fun fetchEditorPicks(): List<BookstoreFeedPick> {
        return WanxiangBackend.fetchBookstoreFeed("publish")
            .filter { it.section == "editor" }
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
): QidianBook = book.copy(
    rank = rank,
    rankName = rankType.title,
    category = book.category.ifBlank { book.subCategory },
)
