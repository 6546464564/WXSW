package io.legado.app.ui.main.bookstore

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.legado.app.help.WanxiangBookstoreMirror
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.http.okHttpClient
import io.legado.app.utils.LogUtils
import org.jsoup.Jsoup

/**
 * 万象书屋·书城 数据源.
 *
 * D-22 (2026-05-08): 数据源切换 zongheng → m.qidian.com/rank/.
 *
 * 演化历史:
 *   v1: qidian.com (PC 站) → JS 反爬挑战 (probe.js / WAF) 静态抓取不可行, 放弃
 *   v2: zongheng.com → 可抓但只有 cover + name, 三 tab 同源 (无 gender 区分)
 *   v3: m.qidian.com/rank/ ← 当前. 起点移动版无 WAF, 用 vite-plugin-ssr 把数据写在
 *       <script id="vite-plugin-ssr_pageContext" type="application/json"> 里.
 *       1 次请求拿 9 个真榜单 × 5 本 = 45 本, 字段全, gender 真区分.
 *
 * 9 个榜单 (m.qidian 真实 SSR key → 中文 → 我们的 RankType):
 *   fyRank    月票榜 (Monthly Vote)
 *   hotRank   阅读榜 (Hot Reading)
 *   dsRank    畅销榜 (Bestseller)
 *   recRank   推荐榜 (Recommend)
 *   updRank   更新榜 (Recent Update)
 *   signRank  签约榜 (Sign)
 *   newpRank  新人榜 (New Author)
 *   newbRank  新书榜 (New Book)
 *   newFans   书友榜 (Fans)
 *   readIndex 阅读指数 (Read Index)
 *
 * 封面 URL 不在 JSON 中, 用 bookId 拼:
 *   https://bookcover.yuewen.com/qdbimg/349573/<bookId>/180
 */
object QidianRepository {

    private const val TAG = "QidianRepository"
    private const val BASE = "https://m.qidian.com"
    private const val UA =
        "Mozilla/5.0 (Linux; Android 12; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36"

    /** 阅文集团 CDN 封面模板; bookId 替换占位即得最终 URL */
    private const val COVER_CDN_TEMPLATE = "https://bookcover.yuewen.com/qdbimg/349573/%s/180"

    /**
     * 万象书屋·书城 频道.
     *
     * D-22: 起点 m 站只有 male / female 两个 gender. "出版" (Publish) 起点没有该频道,
     * 客户端用 male + 切换到"完结/精选榜"差异化, 给用户视觉上还有第三个 tab.
     */
    /**
     * 万象书屋·书城 频道.
     *
     * D-22.1: m.qidian gender=female 与 male 榜单同源 (服务端/客户端均 mirror.ranks 兜底).
     * Publish 走 mirror.ranksPublish (catId=13100 实体书), feed 兜底.
     */
    enum class Channel {
        Male,
        Female,
        Publish,
    }

    /**
     * 万象书屋: 9 种榜单类型. m.qidian.com SSR 一次返回所有 9 个的 5 本, 我们按需消费.
     *
     * @param ssrKey vite-ssr JSON 内的 key
     * @param title  UI 上展示的中文榜单名 (写到 QidianBook.rankName)
     */
    enum class RankType(val ssrKey: String, val title: String) {
        Yuepiao("fyRank", "月票榜"),
        HotReading("hotRank", "阅读榜"),
        Bestseller("dsRank", "畅销榜"),
        Recommend("recRank", "推荐榜"),
        Update("updRank", "更新榜"),
        Sign("signRank", "签约榜"),
        NewAuthor("newpRank", "新人榜"),
        NewBook("newbRank", "新书榜"),
        Fans("newFans", "书友榜"),

        // 万象书屋 D-22.1: /finish/ 完结频道的 4 个榜单. ssrKey 跟 /rank/ 不重叠.
        FinishClassic("classic", "经典完本"),
        FinishMovie("movie", "影视化作品"),
        FinishBestSell("bestSell", "完本畅销"),
        FinishDs("ds", "电视剧改编"),
        ;

