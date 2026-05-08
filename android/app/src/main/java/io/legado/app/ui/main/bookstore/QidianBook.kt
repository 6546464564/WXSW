package io.legado.app.ui.main.bookstore

/**
 * 万象书屋·书城 书目数据.
 *
 * D-22 升级 (2026-05-08): 数据源切换 zongheng → m.qidian.com/rank/ 后, 字段从「封面+书名」
 * 扩展为完整元信息. m 站起点用 vite-plugin-ssr 把数据放在 <script id="vite-plugin-ssr_pageContext"> JSON,
 * 一次请求拿 9 个真榜单 × 5 本, 字段全 (作者/分类/字数/排名/简介).
 *
 * 注意: 封面 URL 不在 JSON 中, 用 bookId 拼 CDN: https://bookcover.yuewen.com/qdbimg/349573/<bid>/180
 */
data class QidianBook(
    /** 书名 (起点字段 bName) */
    val name: String,
    /** 封面 URL — 拼接 https://bookcover.yuewen.com/qdbimg/349573/<bookId>/180 */
    val coverUrl: String,
    /** 作者 (起点字段 bAuth) — 之前为空, 现在有真值 */
    val author: String = "",
    /** 大分类 (起点字段 cat): 玄幻/都市/仙侠/言情/历史/科幻/悬疑/轻小说/游戏/诸天无限 等 */
    val category: String = "",
    /** 子分类 (起点字段 subCat): 修真文明/异术超能/东方玄幻/恋爱日常 等 */
    val subCategory: String = "",
    /** 总字数 (起点字段 cnt): "569.44万字" 这种带单位字符串 */
    val wordCount: String = "",
    /** 起点 bookId — 用于拼封面 URL / 跳详情页 (我们目前只用拼封面) */
    val bookId: String = "",
    /** 该书在所属榜单内的真排名 (起点字段 rankNum, 1-based) */
    val rank: Int = 0,
    /** 来自哪个榜单的中文名 ("月票榜"/"畅销榜"/...), 给 UI badge 用 */
    val rankName: String = "",
    /** 榜单维度数据 (起点字段 rankCnt): "12.04万月票" / "7.08万推荐" / "0月更字" — 部分榜单有 */
    val rankCount: String = "",
    /** 简介 (起点字段 desc) */
    val intro: String = "",
)
