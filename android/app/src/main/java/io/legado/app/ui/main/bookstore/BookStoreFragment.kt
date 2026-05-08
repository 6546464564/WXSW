package io.legado.app.ui.main.bookstore

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible
import androidx.lifecycle.lifecycleScope
import io.legado.app.R
import io.legado.app.base.BaseFragment
import io.legado.app.databinding.FragmentBookStoreBinding
import io.legado.app.help.glide.ImageLoader
import io.legado.app.ui.book.search.SearchActivity
import io.legado.app.ui.main.MainFragmentInterface
import io.legado.app.utils.LogUtils
import io.legado.app.utils.applyStatusBarPadding
import io.legado.app.utils.dpToPx
import io.legado.app.utils.viewbindingdelegate.viewBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 万象书屋·书城
 *
 * D-22 (2026-05-08): 数据源 zongheng → m.qidian.com/rank/.
 *   1 个 HTTP 拉聚合页 → vite-ssr JSON → 9 个真榜单 × 5 本 = 45 本.
 *   字段含真作者/真分类/真字数/真排名/真简介, 副标签和徽章不再用 FALLBACK 假数据.
 *
 * 板块映射 (起点 m 站 SSR key → 我们的 UI 板块):
 *   hero          = fyRank #1            (月票第一名当头条卡片)
 *   今日必读 grid = hotRank   (8 本)     (阅读榜 — 大家都在看)
 *   完本精选 grid = newbRank  (8 本)     (新书榜 — "起点没纯完结榜, 用新书替代")
 *   推荐榜 grid   = recRank   (8 本)     (推荐榜 — 带真排名 1-5+)
 *
 * 点击书目 -> SearchActivity 预填书名
 */
class BookStoreFragment() : BaseFragment(R.layout.fragment_book_store), MainFragmentInterface {

    constructor(position: Int) : this() {
        val bundle = Bundle()
        bundle.putInt("position", position)
        arguments = bundle
    }

    override val position: Int? get() = arguments?.getInt("position")

    private val binding by viewBinding(FragmentBookStoreBinding::bind)

    private var currentChannel = QidianRepository.Channel.Male
    private var loading = false

    /** 当前 in-flight 的列表加载 Job; 切换频道时取消, 避免旧请求覆盖新频道 */
    private var loadJob: Job? = null

    /**
     * 万象书屋 D-22: 频道维度短时缓存. 现在缓存的是「整张榜单 map」,
     * 切 Tab 来回时复用避免重复请求 m.qidian.
     */
    private val channelRankCache =
        mutableMapOf<QidianRepository.Channel, Pair<Map<QidianRepository.RankType, List<QidianBook>>, Long>>()

    /** 当前已加载的书目列表 (9 榜单合并去重); 「换一换」时基于此数组做循环切片 */
    private var allBooks: List<QidianBook> = emptyList()

    /** 「换一换」翻页偏移; 每次点击 +1, 越界回 0 重新洗牌 */
    private var swapPageMustRead = 0
    private var swapPageComplete = 0
    private var swapPageRanked = 0

    private lateinit var inflater: LayoutInflater

    companion object {
        private const val MUST_READ_GRID = 8
        private const val COMPLETE_GRID = 8
        private const val RANKED_COUNT = 8
        private const val TAG = "BookStoreFragment"
        private const val CACHE_TTL_MS = 5 * 60_000L
    }

    override fun onFragmentCreated(view: View, savedInstanceState: Bundle?) {
        inflater = layoutInflater
        setupSwipeRefreshColors()
        setupSectionActions()
        setupTopBar()
        setupBanners()
        binding.refreshLayout.setOnRefreshListener { reload(forceRefresh = true) }
        reload(forceRefresh = false)
        // 万象书屋 D-17 (THEME-EInk): EInk 模式下书城页布局含大量米黄色 drawable (bg_cosmic_*),
        // 这些 drawable 不响应 night 资源切换 (因为 EInk 走 NIGHT_NO).
        // 在代码层面动态覆盖为纯白, 让 EInk 模式下书城跟其他页保持一致 (黑白阅读)
        applyEInkOverridesIfNeeded()
    }