        /** /finish/ 完结频道 4 榜 */
        val isFinishRank: Boolean
            get() = when (this) {
                FinishClassic, FinishMovie, FinishBestSell, FinishDs -> true
                else -> false
            }

        /** mirror finish JSON 内的 key */
        val finishMirrorKey: String get() = ssrKey

        /** /finish/<path> 单榜详情 path */
        val finishDetailPath: String?
            get() = when (this) {
                FinishClassic -> "classic"
                FinishMovie -> "movie"
                FinishBestSell -> "bestSell"
                FinishDs -> "ds"
                else -> null
            }

        companion object {
            /** 全部榜单的 ssrKey → RankType 反查表 */
            val byKey: Map<String, RankType> by lazy { entries.associateBy { it.ssrKey } }
        }
    }

    /**
     * 抓书城 9 榜单数据.
     *
     * D-23 (2026-05-08): 数据源优先级:
     *   1. 后端 mirror (/api/bookstore/mirror) — 后端定时抓的 cache, 1 跳到我们 server
     *   2. 直抓 m.qidian.com/rank/ — 后端 503 / 网络故障时降级
     *
     * D-22.1 / iOS 对齐: 女频优先 mirror.ranksFemale; 空则 fallback ranks + gender=female 直抓.
     *
     * @param gender male / female (Publish 走 fetchFinishRanks, 不调此方法)
     * @return 9 个 RankType → List<QidianBook> (每榜 ~5 本); 找不到 SSR JSON 时抛异常
     */
    suspend fun fetchAllRanks(gender: Channel = Channel.Male): Map<RankType, List<QidianBook>> {
        // 1. 优先后端 mirror
        WanxiangBookstoreMirror.fetch()?.let { mirror ->
            var ranksObj = if (gender == Channel.Female) {
                mirror.getAsJsonObject("ranksFemale")
            } else {
                mirror.getAsJsonObject("ranks")
            }
            // m.qidian gender=female 与 male 榜单同源; mirror 女频抓取失败时用 ranks 兜底, 避免女频 tab 空榜
            if ((ranksObj == null || ranksObj.size() == 0) && gender == Channel.Female) {
                ranksObj = mirror.getAsJsonObject("ranks")
                if (ranksObj != null && ranksObj.size() > 0) {
                    LogUtils.d(TAG, "ranksFemale empty, fallback mirror ranks")
                }
            }
            if (ranksObj != null && ranksObj.size() > 0) {
                LogUtils.d(TAG, "${if (gender == Channel.Female) "ranksFemale" else "ranks"} from mirror version=${mirror.get("version")?.asLong}")
                return parseMirrorRanks(ranksObj)
            }
            if (gender == Channel.Male) {
                LogUtils.d(TAG, "mirror ranks empty, fallback direct")
            }
        }
        // 2. 后端没有 / 失败 → 直抓 m.qidian
        val genderParam = if (gender == Channel.Female) "female" else "male"
        LogUtils.d(TAG, "ranks fallback to direct fetch gender=$genderParam")
        val url = "$BASE/rank/?gender=$genderParam"
        return fetchPageWithSSR(url) { pageData -> parseRanksFromPageData(pageData) }
    }

    /** 出版频道: mirror.ranksPublish (起点 catId=13100 实体书分类) */
    suspend fun fetchPublishMirrorRanks(): Map<RankType, List<QidianBook>> {
        WanxiangBookstoreMirror.fetch()?.let { mirror ->
            mirror.getAsJsonObject("ranksPublish")?.let { obj ->
                if (obj.size() > 0) {
                    LogUtils.d(TAG, "ranksPublish from mirror version=${mirror.get("version")?.asLong}")
                    return parseMirrorRanks(obj)
                }
            }
        }
        return emptyMap()
    }

