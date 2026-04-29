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
import io.legado.app.utils.dpToPx
import io.legado.app.utils.viewbindingdelegate.viewBinding
import kotlinx.coroutines.Dispatchers
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

    /** 频道维度短时缓存，减少 Tab 来回切换时的重复请求 */
    private val channelBookCache = mutableMapOf<QidianRepository.Channel, Pair<List<QidianBook>, Long>>()

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

        binding.sectionComplete.tvSectionTitle.setText(R.string.bs_complete_select)
        binding.sectionComplete.tvSectionAction.setText(R.string.bs_complete_zone)

        binding.sectionRecommend.tvSectionTitle.setText(R.string.bs_recommend_rank)
        binding.sectionRecommend.tvSectionAction.setText(R.string.bs_full_rank)
    }

    private fun setupTopBar() {
        binding.tabMale.setOnClickListener { switchChannel(QidianRepository.Channel.Male) }
        binding.tabFemale.setOnClickListener { switchChannel(QidianRepository.Channel.Female) }
        binding.tabPublish.setOnClickListener { switchChannel(QidianRepository.Channel.Publish) }
        binding.ivSearch.setOnClickListener { SearchActivity.start(requireContext(), null) }
        upTabIndicator()
    }

    private fun setupBanners() {
        binding.cardRank.setOnClickListener {
            scrollSectionIntoView(binding.sectionRecommend.root)
        }
        binding.cardLibrary.setOnClickListener {
            scrollSectionIntoView(binding.sectionComplete.root)
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
            tv.textSize = if (active) 18f else 16f
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
        if (currentChannel == channel || loading) return
        currentChannel = channel
        upTabIndicator()
        reload(forceRefresh = false)
    }

    private fun reload(forceRefresh: Boolean) {
        if (loading) return
        val ch = currentChannel

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
        lifecycleScope.launch {
            try {
                val books = withContext(Dispatchers.IO) {
                    val (p1, p2) = listOf(
                        async { runCatching { QidianRepository.fetchList(ch, 1) }.getOrDefault(emptyList()) },
                        async { runCatching { QidianRepository.fetchList(ch, 2) }.getOrDefault(emptyList()) },
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
        val iter = books.iterator()
        if (iter.hasNext()) bindHero(iter.next())
        repeat(MUST_READ_GRID) { if (iter.hasNext()) addGridCell(binding.gridMustRead, iter.next()) }
        repeat(COMPLETE_GRID) { if (iter.hasNext()) addGridCell(binding.gridComplete, iter.next()) }
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

    private fun addGridCell(grid: GridLayout, book: QidianBook) {
        val v = inflater.inflate(R.layout.item_book_store_book_grid, grid, false)
        v.layoutParams = gridCellLayoutParams()
        v.findViewById<TextView>(R.id.tvName).text = book.name
        loadCover(v.findViewById(R.id.ivCover), book.coverUrl)
        v.setOnClickListener { jumpSearch(book.name) }
        grid.addView(v)
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
