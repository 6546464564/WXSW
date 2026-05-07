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
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 万象书屋·书城
 *
 * 数据源: 纵横中文网列表页 SSR HTML（封面 + 书名）
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

    /** 频道维度短时缓存，减少 Tab 来回切换时的重复请求 */
    private val channelBookCache = mutableMapOf<QidianRepository.Channel, Pair<List<QidianBook>, Long>>()

    /** 当前已加载的书目列表; 「换一换」时基于此数组做随机切片 */
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

        /**
         * 万象书屋: 模仿 QQ 阅读, 按格子位置发副标签
         * 数据源 zongheng 没有真实标签, 用关键词循环代替, 增强视觉层次
         */
        private val FALLBACK_TAGS = arrayOf(
            "新书首发", "热血爽文", "高分爆款", "悬疑烧脑",
            "玄幻仙侠", "都市言情", "口碑必读", "完本经典",
            "万人收藏", "强推", "口碑佳作", "新晋黑马",
            "好评如潮", "脑洞大开", "现象级", "重磅更新",
        )
    }

    override fun onFragmentCreated(view: View, savedInstanceState: Bundle?) {
        inflater = layoutInflater
        setupSwipeRefreshColors()
        setupSectionHeaders()
        setupTopBar()
        setupBanners()
        binding.refreshLayout.setOnRefreshListener { reload(forceRefresh = true) }
        reload(forceRefresh = false)
    }

    private fun setupSwipeRefreshColors() {
        val accent = ContextCompat.getColor(requireContext(), R.color.wanxiang_accent)
        val primary = ContextCompat.getColor(requireContext(), R.color.wanxiang_primary)
        binding.refreshLayout.setColorSchemeColors(accent, primary)
        binding.refreshLayout.setProgressBackgroundColorSchemeResource(R.color.wanxiang_card)
    }

    private fun setupSectionHeaders() {
        binding.sectionMustRead.tvSectionTitle.setText(R.string.bs_today_must_read)
        binding.sectionMustRead.tvSectionAction.setText(R.string.bs_serial_zone)
        binding.sectionMustRead.tvSectionAction.setOnClickListener {
            swapPageMustRead++
            rebindMustRead()
        }

        binding.sectionComplete.tvSectionTitle.setText(R.string.bs_complete_select)
        binding.sectionComplete.tvSectionAction.setText(R.string.bs_complete_zone)
        binding.sectionComplete.tvSectionAction.setOnClickListener {
            swapPageComplete++
            rebindComplete()
        }

        binding.sectionRecommend.tvSectionTitle.setText(R.string.bs_recommend_rank)
        binding.sectionRecommend.tvSectionAction.setText(R.string.bs_full_rank)
        // 万象书屋: 「查看完整榜单」改为换一批榜单内容(因为本地没有真正的排行 API,
        // 直接打开搜索页也无关键词可填; 翻页 + 滚到榜单位置, 给用户「展开更多」的反馈)
        binding.sectionRecommend.tvSectionAction.setOnClickListener {
            swapPageRanked++
            rebindRanked()
            scrollSectionIntoView(binding.sectionRecommend.root)
        }
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
        // 万象书屋: banner 之前只是页内 scroll, 用户期待是「打开完整榜单/书库」.
        // 现在直接跳到 SearchActivity 用对应关键字, 让 banner 名实相符.
        binding.cardRank.setOnClickListener {
            SearchActivity.start(requireContext(), getString(R.string.bs_banner_rank_keyword))
        }
        binding.cardLibrary.setOnClickListener {
            SearchActivity.start(requireContext(), getString(R.string.bs_banner_library_keyword))
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
            val hit = channelBookCache[ch]
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
                val books = withContext(Dispatchers.IO) {
                    val pages = ch.pages
                    val first = pages.getOrNull(0) ?: 1
                    val second = pages.getOrNull(1) ?: (first + 1)
                    val (p1, p2) = listOf(
                        async { runCatching { QidianRepository.fetchList(ch, first) }.getOrDefault(emptyList()) },
                        async { runCatching { QidianRepository.fetchList(ch, second) }.getOrDefault(emptyList()) },
                    ).awaitAll()
                    mergeAndDedupe(p1, p2)
                }
                if (!isAdded) return@launch
                if (currentChannel != ch) return@launch
                if (books.isEmpty()) {
                    binding.tvStatus.setText(R.string.bs_load_failed)
                } else {
                    channelBookCache[ch] = Pair(books, System.currentTimeMillis())
                    bindAllSlots(books)
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

    /** 合并两页结果并按书名 + 封面 URL 去重（避免 CDN 占位图导致误合并） */
    private fun mergeAndDedupe(a: List<QidianBook>, b: List<QidianBook>): List<QidianBook> {
        val seen = LinkedHashSet<String>()
        val out = ArrayList<QidianBook>(64)
        for (book in a + b) {
            val key = "${book.name.trim()}|${book.coverUrl.substringBefore('?')}"
            if (seen.add(key)) out.add(book)
        }
        return out
    }

    private fun clearAllSlots() {
        binding.heroSlot.removeAllViews()
        binding.gridMustRead.removeAllViews()
        binding.gridComplete.removeAllViews()
        binding.gridRanked.removeAllViews()
    }

    private fun bindAllSlots(books: List<QidianBook>) {
        // 万象书屋: 始终先清空所有 grid; 单一职责让缓存命中和重新拉取两条路径都安全.
        clearAllSlots()
        // zongheng 在无登录态下对任意 c{n}/p{m}/s{k} 参数都返回同一份热门列表 (实测).
        // 三个频道无法在数据层差异化, 这里在客户端按频道做循环旋转, 让用户切 Tab 看到不同入口.
        val channelOffset = when (currentChannel) {
            QidianRepository.Channel.Male -> 0
            QidianRepository.Channel.Female -> books.size / 3
            QidianRepository.Channel.Publish -> 2 * books.size / 3
        }
        val rotated = if (books.isEmpty() || channelOffset == 0) books else {
            (channelOffset until channelOffset + books.size).map { books[it % books.size] }
        }
        allBooks = rotated
        // 切换频道时重置「换一换」起点
        swapPageMustRead = 0
        swapPageComplete = 0
        swapPageRanked = 0
        LogUtils.d(
            TAG,
            "bind ch=$currentChannel total=${rotated.size} first=${rotated.firstOrNull()?.name}"
        )
        val iter = rotated.iterator()
        if (iter.hasNext()) bindHero(iter.next())
        var idx = 0
        repeat(MUST_READ_GRID) {
            if (iter.hasNext()) addGridCell(binding.gridMustRead, iter.next(), idx++)
        }
        repeat(COMPLETE_GRID) {
            if (iter.hasNext()) addGridCell(binding.gridComplete, iter.next(), idx++)
        }
        var rank = 1
        repeat(RANKED_COUNT) {
            if (iter.hasNext()) addRankedCell(binding.gridRanked, rank, iter.next())
            rank++
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
        loadCover(v.findViewById(R.id.ivCover), book.coverUrl)
        applyBadgeAndTag(v, book, index)
        v.setOnClickListener { jumpSearch(book.name) }
        grid.addView(v)
    }

    /**
     * 万象书屋: 仿 QQ 阅读, 给网格里的书加封面右上角徽章 + 书名下方标签
     * - index % 8 == 0/4 → 红色"必读"角
     * - index % 8 == 2/6 → 金色"会员"角
     * - 其他无角
     * 副标签按 index 循环取 FALLBACK_TAGS
     */
    private fun applyBadgeAndTag(v: View, book: QidianBook, index: Int) {
        val badge = v.findViewById<TextView>(R.id.tvBadge)
        when (index % 8) {
            0, 4 -> {
                badge.setBackgroundResource(R.drawable.bs_badge_hot)
                badge.setText(R.string.bs_badge_must_read)
                badge.isVisible = true
            }
            2, 6 -> {
                badge.setBackgroundResource(R.drawable.bs_badge_member)
                badge.setText(R.string.bs_badge_member)
                badge.isVisible = true
            }
            else -> badge.isVisible = false
        }
        val tag = v.findViewById<TextView>(R.id.tvTag)
        tag.text = FALLBACK_TAGS[index % FALLBACK_TAGS.size]
        tag.isVisible = true
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