    /** 出版频道榜单详情页 (~50 本): 月票走 yuepiaoTop50Publish, 其余合并各榜 */
    suspend fun fetchPublishRankPages(type: RankType, target: Int = 50): List<QidianBook> {
        if (type == RankType.Yuepiao) {
            WanxiangBookstoreMirror.fetch()?.let { mirror ->
                val arr = mirror.getAsJsonArray("yuepiaoTop50Publish")
                if (arr != null && arr.size() > 0) {
                    LogUtils.d(TAG, "yuepiaoTop50Publish from mirror size=${arr.size()}")
                    return arr.mapNotNull {
                        runCatching { mirrorBookToQidian(it.asJsonObject, RankType.Yuepiao) }.getOrNull()
                    }.take(target)
                }
            }
        }
        val ranks = fetchPublishMirrorRanks()
        if (ranks.isEmpty()) return emptyList()
        val seen = LinkedHashSet<String>()
        val out = ArrayList<QidianBook>(target + 10)
        val order = if (type == RankType.Yuepiao) {
            listOf(RankType.Yuepiao)
        } else {
            listOf(type, RankType.HotReading, RankType.NewBook, RankType.Recommend)
        }
        for (rt in order) {
            if (rt == RankType.Yuepiao && type != RankType.Yuepiao) continue
            ranks[rt]?.forEach { b ->
                val key = b.bookId.ifEmpty { b.name }
                if (seen.add(key)) out.add(b)
            }
        }
        return out.take(target)
    }

    /** 万象书屋 D-23: mirror 的 ranks 字段 → RankType map. */
    private fun parseMirrorRanks(ranksObj: JsonObject): Map<RankType, List<QidianBook>> {
        val rankTypes = listOf(
            RankType.Yuepiao, RankType.HotReading, RankType.Bestseller,
            RankType.Recommend, RankType.Update, RankType.Sign,
            RankType.NewAuthor, RankType.NewBook, RankType.Fans,
        )
        val out = LinkedHashMap<RankType, List<QidianBook>>()
        for (rt in rankTypes) {
            val arr = ranksObj.getAsJsonArray(rt.ssrKey) ?: continue
            out[rt] = arr.mapNotNull { runCatching { mirrorBookToQidian(it.asJsonObject, rt) }.getOrNull() }
        }
        return out
    }

    /**
     * mirror 的 Book schema → 客户端 QidianBook.
     * mirror 字段 (来自后端 jobs/qidianMirror.js parseBook):
     *   bid / name / author / cat / subCat / wordCount / rank / rankCount / intro / coverUrl
     */
    private fun mirrorBookToQidian(obj: JsonObject, rankType: RankType): QidianBook? {
        val name = obj.get("name")?.asString?.trim().orEmpty()
        if (name.isBlank()) return null
        val bid = mirrorBidString(obj) ?: return null
        val cover = obj.get("coverUrl")?.asString?.trim().orEmpty()
            .ifBlank { COVER_CDN_TEMPLATE.format(bid) }
        return QidianBook(
            name = name,
            coverUrl = cover,
            author = obj.get("author")?.asString?.trim().orEmpty(),
            category = obj.get("cat")?.asString?.trim().orEmpty(),
            subCategory = obj.get("subCat")?.asString?.trim().orEmpty(),
            wordCount = obj.get("wordCount")?.asString?.trim().orEmpty(),
            bookId = bid,
            rank = obj.get("rank")?.asInt ?: 0,
            rankName = rankType.title,
            rankCount = obj.get("rankCount")?.asString?.trim().orEmpty(),
            intro = obj.get("intro")?.asString?.trim().orEmpty(),
        )
    }

    /** mirror bid 可能是 String 或 Number — 跟 iOS stringNumber 对齐 */
    private fun mirrorBidString(obj: JsonObject): String? {
        val bidEl = obj.get("bid") ?: return null
        if (!bidEl.isJsonPrimitive) return null
        val p = bidEl.asJsonPrimitive
        val bid = when {
            p.isString -> p.asString.trim()
            p.isNumber -> p.asLong.toString()
            else -> return null
        }
        return bid.takeIf { it.isNotBlank() }
    }

