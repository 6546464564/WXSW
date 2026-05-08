package io.legado.app.ui.main.bookstore

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import androidx.core.view.isVisible
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import io.legado.app.R
import io.legado.app.base.BaseActivity
import io.legado.app.databinding.ActivityRankDetailBinding
import io.legado.app.ui.book.search.SearchActivity
import io.legado.app.utils.LogUtils
import io.legado.app.utils.viewbindingdelegate.viewBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 万象书屋·完整榜单详情页.
 *
 * D-22.1 (2026-05-08): 书城 banner "热门排行" / "完本书库" 点击落地页.
 *
 * 来源:
 *   - mode = "rank" + RankType: 走 m.qidian.com/rank/<path>?pageNum=N 单榜分页接口 (20+ 本)
 *   - mode = "finish":          走 m.qidian.com/finish/, 把 4 完结榜合并展示
 *
 * 列表样式: 书架 list item 风格 (大封面 + 书名 + 作者 + 分类 + 字数 + 简介)
 * 点击书目: 跳 SearchActivity 用书名搜本地书源 (跟书城首页一致)
 */
class RankDetailActivity : BaseActivity<ActivityRankDetailBinding>() {

    override val binding by viewBinding(ActivityRankDetailBinding::inflate)

    private lateinit var adapter: RankDetailAdapter
    private var loadJob: Job? = null

    /** 当前 mode: rank | finish */
    private val mode: String by lazy { intent.getStringExtra(EXTRA_MODE) ?: "rank" }

    /** 仅 mode=rank 时使用; 决定走哪个单榜分页接口 */
    private val rankType: QidianRepository.RankType by lazy {
        intent.getStringExtra(EXTRA_RANK_TYPE)
            ?.let { runCatching { QidianRepository.RankType.valueOf(it) }.getOrNull() }
            ?: QidianRepository.RankType.Yuepiao
    }

    private val titleText: String by lazy {
        intent.getStringExtra(EXTRA_TITLE) ?: when (mode) {
            "finish" -> "完本书库"
            else -> rankType.title
        }
    }

    override fun onActivityCreated(savedInstanceState: Bundle?) {
        binding.titleBar.title = titleText
        adapter = RankDetailAdapter(this) { book -> SearchActivity.start(this, book.name) }
        binding.recyclerView.layoutManager = LinearLayoutManager(this)
        binding.recyclerView.adapter = adapter
        binding.refreshLayout.setOnRefreshListener { loadData() }
        loadData()
    }

    private fun loadData() {
        loadJob?.cancel()
        binding.tvStatus.isVisible = true
        binding.tvStatus.setText(R.string.bs_loading)
        binding.refreshLayout.isRefreshing = true
        loadJob = lifecycleScope.launch {
            try {
                val books = withContext(Dispatchers.IO) {
                    when (mode) {
                        "finish" -> loadFinishLibrary()
                        else -> QidianRepository.fetchRankPages(rankType, target = TARGET_COUNT)
                    }
                }
                if (isFinishing) return@launch
                if (books.isEmpty()) {
                    binding.tvStatus.setText(R.string.bs_load_failed)
                } else {
                    adapter.submit(books)
                    binding.tvStatus.isVisible = false
                    LogUtils.d(TAG, "loaded ${books.size} books, mode=$mode")
                }
            } catch (t: Throwable) {
                LogUtils.d(TAG, "load failed: ${t.message}")
                if (!isFinishing) binding.tvStatus.setText(R.string.bs_load_failed)
            } finally {
                if (!isFinishing) binding.refreshLayout.isRefreshing = false
            }
        }
    }

    /**
     * 万象书屋 D-22.3: 完本书库扩展到 50 本.
     *
     * 数据源现实:
     *   - 起点 m.qidian.com /finish/ SSR 只暴露 ~23 本经典完本/影视化作品 (固定)
     *   - 其他榜单的独立 SSR 路径都返 404 (只 /rank/yuepiao 一个)
     *   - 其他榜单的 majax ajax 也都返 not found (只 /majax/rank/yuepiaolist 一个)
     *
     * 因此 50 本组成: /finish/ 23 本 + yuepiao majax 后续 27 本.
     *   前 23 本是真完结经典(诡秘之主/斗破苍穹/斗罗大陆/庆余年/将夜...)
     *   后 27 本来自月票榜 顶部高字数书 (字数 ≥ 200 万的多为完本或近完本经典)
     *   去重后总数 50 本左右.
     */
    private suspend fun loadFinishLibrary(): List<QidianBook> {
        val seen = HashSet<String>()
        val out = ArrayList<QidianBook>(TARGET_COUNT + 30)

        // 1) /finish/ 4 完结榜 (经典完本最优先)
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

        // 2) 月票榜补充至 50 本. 起点 m.qidian 只 yuepiao majax 接口可分页,
        //    顶部多是大神作/经典书 (200 万字+占比高), 跟"完本书库"语义接近.
        //    用字数过滤优先 200 万以上的, 提升完本概率.
        if (out.size < TARGET_COUNT) {
            val need = TARGET_COUNT - out.size
            runCatching {
                QidianRepository.fetchRankPages(
                    QidianRepository.RankType.Yuepiao,
                    target = need * 2,  // 多拉一倍, 留过滤空间
                )
            }.getOrNull()?.let { yuepiaoBooks ->
                // 优先字数 ≥ 200 万 (完本概率高), 然后字数 ≥ 100 万, 最后兜底
                val highWord = yuepiaoBooks.filter { it.parseWordCount() >= 2_000_000 }
                val midWord = yuepiaoBooks.filter {
                    it.parseWordCount() in 1_000_000 until 2_000_000
                }
                val rest = yuepiaoBooks.filter { it.parseWordCount() < 1_000_000 }
                for (b in highWord + midWord + rest) {
                    if (out.size >= TARGET_COUNT) break
                    if (seen.add(b.bookId)) out.add(b)
                }
            }
        }
        return out.take(TARGET_COUNT)
    }

    /** "569.44万字" → 5_694_400; "27.39万字" → 273_900; 解析失败返 0 */
    private fun QidianBook.parseWordCount(): Long {
        if (wordCount.isBlank()) return 0
        val m = Regex("""([\d.]+)\s*万""").find(wordCount) ?: return 0
        val num = m.groupValues[1].toDoubleOrNull() ?: return 0
        return (num * 10000).toLong()
    }

    companion object {
        private const val TAG = "RankDetailActivity"
        private const val EXTRA_MODE = "mode"            // "rank" | "finish"
        private const val EXTRA_RANK_TYPE = "rankType"   // RankType enum name
        private const val EXTRA_TITLE = "title"

        /** 万象书屋 D-22.3: 目标加载本数. 50 本是起点 m 站 majax 3 页能稳拉的量. */
        private const val TARGET_COUNT = 50

        /** 启动: 显示某个 RankType 的完整 20+ 本 (调单榜分页接口) */
        fun startRank(ctx: Context, rankType: QidianRepository.RankType, title: String? = null) {
            ctx.startActivity(Intent(ctx, RankDetailActivity::class.java).apply {
                putExtra(EXTRA_MODE, "rank")
                putExtra(EXTRA_RANK_TYPE, rankType.name)
                title?.let { putExtra(EXTRA_TITLE, it) }
            })
        }

        /** 启动: 显示完本书库 (合并 /finish/ 4 个完结榜) */
        fun startFinish(ctx: Context, title: String? = null) {
            ctx.startActivity(Intent(ctx, RankDetailActivity::class.java).apply {
                putExtra(EXTRA_MODE, "finish")
                title?.let { putExtra(EXTRA_TITLE, it) }
            })
        }
    }
}
