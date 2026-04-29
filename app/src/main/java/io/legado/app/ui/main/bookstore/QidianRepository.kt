package io.legado.app.ui.main.bookstore

import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.http.okHttpClient
import io.legado.app.utils.LogUtils
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

/**
 * 万象书屋·书城 数据源
 *
 * 设计变更说明: 起点中文网 qidian.com 全站启用了 JS 反爬挑战 (probe.js / WAF),
 * 所有 listing 页都返回 202 stub。在不引入 WebView 渲染的前提下静态抓取不可行。
 * 改用纵横中文网 (book.zongheng.com) 同类 SSR 列表页, 数据形态一致 (封面+书名).
 *
 * 严格只取 cover + name (按用户要求), 不抓作者/简介/字数等。
 */
object QidianRepository {

    private const val TAG = "QidianRepository"

    /**
     * 3 个频道映射到 zongheng 不同分类页, 视觉上对应 ssyd 的「男生/女生/出版」Tab。
     * URL 模式: /store/c{cat}/c0/b0/u0/p{page}/v0/s9/t0/u0/i1/ALL.html
     */
    enum class Channel(val label: String, val category: Int) {
        Male("男生", 2),     // 玄幻/奇幻 主流男频
        Female("女生", 10),  // 言情/都市言情 偏女频
        Publish("出版", 8),  // 历史/军事/出版相关
        ;

        fun urlFor(page: Int): String =
            "https://book.zongheng.com/store/c$category/c0/b0/u0/p$page/v0/s9/t0/u0/i1/ALL.html"
    }

    private const val UA =
        "Mozilla/5.0 (Linux; Android 12; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36"

    /**
     * 抓取指定频道指定页(1-based)的书单
     * 失败抛异常, 由 Fragment 捕获显示加载失败
     */
    suspend fun fetchList(channel: Channel, page: Int = 1): List<QidianBook> {
        val url = channel.urlFor(page)
        LogUtils.d(TAG, "fetch $url")
        val resp = okHttpClient.newCallStrResponse(retry = 1) {
            url(url)
            header("User-Agent", UA)
            header("Referer", "https://book.zongheng.com/")
            header("Accept-Language", "zh-CN,zh;q=0.9")
        }
        val html = resp.body ?: throw IllegalStateException("空响应")
        val books = parseList(html, url)
        LogUtils.d(TAG, "parsed ${books.size} books from $url")
        if (books.isEmpty()) throw IllegalStateException("解析到 0 条数据 (zongheng 页面结构可能变更)")
        return books
    }

    /**
     * 容错解析:
     * zongheng 列表 SSR HTML 模板: <li class="book-li"> 内含
     *   <img class="book-cover" data-src="..." src="占位图" alt="书名">
     *   <a class="book-title">书名</a>
     */
    private fun parseList(html: String, baseUrl: String): List<QidianBook> {
        val doc: Document = Jsoup.parse(html, baseUrl)
        val itemSelectors = listOf(
            "li.book-li",
            ".book-layout",
            "li[class*=book-li]",
            ".book-box-li"
        )
        var items: List<Element> = emptyList()
        for (sel in itemSelectors) {
            val nodes = doc.select(sel)
            if (nodes.isNotEmpty()) {
                items = nodes
                break
            }
        }
        return items.mapNotNull { parseItem(it) }
    }

    private fun parseItem(item: Element): QidianBook? {
        // 名字: 优先 a.book-title, 兜底 img[alt]
        val titleA = item.selectFirst("a.book-title")
        val coverImg = item.selectFirst("img.book-cover")
            ?: item.selectFirst("img")
            ?: return null

        val name = titleA?.text()?.trim()?.replace(Regex("\\s+"), " ")
            ?.takeIf { it.isNotEmpty() }
            ?: coverImg.attr("alt").trim().replace(Regex("\\s+"), " ").takeIf { it.isNotEmpty() }
            ?: return null

        val coverRaw = sequenceOf(
            coverImg.attr("data-src"),
            coverImg.attr("data-original"),
            coverImg.attr("src")
        ).firstOrNull {
            it.isNotBlank() && !it.contains("placeholder") && !it.endsWith(".png")
        } ?: sequenceOf(
            coverImg.attr("data-src"),
            coverImg.attr("src")
        ).firstOrNull { it.isNotBlank() } ?: return null

        val cover = when {
            coverRaw.startsWith("//") -> "https:$coverRaw"
            coverRaw.startsWith("/") -> "https://book.zongheng.com$coverRaw"
            else -> coverRaw
        }
        return QidianBook(name = name, coverUrl = cover)
    }
}