    /**
     * 万象书屋 D-22.1: 抓 m.qidian.com/finish/ 完结频道, 解析 vite-ssr JSON 返回 4 完结榜.
     *
     * /finish/ 字段跟 /rank/ 略不同:
     *   - bid 是 number (不是 string), parser 兼容
     *   - 没有 rankNum (按数组顺序赋值排名)
     *   - 没有 subCat (tag 直接用 cat 显示)
     *   - movie 是简化字段 (只有 bName/bid/bAuth/cid)
     */
    suspend fun fetchFinishRanks(): Map<RankType, List<QidianBook>> {
        // D-23: 优先 mirror
        WanxiangBookstoreMirror.fetch()?.let { mirror ->
            val finishObj = mirror.getAsJsonObject("finish")
            if (finishObj != null && finishObj.size() > 0) {
                LogUtils.d(TAG, "finish from mirror")
                return parseMirrorFinish(finishObj)
            }
        }
        LogUtils.d(TAG, "finish fallback to direct fetch")
        val url = "$BASE/finish/"
        return fetchPageWithSSR(url) { pageData -> parseFinishFromPageData(pageData) }
    }

    /** 万象书屋 D-23: mirror 的 finish 字段 → 4 完结 RankType map. */
    private fun parseMirrorFinish(finishObj: JsonObject): Map<RankType, List<QidianBook>> {
        val keyTypeMap = mapOf(
            "classic" to RankType.FinishClassic,
            "movie" to RankType.FinishMovie,
            "bestSell" to RankType.FinishBestSell,
            "ds" to RankType.FinishDs,
        )
        val out = LinkedHashMap<RankType, List<QidianBook>>()
        for ((key, rt) in keyTypeMap) {
            val arr = finishObj.getAsJsonArray(key) ?: continue
            out[rt] = arr.mapNotNull { runCatching { mirrorBookToQidian(it.asJsonObject, rt) }.getOrNull() }
        }
        return out
    }

    /**
     * 万象书屋 D-22.1 / D-22.3: 单榜分页接口.
     *
     * D-22.1: 仅 SSR 第一页 (20 本) — pageNum 参数被起点 m 站 SSR 忽略, 一直返第 1 页.
     * D-22.3: 改用 majax ajax 接口 — pageNum 参数生效, 可以拉 21-1000 名 (起点 SSR JSON
     *         的 total: 1000 是真总数). 需要从 SSR 页先拿到 _csrfToken cookie 再带 token 请求 majax.
     *
     * 工作流:
     *   1. 第一次调用时, GET /rank/?gender=male 把 _csrfToken cookie 写到 OkHttp cookie jar
     *      (legado okHttpClient 自动管理 cookie)
     *   2. GET /majax/rank/<path>List?_csrfToken=<token>&gender=male&pageNum=N
     *   3. 返回 JSON {code:0, data:{records:[20 本]}}
     */
    /** SSR 拉第一页 (无需 csrf token, 永远稳定) */
    private suspend fun fetchRankSsr(type: RankType, gender: Channel = Channel.Male): List<QidianBook> {
        val path = rankDetailPath(type)
            ?: throw IllegalArgumentException("RankType ${type.name} 无单榜分页 path")
        val genderParam = if (gender == Channel.Female) "female" else "male"
        val url = "$BASE/rank/$path?gender=$genderParam"
        LogUtils.d(TAG, "fetch detail SSR $url")
        val resp = okHttpClient.newCallStrResponse(retry = 1) {
            url(url)
            header("User-Agent", UA)
            header("Referer", "$BASE/")
            header("Accept-Language", "zh-CN,zh;q=0.9")
            header("Accept", "text/html,application/xhtml+xml")
        }
        val html = resp.body ?: throw IllegalStateException("空响应")
        val doc = Jsoup.parse(html)
        val script = doc.selectFirst("script#vite-plugin-ssr_pageContext")
            ?: throw IllegalStateException("vite-ssr script 不存在")
        val root = JsonParser.parseString(script.data())
        val pageData = root.asJsonObject
            .getAsJsonObject("pageContext")
            ?.getAsJsonObject("pageProps")
            ?.getAsJsonObject("pageData")
            ?: throw IllegalStateException("pageData 缺失")
        val records = pageData.getAsJsonArray("records") ?: return emptyList()
        return records.mapNotNull { runCatching { parseBook(it.asJsonObject, type) }.getOrNull() }
    }