    /**
     * 万象书屋 D-17 (THEME-EInk): EInk 模式下覆盖书城页全部底色为白色,
     * 卡片仍保留圆角但去掉米黄底, 章节封面保持彩色 (PNG 保留, 用户依赖封面识别书).
     * Light/Dark 模式不进此分支, drawable 自动走 values/values-night/ 即可.
     */
    private fun applyEInkOverridesIfNeeded() {
        if (!io.legado.app.help.config.AppConfig.isEInkMode) return
        val white = android.graphics.Color.WHITE
        // 1) 整体背景
        binding.root.setBackgroundColor(white)
        // 2) 顶栏 (吸顶)
        binding.topBarContainer.setBackgroundColor(white)
        // 3) 排行 / 完本书库 banner — 根背景被 cardview, 内部 LinearLayout 用了 bs_banner_*_bg drawable
        binding.cardRank.setCardBackgroundColor(white)
        binding.cardLibrary.setCardBackgroundColor(white)
        // CardView 内部第一个 LinearLayout 也覆盖白色 (清米黄 drawable)
        (binding.cardRank.getChildAt(0) as? android.view.View)?.setBackgroundColor(white)
        (binding.cardLibrary.getChildAt(0) as? android.view.View)?.setBackgroundColor(white)
        // 4) NestedScrollView 内的 LinearLayout 背景为透明, 跟随 root 即可, 不动.
        // 5) 顶栏 tab 文字色 EInk 用纯黑 (默认 wanxiang_text_primary 在 EInk 仍走 light 米黄系)
        val black = android.graphics.Color.BLACK
        binding.tabMale.setTextColor(black)
        binding.tabFemale.setTextColor(black)
        binding.tabPublish.setTextColor(black)
        binding.ivSearch.imageTintList = android.content.res.ColorStateList.valueOf(black)
    }

    private fun setupSwipeRefreshColors() {
        val accent = ContextCompat.getColor(requireContext(), R.color.wanxiang_accent)
        val primary = ContextCompat.getColor(requireContext(), R.color.wanxiang_primary)
        binding.refreshLayout.setColorSchemeColors(accent, primary)
        binding.refreshLayout.setProgressBackgroundColorSchemeResource(R.color.wanxiang_card)
    }

    /**
     * 万象书屋 D-22.2: 板块 click 行为只设一次 (创建时), 标题在 bindAllSlots 里随 channel 动态更新.
     *
     * 解决 D-22.1 后用户反馈的"逻辑很乱": 之前板块标题是写死的"新用户必读/完本精选/推荐榜",
     * 但实际数据按 channel 取了不同的起点榜单 (男频"完本精选"实际是新书榜, 文不对题).
     *
     * 现在标题完全由 RankType.title 驱动, 跟数据来源一致, 用户能直接看出板块是什么榜.
     */
    private fun setupSectionActions() {
        // 万象书屋 D-22.4: 三个 section 操作统一为 "换一批 ↻", 都走客户端切片 swap.
        // 之前推荐榜的 "查看完整 ›" 跳 RankDetailActivity, 但起点除了 yuepiao 都没分页接口,
        // 退化到聚合页 5 本时 UI 看到"完整"反而只 5 本, 不如统一换一批稳定.
        // 想看 50 本完整榜单的用户走顶部 "热门排行" / "完本书库" banner 即可.
        binding.sectionMustRead.tvSectionAction.setText(R.string.bs_swap_more)
        binding.sectionMustRead.tvSectionAction.setOnClickListener {
            swapPageMustRead++
            rebindMustRead()
        }

        binding.sectionComplete.tvSectionAction.setText(R.string.bs_swap_more)
        binding.sectionComplete.tvSectionAction.setOnClickListener {
            swapPageComplete++
            rebindComplete()
        }

        binding.sectionRecommend.tvSectionAction.setText(R.string.bs_swap_more)
        binding.sectionRecommend.tvSectionAction.setOnClickListener {
            swapPageRanked++
            rebindRanked()
        }
    }

