package io.legado.app.ui.main.bookstore

import io.legado.app.help.coroutine.Coroutine
import io.legado.app.utils.LogUtils
import org.json.JSONArray
import org.json.JSONObject
import splitties.init.appCtx
import java.io.File

/**
 * 万象书屋: 「换一批」扩展榜磁盘 cache — 跟 iOS ExtendedRanksDiskCache 对齐.
 */
object BookStoreExtendedRanksDiskCache {

    private const val TAG = "BookStoreExtDisk"
    private const val FILE_NAME = "bookstore_extended_ranks.json"

    private val cacheFile: File
        get() = File(appCtx.filesDir, FILE_NAME)

    fun load(): Map<QidianRepository.Channel, Map<QidianRepository.RankType, List<QidianBook>>> {
        val file = cacheFile
        if (!file.exists()) return emptyMap()
        return runCatching {
            val root = JSONObject(file.readText())
            val out = LinkedHashMap<QidianRepository.Channel, Map<QidianRepository.RankType, List<QidianBook>>>()
            for (chKey in root.keys()) {
                val channel = channelFromKey(chKey) ?: continue
                val ranksObj = root.optJSONObject(chKey) ?: continue
                val ranks = LinkedHashMap<QidianRepository.RankType, List<QidianBook>>()
                for (typeKey in ranksObj.keys()) {
                    val type = rankTypeFromKey(typeKey) ?: continue
                    val arr = ranksObj.optJSONArray(typeKey) ?: continue
                    val books = (0 until arr.length()).mapNotNull { i ->
                        arr.optJSONObject(i)?.let { dictToBook(it) }
                    }
                    if (books.isNotEmpty()) ranks[type] = books
                }
                if (ranks.isNotEmpty()) out[channel] = ranks
            }
            out
        }.getOrElse {
            LogUtils.d(TAG, "load failed: ${it.message}")
            emptyMap()
        }
    }

    fun save(cache: Map<QidianRepository.Channel, Map<QidianRepository.RankType, List<QidianBook>>>) {
        Coroutine.async {
            runCatching {
                val root = JSONObject()
                for ((channel, ranks) in cache) {
                    val ranksObj = JSONObject()
                    for ((type, books) in ranks) {
                        if (books.isEmpty()) continue
                        val arr = JSONArray()
                        books.forEach { arr.put(bookToJson(it)) }
                        ranksObj.put(rankKey(type), arr)
                    }
                    if (ranksObj.length() > 0) {
                        root.put(channelKey(channel), ranksObj)
                    }
                }
                cacheFile.writeText(root.toString())
            }.onFailure { LogUtils.d(TAG, "save failed: ${it.message}") }
        }
    }

    private fun channelKey(ch: QidianRepository.Channel): String = when (ch) {
        QidianRepository.Channel.Male -> "male"
        QidianRepository.Channel.Female -> "female"
        QidianRepository.Channel.Publish -> "publish"
    }

    private fun channelFromKey(key: String): QidianRepository.Channel? = when (key) {
        "male", "Male" -> QidianRepository.Channel.Male
        "female", "Female" -> QidianRepository.Channel.Female
        "publish", "Publish" -> QidianRepository.Channel.Publish
        else -> null
    }

    private fun rankKey(rt: QidianRepository.RankType): String = when (rt) {
        QidianRepository.RankType.Yuepiao -> "yuepiao"
        QidianRepository.RankType.HotReading -> "hotReading"
        QidianRepository.RankType.Bestseller -> "bestseller"
        QidianRepository.RankType.Recommend -> "recommend"
        QidianRepository.RankType.Update -> "update"
        QidianRepository.RankType.Sign -> "sign"
        QidianRepository.RankType.NewAuthor -> "newAuthor"
        QidianRepository.RankType.NewBook -> "newBook"
        QidianRepository.RankType.Fans -> "fans"
        QidianRepository.RankType.FinishClassic -> "finishClassic"
        QidianRepository.RankType.FinishMovie -> "finishMovie"
        QidianRepository.RankType.FinishBestSell -> "finishBestSell"
        QidianRepository.RankType.FinishDs -> "finishDs"
    }

    private fun rankTypeFromKey(key: String): QidianRepository.RankType? =
        QidianRepository.RankType.entries.find { rankKey(it) == key }

    private fun bookToJson(b: QidianBook): JSONObject = JSONObject()
        .put("n", b.name)
        .put("c", b.coverUrl)
        .put("a", b.author)
        .put("ca", b.category)
        .put("sc", b.subCategory)
        .put("wc", b.wordCount)
        .put("bi", b.bookId)
        .put("r", b.rank)
        .put("rn", b.rankName)
        .put("rc", b.rankCount)
        .put("i", b.intro)

    private fun dictToBook(o: JSONObject): QidianBook? {
        val name = o.optString("n").trim()
        if (name.isEmpty()) return null
        return QidianBook(
            name = name,
            coverUrl = o.optString("c"),
            author = o.optString("a"),
            category = o.optString("ca"),
            subCategory = o.optString("sc"),
            wordCount = o.optString("wc"),
            bookId = o.optString("bi"),
            rank = o.optInt("r"),
            rankName = o.optString("rn"),
            rankCount = o.optString("rc"),
            intro = o.optString("i"),
        )
    }
}