    /**
     * D-22.3: ajax 拉第 N 页 (N>=2). 需要 _csrfToken.
     * majax 接口路径模式: /majax/rank/<path>List (注意 path 后缀 "List")
     */
    private suspend fun fetchRankAjax(
        type: RankType,
        pageNum: Int,
        gender: Channel = Channel.Male,
    ): List<QidianBook> {
        val path = rankAjaxPath(type)
            ?: throw IllegalArgumentException("RankType ${type.name} 无 majax path")
        val genderParam = if (gender == Channel.Female) "female" else "male"
        val csrf = ensureCsrfToken(gender)
        val url = "$BASE/majax/rank/$path?_csrfToken=$csrf&gender=$genderParam&pageNum=$pageNum"
        LogUtils.d(TAG, "fetch detail ajax $url")
        val resp = okHttpClient.newCallStrResponse(retry = 1) {
            url(url)
            header("User-Agent", UA)
            header("Referer", "$BASE/rank/${rankDetailPath(type)}?gender=$genderParam")
            header("Accept", "application/json, text/plain, */*")
            header("Cookie", "_csrfToken=$csrf")
        }
        val raw = resp.body ?: return emptyList()
        val json = runCatching { JsonParser.parseString(raw).asJsonObject }.getOrNull()
            ?: return emptyList()
        if (json.get("code")?.asInt != 0) {
            LogUtils.d(TAG, "majax err code=${json.get("code")} msg=${json.get("msg")}")
            return emptyList()
        }
        val records = json.getAsJsonObject("data")?.getAsJsonArray("records") ?: return emptyList()
        return records.mapNotNull { runCatching { parseBook(it.asJsonObject, type) }.getOrNull() }
    }

    /**
     * 拉多页凑够 [target] 本; 失败的页跳过, 已拿到的不浪费.
     *
     * iOS 对齐: 非完结榜走 SSR + majax 分页; 完结榜走 fetchFinishRankPages;
     * Yuepiao 优先 mirror yuepiaoTop50 / yuepiaoTop50Female.
     */
    suspend fun fetchRankPages(
        type: RankType,
        target: Int = 50,
        gender: Channel = Channel.Male,
    ): List<QidianBook> {
        val genderParam = if (gender == Channel.Female) "female" else "male"
        // D-23: Yuepiao 优先 mirror top50
        if (type == RankType.Yuepiao) {
            WanxiangBookstoreMirror.fetch()?.let { mirror ->
                var arr = if (gender == Channel.Female) {
                    mirror.getAsJsonArray("yuepiaoTop50Female")
                } else {
                    mirror.getAsJsonArray("yuepiaoTop50")
                }
                if ((arr == null || arr.size() == 0) && gender == Channel.Female) {
                    arr = mirror.getAsJsonArray("yuepiaoTop50")
                }
                if (arr != null && arr.size() > 0) {
                    LogUtils.d(TAG, "yuepiao top50 from mirror size=${arr.size()}")
                    return arr.mapNotNull {
                        runCatching { mirrorBookToQidian(it.asJsonObject, RankType.Yuepiao) }.getOrNull()
                    }.take(target)
                }
            }
            LogUtils.d(TAG, "yuepiao 50 fallback to direct fetch (SSR + majax)")
        }
        if (type.isFinishRank) {
            return fetchFinishRankPages(type, target)
        }
        if (rankDetailPath(type) == null) {
            val all = runCatching { fetchAllRanks(gender) }.getOrNull() ?: return emptyList()
            return (all[type] ?: emptyList()).take(target)
        }
        LogUtils.d(TAG, "rank pages paginated type=${type.name} gender=$genderParam target=$target")
        val out = ArrayList<QidianBook>(target + 20)
        val seen = HashSet<String>()
        var page = 1
        while (out.size < target && page <= 5) {
            val books = try {
                if (page == 1 && gender == Channel.Male) {
                    fetchRankSsr(type, gender)
                } else {
                    fetchRankAjax(type, page, gender)
                }
            } catch (t: Throwable) {
                LogUtils.d(TAG, "page=$page failed: ${t.javaClass.simpleName}: ${t.message}")
                emptyList()
            }
            LogUtils.d(TAG, "page=$page got=${books.size} total=${out.size + books.size}")
            if (books.isEmpty()) break
            for (b in books) if (seen.add(b.bookId)) out.add(b)
            page++
        }
        return out.take(target)
    }

