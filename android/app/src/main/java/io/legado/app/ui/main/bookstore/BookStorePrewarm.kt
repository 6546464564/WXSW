package io.legado.app.ui.main.bookstore

import io.legado.app.help.WanxiangBookstoreMirror
import io.legado.app.help.coroutine.Coroutine
import io.legado.app.utils.LogUtils

/**
 * 万象书屋: 书城进程级缓存 + 启动预热 (跟 iOS BookStoreViewModel / RankDetailViewModel prewarm 对齐).
 *
 * Android ViewPager 不像 iOS 那样切 Tab 才构造 Fragment; 但 mirror 网络仍可能在
 * 用户进书城前未就绪. 在 [WanxiangBackend.start] 后台灌 cache, 切 Tab 秒开.
 */
object BookStorePrewarm {

    private const val TAG = "BookStorePrewarm"
    private const val CACHE_TTL_MS = 24 * 60 * 60_000L   // 1 天

    /** 频道 → (ranks, timestamp) — 跟 iOS BookStoreViewModel.channelRankCache 对齐 */
    val channelRankCache =
        mutableMapOf<QidianRepository.Channel, Pair<Map<QidianRepository.RankType, List<QidianBook>>, Long>>()

    /** RankDetail 进程级 cache — key: "rank:MALE:Yuepiao" | "finish:Female"; TTL 1 天 */
    val rankDetailCache = mutableMapOf<String, Pair<List<QidianBook>, Long>>()

    fun rankCacheKey(mode: String, channel: QidianRepository.Channel, type: QidianRepository.RankType? = null): String {
        return if (mode == "finish") "finish:${channel.name}" else "rank:${channel.name}:${type?.name}"
    }

    fun getRankDetailCached(key: String): List<QidianBook>? {
        val hit = rankDetailCache[key] ?: return null
        if (System.currentTimeMillis() - hit.second >= CACHE_TTL_MS) return null
        return hit.first.takeIf { it.isNotEmpty() }
    }

    /** 拉取失败时回退到过期 cache */
    fun getRankDetailStale(key: String): List<QidianBook>? {
        return rankDetailCache[key]?.first?.takeIf { it.isNotEmpty() }
    }

    fun putRankDetailCache(key: String, books: List<QidianBook>) {
        if (books.isNotEmpty()) {
            rankDetailCache[key] = Pair(books, System.currentTimeMillis())
        }
    }

    /** 下拉刷新 mirror 后清 RankDetail 预热, 避免仍展示旧 banner 列表 */
    fun clearRankDetailCache() {
        rankDetailCache.clear()
    }

    /** 强制刷新 mirror 后清频道榜单 cache */
    fun clearChannelRankCache() {
        channelRankCache.clear()
    }

    /** App 启动后 fire-and-forget; 失败静默, 用户进书城走原冷路径 */
    fun prewarmInBackground() {
        Coroutine.async { runCatching { prewarm() } }
    }

    suspend fun prewarm() {
                // 1) 预热 mirror (磁盘 → 内存, 后续 QidianRepository 1 跳命中后端)
                WanxiangBookstoreMirror.fetch(forceRefresh = false)

                // 2) 三频道榜单灌进 cache
                val now = System.currentTimeMillis()
                runCatching { QidianRepository.fetchAllRanks(QidianRepository.Channel.Male) }
                    .getOrNull()
                    ?.takeIf { m -> m.values.any { it.isNotEmpty() } }
                    ?.let { channelRankCache[QidianRepository.Channel.Male] = Pair(it, now) }
                runCatching { QidianRepository.fetchAllRanks(QidianRepository.Channel.Female) }
                    .getOrNull()
                    ?.takeIf { m -> m.values.any { it.isNotEmpty() } }
                    ?.let { channelRankCache[QidianRepository.Channel.Female] = Pair(it, now) }
                runCatching { PublishBookstore.fetchRanks() }
                    .getOrNull()
                    ?.takeIf { m -> m.values.any { it.isNotEmpty() } }
                    ?.let { channelRankCache[QidianRepository.Channel.Publish] = Pair(it, now) }

                // 3) Banner 落地页: 男女月票 TOP50 + 男女完本书库
                for (gender in listOf(QidianRepository.Channel.Male, QidianRepository.Channel.Female)) {
                    runCatching {
                        QidianRepository.fetchRankPages(
                            QidianRepository.RankType.Yuepiao, target = 50, gender = gender,
                        )
                    }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { yuepiao ->
                        putRankDetailCache(
                            rankCacheKey("rank", gender, QidianRepository.RankType.Yuepiao),
                            yuepiao,
                        )
                    }
                    runCatching { loadFinishLibraryPrewarm(gender) }
                        .getOrNull()?.takeIf { it.isNotEmpty() }?.let { finish ->
                            putRankDetailCache(rankCacheKey("finish", gender), finish)
                        }
                }
                runCatching {
                    PublishBookstore.fetchRankPages(QidianRepository.RankType.Yuepiao, target = 50)
                }.getOrNull()?.takeIf { it.isNotEmpty() }?.let { yuepiao ->
                    putRankDetailCache(
                        rankCacheKey("rank", QidianRepository.Channel.Publish, QidianRepository.RankType.Yuepiao),
                        yuepiao,
                    )
                }
                runCatching { PublishBookstore.fetchLibraryMerged(target = 50) }
                    .getOrNull()?.takeIf { it.isNotEmpty() }?.let { library ->
                        putRankDetailCache(rankCacheKey("finish", QidianRepository.Channel.Publish), library)
                    }

        LogUtils.d(TAG, "prewarm ok ranks=${channelRankCache.size} rankDetail=${rankDetailCache.size}")
    }

    /** 跟 RankDetailActivity.loadFinishLibrary 同算法, 供预热复用 */
    private suspend fun loadFinishLibraryPrewarm(
        gender: QidianRepository.Channel = QidianRepository.Channel.Male,
    ): List<QidianBook> {
        val target = 50
        val seen = HashSet<String>()
        val out = ArrayList<QidianBook>(target + 10)
        if (gender != QidianRepository.Channel.Female) {
            runCatching { QidianRepository.fetchFinishRanks() }.getOrNull()?.let { ranks ->
                val order = listOf(
                    QidianRepository.RankType.FinishClassic,
                    QidianRepository.RankType.FinishBestSell,
                    QidianRepository.RankType.FinishDs,
                    QidianRepository.RankType.FinishMovie,
                )
                for (rt in order) {
                    ranks[rt]?.forEach { if (seen.add(it.bookId)) out.add(it) }
                }
            }
        }
        if (out.size < target) {
            val need = target - out.size
            runCatching {
                QidianRepository.fetchRankPages(
                    QidianRepository.RankType.Yuepiao, target = need * 2, gender = gender,
                )
            }.getOrNull()?.let { yuepiaoBooks ->
                val high = yuepiaoBooks.filter { parseWordCount(it.wordCount) >= 2_000_000 }
                val mid = yuepiaoBooks.filter {
                    val w = parseWordCount(it.wordCount)
                    w in 1_000_000 until 2_000_000
                }
                val rest = yuepiaoBooks.filter { parseWordCount(it.wordCount) < 1_000_000 }
                for (b in high + mid + rest) {
                    if (out.size >= target) break
                    if (seen.add(b.bookId)) out.add(b)
                }
            }
        }
        return out.take(target)
    }

    private fun parseWordCount(s: String): Long {
        if (s.isBlank()) return 0
        val m = Regex("""([\d.]+)\s*万""").find(s) ?: return 0
        return (m.groupValues[1].toDoubleOrNull()?.times(10000) ?: 0.0).toLong()
    }
}
