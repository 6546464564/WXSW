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
import io.legado.app.data.appDb
import io.legado.app.databinding.FragmentBookStoreBinding
import io.legado.app.help.WanxiangAnalytics
import io.legado.app.help.book.isNotShelf
import io.legado.app.help.glide.ImageLoader
import io.legado.app.ui.book.search.SearchActivity
import io.legado.app.ui.main.MainFragmentInterface
import io.legado.app.utils.LogUtils
import io.legado.app.utils.applyStatusBarPadding
import io.legado.app.utils.dpToPx
import io.legado.app.utils.viewbindingdelegate.viewBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
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
 * 点击书目 -> BookstoreDetailLauncher 秒进详情 stub, 后台找源
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

    /** 扩展榜单加载 Job (lazy 拉到 ~50 本, 给「换一批」用) */
    private var extendJob: Job? = null

    /** 9 (or 4) 榜单 map — 跟 iOS BookStoreViewModel.ranks 对齐 */
    private var ranks: Map<QidianRepository.RankType, List<QidianBook>> = emptyMap()

    /** 各 section 对应榜单的扩展池 (lazy fetchRankPages target=50) */
    private val extendedRanks = mutableMapOf<QidianRepository.RankType, List<QidianBook>>()

    /**
     * 万象书屋 D-22: 频道维度短时缓存 — 进程级单例 (跟 iOS BookStoreViewModel 对齐).
     */
    private val channelRankCache get() = BookStorePrewarm.channelRankCache

    /** 当前已加载的书目列表 (9 榜单合并去重); 「换一换」时基于此数组做循环切片 */
    private var allBooks: List<QidianBook> = emptyList()

    /** 「换一换」翻页偏移; 每次点击 +1, 越界回 0 重新洗牌 */
    private var swapPageMustRead = 0
    private var swapPageComplete = 0
    private var swapPageRanked = 0

    /** 跟 iOS shelfDedupeKeys 对齐 — name+author 去重 */
    private var shelfDedupeKeys: Set<String> = emptySet()

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
        binding.loadFailedSection.btnRetryLoad.setOnClickListener { reload(forceRefresh = true) }
        binding.refreshLayout.setOnRefreshListener { reload(forceRefresh = true) }
        reload(forceRefresh = false)
        refreshShelfKeys()
        // 万象书屋 D-17 (THEME-EInk): EInk 模式下书城页布局含大量米黄色 drawable (bg_cosmic_*),
        // 这些 drawable 不响应 night 资源切换 (因为 EInk 走 NIGHT_NO).
        // 在代码层面动态覆盖为纯白, 让 EInk 模式下书城跟其他页保持一致 (黑白阅读)
        applyEInkOverridesIfNeeded()
    }

    override fun onResume() {
        super.onResume()
        refreshShelfKeys()
    }

    private fun refreshShelfKeys() {
        lifecycleScope.launch {
            val keys = withContext(Dispatchers.IO) {
                appDb.bookDao.flowAll().first()
                    .filterNot { it.isNotShelf }
                    .map { shelfKey(it.name, it.author) }
                    .toSet()
            }
            if (!isAdded) return@launch
            shelfDedupeKeys = keys
            if (ranks.isNotEmpty()) {
                rebindMustRead()
                rebindComplete()
                rebindRanked()
            }
        }
    }

    private fun shelfKey(name: String, author: String) = "$name\u0000$author"

    private fun QidianBook.isOnShelf(): Boolean = shelfDedupeKeys.contains(shelfKey(name, author))

    private fun showLoadingUi(clearContent: Boolean) {
        binding.loadFailedSection.root.isVisible = false
        binding.skeletonSection.root.isVisible = clearContent
        binding.bookStoreContent.isVisible = !clearContent
        binding.tvStatus.isVisible = !clearContent
    }

    private fun showContentUi() {
        binding.loadFailedSection.root.isVisible = false
        binding.skeletonSection.root.isVisible = false
        binding.bookStoreContent.isVisible = true
        binding.tvStatus.isVisible = false
    }

    private fun showFailedUi() {
        binding.loadFailedSection.root.isVisible = true
        binding.skeletonSection.root.isVisible = false
        binding.bookStoreContent.isVisible = false
        binding.tvStatus.isVisible = false
        binding.refreshLayout.isRefreshing = false
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

    /** 「换一换」: 在同榜单扩展池内翻页 — 跟 iOS sectionBooks 对齐 */
    private fun rebindMustRead() {
        rebindSection(
            grid = binding.gridMustRead,
            type = mustReadType(),
            page = swapPageMustRead,
            slotOffset = 0,
            ranked = false,
            gridSlotOffset = 0,
        )
    }

    private fun rebindComplete() {
        rebindSection(
            grid = binding.gridComplete,
            type = completeType(),
            page = swapPageComplete,
            slotOffset = MUST_READ_GRID,
            ranked = false,
            gridSlotOffset = MUST_READ_GRID,
        )
    }

    private fun rebindRanked() {
        rebindSection(
            grid = binding.gridRanked,
            type = recommendType(),
            page = swapPageRanked,
            slotOffset = MUST_READ_GRID + COMPLETE_GRID,
            ranked = true,
            gridSlotOffset = 0,
        )
    }

    private fun rebindSection(
        grid: GridLayout,
        type: QidianRepository.RankType,
        page: Int,
        slotOffset: Int,
        ranked: Boolean,
        gridSlotOffset: Int,
    ) {
        val books = sectionBooks(type, page, slotOffset, if (ranked) RANKED_COUNT else MUST_READ_GRID)
        if (books.isEmpty()) return
        grid.removeAllViews()
        if (ranked) {
            books.forEachIndexed { idx, book ->
                addRankedGridCell(grid, idx + 1, book)
            }
        } else {
            books.forEachIndexed { idx, book ->
                addGridCell(grid, book, gridSlotOffset + idx)
            }
        }
    }

    /**
     * 跟 iOS `sectionBooks` 一致: page=0 取榜单前 N 本; page>0 在 rankPool 内循环切片.
     */
    private fun sectionBooks(
        type: QidianRepository.RankType,
        page: Int,
        slotOffset: Int,
        count: Int,
    ): List<QidianBook> {
        val pool = rankPool(type)
        if (pool.isEmpty()) return emptyList()
        if (page == 0) return pool.take(count)
        val start = ((page * count) + slotOffset + 1) % pool.size
        return (0 until count).map { pool[(start + it) % pool.size] }
    }

    private fun rankPool(type: QidianRepository.RankType): List<QidianBook> {
        extendedRanks[type]?.takeIf { it.isNotEmpty() }?.let { return it }
        return ranks[type].orEmpty()
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
        // 保留空壳: 实际 banner 在 bindAllSlots → updateBanners() 里按 channel 动态设置
    }

    private fun heroType(): QidianRepository.RankType = when (currentChannel) {
        QidianRepository.Channel.Male, QidianRepository.Channel.Female -> QidianRepository.RankType.Yuepiao
        QidianRepository.Channel.Publish -> QidianRepository.RankType.Yuepiao
    }

    private fun mustReadType(): QidianRepository.RankType = when (currentChannel) {
        QidianRepository.Channel.Male, QidianRepository.Channel.Female -> QidianRepository.RankType.HotReading
        QidianRepository.Channel.Publish -> QidianRepository.RankType.HotReading
    }

    private fun completeType(): QidianRepository.RankType = when (currentChannel) {
        QidianRepository.Channel.Male, QidianRepository.Channel.Female -> QidianRepository.RankType.NewBook
        QidianRepository.Channel.Publish -> QidianRepository.RankType.NewBook
    }

    private fun recommendType(): QidianRepository.RankType = when (currentChannel) {
        QidianRepository.Channel.Male, QidianRepository.Channel.Female -> QidianRepository.RankType.Recommend
        QidianRepository.Channel.Publish -> QidianRepository.RankType.Recommend
    }

    private fun updateBanners() {
        val hero = heroType()
        val complete = completeType()
        when (currentChannel) {
            QidianRepository.Channel.Publish -> {
                binding.tvBannerRankTitle.text = getString(R.string.bs_rank)
                binding.tvBannerRankSub.text = "${hero.title} TOP 50"
                binding.tvBannerLibraryTitle.text = getString(R.string.bs_library_publish)
                binding.tvBannerLibrarySub.text = getString(R.string.bs_library_publish_sub)
            }
            else -> {
                binding.tvBannerRankTitle.text = getString(R.string.bs_rank)
                binding.tvBannerRankSub.text = "${hero.title} TOP 50"
                binding.tvBannerLibraryTitle.text = getString(R.string.bs_library)
                binding.tvBannerLibrarySub.text = getString(R.string.bs_library_sub)
            }
        }
        binding.cardRank.setOnClickListener {
            WanxiangAnalytics.track("bs_banner_rank", type = hero.name)
            RankDetailActivity.startRank(requireContext(), hero, hero.title, currentChannel)
        }
        binding.cardLibrary.setOnClickListener {
            WanxiangAnalytics.track("bs_banner_library", type = "click")
            val libraryTitle = if (currentChannel == QidianRepository.Channel.Publish) {
                getString(R.string.bs_library_publish)
            } else {
                getString(R.string.bs_library)
            }
            RankDetailActivity.startFinish(requireContext(), libraryTitle, currentChannel)
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
        if (currentChannel == channel) return
        currentChannel = channel
        upTabIndicator()
        binding.bookStoreScroll.post { binding.bookStoreScroll.scrollTo(0, 0) }
        val hit = channelRankCache[channel]
        if (hit == null || System.currentTimeMillis() - hit.second >= CACHE_TTL_MS) {
            ranks = emptyMap()
            extendedRanks.clear()
            clearAllSlots()
        }
        reload(forceRefresh = false)
    }

    private fun reload(forceRefresh: Boolean) {
        val ch = currentChannel
        // 切换 / 重试时先取消旧任务,避免它把过期数据写回 UI
        loadJob?.cancel()

        if (!forceRefresh) {
            val hit = channelRankCache[ch]
            if (hit != null && System.currentTimeMillis() - hit.second < CACHE_TTL_MS) {
                binding.refreshLayout.isRefreshing = false
                bindAllSlots(hit.first)
                showContentUi()
                return
            }
        }

        loading = true
        binding.refreshLayout.isRefreshing = true
        val hadContent = ranks.values.any { it.isNotEmpty() }
        if (!hadContent || forceRefresh) {
            showLoadingUi(clearContent = !hadContent)
        }
        binding.tvStatus.setText(R.string.bs_loading)
        if (!hadContent) {
            clearAllSlots()
        }
        loadJob = lifecycleScope.launch {
            try {
                if (forceRefresh) {
                    withContext(Dispatchers.IO) {
                        io.legado.app.help.WanxiangBookstoreMirror.fetch(forceRefresh = true)
                    }
                    BookStorePrewarm.clearRankDetailCache()
                    BookStorePrewarm.clearChannelRankCache()
                }
                val ranks = withContext(Dispatchers.IO) {
                    when (ch) {
                        QidianRepository.Channel.Publish -> PublishBookstore.fetchRanks()
                        QidianRepository.Channel.Female -> QidianRepository.fetchAllRanks(QidianRepository.Channel.Female)
                        QidianRepository.Channel.Male -> QidianRepository.fetchAllRanks(QidianRepository.Channel.Male)
                    }
                }
                if (!isAdded) return@launch
                if (currentChannel != ch) return@launch
                if (ranks.values.all { it.isEmpty() }) {
                    showFailedUi()
                } else {
                    channelRankCache[ch] = Pair(ranks, System.currentTimeMillis())
                    bindAllSlots(ranks)
                    showContentUi()
                }
            } catch (t: Throwable) {
                LogUtils.d(TAG, "load failed: ${t.message}")
                if (isAdded) {
                    if (ranks.values.any { it.isNotEmpty() }) {
                        showContentUi()
                    } else {
                        showFailedUi()
                    }
                }
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
     * (已废弃: 出版现走 PublishBookstore / mirror.ranksPublish)
     */
    private fun bindAllSlots(ranks: Map<QidianRepository.RankType, List<QidianBook>>) {
        clearAllSlots()
        this.ranks = ranks
        extendedRanks.clear()
        extendJob?.cancel()
        var pool = mergeAllRanks(ranks)
        allBooks = pool
        swapPageMustRead = 0
        swapPageComplete = 0
        swapPageRanked = 0
        LogUtils.d(
            TAG,
            "bind ch=$currentChannel ranks=${ranks.keys} total=${allBooks.size} " +
                "first=${allBooks.firstOrNull()?.name}"
        )

        updateSectionTitles(mustReadType(), completeType(), recommendType())
        updateBanners()

        val heroBook = ranks[heroType()]?.firstOrNull() ?: allBooks.firstOrNull()
        heroBook?.let { bindHero(it) }

        rebindMustRead()
        rebindComplete()
        rebindRanked()

        ensureExtendedRanks(listOf(mustReadType(), completeType(), recommendType()))
    }

    private fun ensureExtendedRanks(types: List<QidianRepository.RankType>) {
        extendJob?.cancel()
        val ch = currentChannel
        extendJob = lifecycleScope.launch {
            for (type in types) {
                if ((extendedRanks[type]?.size ?: 0) >= 20) continue
                val full = withContext(Dispatchers.IO) {
                    when (ch) {
                        QidianRepository.Channel.Publish ->
                            PublishBookstore.fetchRankPages(type, target = 50)
                        else -> QidianRepository.fetchRankPages(
                            type,
                            target = 50,
                            gender = ch,
                        )
                    }
                }
                if (!isAdded || currentChannel != ch) return@launch
                if (full.isEmpty()) continue
                extendedRanks[type] = full
                when (type) {
                    mustReadType() -> rebindMustRead()
                    completeType() -> rebindComplete()
                    recommendType() -> rebindRanked()
                    else -> Unit
                }
            }
        }
    }

    private fun bindHero(book: QidianBook) {
        val v = inflater.inflate(R.layout.item_book_store_book_hero, binding.heroSlot, false)
        v.findViewById<TextView>(R.id.tvName).text = book.name
        v.findViewById<TextView>(R.id.tvRankName).text = book.rankName.ifBlank { heroType().title }
        v.findViewById<TextView?>(R.id.tvAuthor)?.let { tv ->
            if (book.author.isNotBlank()) {
                tv.text = book.author
                tv.isVisible = true
            } else {
                tv.isVisible = false
            }
        }
        val tagText = book.subCategory.ifBlank { book.category }
        v.findViewById<TextView?>(R.id.tvTag)?.let { tag ->
            if (tagText.isNotBlank()) {
                tag.text = tagText
                tag.isVisible = true
            } else {
                tag.isVisible = false
            }
        }
        v.findViewById<TextView?>(R.id.tvIntro)?.let { intro ->
            if (book.intro.isNotBlank()) {
                intro.text = book.intro
                intro.isVisible = true
            } else {
                intro.isVisible = false
            }
        }
        loadCover(v.findViewById(R.id.ivCover), book.coverUrl, book)
        v.findViewById<TextView?>(R.id.tvSource)?.let { src ->
            if (currentChannel == QidianRepository.Channel.Publish) {
                src.text = "出版"
                src.isVisible = true
            } else {
                src.isVisible = false
            }
        }
        applyShelfBadge(v, book)
        v.setOnClickListener { openBookstoreBook(book) }
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
        loadCover(v.findViewById(R.id.ivCover), book.coverUrl, book)
        applyBadgeAndTag(v, book, index)
        v.findViewById<TextView?>(R.id.tvSource)?.let { src ->
            if (currentChannel == QidianRepository.Channel.Publish) {
                src.text = "出版"
                src.isVisible = true
            }
        }
        applyShelfBadge(v, book)
        v.setOnClickListener { openBookstoreBook(book) }
        grid.addView(v)
    }

    private fun addRankedGridCell(grid: GridLayout, displayRank: Int, book: QidianBook) {
        val v = inflater.inflate(R.layout.item_book_store_book_grid, grid, false)
        v.layoutParams = gridCellLayoutParams()
        v.findViewById<TextView>(R.id.tvName).text = book.name
        v.findViewById<TextView?>(R.id.tvAuthor)?.let {
            if (book.author.isNotBlank()) {
                it.text = book.author
                it.isVisible = true
            } else {
                it.isVisible = false
            }
        }
        val tagText = book.subCategory.ifBlank { book.category }
        v.findViewById<TextView?>(R.id.tvTag)?.let { tag ->
            if (tagText.isNotBlank()) {
                tag.text = tagText
                tag.isVisible = true
            } else {
                tag.isVisible = false
            }
        }
        v.findViewById<TextView>(R.id.tvBadge).isVisible = false
        v.findViewById<TextView>(R.id.tvRankOverlay).let { rank ->
            rank.text = displayRank.toString()
            rank.setBackgroundResource(
                when (displayRank) {
                    1 -> R.drawable.bs_rank_badge_1
                    2 -> R.drawable.bs_rank_badge_2
                    3 -> R.drawable.bs_rank_badge_3
                    else -> R.drawable.bs_rank_badge_n
                },
            )
            rank.isVisible = true
        }
        loadCover(v.findViewById(R.id.ivCover), book.coverUrl, book)
        v.findViewById<TextView?>(R.id.tvSource)?.let { src ->
            if (currentChannel == QidianRepository.Channel.Publish) {
                src.text = "出版"
                src.isVisible = true
            }
        }
        applyShelfBadge(v, book)
        v.setOnClickListener { openBookstoreBook(book) }
        grid.addView(v)
    }

    private fun applyShelfBadge(v: View, book: QidianBook) {
        v.findViewById<TextView?>(R.id.tvShelfBadge)?.isVisible = book.isOnShelf()
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
        loadCover(v.findViewById(R.id.ivCover), book.coverUrl, book)
        v.setOnClickListener { openBookstoreBook(book) }
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

    private fun loadCover(iv: ImageView, url: String?, book: QidianBook? = null) {
        if (iv is io.legado.app.ui.widget.image.CoverImageView) {
            iv.load(
                path = url?.takeIf { it.isNotBlank() },
                name = book?.name,
                author = book?.author,
                fragment = this,
                lifecycle = this.lifecycle,
            )
            return
        }
        ImageLoader.load(this, this.lifecycle, url)
            .placeholder(R.drawable.bs_cover_placeholder)
            .error(R.drawable.bs_cover_placeholder)
            .into(iv)
    }

    private fun openBookstoreBook(book: QidianBook) {
        BookstoreDetailLauncher.open(requireContext(), book)
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