    /** 完结频道单榜扩展到 target 本 (mirror → /finish/<path> SSR → 4 完结榜兜底) */
    private suspend fun fetchFinishRankPages(type: RankType, target: Int): List<QidianBook> {
        val out = ArrayList<QidianBook>(target + 10)
        val seen = HashSet<String>()
        WanxiangBookstoreMirror.fetch()?.let { mirror ->
            val finishObj = mirror.getAsJsonObject("finish")
            val arr = finishObj?.getAsJsonArray(type.finishMirrorKey)
            arr?.forEach { el ->
                runCatching { mirrorBookToQidian(el.asJsonObject, type) }.getOrNull()?.let { b ->
                    if (seen.add(b.bookId)) out.add(b)
                }
            }
        }
        if (out.size < target) {
            val path = type.finishDetailPath
            if (path != null) {
                runCatching {
                    fetchPageData("$BASE/finish/$path").getAsJsonArray("records")
                        ?.mapNotNull { runCatching { parseBook(it.asJsonObject, type) }.getOrNull() }
                        .orEmpty()
                }.getOrNull()?.forEach { b ->
                    if (seen.add(b.bookId)) out.add(b)
                }
            }
        }
        if (out.size < target) {
            runCatching { fetchFinishRanks() }.getOrNull()?.get(type).orEmpty().forEach { b ->
                if (seen.add(b.bookId)) out.add(b)
            }
        }
        return out.take(target)
    }

    /**
     * 万象书屋 D-22.3: 拉 csrf token. 起点 m 站在响应的 Set-Cookie header 设置 _csrfToken=<uuid>.
     *
     * 注意: legado 的 okHttpClient 默认禁用了 CookieJar (HttpHelper.kt:62 注释掉了 .cookieJar),
     * 所以 cookie 不会自动持久化. 我们手动从 Set-Cookie response header 解析 + 内存缓存.
     * 一次拿到后整个 App 进程都复用 (csrf cookie 寿命 1 年, 起点 server 接受任意 csrf 配对当前 session).
     */
    private suspend fun ensureCsrfToken(gender: Channel = Channel.Male): String {
        if (gender == Channel.Female) {
            cachedCsrfTokenFemale?.let { return it }
        } else {
            cachedCsrfTokenMale?.let { return it }
        }
        val genderParam = if (gender == Channel.Female) "female" else "male"
        val resp = okHttpClient.newCallStrResponse(retry = 1) {
            url("$BASE/rank/yuepiao?gender=$genderParam")
            header("User-Agent", UA)
            header("Accept", "text/html")
        }
        val setCookies = resp.raw.headers("Set-Cookie")
        val csrfLine = setCookies.firstOrNull { it.startsWith("_csrfToken=") }
            ?: throw IllegalStateException("响应未带 _csrfToken Set-Cookie (起点改了协议?)")
        val token = csrfLine.removePrefix("_csrfToken=").substringBefore(";").trim()
        if (token.isEmpty()) throw IllegalStateException("_csrfToken 空值")
        if (gender == Channel.Female) {
            cachedCsrfTokenFemale = token
        } else {
            cachedCsrfTokenMale = token
        }
        LogUtils.d(TAG, "csrf token cached gender=$genderParam")
        return token
    }