    /**
     * D-22.2: 在 bindAllSlots 里每次根据当前 channel 的 RankType 三元组同步 section 标题.
     */
    private fun updateSectionTitles(
        mustReadType: QidianRepository.RankType,
        completeType: QidianRepository.RankType,
        rankedType: QidianRepository.RankType,
    ) {
        binding.sectionMustRead.tvSectionTitle.text = mustReadType.title
        binding.sectionComplete.tvSectionTitle.text = completeType.title
        binding.sectionRecommend.tvSectionTitle.text = rankedType.title
    }

    /** 「换一换」: 取下一页 8 本, 不重新发请求 */
    private fun rebindMustRead() {
        if (allBooks.isEmpty()) return
        binding.gridMustRead.removeAllViews()
        val sliced = sliceBooks(allBooks, swapPageMustRead, MUST_READ_GRID, offsetSeed = 1)
        sliced.forEachIndexed { idx, book ->
            addGridCell(binding.gridMustRead, book, idx)
        }
    }

    private fun rebindComplete() {
        if (allBooks.isEmpty()) return
        binding.gridComplete.removeAllViews()
        val sliced =
            sliceBooks(allBooks, swapPageComplete, COMPLETE_GRID, offsetSeed = MUST_READ_GRID + 1)
        sliced.forEachIndexed { idx, book ->
            addGridCell(binding.gridComplete, book, idx + MUST_READ_GRID)
        }
    }

    private fun rebindRanked() {
        if (allBooks.isEmpty()) return
        binding.gridRanked.removeAllViews()
        val offset = MUST_READ_GRID + COMPLETE_GRID + 1
        val sliced = sliceBooks(allBooks, swapPageRanked, RANKED_COUNT, offsetSeed = offset)
        // 排名始终从 1 开始, 让换页前后徽章顺序保持一致
        sliced.forEachIndexed { idx, book ->
            addRankedCell(binding.gridRanked, idx + 1, book)
        }
    }

    /**
     * 万象书屋: 取一段循环切片, 每次 swap 翻一页
     * offsetSeed 用于不同 section 之间稍微错开起点, 避免「必读」「完本」内容雷同
     */
    private fun sliceBooks(
        all: List<QidianBook>,
        page: Int,
        size: Int,
        offsetSeed: Int = 0
    ): List<QidianBook> {
        if (all.isEmpty()) return emptyList()
        val start = ((page * size) + offsetSeed) % all.size
        return (0 until size).map { all[(start + it) % all.size] }
    }

    private fun setupTopBar() {
        // 万象书屋: 真机上 (尤其刘海/挖孔屏) 状态栏会盖住 Tab 区域,
        // 导致 男生/女生/出版 点击事件被吃掉. 给顶栏加上状态栏 inset 后下移即可正常.
        binding.topBarContainer.applyStatusBarPadding()
        binding.tabMale.setOnClickListener { switchChannel(QidianRepository.Channel.Male) }
        binding.tabFemale.setOnClickListener { switchChannel(QidianRepository.Channel.Female) }
        binding.tabPublish.setOnClickListener { switchChannel(QidianRepository.Channel.Publish) }
        binding.ivSearch.setOnClickListener { SearchActivity.start(requireContext(), null) }
        upTabIndicator()
    }