    @Volatile
    private var cachedCsrfTokenMale: String? = null

    @Volatile
    private var cachedCsrfTokenFemale: String? = null

    /** RankType → /rank/<path>?pageNum=N 的 SSR path. */
    private fun rankDetailPath(type: RankType): String? = when (type) {
        RankType.Yuepiao    -> "yuepiao"
        RankType.HotReading -> "hotsales"
        RankType.Bestseller -> "ds"
        RankType.Recommend  -> "recom"
        RankType.Update     -> "update"
        RankType.Sign       -> "signnewbook"
        RankType.NewAuthor  -> "newauthor"
        RankType.NewBook    -> "newbook"
        RankType.Fans       -> "newFans"
        else                -> null
    }

    /** RankType → /majax/rank/<path>List 的 ajax path (path 后缀加 "List", 实测) */
    private fun rankAjaxPath(type: RankType): String? = when (type) {
        RankType.Yuepiao    -> "yuepiaolist"
        RankType.HotReading -> "hotsalesList"
        RankType.Bestseller -> "dsList"
        RankType.Recommend  -> "recList"
        RankType.Update     -> "updateList"
        RankType.Sign       -> "signnewbookList"
        RankType.NewAuthor  -> "newauthorList"
        RankType.NewBook    -> "newbookList"
        RankType.Fans       -> "newFansList"
        else                -> null
    }

    /** 通用抓 vite-ssr 页 pageData, 给 fetchAllRanks/fetchFinishRanks/fetchFinishRankPages 复用 */
    private suspend fun fetchPageData(url: String): com.google.gson.JsonObject {
        LogUtils.d(TAG, "fetch $url")
        val resp = okHttpClient.newCallStrResponse(retry = 1) {
            url(url)
            header("User-Agent", UA)
            header("Referer", "$BASE/")
            header("Accept-Language", "zh-CN,zh;q=0.9")
            header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9")
        }
        val html = resp.body ?: throw IllegalStateException("空响应")
        val doc = Jsoup.parse(html)
        val script = doc.selectFirst("script#vite-plugin-ssr_pageContext")
            ?: throw IllegalStateException("vite-ssr script 不存在")
        val root = JsonParser.parseString(script.data())
            ?: throw IllegalStateException("vite-ssr JSON 解析失败")
        return root.asJsonObject
            .getAsJsonObject("pageContext")
            ?.getAsJsonObject("pageProps")
            ?.getAsJsonObject("pageData")
            ?: throw IllegalStateException("pageData 缺失")
    }

    /** 万象书屋: 通用抓 vite-ssr 页 + parse helper, 给 fetchAllRanks/fetchFinishRanks 复用 */
    private suspend fun fetchPageWithSSR(
        url: String,
        parse: (com.google.gson.JsonObject) -> Map<RankType, List<QidianBook>>,
    ): Map<RankType, List<QidianBook>> {
        return parse(fetchPageData(url))
    }

    /**
     * 解析 /rank/ 聚合页 pageData → 9 个 rank 榜单. 9 个 ssrKey: fyRank/hotRank/.../newFans.
     * 任一缺失返空 list, 不影响其他榜单可用.
     */
    private fun parseRanksFromPageData(
        pageData: com.google.gson.JsonObject
    ): Map<RankType, List<QidianBook>> {
        val rankTypes = listOf(
            RankType.Yuepiao, RankType.HotReading, RankType.Bestseller,
            RankType.Recommend, RankType.Update, RankType.Sign,
            RankType.NewAuthor, RankType.NewBook, RankType.Fans,
        )
        val out = LinkedHashMap<RankType, List<QidianBook>>()
        for (rt in rankTypes) {
            val arr = pageData.getAsJsonArray(rt.ssrKey)
            if (arr == null || arr.size() == 0) {
                out[rt] = emptyList()
                continue
            }
            out[rt] = arr.mapNotNull { runCatching { parseBook(it.asJsonObject, rt) }.getOrNull() }
        }
        val total = out.values.sumOf { it.size }
        LogUtils.d(TAG, "parsed ranks=${out.keys.size} total=$total")
        if (total == 0) throw IllegalStateException("解析到 0 条数据 (m.qidian 字段名变更?)")
        return out
    }

    /**
     * 万象书屋 D-22.1: 解析 /finish/ 完结页 pageData → 4 个完结榜.
     * /finish/ keys: classic / movie / bestSell / ds.
     */
    private fun parseFinishFromPageData(
        pageData: com.google.gson.JsonObject
    ): Map<RankType, List<QidianBook>> {
        val finishTypes = listOf(
            RankType.FinishClassic, RankType.FinishMovie,
            RankType.FinishBestSell, RankType.FinishDs,
        )
        val out = LinkedHashMap<RankType, List<QidianBook>>()
        for (rt in finishTypes) {
            val arr = pageData.getAsJsonArray(rt.ssrKey)
            if (arr == null || arr.size() == 0) {
                out[rt] = emptyList()
                continue
            }
            out[rt] = arr.mapIndexedNotNull { idx, el ->
                runCatching { parseBook(el.asJsonObject, rt, fallbackRank = idx + 1) }.getOrNull()
            }
        }
        val total = out.values.sumOf { it.size }
        LogUtils.d(TAG, "parsed finish ranks=${out.keys.size} total=$total")
        if (total == 0) throw IllegalStateException("解析到 0 条 finish 数据")
        return out
    }

    /**
     * 解析单本书. 起点字段名:
     *   /rank/ 系列: bName / bAuth / bid (string) / cat / subCat / cnt / desc / rankNum / rankCnt
     *   /finish/ 系列: bName / bAuth / bid (number) / cat / cnt / desc / state — 无 subCat / rankNum / rankCnt
     *
     * @param fallbackRank /finish/ 等没有 rankNum 的榜单按数组顺序赋值的兜底排名
     */
    private fun parseBook(
        obj: com.google.gson.JsonObject,
        rankType: RankType,
        fallbackRank: Int = 0,
    ): QidianBook? {
        // bid 在 /rank/ 是 string, 在 /finish/ 是 number, 兼容
        val bidEl = obj.get("bid") ?: return null
        val bid = if (bidEl.isJsonPrimitive) {
            val p = bidEl.asJsonPrimitive
            when {
                p.isString -> p.asString.takeIf { it.isNotBlank() }
                p.isNumber -> p.asLong.toString()
                else -> null
            }
        } else null
        if (bid.isNullOrBlank()) return null

        val name = obj.get("bName")?.asString?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val author = obj.get("bAuth")?.asString?.trim().orEmpty()
        val cat = obj.get("cat")?.asString?.trim().orEmpty()
        val subCat = obj.get("subCat")?.asString?.trim().orEmpty()
        val cnt = obj.get("cnt")?.asString?.trim().orEmpty()
        val desc = obj.get("desc")?.asString?.trim().orEmpty()
        val rankNum = runCatching { obj.get("rankNum")?.asInt }.getOrNull()
            ?: fallbackRank
        val rankCnt = obj.get("rankCnt")?.asString?.trim().orEmpty()
        val coverUrl = COVER_CDN_TEMPLATE.format(bid)
        return QidianBook(
            name = name,
            coverUrl = coverUrl,
            author = author,
            category = cat,
            subCategory = subCat,
            wordCount = cnt,
            bookId = bid,
            rank = rankNum,
            rankName = rankType.title,
            rankCount = rankCnt,
            intro = desc,
        )
    }
}