    private fun setupBanners() {
        // 万象书屋 D-22.1 / D-22.3: banner 跳 RankDetailActivity 起点完整榜单详情页.
        //   "热门排行" -> Yuepiao 月票榜 50 本 (起点 m 站只 yuepiaolist majax 接口稳定支持分页)
        //   "完本书库" -> /finish/ 4 完结榜 + yuepiao 字数过滤补足共 50 本
        binding.cardRank.setOnClickListener {
            RankDetailActivity.startRank(
                requireContext(), QidianRepository.RankType.Yuepiao, getString(R.string.bs_rank)
            )
        }
        binding.cardLibrary.setOnClickListener {
            RankDetailActivity.startFinish(requireContext(), getString(R.string.bs_library))
        }
    }

    /** 将栏目标题滚入可视区域（顶部留白） */
    private fun scrollSectionIntoView(target: View) {
        val scroll = binding.bookStoreScroll
        val content = scroll.getChildAt(0) as? ViewGroup ?: return
        scroll.post {
            val y = target.offsetInAncestor(content) - 8.dpToPx()
            scroll.smoothScrollTo(0, y.coerceAtLeast(0))
        }
    }

    private fun upTabIndicator() {
        val tabs = listOf(binding.tabMale, binding.tabFemale, binding.tabPublish)
        val activeIdx = when (currentChannel) {
            QidianRepository.Channel.Male -> 0
            QidianRepository.Channel.Female -> 1
            QidianRepository.Channel.Publish -> 2
        }
        val activeColor = ContextCompat.getColor(requireContext(), R.color.wanxiang_text_primary)
        val inactiveColor = ContextCompat.getColor(requireContext(), R.color.wanxiang_text_secondary)
        tabs.forEachIndexed { i, tv ->
            val active = (i == activeIdx)
            tv.setTextColor(if (active) activeColor else inactiveColor)
            tv.setTypeface(null, if (active) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
            tv.textSize = if (active) 20f else 17f
        }
        binding.topBar.post {
            val tab = tabs[activeIdx]
            val indicator = binding.tabIndicator
            val center = tab.left + tab.width / 2
            val w = indicator.layoutParams.width.takeIf { it > 0 } ?: indicator.width
            val params = indicator.layoutParams as LinearLayout.LayoutParams
            params.marginStart = (center - w / 2).coerceAtLeast(0)
            indicator.layoutParams = params
        }
    }

    private fun switchChannel(channel: QidianRepository.Channel) {
        // 万象书屋: 即使上一次加载还在飞,也允许立刻切换;旧请求会被 loadJob.cancel 丢弃
        if (currentChannel == channel) return
        currentChannel = channel
        upTabIndicator()
        // 切换 Tab 时把滚动位置重置回顶部, 避免上个 Tab 下拉到中段后切回还停留在「新书首发」
        binding.bookStoreScroll.post { binding.bookStoreScroll.scrollTo(0, 0) }
        reload(forceRefresh = false)
    }

    private fun reload(forceRefresh: Boolean) {
        val ch = currentChannel
        // 切换 / 重试时先取消旧任务,避免它把过期数据写回 UI
        loadJob?.cancel()

        if (!forceRefresh) {
            val hit = channelRankCache[ch]
            if (hit != null && System.currentTimeMillis() - hit.second < CACHE_TTL_MS) {
                binding.tvStatus.isVisible = false
                binding.refreshLayout.isRefreshing = false
                bindAllSlots(hit.first)
                return
            }
        }

        loading = true
        binding.refreshLayout.isRefreshing = true
        binding.tvStatus.isVisible = true
        binding.tvStatus.setText(R.string.bs_loading)
        clearAllSlots()
        loadJob = lifecycleScope.launch {
            try {
                val ranks = withContext(Dispatchers.IO) {
                    when (ch) {
                        QidianRepository.Channel.Publish -> QidianRepository.fetchFinishRanks()
                        else -> QidianRepository.fetchAllRanks()
                    }
                }
                if (!isAdded) return@launch
                if (currentChannel != ch) return@launch
                if (ranks.values.all { it.isEmpty() }) {
                    binding.tvStatus.setText(R.string.bs_load_failed)
                } else {
                    channelRankCache[ch] = Pair(ranks, System.currentTimeMillis())
                    bindAllSlots(ranks)
                    binding.tvStatus.isVisible = false
                }
            } catch (t: Throwable) {
                LogUtils.d(TAG, "load failed: ${t.message}")
                if (isAdded) binding.tvStatus.setText(R.string.bs_load_failed)
            } finally {
                if (isAdded) {
                    loading = false
                    binding.refreshLayout.isRefreshing = false
                }
            }
        }
    }

    /**
     * 万象书屋 D-22: 把 9 个榜单的所有书去重合并成一个池, 给"换一换"用.
     * 同一本书可能同时上多个榜 (例如《玄鉴仙族》同时是月票/阅读/推荐第一), 按 bookId 去重.
     */
    private fun mergeAllRanks(
        ranks: Map<QidianRepository.RankType, List<QidianBook>>
    ): List<QidianBook> {
        val seen = LinkedHashSet<String>()
        val out = ArrayList<QidianBook>(64)
        for (list in ranks.values) {
            for (book in list) {
                val key = book.bookId.ifEmpty { book.name }
                if (seen.add(key)) out.add(book)
            }
        }
        return out
    }

    private fun clearAllSlots() {
        binding.heroSlot.removeAllViews()
        binding.gridMustRead.removeAllViews()
        binding.gridComplete.removeAllViews()
        binding.gridRanked.removeAllViews()
    }

    /**
     * 万象书屋 D-22: 用 9 榜单 map 直接驱动 UI, 不再做 channel offset 假装差异.
     *
     * 板块映射:
     *   hero          = fyRank #1            (月票第一)
     *   gridMustRead  = hotRank   top 8     (阅读榜)
     *   gridComplete  = newbRank  top 8     (新书榜, 起点无纯完结榜替代用)
     *   gridRanked    = recRank   top 8     (推荐榜, 带真排名 1-5+)
     *
     * Publish 频道复用 male 数据但板块顺序换一下 (用 dsRank 畅销榜替 hotRank, 让 tab 视觉有别).
     */
    private fun bindAllSlots(ranks: Map<QidianRepository.RankType, List<QidianBook>>) {
        clearAllSlots()
        var pool = mergeAllRanks(ranks)
        if (currentChannel == QidianRepository.Channel.Female) {
            // 女生 tab: 言情/恋爱主题书优先排到前面 (m.qidian 男频热榜本身言情少, 但能挑出几本)
            pool = pool.sortedByDescending { it.isLikelyFemale() }
        }
        allBooks = pool
        swapPageMustRead = 0
        swapPageComplete = 0
        swapPageRanked = 0
        LogUtils.d(
            TAG,
            "bind ch=$currentChannel ranks=${ranks.keys} total=${allBooks.size} " +
                "first=${allBooks.firstOrNull()?.name}"
        )

        val (heroType, mustReadType, completeType, rankedType) = when (currentChannel) {
            QidianRepository.Channel.Male -> arrayOf(
                QidianRepository.RankType.Yuepiao,
                QidianRepository.RankType.HotReading,
                QidianRepository.RankType.NewBook,
                QidianRepository.RankType.Recommend,
            )
            QidianRepository.Channel.Female -> arrayOf(
                // 女生用 m.qidian 同一份数据但重新映射 RankType, 让 hero/必读/完本/推荐 的书各不相同
                QidianRepository.RankType.Bestseller,
                QidianRepository.RankType.NewAuthor,
                QidianRepository.RankType.Sign,
                QidianRepository.RankType.Update,
            )
            QidianRepository.Channel.Publish -> arrayOf(
                // 出版走 /finish/, 4 个真完结榜
                QidianRepository.RankType.FinishClassic,
                QidianRepository.RankType.FinishClassic,
                QidianRepository.RankType.FinishBestSell,
                QidianRepository.RankType.FinishMovie,
            )
        }

        // D-22.2: section 标题随 channel 动态显示真实榜名 (跟数据来源一致)
        updateSectionTitles(mustReadType, completeType, rankedType)

        // hero: heroType 第一本; 退化到 allBooks 第一本
        val heroBook = ranks[heroType]?.firstOrNull() ?: allBooks.firstOrNull()
        heroBook?.let { bindHero(it) }

        bindGridFromRank(binding.gridMustRead, ranks, mustReadType, MUST_READ_GRID, slotOffset = 0)
        bindGridFromRank(binding.gridComplete, ranks, completeType, COMPLETE_GRID, slotOffset = MUST_READ_GRID)
        bindRankedFromRank(binding.gridRanked, ranks, rankedType, RANKED_COUNT)
    }

    /** 万象书屋 D-22.1: 启发式判断"像女频" — 用 cat/subCat 关键词命中. */
    private fun QidianBook.isLikelyFemale(): Boolean {
        val text = "$category $subCategory"
        val keywords = listOf("言情", "恋爱", "古言", "宫廷", "宅斗", "爱情", "玄幻言情", "现代言情")
        return keywords.any { it in text }
    }

    /**
     * 从 ranks[type] 取 [count] 本填充 [grid].
     * 起点 SSR 每榜只 5 本, 不足 count 时用 allBooks 顺序兜底 (跳过已展示 bookId).
     */
    private fun bindGridFromRank(
        grid: GridLayout,
        ranks: Map<QidianRepository.RankType, List<QidianBook>>,
        type: QidianRepository.RankType,
        count: Int,
        slotOffset: Int,
    ) {
        val primary = ranks[type].orEmpty()
        val seen = primary.mapTo(HashSet()) { it.bookId }
        val padding = if (primary.size >= count) emptyList() else {
            allBooks.asSequence()
                .filter { seen.add(it.bookId) }
                .take(count - primary.size)
                .toList()
        }
        val merged = (primary + padding).take(count)
        merged.forEachIndexed { idx, book ->
            addGridCell(grid, book, slotOffset + idx)
        }
    }

    /** 推荐榜 grid: 跟 grid 一样兜底, 但用 addRankedCell 显示真 rank 徽章 */
    private fun bindRankedFromRank(
        grid: GridLayout,
        ranks: Map<QidianRepository.RankType, List<QidianBook>>,
        type: QidianRepository.RankType,
        count: Int,
    ) {
        val primary = ranks[type].orEmpty()
        val seen = primary.mapTo(HashSet()) { it.bookId }
        val padding = if (primary.size >= count) emptyList() else {
            allBooks.asSequence()
                .filter { seen.add(it.bookId) }
                .take(count - primary.size)
                .toList()
        }
        val merged = (primary + padding).take(count)
        merged.forEachIndexed { idx, book ->
            // 优先用 book.rank (真排名); 兜底书没有 rank 时按位置 idx+1
            val displayRank = book.rank.takeIf { it > 0 } ?: (idx + 1)
            addRankedCell(grid, displayRank, book)
        }
    }

    private fun bindHero(book: QidianBook) {
        val v = inflater.inflate(R.layout.item_book_store_book_hero, binding.heroSlot, false)
        v.findViewById<TextView>(R.id.tvName).text = book.name
        loadCover(v.findViewById(R.id.ivCover), book.coverUrl)
        v.setOnClickListener { jumpSearch(book.name) }
        binding.heroSlot.addView(v)
    }

    private fun addGridCell(grid: GridLayout, book: QidianBook, index: Int) {
        val v = inflater.inflate(R.layout.item_book_store_book_grid, grid, false)
        v.layoutParams = gridCellLayoutParams()
        v.findViewById<TextView>(R.id.tvName).text = book.name
        // 万象书屋 D-22: 显示真作者. layout 里 tv_author 可能不存在 (旧版 layout 没加),
        // findViewById 返 null 直接跳过, 兼容老布局.
        v.findViewById<TextView?>(R.id.tvAuthor)?.let {
            if (book.author.isNotBlank()) {
                it.text = book.author
                it.isVisible = true
            } else {
                it.isVisible = false
            }
        }
        loadCover(v.findViewById(R.id.ivCover), book.coverUrl)
        applyBadgeAndTag(v, book, index)
        v.setOnClickListener { jumpSearch(book.name) }
        grid.addView(v)
    }

    /**
     * 万象书屋 D-22: 徽章和副标签都用真数据, 不再 index%N 假.
     *
     * 副标签 (tvTag): 优先 book.subCategory ("修真文明"/"东方玄幻") → 次选 book.category
     *   ("玄幻"/"都市") → 都没有时隐藏. 同一本书永远显示同标签 (用户体感一致).
     *
     * 徽章 (tvBadge): 按真排名分级 (来自 SSR 的 rankNum):
     *   rank == 1   → 红"榜首"
     *   rank == 2-3 → 金"上榜" (top 3 视觉强调)
     *   其他        → 无徽章
     */
    private fun applyBadgeAndTag(v: View, book: QidianBook, index: Int) {
        val badge = v.findViewById<TextView>(R.id.tvBadge)
        when (book.rank) {
            1 -> {
                badge.setBackgroundResource(R.drawable.bs_badge_hot)
                badge.setText(R.string.bs_badge_no1)
                badge.isVisible = true
            }
            2, 3 -> {
                badge.setBackgroundResource(R.drawable.bs_badge_member)
                badge.text = "TOP${book.rank}"
                badge.isVisible = true
            }
            else -> badge.isVisible = false
        }
        val tag = v.findViewById<TextView>(R.id.tvTag)
        val tagText = book.subCategory.ifBlank { book.category }
        if (tagText.isNotBlank()) {
            tag.text = tagText
            tag.isVisible = true
        } else {
            tag.isVisible = false
        }
    }

    private fun addRankedCell(grid: GridLayout, rank: Int, book: QidianBook) {
        val v = inflater.inflate(R.layout.item_book_store_book_ranked, grid, false)
        v.layoutParams = gridCellLayoutParams()
        val tvRank = v.findViewById<TextView>(R.id.tvRank)
        tvRank.text = rank.toString()
        tvRank.setBackgroundResource(
            when (rank) {
                1 -> R.drawable.bs_rank_badge_1
                2 -> R.drawable.bs_rank_badge_2
                3 -> R.drawable.bs_rank_badge_3
                else -> R.drawable.bs_rank_badge_n
            },
        )
        v.findViewById<TextView>(R.id.tvName).text = book.name
        loadCover(v.findViewById(R.id.ivCover), book.coverUrl)
        v.setOnClickListener { jumpSearch(book.name) }
        grid.addView(v)
    }

    /**
     * 明确 GridLayout 列权重，避免部分机型上宫格宽度分配异常。
     */
    private fun gridCellLayoutParams(): GridLayout.LayoutParams {
        return GridLayout.LayoutParams(
            GridLayout.spec(GridLayout.UNDEFINED, 1f),
            GridLayout.spec(GridLayout.UNDEFINED, 1f),
        ).apply {
            width = 0
            height = GridLayout.LayoutParams.WRAP_CONTENT
        }
    }

    private fun loadCover(iv: ImageView, url: String?) {
        ImageLoader.load(this, this.lifecycle, url)
            .placeholder(R.drawable.bs_cover_placeholder)
            .error(R.drawable.bs_cover_placeholder)
            .into(iv)
    }

    private fun jumpSearch(bookName: String) {
        SearchActivity.start(requireContext(), bookName)
    }

    private fun View.offsetInAncestor(ancestor: ViewGroup): Int {
        var d = 0
        var v: View? = this
        while (v != null && v !== ancestor) {
            d += v.top
            v = v.parent as? View
        }
        return d
    }
}
