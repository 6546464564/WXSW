package io.legado.app.ui.book.read

import android.annotation.SuppressLint
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.os.Looper
import android.view.Gravity
import android.view.InputDevice
import android.view.KeyEvent
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import androidx.activity.addCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.widget.PopupMenu
import androidx.core.net.toUri
import androidx.core.view.get
import androidx.core.view.size
import androidx.lifecycle.lifecycleScope
import com.jaredrummler.android.colorpicker.ColorPickerDialogListener
import io.legado.app.BuildConfig
import io.legado.app.R
import io.legado.app.constant.AppConst
import io.legado.app.constant.AppLog
import io.legado.app.constant.BookType
import io.legado.app.constant.EventBus
import io.legado.app.constant.PreferKey
import io.legado.app.constant.Status
import io.legado.app.data.appDb
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookProgress
import io.legado.app.data.entities.BookSource
import io.legado.app.exception.NoStackTraceException
import io.legado.app.help.IntentData
import io.legado.app.help.book.BookHelp
import io.legado.app.help.book.ContentProcessor
import io.legado.app.help.book.isAudio
import io.legado.app.help.book.isEpub
import io.legado.app.help.book.isLocal
import io.legado.app.help.book.isLocalTxt
import io.legado.app.help.book.isMobi
import io.legado.app.help.book.removeType
import io.legado.app.help.book.update
import io.legado.app.help.config.AppConfig
import io.legado.app.help.config.ReadBookConfig
import io.legado.app.help.config.ReadTipConfig
import io.legado.app.help.coroutine.Coroutine
import io.legado.app.help.source.getSourceType
import io.legado.app.lib.dialogs.SelectItem
import io.legado.app.lib.dialogs.alert
import io.legado.app.lib.dialogs.selector
import io.legado.app.lib.theme.accentColor
import io.legado.app.model.ReadBook
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setChapter
import io.legado.app.model.analyzeRule.AnalyzeRule.Companion.setCoroutineContext
import io.legado.app.model.localBook.EpubFile
import io.legado.app.model.localBook.MobiFile
import io.legado.app.receiver.NetworkChangedListener
import io.legado.app.receiver.TimeBatteryReceiver
import io.legado.app.ui.about.AppLogDialog
import io.legado.app.ui.book.bookmark.BookmarkDialog
import io.legado.app.ui.book.changesource.ChangeBookSourceDialog
import io.legado.app.ui.book.changesource.ChangeChapterSourceDialog
import io.legado.app.ui.book.info.BookInfoActivity
import io.legado.app.ui.book.read.config.AutoReadDialog
import io.legado.app.ui.book.read.config.BgTextConfigDialog.Companion.BG_COLOR
import io.legado.app.ui.book.read.config.BgTextConfigDialog.Companion.TEXT_COLOR
import io.legado.app.ui.book.read.config.MoreConfigDialog
import io.legado.app.ui.book.read.config.ReadStyleDialog
import io.legado.app.ui.book.read.config.TipConfigDialog.Companion.TIP_COLOR
import io.legado.app.ui.book.read.config.TipConfigDialog.Companion.TIP_DIVIDER_COLOR
import io.legado.app.ui.book.read.page.ContentTextView
import io.legado.app.ui.book.read.page.ReadView
import io.legado.app.ui.book.read.page.entities.PageDirection
import io.legado.app.ui.book.read.page.entities.TextPage
import io.legado.app.ui.book.read.page.provider.ChapterProvider
import io.legado.app.ui.book.read.page.provider.LayoutProgressListener
import io.legado.app.ui.book.searchContent.SearchContentActivity
import io.legado.app.ui.book.searchContent.SearchResult
import io.legado.app.ui.book.toc.TocActivityResult
import io.legado.app.ui.book.toc.rule.TxtTocRuleDialog
import io.legado.app.ui.browser.WebViewActivity
import io.legado.app.ui.dict.DictDialog
import io.legado.app.ui.file.HandleFileContract
import io.legado.app.ui.login.SourceLoginActivity
import io.legado.app.ui.replace.ReplaceRuleActivity
import io.legado.app.ui.replace.edit.ReplaceEditActivity
import io.legado.app.ui.widget.PopupAction
import io.legado.app.ui.widget.dialog.PhotoDialog
import io.legado.app.utils.ACache
import io.legado.app.utils.Debounce
import io.legado.app.utils.LogUtils
import io.legado.app.utils.ensureMainActivityIfTaskRoot
import io.legado.app.utils.NetworkUtils
import io.legado.app.utils.StartActivityContract
import io.legado.app.utils.applyOpenTint
import io.legado.app.utils.buildMainHandler
import io.legado.app.utils.dismissDialogFragment
import io.legado.app.utils.getPrefBoolean
import io.legado.app.utils.getPrefString
import io.legado.app.utils.hexString
import io.legado.app.utils.iconItemOnLongClick
import io.legado.app.utils.invisible
import io.legado.app.utils.isAbsUrl
import io.legado.app.utils.isTrue
import io.legado.app.utils.launch
import io.legado.app.utils.navigationBarGravity
import io.legado.app.utils.observeEvent
import io.legado.app.utils.observeEventSticky
import io.legado.app.utils.postEvent
import io.legado.app.utils.showDialogFragment
import io.legado.app.utils.showHelp
import io.legado.app.utils.startActivity
import io.legado.app.utils.startActivityForBook
import io.legado.app.utils.sysScreenOffTime
import io.legado.app.utils.throttle
import io.legado.app.utils.toastOnUi
import io.legado.app.utils.visible
import kotlinx.coroutines.Dispatchers.IO
import kotlinx.coroutines.Dispatchers.Main
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 阅读界面
 */
class ReadBookActivity : BaseReadBookActivity(),
    View.OnTouchListener,
    ReadView.CallBack,
    TextActionMenu.CallBack,
    ContentTextView.CallBack,
    PopupMenu.OnMenuItemClickListener,
    ReadMenu.CallBack,
    SearchMenu.CallBack,
    ChangeBookSourceDialog.CallBack,
    ChangeChapterSourceDialog.CallBack,
    ReadBook.CallBack,
    AutoReadDialog.CallBack,
    TxtTocRuleDialog.CallBack,
    ColorPickerDialogListener,
    LayoutProgressListener {

    private val tocActivity =
        registerForActivityResult(TocActivityResult()) {
            it?.let {
                viewModel.openChapter(it.first, it.second)
            }
        }
    private val replaceActivity =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            if (it.resultCode == RESULT_OK) {
                viewModel.replaceRuleChanged()
            }
        }
    private val searchContentActivity =
        registerForActivityResult(StartActivityContract(SearchContentActivity::class.java)) {
            val data = it.data ?: return@registerForActivityResult
            val key = data.getLongExtra("key", System.currentTimeMillis())
            val index = data.getIntExtra("index", 0)
            val searchResult = IntentData.get<SearchResult>("searchResult$key")
            val searchResultList = IntentData.get<List<SearchResult>>("searchResultList$key")
            if (searchResult != null && searchResultList != null) {
                viewModel.searchContentQuery = searchResult.query
                binding.searchMenu.upSearchResultList(searchResultList)
                isShowingSearchResult = true
                viewModel.searchResultIndex = index
                binding.searchMenu.updateSearchResultIndex(index)
                binding.searchMenu.selectedSearchResult?.let { currentResult ->
                    ReadBook.saveCurrentBookProgress() //退出全文搜索恢复此时进度
                    skipToSearch(currentResult)
                    showActionMenu()
                }
            }
        }
    private val bookInfoActivity =
        registerForActivityResult(StartActivityContract(BookInfoActivity::class.java)) {
            if (it.resultCode == RESULT_OK) {
                setResult(RESULT_DELETED)
                super.finish()
            } else {
                ReadBook.loadOrUpContent()
            }
        }
    private val selectImageDir = registerForActivityResult(HandleFileContract()) {
        it.uri?.let { uri ->
            ACache.get().put(AppConst.imagePathKey, uri.toString())
            viewModel.saveImage(it.value, uri)
        }
    }
    private var menu: Menu? = null
    private var backupJob: Job? = null
    val textActionMenu: TextActionMenu by lazy {
        TextActionMenu(this, this)
    }
    private val popupAction: PopupAction by lazy {
        PopupAction(this)
    }
    override val isInitFinish: Boolean get() = viewModel.isInitFinish
    override val isScroll: Boolean get() = binding.readView.isScroll
    private val isAutoPage get() = binding.readView.isAutoPage
    override var isShowingSearchResult = false
    override var isSelectingSearchResult = false
        set(value) {
            field = value && isShowingSearchResult
        }
    private val timeBatteryReceiver = TimeBatteryReceiver()
    private var screenTimeOut: Long = 0
    private var loadStates: Boolean = false
    override val pageFactory get() = binding.readView.pageFactory
    override val pageDelegate get() = binding.readView.pageDelegate
    override val headerHeight: Int get() = binding.readView.curPage.headerHeight
    private val nextPageDebounce by lazy { Debounce { keyPage(PageDirection.NEXT) } }
    private val prevPageDebounce by lazy { Debounce { keyPage(PageDirection.PREV) } }
    private var bookChanged = false
    private var pageChanged = false
    private val handler by lazy { buildMainHandler() }
    private val screenOffRunnable by lazy { Runnable { keepScreenOn(false) } }
    private val executor = ReadBook.executor
    private val upSeekBarThrottle = throttle(200) {
        runOnUiThread {
            upSeekBarProgress()
            binding.readMenu.upSeekBar()
        }
    }

    //恢复跳转前进度对话框的交互结果
    private var confirmRestoreProcess: Boolean? = null
    private val networkChangedListener by lazy {
        NetworkChangedListener(this)
    }
    private var justInitData: Boolean = false
    private var syncDialog: AlertDialog? = null

    /**
     * 万象书屋: 翻到底时显示的"作者努力更新中"占位页节流标记.
     * 同一章节进入过 finished 页就不再自动重弹; 章节进度变化后自动重置.
     * 之前是 AlertDialog 弹窗, 现在改为内嵌全屏 view (view_book_finished),
     * 用户视觉上感受为"最后一页就是这样的内容".
     */
    private var bookFinishedShownAtChapter: Int = -1

    // 万象书屋: lazy 拿 finish-page 控件 (ViewBinding 不会穿透 <include>, 走 findViewById)
    private val bookFinishedView by lazy { findViewById<android.view.View>(R.id.book_finished_view) }
    private val tvFinishedTitle by lazy { findViewById<android.widget.TextView>(R.id.tvFinishedTitle) }
    private val tvFinishedSubtitle by lazy { findViewById<android.widget.TextView>(R.id.tvFinishedSubtitle) }
    private val tvFinishedSwipeHint by lazy { findViewById<android.widget.TextView>(R.id.tvFinishedSwipeHint) }
    private val finishedDividerLine by lazy { findViewById<android.view.View>(R.id.finishedDividerLine) }
    private val finishedDividerDot by lazy { findViewById<android.view.View>(R.id.finishedDividerDot) }
    private val btnFinishedChangeSource by lazy { findViewById<android.view.View>(R.id.btnFinishedChangeSource) }
    private val btnFinishedGoBookshelf by lazy { findViewById<android.view.View>(R.id.btnFinishedGoBookshelf) }
    private val btnFinishedGoBookstore by lazy { findViewById<android.view.View>(R.id.btnFinishedGoBookstore) }
    private val btnFinishedExtendUnlock by lazy { findViewById<android.widget.Button>(R.id.btnFinishedExtendUnlock) }

    // 万象书屋: 顶部纯净阅读倒计时条 (解锁窗口内显示)
    private val unlockBar by lazy { findViewById<android.view.View>(R.id.unlock_bar) }
    private val unlockBarRemaining by lazy { findViewById<android.widget.TextView>(R.id.unlock_bar_remaining) }
    private val unlockBarButton by lazy { findViewById<android.widget.Button>(R.id.unlock_bar_button) }
    /** unlock bar 更新协程 (每秒一次), Activity destroy 时取消 */
    private var unlockBarJob: kotlinx.coroutines.Job? = null

    // 万象书屋: 章节付费墙锁屏控件
    private val chapterUnlockView by lazy { findViewById<android.view.View>(R.id.chapter_unlock_view) }
    private val tvUnlockTitle by lazy { findViewById<android.widget.TextView>(R.id.tvUnlockTitle) }
    private val tvUnlockSubtitle by lazy { findViewById<android.widget.TextView>(R.id.tvUnlockSubtitle) }
    private val tvUnlockIcon by lazy { findViewById<android.widget.TextView>(R.id.tvUnlockIcon) }
    private val btnUnlockWatch by lazy { findViewById<android.view.View>(R.id.btnUnlockWatch) }
    private val btnUnlockGoBack by lazy { findViewById<android.view.View>(R.id.btnUnlockGoBack) }
    private val unlockLoading by lazy { findViewById<android.view.View>(R.id.unlockLoading) }
    private val tvUnlockLoadingMsg by lazy { findViewById<android.widget.TextView>(R.id.tvUnlockLoadingMsg) }

    @SuppressLint("ClickableViewAccessibility")
    override fun onActivityCreated(savedInstanceState: Bundle?) {
        super.onActivityCreated(savedInstanceState)
        binding.cursorLeft.setColorFilter(accentColor)
        binding.cursorRight.setColorFilter(accentColor)
        binding.cursorLeft.setOnTouchListener(this)
        binding.cursorRight.setOnTouchListener(this)
        window.setBackgroundDrawable(null)
        upScreenTimeOut()
        ReadBook.register(this)
        onBackPressedDispatcher.addCallback(this) {
            if (isShowingSearchResult) {
                exitSearchMenu()
                restoreLastBookProcess()
                return@addCallback
            }
            //拦截返回供恢复阅读进度
            if (ReadBook.lastBookProgress != null && confirmRestoreProcess != false) {
                restoreLastBookProcess()
                return@addCallback
            }
            if (isAutoPage) {
                autoPageStop()
                return@addCallback
            }
            if (getPrefBoolean("disableReturnKey") && !menuLayoutIsVisible) {
                return@addCallback
            }
            finish()
        }
    }

    override fun onPostCreate(savedInstanceState: Bundle?) {
        super.onPostCreate(savedInstanceState)
        viewModel.initReadBookConfig(intent)
        Looper.myQueue().addIdleHandler {
            viewModel.initData(intent)
            false
        }
        justInitData = true
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        viewModel.initData(intent)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        upSystemUiVisibility()
        if (hasFocus) {
            binding.readMenu.upBrightnessState()
        } else if (!menuLayoutIsVisible) {
            ReadBook.cancelPreDownloadTask()
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        upSystemUiVisibility()
        binding.readView.upStatusBar()
    }

    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        if (!isTopResumedActivity) {
            ReadBook.cancelPreDownloadTask()
        }
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    override fun onResume() {
        super.onResume()
        ReadBook.readStartTime = System.currentTimeMillis()
        if (bookChanged) {
            bookChanged = false
            ReadBook.callBack = this
            viewModel.initData(intent)
            justInitData = true
        } else {
            //web端阅读时，app处于阅读界面，本地记录会覆盖web保存的进度，在此处恢复
            ReadBook.webBookProgress?.let {
                ReadBook.setProgress(it)
                ReadBook.webBookProgress = null
            }
        }
        upSystemUiVisibility()
        registerReceiver(timeBatteryReceiver, timeBatteryReceiver.filter)
        binding.readView.upTime()
        screenOffTimerStart()
        // 网络监听，当从无网切换到网络环境时同步进度（注意注册的同时就会收到监听，因此界面激活时无需重复执行同步操作）
        networkChangedListener.register()
        // 万象书屋: 已移除 WebDav 进度同步, 不再监听网络变化做同步
        // 万象书屋: 记录"开始阅读时刻", 给激励位的 30 分钟计时打个起点 (兼容旧时间制)
        io.legado.app.ad.AdRateLimiter.markEnterReader()
        // 万象书屋: 旧时间制询问对话框 RewardedAdHelper.tryPrompt 已废弃,
        // 改为章节级付费墙 (checkChapterPaywall, 由 upContent 触发), 不再走询问形式.
        // 万象书屋: 启动顶部"纯净阅读"倒计时条更新, 每秒刷一次
        startUnlockBarUpdater()
    }

    override fun onPause() {
        super.onPause()
        autoPageStop()
        backupJob?.cancel()
        ReadBook.saveRead()
        ReadBook.cancelPreDownloadTask()
        unregisterReceiver(timeBatteryReceiver)
        upSystemUiVisibility()
        // 万象书屋: 已移除 WebDav 进度同步与自动备份
        justInitData = false
        networkChangedListener.unRegister()
        // 停 unlock bar 协程
        unlockBarJob?.cancel()
        unlockBarJob = null
    }

    /**
     * 万象书屋: 启动顶部"纯净阅读 X 分钟 [续广告]"倒计时条.
     * 每秒更新一次, 解锁过期自动隐藏, 冷却中按钮置灰显示倒计时.
     */
    private fun startUnlockBarUpdater() {
        unlockBarJob?.cancel()
        val cfg = io.legado.app.ad.AdRepository.current().config
        val rwd = cfg.placements.rewardedReadingUnlock
        // 后端关闭顶部条 / 全局关广告 / 用户拒绝隐私 → 不显示
        if (!rwd.showCountdownBar || cfg.effectivelyDisabled() || !io.legado.app.ad.AdManager.isConsented()) {
            unlockBar.visibility = android.view.View.GONE
            return
        }
        unlockBarJob = lifecycleScope.launch {
            while (isActive) {
                refreshUnlockBarOnce(rwd)
                // 万象书屋 D-13 修复: bar 只在解锁窗口内显示 (refreshUnlockBarOnce 内置 GONE).
                // 闲置场景 5s 一次, 等真有解锁后 1s 刷新倒计时.
                val rl = io.legado.app.ad.AdRateLimiter
                val needFast = rl.remainingUnlockMs() > 0 ||
                    rl.secondsUntilNextRewardedAllowed(rwd.cooldownSec) > 0
                kotlinx.coroutines.delay(if (needFast) 1000 else 5000)
            }
        }
    }

    private fun refreshUnlockBarOnce(rwd: io.legado.app.ad.AdConfig.RewardedPlacement) {
        val rl = io.legado.app.ad.AdRateLimiter
        val remainMs = rl.remainingUnlockMs()
        if (remainMs <= 0) {
            unlockBar.visibility = android.view.View.GONE
            return
        }
        unlockBar.visibility = android.view.View.VISIBLE
        unlockBarRemaining.text = formatHms(remainMs)

        val cooldownLeft = rl.secondsUntilNextRewardedAllowed(rwd.cooldownSec)
        if (cooldownLeft > 0) {
            unlockBarButton.text = getString(R.string.unlock_bar_button_cooldown, formatMs(cooldownLeft))
            unlockBarButton.alpha = 0.5f
            unlockBarButton.isEnabled = false
            unlockBarButton.setOnClickListener(null)
        } else {
            unlockBarButton.text = getString(R.string.unlock_bar_button_extend, rwd.unlockMinutes)
            unlockBarButton.alpha = 1.0f
            unlockBarButton.isEnabled = true
            unlockBarButton.setOnClickListener { triggerExtendUnlockAd(rwd) }
        }
    }

    /** 主动看广告续期 (从顶部条 / 我的卡片 / finished 页按钮触发) */
    private fun triggerExtendUnlockAd(rwd: io.legado.app.ad.AdConfig.RewardedPlacement) {
        if (!io.legado.app.ad.AdRateLimiter.canShowRewardedAdNow(rwd.cooldownSec)) {
            // 冷却中, 防止 UI 抖动. 正常 button 应该已 disable.
            return
        }
        io.legado.app.ad.AdManager.loadAndShowRewarded(this,
            onSkipped = {
                // 用户跳过 / 网络挂; 不动状态
            },
            onRewarded = {
                io.legado.app.ad.AdRateLimiter.markRewardedSuccess(rwd.unlockMinutes, rwd.maxAccumulatedMinutes)
                val totalMs = io.legado.app.ad.AdRateLimiter.remainingUnlockMs()
                toastOnUi(getString(R.string.unlock_extended_toast, rwd.unlockMinutes, formatHms(totalMs)))
                // 立即刷新 UI
                refreshUnlockBarOnce(rwd)
            }
        )
    }

    /** 把毫秒格式化成 "1 小时 25 分" 或 "25 分 12 秒" */
    private fun formatHms(ms: Long): String {
        val totalSec = (ms / 1000).coerceAtLeast(0)
        val h = totalSec / 3600
        val m = (totalSec % 3600) / 60
        val s = totalSec % 60
        return when {
            h > 0 -> "${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}"
            else  -> "${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}"
        }
    }

    private fun formatMs(seconds: Long): String {
        val m = seconds / 60
        val s = seconds % 60
        return "${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}"
    }

    override fun onCompatCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.book_read, menu)
        menu.iconItemOnLongClick(R.id.menu_change_source) {
            PopupMenu(this, it).apply {
                inflate(R.menu.book_read_change_source)
                this.menu.applyOpenTint(this@ReadBookActivity)
                setOnMenuItemClickListener(this@ReadBookActivity)
            }.show()
        }
        menu.iconItemOnLongClick(R.id.menu_refresh) {
            PopupMenu(this, it).apply {
                inflate(R.menu.book_read_refresh)
                this.menu.applyOpenTint(this@ReadBookActivity)
                setOnMenuItemClickListener(this@ReadBookActivity)
            }.show()
        }
        binding.readMenu.refreshMenuColorFilter()
        return super.onCompatCreateOptionsMenu(menu)
    }

    override fun onPrepareOptionsMenu(menu: Menu): Boolean {
        this.menu = menu
        upMenu()
        return super.onPrepareOptionsMenu(menu)
    }

    override fun onMenuOpened(featureId: Int, menu: Menu): Boolean {
        menu.findItem(R.id.menu_same_title_removed)?.isChecked =
            ReadBook.curTextChapter?.sameTitleRemoved == true
        return super.onMenuOpened(featureId, menu)
    }

    /**
     * 更新菜单
     */
    private fun upMenu() {
        val menu = menu ?: return
        val book = ReadBook.book ?: return
        val onLine = !book.isLocal
        for (i in 0 until menu.size) {
            val item = menu[i]
            when (item.groupId) {
                R.id.menu_group_on_line -> item.isVisible = onLine
                R.id.menu_group_local -> item.isVisible = !onLine
                R.id.menu_group_text -> item.isVisible = book.isLocalTxt
                R.id.menu_group_epub -> item.isVisible = book.isEpub
                else -> when (item.itemId) {
                    R.id.menu_enable_replace -> item.isChecked = book.getUseReplaceRule()
                    R.id.menu_re_segment -> item.isChecked = book.getReSegment()
//                    R.id.menu_enable_review -> {
//                        item.isVisible = BuildConfig.DEBUG
//                        item.isChecked = AppConfig.enableReview
//                    }

                    R.id.menu_reverse_content -> item.isVisible = onLine
                    R.id.menu_del_ruby_tag -> item.isChecked = book.getDelTag(Book.rubyTag)
                    R.id.menu_del_h_tag -> item.isChecked = book.getDelTag(Book.hTag)
                }
            }
        }
        // 万象书屋: 已移除 WebDav 阅读进度同步, 隐藏相关菜单项
        menu.findItem(R.id.menu_get_progress)?.isVisible = false
        menu.findItem(R.id.menu_cover_progress)?.isVisible = false
    }

    /**
     * 菜单
     */
    override fun onCompatOptionsItemSelected(item: MenuItem): Boolean {
        when (item.itemId) {
            R.id.menu_change_source,
            R.id.menu_book_change_source -> {
                binding.readMenu.runMenuOut()
                ReadBook.book?.let {
                    showDialogFragment(ChangeBookSourceDialog(it.name, it.author))
                }
            }

            R.id.menu_chapter_change_source -> lifecycleScope.launch {
                val book = ReadBook.book ?: return@launch
                val chapter =
                    appDb.bookChapterDao.getChapter(book.bookUrl, ReadBook.durChapterIndex)
                        ?: return@launch
                binding.readMenu.runMenuOut()
                showDialogFragment(
                    ChangeChapterSourceDialog(book.name, book.author, chapter.index, chapter.title)
                )
            }

            R.id.menu_refresh,
            R.id.menu_refresh_dur -> {
                if (ReadBook.bookSource == null) {
                    upContent()
                } else {
                    ReadBook.book?.let {
                        ReadBook.curTextChapter = null
                        binding.readView.upContent()
                        viewModel.refreshContentDur(it)
                    }
                }
            }

            R.id.menu_refresh_after -> {
                if (ReadBook.bookSource == null) {
                    upContent()
                } else {
                    ReadBook.book?.let {
                        ReadBook.clearTextChapter()
                        binding.readView.upContent()
                        viewModel.refreshContentAfter(it)
                    }
                }
            }

            R.id.menu_refresh_all -> {
                if (ReadBook.bookSource == null) {
                    upContent()
                } else {
                    ReadBook.book?.let {
                        refreshContentAll(it)
                    }
                }
            }

            R.id.menu_download -> showDownloadDialog()
            R.id.menu_add_bookmark -> addBookmark()
            R.id.menu_simulated_reading -> showSimulatedReading()
            R.id.menu_edit_content -> showDialogFragment(ContentEditDialog())
            R.id.menu_update_toc -> ReadBook.book?.let {
                if (it.isEpub) {
                    BookHelp.clearCache(it)
                    EpubFile.clear()
                }
                if (it.isMobi) {
                    MobiFile.clear()
                }
                loadChapterList(it)
            }

            R.id.menu_enable_replace -> changeReplaceRuleState()
            R.id.menu_re_segment -> ReadBook.book?.let {
                it.setReSegment(!it.getReSegment())
                item.isChecked = it.getReSegment()
                ReadBook.loadContent(false)
            }

//            R.id.menu_enable_review -> {
//                AppConfig.enableReview = !AppConfig.enableReview
//                item.isChecked = AppConfig.enableReview
//                ReadBook.loadContent(false)
//            }

            R.id.menu_del_ruby_tag -> ReadBook.book?.let {
                item.isChecked = !item.isChecked
                if (item.isChecked) {
                    it.addDelTag(Book.rubyTag)
                } else {
                    it.removeDelTag(Book.rubyTag)
                }
                refreshContentAll(it)
            }

            R.id.menu_del_h_tag -> ReadBook.book?.let {
                item.isChecked = !item.isChecked
                if (item.isChecked) {
                    it.addDelTag(Book.hTag)
                } else {
                    it.removeDelTag(Book.hTag)
                }
                refreshContentAll(it)
            }

            R.id.menu_page_anim -> showPageAnimConfig {
                binding.readView.upPageAnim()
                ReadBook.loadContent(false)
            }

            R.id.menu_log -> showDialogFragment<AppLogDialog>()
            R.id.menu_toc_regex -> showDialogFragment(
                TxtTocRuleDialog(ReadBook.book?.tocUrl)
            )

            R.id.menu_reverse_content -> ReadBook.book?.let {
                viewModel.reverseContent(it)
            }

            R.id.menu_set_charset -> showCharsetConfig()
            R.id.menu_image_style -> {
                val imgStyles =
                    arrayListOf(
                        Book.imgStyleDefault, Book.imgStyleFull, Book.imgStyleText,
                        Book.imgStyleSingle
                    )
                selector(
                    R.string.image_style,
                    imgStyles
                ) { _, index ->
                    val imageStyle = imgStyles[index]
                    ReadBook.book?.setImageStyle(imageStyle)
                    if (imageStyle == Book.imgStyleSingle) {
                        ReadBook.book?.setPageAnim(0)  // 切换图片样式single后，自动切换为覆盖
                        binding.readView.upPageAnim()
                    }
                    ReadBook.loadContent(false)
                }
            }

            R.id.menu_get_progress -> ReadBook.book?.let {
                viewModel.syncBookProgress(it) { progress ->
                    sureSyncProgress(progress)
                }
            }

            R.id.menu_cover_progress -> ReadBook.book?.let {
                ReadBook.uploadProgress(true) { toastOnUi(R.string.upload_book_success) }
            }

            R.id.menu_same_title_removed -> {
                ReadBook.book?.let {
                    val contentProcessor = ContentProcessor.get(it)
                    val textChapter = ReadBook.curTextChapter
                    if (textChapter != null
                        && !textChapter.sameTitleRemoved
                        && !contentProcessor.removeSameTitleCache.contains(
                            textChapter.chapter.getFileName("nr")
                        )
                    ) {
                        toastOnUi("未找到可移除的重复标题")
                    }
                }
                viewModel.reverseRemoveSameTitle()
            }

            R.id.menu_effective_replaces -> showDialogFragment<EffectiveReplacesDialog>()

            R.id.menu_help -> showHelp()
        }
        return super.onCompatOptionsItemSelected(item)
    }

    private fun refreshContentAll(book: Book) {
        ReadBook.clearTextChapter()
        binding.readView.upContent()
        viewModel.refreshContentAll(book)
    }

    override fun onMenuItemClick(item: MenuItem): Boolean {
        return onCompatOptionsItemSelected(item)
    }

    /**
     * 按键拦截,显示菜单
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        val action = event.action
        val isDown = action == 0

        if (keyCode == KeyEvent.KEYCODE_MENU) {
            if (isDown && !binding.readMenu.canShowMenu) {
                binding.readMenu.runMenuIn()
                return true
            }
            if (!isDown && !binding.readMenu.canShowMenu) {
                binding.readMenu.canShowMenu = true
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    /**
     * 鼠标滚轮事件
     */
    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (0 != (event.source and InputDevice.SOURCE_CLASS_POINTER)) {
            if (event.action == MotionEvent.ACTION_SCROLL) {
                val axisValue = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
                LogUtils.d("onGenericMotionEvent", "axisValue = $axisValue")
                // 获得垂直坐标上的滚动方向
                if (axisValue < 0.0f) { // 滚轮向下滚
                    mouseWheelPage(PageDirection.NEXT)
                } else { // 滚轮向上滚
                    mouseWheelPage(PageDirection.PREV)
                }
                return true
            }
        }
        return super.onGenericMotionEvent(event)
    }

    /**
     * 按键事件
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (menuLayoutIsVisible) {
            return super.onKeyDown(keyCode, event)
        }
        val longPress = event.repeatCount > 0
        when {
            isPrevKey(keyCode) -> {
                handleKeyPage(PageDirection.PREV, longPress)
                return true
            }

            isNextKey(keyCode) -> {
                handleKeyPage(PageDirection.NEXT, longPress)
                return true
            }
        }
        when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> if (volumeKeyPage(PageDirection.PREV, longPress)) {
                return true
            }

            KeyEvent.KEYCODE_VOLUME_DOWN -> if (volumeKeyPage(PageDirection.NEXT, longPress)) {
                return true
            }

            KeyEvent.KEYCODE_PAGE_UP -> {
                handleKeyPage(PageDirection.PREV, longPress)
                return true
            }

            KeyEvent.KEYCODE_PAGE_DOWN -> {
                handleKeyPage(PageDirection.NEXT, longPress)
                return true
            }

            KeyEvent.KEYCODE_SPACE -> {
                handleKeyPage(PageDirection.NEXT, longPress)
                return true
            }
        }

        return super.onKeyDown(keyCode, event)
    }

    /**
     * 松开按键事件
     */
    override fun onKeyUp(keyCode: Int, event: KeyEvent): Boolean {
        when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN -> {
                if (volumeKeyPage(PageDirection.NONE, false)) {
                    return true
                }
            }

        }
        return super.onKeyUp(keyCode, event)
    }

    /**
     * view触摸,文字选择
     */
    @SuppressLint("ClickableViewAccessibility")
    override fun onTouch(v: View, event: MotionEvent): Boolean = binding.run {
        if (!binding.readView.isTextSelected) {
            return false
        }
        when (event.action) {
            MotionEvent.ACTION_DOWN -> textActionMenu.dismiss()
            MotionEvent.ACTION_MOVE -> {
                when (v.id) {
                    R.id.cursor_left -> if (!readView.curPage.getReverseStartCursor()) {
                        readView.curPage.selectStartMove(
                            event.rawX + cursorLeft.width,
                            event.rawY - cursorLeft.height
                        )
                    } else {
                        readView.curPage.selectEndMove(
                            event.rawX - cursorRight.width,
                            event.rawY - cursorRight.height
                        )
                    }

                    R.id.cursor_right -> if (readView.curPage.getReverseEndCursor()) {
                        readView.curPage.selectStartMove(
                            event.rawX + cursorLeft.width,
                            event.rawY - cursorLeft.height
                        )
                    } else {
                        readView.curPage.selectEndMove(
                            event.rawX - cursorRight.width,
                            event.rawY - cursorRight.height
                        )
                    }
                }
            }

            MotionEvent.ACTION_UP -> {
                readView.curPage.resetReverseCursor()
                showTextActionMenu()
            }
        }
        return true
    }

    /**
     * 更新文字选择开始位置
     */
    override fun upSelectedStart(x: Float, y: Float, top: Float) = binding.run {
        cursorLeft.x = x - cursorLeft.width
        cursorLeft.y = y
        cursorLeft.visible(true)
        textMenuPosition.x = x
        textMenuPosition.y = top
    }

    /**
     * 更新文字选择结束位置
     */
    override fun upSelectedEnd(x: Float, y: Float) = binding.run {
        cursorRight.x = x
        cursorRight.y = y
        cursorRight.visible(true)
    }

    /**
     * 取消文字选择
     */
    override fun onCancelSelect() = binding.run {
        cursorLeft.invisible()
        cursorRight.invisible()
        textActionMenu.dismiss()
    }

    override fun onLongScreenshotTouchEvent(event: MotionEvent): Boolean {
        return binding.readView.onTouchEvent(event)
    }

    /**
     * 显示文本操作菜单
     */
    override fun showTextActionMenu() {
        val navigationBarHeight =
            if (!ReadBookConfig.hideNavigationBar && navigationBarGravity == Gravity.BOTTOM)
                binding.navigationBar.height else 0
        textActionMenu.show(
            binding.textMenuPosition,
            binding.root.height + navigationBarHeight,
            binding.textMenuPosition.x.toInt(),
            binding.textMenuPosition.y.toInt(),
            binding.cursorLeft.y.toInt() + binding.cursorLeft.height,
            binding.cursorRight.x.toInt(),
            binding.cursorRight.y.toInt() + binding.cursorRight.height
        )
    }

    /**
     * 当前选择的文本
     */
    override val selectedText: String get() = binding.readView.getSelectText()

    /**
     * 文本选择菜单操作
     */
    override fun onMenuItemSelected(itemId: Int): Boolean {
        when (itemId) {
            R.id.menu_bookmark -> binding.readView.curPage.let {
                val bookmark = it.createBookmark()
                if (bookmark == null) {
                    toastOnUi(R.string.create_bookmark_error)
                } else {
                    showDialogFragment(BookmarkDialog(bookmark))
                }
                return true
            }

            R.id.menu_replace -> {
                val scopes = arrayListOf<String>()
                ReadBook.book?.name?.let {
                    scopes.add(it)
                }
                ReadBook.bookSource?.bookSourceUrl?.let {
                    scopes.add(it)
                }
                val text = selectedText.lineSequence().joinToString("\n") { it.trim() }
                replaceActivity.launch(
                    ReplaceEditActivity.startIntent(
                        this,
                        pattern = text,
                        scope = scopes.joinToString(";")
                    )
                )
                return true
            }

            R.id.menu_search_content -> {
                viewModel.searchContentQuery = selectedText
                openSearchActivity(selectedText)
                return true
            }

            R.id.menu_dict -> {
                showDialogFragment(DictDialog(selectedText))
                return true
            }
        }
        return false
    }

    /**
     * 文本选择菜单操作完成
     */
    override fun onMenuActionFinally() = binding.run {
        textActionMenu.dismiss()
        readView.cancelSelect()
    }

    /**
     * 鼠标滚轮翻页
     */
    private fun mouseWheelPage(direction: PageDirection) {
        if (menuLayoutIsVisible || !AppConfig.mouseWheelPage) {
            return
        }
        keyPageDebounce(direction, mouseWheel = true, longPress = false)
    }

    /**
     * 音量键翻页
     */
    private fun volumeKeyPage(direction: PageDirection, longPress: Boolean): Boolean {
        if (!AppConfig.volumeKeyPage) {
            return false
        }
        handleKeyPage(direction, longPress)
        return true
    }

    private fun handleKeyPage(direction: PageDirection, longPress: Boolean) {
        if (AppConfig.keyPageOnLongPress || direction == PageDirection.NONE) {
            keyPage(direction)
        } else {
            keyPageDebounce(direction, longPress = longPress)
        }
    }

    private fun keyPageDebounce(
        direction: PageDirection,
        mouseWheel: Boolean = false,
        longPress: Boolean
    ) {
        if (longPress) {
            return
        }
        nextPageDebounce.apply {
            wait = if (mouseWheel) 200L else 600L
            leading = !mouseWheel
            trailing = mouseWheel
        }
        prevPageDebounce.apply {
            wait = if (mouseWheel) 200L else 600L
            leading = !mouseWheel
            trailing = mouseWheel
        }
        when (direction) {
            PageDirection.NEXT -> nextPageDebounce.invoke()
            PageDirection.PREV -> prevPageDebounce.invoke()
            else -> {}
        }
    }

    private fun keyPage(direction: PageDirection) {
        binding.readView.cancelSelect()
        binding.readView.pageDelegate?.isCancel = false
        binding.readView.pageDelegate?.keyTurnPage(direction)
    }

    override fun upMenuView() {
        handler.post {
            upMenu()
            binding.readMenu.upBookView()
        }
    }

    override fun loadChapterList(book: Book) {
        ReadBook.upMsg(getString(R.string.toc_updateing))
        viewModel.loadChapterList(book)
    }

    /**
     * 内容加载完成
     */
    override fun contentLoadFinish() {
        loadStates = true
    }

    /**
     * 更新内容
     */
    override fun upContent(
        relativePosition: Int,
        resetPageOffset: Boolean,
        success: (() -> Unit)?
    ) {
        lifecycleScope.launch {
            binding.readView.upContent(relativePosition, resetPageOffset)
            if (relativePosition == 0) {
                upSeekBarProgress()
                // 万象书屋: 章节切换时把"作者努力更新中"占位页隐藏 + 重置节流标记,
                // 这样用户翻回前一章再翻到底, 仍能看到提示 (用户期望: 每次"撞到底"都给指引)
                if (bookFinishedView.visibility == android.view.View.VISIBLE
                    && ReadBook.durChapterIndex != bookFinishedShownAtChapter
                ) {
                    bookFinishedView.visibility = android.view.View.GONE
                }
                // 万象书屋: 章节级付费墙. 进入新章节立刻检查是否要拦截
                checkChapterPaywall()
            }
            loadStates = false
            success?.invoke()
        }
    }

    /**
     * 万象书屋: 章节级付费墙检查.
     * - 头 freeChapters 章免费
     * - 之后必须看广告解锁 unlockMinutes 分钟
     * - 没看完 → 锁屏页阻止继续阅读
     */
    private fun checkChapterPaywall() {
        val cfg = io.legado.app.ad.AdRepository.current().config
        val unlock = cfg.chapterUnlock
        if (!unlock.enabled) return
        // 用户没同意隐私 / 广告全局关闭 → 不能因为广告挂了就锁书, 直接放过
        if (cfg.effectivelyDisabled() || !io.legado.app.ad.AdManager.isConsented()) {
            hideChapterUnlockView()
            return
        }
        val curChapter = ReadBook.durChapterIndex
        val book = ReadBook.book ?: return
        // 记账: 用户进入了一个不同的章节 (内存去重防止同章页内多次累计)
        io.legado.app.ad.AdRateLimiter.markChapterOpened("${book.bookUrl}|$curChapter")

        if (!io.legado.app.ad.AdRateLimiter.shouldRequireUnlock(unlock.freeChapters)) {
            hideChapterUnlockView()
            return
        }
        // 万象书屋: blockOnSkip=false 时跳过锁屏 (灰度模式), 仅尝试加载广告但不强制阻断阅读.
        // 适合上线初期"软付费墙": 看广告体验流畅就转化, 不看的也不影响留存.
        if (!unlock.blockOnSkip) {
            // 仍触发广告加载, 看完照常记账; 不显示锁屏
            io.legado.app.ad.AdManager.loadAndShowRewarded(this,
                onSkipped = { /* 软模式: 跳过即放过 */ },
                onRewarded = { io.legado.app.ad.AdRateLimiter.markRewardedSuccess(unlock.unlockMinutes) }
            )
            return
        }
        // 命中拦截: 显示锁屏 + 立即触发激励视频 (强制付费墙, blockOnSkip=true)
        showChapterUnlockView(unlock.unlockMinutes)
        triggerRewardedForUnlock(unlock)
    }

    private fun showChapterUnlockView(unlockMinutes: Int) {
        applyReadThemeToView(chapterUnlockView, listOf(tvUnlockTitle, tvUnlockSubtitle, tvUnlockIcon, tvUnlockLoadingMsg))
        tvUnlockSubtitle.text = getString(R.string.chapter_unlock_subtitle, unlockMinutes)
        // 显示初始: loading 状态 (按钮先隐藏, 等加载结果)
        unlockLoading.visibility = android.view.View.VISIBLE
        tvUnlockLoadingMsg.visibility = android.view.View.VISIBLE
        btnUnlockWatch.visibility = android.view.View.GONE
        btnUnlockGoBack.visibility = android.view.View.GONE
        chapterUnlockView.visibility = android.view.View.VISIBLE
    }

    private fun showUnlockButtons() {
        unlockLoading.visibility = android.view.View.GONE
        tvUnlockLoadingMsg.visibility = android.view.View.GONE
        btnUnlockWatch.visibility = android.view.View.VISIBLE
        btnUnlockGoBack.visibility = android.view.View.VISIBLE
    }

    private fun hideChapterUnlockView() {
        chapterUnlockView.visibility = android.view.View.GONE
    }

    /** 立刻调激励视频. 用户看完 → 解锁; 没看完 → 显示重试按钮. */
    private fun triggerRewardedForUnlock(unlock: io.legado.app.ad.AdConfig.ChapterUnlock) {
        io.legado.app.ad.AdManager.loadAndShowRewarded(
            this,
            onSkipped = {
                // 万象书屋: 广告失败兜底 — 防止 YLH/CSJ 平台配置问题 (包名/冷启动) 让用户彻底卡死.
                // 连续失败 3 次自动给 5 分钟解锁, 让用户能继续阅读.
                val gracted = io.legado.app.ad.AdRateLimiter.recordAdFailureAndCheckGrace()
                if (gracted) {
                    hideChapterUnlockView()
                    toastOnUi(getString(R.string.chapter_unlock_grace_toast, io.legado.app.ad.AdRateLimiter.AD_FAILURE_GRACE_MINUTES))
                    return@loadAndShowRewarded
                }
                // 否则显示重试按钮, 维持锁屏
                showUnlockButtons()
                btnUnlockWatch.setOnClickListener { triggerRewardedForUnlock(unlock) }
                btnUnlockGoBack.setOnClickListener {
                    hideChapterUnlockView()
                    io.legado.app.model.ReadBook.moveToPrevChapter(upContent = true, upContentInPlace = true)
                }
            },
            onRewarded = {
                // 万象书屋: 章节付费墙路径也走累加 (跟主动续期共享 KEY_UNLOCK_UNTIL_MS)
                val rwd = io.legado.app.ad.AdRepository.current().config.placements.rewardedReadingUnlock
                io.legado.app.ad.AdRateLimiter.markRewardedSuccess(unlock.unlockMinutes, rwd.maxAccumulatedMinutes)
                hideChapterUnlockView()
                toastOnUi(getString(R.string.chapter_unlock_unlocked_toast, unlock.unlockMinutes))
                // 立即刷新顶部条
                refreshUnlockBarOnce(rwd)
            }
        )
    }

    /** 把当前阅读主题色应用到任意 view + 一组 textView. 给 finished page / unlock page 复用. */
    private fun applyReadThemeToView(root: android.view.View, textViews: List<android.widget.TextView>) {
        val cfg = io.legado.app.help.config.ReadBookConfig
        val textColor = cfg.textColor
        val bgDrawable = cfg.bg
        if (bgDrawable != null) {
            root.background = bgDrawable.constantState?.newDrawable()?.mutate()
                ?: android.graphics.drawable.ColorDrawable(cfg.bgMeanColor)
        } else {
            root.setBackgroundColor(cfg.bgMeanColor)
        }
        for (tv in textViews) tv.setTextColor(textColor)
    }

    override suspend fun upContentAwait(
        relativePosition: Int,
        resetPageOffset: Boolean,
        success: (() -> Unit)?
    ) = withContext(Main.immediate) {
        binding.readView.upContent(relativePosition, resetPageOffset)
        if (relativePosition == 0) {
            upSeekBarProgress()
            // 万象书屋: 跟 upContent 同步执行 paywall + finished view 节流逻辑,
            // 防止 ReadBook.moveToNextChapterAwait 等异步路径绕过付费墙.
            if (bookFinishedView.visibility == android.view.View.VISIBLE
                && ReadBook.durChapterIndex != bookFinishedShownAtChapter
            ) {
                bookFinishedView.visibility = android.view.View.GONE
            }
            checkChapterPaywall()
        }
        loadStates = false
    }

    override fun upPageAnim(upRecorder: Boolean) {
        lifecycleScope.launch {
            binding.readView.upPageAnim(upRecorder)
        }
    }

    override fun notifyBookChanged() {
        bookChanged = true
        if (!ReadBook.inBookshelf) {
            viewModel.removeFromBookshelf { super.finish() }
        }
    }

    override fun cancelSelect() {
        runOnUiThread {
            binding.readView.cancelSelect()
        }
    }

    /**
     * 页面改变
     */
    override fun pageChanged() {
        pageChanged = true
        binding.readView.onPageChange()
        handler.post {
            upSeekBarProgress()
            // 万象书屋: 旧时间制询问对话框 RewardedAdHelper.tryPrompt 已废弃,
            // 章节级付费墙的拦截在 upContent (章节切换) 中, 不需要每次翻页都判断
        }
        executor.execute {
            startBackupJob()
        }
    }

    /**
     * 更新进度条位置
     */
    private fun upSeekBarProgress() {
        val progress = when (AppConfig.progressBarBehavior) {
            "page" -> ReadBook.durPageIndex
            else /* chapter */ -> ReadBook.durChapterIndex
        }
        binding.readMenu.setSeekPage(progress)
    }

    /**
     * 显示菜单
     */
    override fun showMenuBar() {
        binding.readMenu.runMenuIn()
    }

    override val oldBook: Book?
        get() = ReadBook.book

    override fun changeTo(source: BookSource, book: Book, toc: List<BookChapter>) {
        if (!book.isAudio) {
            viewModel.changeTo(book, toc)
        } else {
            lifecycleScope.launch {
                withContext(IO) {
                    ReadBook.book?.migrateTo(book, toc)
                    book.removeType(BookType.updateError)
                    ReadBook.book?.delete()
                    appDb.bookDao.insert(book)
                }
                startActivityForBook(book)
                finish()
            }
        }
    }

    override fun replaceContent(content: String) {
        ReadBook.book?.let {
            viewModel.saveContent(it, content)
        }
    }

    override fun showActionMenu() {
        when {
            isAutoPage -> showDialogFragment<AutoReadDialog>()
            isShowingSearchResult -> binding.searchMenu.runMenuIn()
            else -> binding.readMenu.runMenuIn()
        }
    }

    /**
     * 自动翻页
     */
    override fun autoPage() {
        if (isAutoPage) {
            autoPageStop()
        } else {
            binding.readView.autoPager.start()
            binding.readMenu.setAutoPage(true)
            screenTimeOut = -1L
            screenOffTimerStart()
        }
    }

    override fun autoPageStop() {
        if (isAutoPage) {
            binding.readView.autoPager.stop()
            binding.readMenu.setAutoPage(false)
            dismissDialogFragment<AutoReadDialog>()
            upScreenTimeOut()
        }
    }

    override fun openBookInfoActivity() {
        ReadBook.book?.let {
            bookInfoActivity.launch {
                putExtra("name", it.name)
                putExtra("author", it.author)
            }
        }
    }

    /**
     * 替换
     */
    override fun openReplaceRule() {
        replaceActivity.launch(Intent(this, ReplaceRuleActivity::class.java))
    }

    /**
     * 打开目录
     */
    override fun openChapterList() {
        ReadBook.book?.let {
            tocActivity.launch(it.bookUrl)
        }
    }

    /**
     * 打开搜索界面
     */
    override fun openSearchActivity(searchWord: String?) {
        val book = ReadBook.book ?: return
        searchContentActivity.launch {
            putExtra("bookUrl", book.bookUrl)
            putExtra("searchWord", searchWord ?: viewModel.searchContentQuery)
            putExtra("searchResultIndex", viewModel.searchResultIndex)
            viewModel.searchResultList?.first()?.let {
                if (it.query == viewModel.searchContentQuery) {
                    IntentData.put("searchResultList", viewModel.searchResultList)
                }
            }
        }
    }

    /**
     * 显示阅读样式配置
     */
    override fun showReadStyle() {
        showDialogFragment<ReadStyleDialog>()
    }

    /**
     * 显示更多设置
     */
    override fun showMoreSetting() {
        showDialogFragment<MoreConfigDialog>()
    }

    override fun showSearchSetting() {
        showDialogFragment<MoreConfigDialog>()
    }

    /**
     * 更新状态栏,导航栏
     */
    override fun upSystemUiVisibility() {
        upSystemUiVisibility(isInMultiWindow, !menuLayoutIsVisible, bottomDialog > 0)
        upNavigationBarColor()
    }

    /**
     * 万象书屋: 用户翻到全书最后一页. 在阅读区上方显示「作者努力更新中」占位页 (非弹窗).
     * 节流: 同一章节进入过就不再重显; 章节进度变化或用户点了三个出口任一即重置.
     */
    /** 万象书屋: finished view 上的手势识别器 — 任意方向滑动都视作"翻回正文" */
    private val bookFinishedGestureDetector by lazy {
        android.view.GestureDetector(this, object : android.view.GestureDetector.SimpleOnGestureListener() {
            override fun onFling(
                e1: android.view.MotionEvent?, e2: android.view.MotionEvent,
                velocityX: Float, velocityY: Float
            ): Boolean {
                if (e1 == null) return false
                val dx = e2.x - e1.x
                val dy = e2.y - e1.y
                if (kotlin.math.abs(dx) > 80 || kotlin.math.abs(dy) > 80) {
                    // 万象书屋: 主导方向决定退出动画 — 跟着用户手指走, 像翻页那样
                    hideBookFinishedViewWithAnim(dx, dy)
                    return true
                }
                return false
            }
            override fun onSingleTapUp(e: android.view.MotionEvent): Boolean {
                hideBookFinishedViewWithAnim(0f, 0f)
                return true
            }
        })
    }

    override fun onNoNextPage() {
        // 已经在显示中, 跳过
        if (bookFinishedView.visibility == android.view.View.VISIBLE) return
        val curChapter = ReadBook.durChapterIndex
        if (curChapter == bookFinishedShownAtChapter) return
        bookFinishedShownAtChapter = curChapter

        // 万象书屋: 跟随当前阅读主题 (背景图 + 文字色), 让占位页看起来"是最后一页"
        applyReadThemeToBookFinishedView()

        // 三按钮 click handler. 点完任一按钮后隐藏 view, 让用户能继续操作.
        btnFinishedChangeSource.setOnClickListener {
            hideBookFinishedView()
            ReadBook.book?.let {
                showDialogFragment(ChangeBookSourceDialog(it.name, it.author))
            }
        }
        btnFinishedGoBookshelf.setOnClickListener {
            hideBookFinishedView()
            jumpToMainTab(io.legado.app.ui.main.MainActivity.TAB_BOOKSHELF)
        }
        btnFinishedGoBookstore.setOnClickListener {
            hideBookFinishedView()
            jumpToMainTab(io.legado.app.ui.main.MainActivity.TAB_BOOKSTORE)
        }

        // 万象书屋: 看广告续期主推按钮 (累加纯净阅读). 仅当激励视频启用时显示.
        val cfg = io.legado.app.ad.AdRepository.current().config
        val rwd = cfg.placements.rewardedReadingUnlock
        if (rwd.enabled && !cfg.effectivelyDisabled() && io.legado.app.ad.AdManager.isConsented()) {
            btnFinishedExtendUnlock.visibility = android.view.View.VISIBLE
            // 冷却中按钮置灰显示倒计时
            val cooldownLeft = io.legado.app.ad.AdRateLimiter.secondsUntilNextRewardedAllowed(rwd.cooldownSec)
            if (cooldownLeft > 0) {
                btnFinishedExtendUnlock.text = getString(R.string.unlock_bar_button_cooldown, formatMs(cooldownLeft))
                btnFinishedExtendUnlock.alpha = 0.5f
                btnFinishedExtendUnlock.isEnabled = false
            } else {
                btnFinishedExtendUnlock.text = getString(R.string.book_finished_extend_unlock, rwd.unlockMinutes)
                btnFinishedExtendUnlock.alpha = 1.0f
                btnFinishedExtendUnlock.isEnabled = true
                btnFinishedExtendUnlock.setOnClickListener {
                    triggerExtendUnlockAd(rwd)
                }
            }
        } else {
            btnFinishedExtendUnlock.visibility = android.view.View.GONE
        }

        // 万象书屋: finished view 空白区接管手势 — 任意滑动 / 单击都隐藏并回正文
        // 让用户像"普通书页"一样可以往回翻. 按钮区点击不走这里 (button 自己消费 event).
        bookFinishedView.setOnTouchListener { _, event ->
            bookFinishedGestureDetector.onTouchEvent(event)
        }

        bookFinishedView.visibility = android.view.View.VISIBLE
    }

    private fun hideBookFinishedView() {
        bookFinishedView.visibility = android.view.View.GONE
        // 万象书屋: 重置节流标记, 让用户从前一页再翻回最后一页时仍能再看到 finished 页
        bookFinishedShownAtChapter = -1
    }

    /**
     * 隐藏 finished view 时根据用户滑动主方向做翻页动画:
     *   dx > 0 (向右滑) → finished view 向右滑出, 模拟"翻回上一页"
     *   dx < 0 (向左滑) → 向左滑出
     *   竖直滑 / 单击 → 简单淡出
     */
    private fun hideBookFinishedViewWithAnim(dx: Float, dy: Float) {
        val v = bookFinishedView
        // 防止动画期间被多次触发
        if (v.visibility != android.view.View.VISIBLE) return
        v.setOnTouchListener(null)
        val w = v.width.toFloat()
        val h = v.height.toFloat()
        val anim = if (kotlin.math.abs(dx) > kotlin.math.abs(dy) && kotlin.math.abs(dx) > 80) {
            v.animate().translationX(if (dx > 0) w else -w).alpha(0f)
        } else if (kotlin.math.abs(dy) > 80) {
            v.animate().translationY(if (dy > 0) h else -h).alpha(0f)
        } else {
            v.animate().alpha(0f)
        }
        anim.setDuration(220).withEndAction {
            // 复位 + 隐藏 + 重置节流, 下次触发还能正常显示
            v.translationX = 0f
            v.translationY = 0f
            v.alpha = 1f
            hideBookFinishedView()
        }.start()
    }

    /** 把当前阅读主题 (背景 + 文字色) 应用到"作者努力更新中"页. */
    private fun applyReadThemeToBookFinishedView() {
        val cfg = io.legado.app.help.config.ReadBookConfig
        val textColor = cfg.textColor
        val bgDrawable = cfg.bg
        // 背景: 优先用阅读主题的 bg drawable (可能是图片或纯色); 没有时用 bgMeanColor 兜底
        if (bgDrawable != null) {
            bookFinishedView.background = bgDrawable.constantState?.newDrawable()?.mutate()
                ?: android.graphics.drawable.ColorDrawable(cfg.bgMeanColor)
        } else {
            bookFinishedView.setBackgroundColor(cfg.bgMeanColor)
        }
        // 文字色: 主标题用主色 + 70% alpha 的副标题色 (跟系统 textColorSecondary 行为一致)
        tvFinishedTitle.setTextColor(textColor)
        val subAlpha = (android.graphics.Color.alpha(textColor) * 0.7f).toInt().coerceIn(0, 255)
        val subColor = android.graphics.Color.argb(
            subAlpha,
            android.graphics.Color.red(textColor),
            android.graphics.Color.green(textColor),
            android.graphics.Color.blue(textColor)
        )
        tvFinishedSubtitle.setTextColor(subColor)
        tvFinishedSwipeHint.setTextColor(subColor)
        // 分隔线 / 装饰点
        finishedDividerLine.setBackgroundColor(android.graphics.Color.argb(
            (android.graphics.Color.alpha(textColor) * 0.3f).toInt().coerceIn(0, 255),
            android.graphics.Color.red(textColor),
            android.graphics.Color.green(textColor),
            android.graphics.Color.blue(textColor)
        ))
        finishedDividerDot.setBackgroundColor(textColor)
    }

    private fun jumpToMainTab(tab: String) {
        // 万象书屋: 告知用户"阅读进度已保存", 消除"会不会丢进度"的担忧
        toastOnUi(R.string.book_progress_saved_toast)
        startActivity(Intent(this, io.legado.app.ui.main.MainActivity::class.java).apply {
            putExtra(io.legado.app.ui.main.MainActivity.EXTRA_SELECT_TAB, tab)
            addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        })
        finish()
    }

    // 退出全文搜索
    override fun exitSearchMenu() {
        if (isShowingSearchResult) {
            isShowingSearchResult = false
            binding.searchMenu.invalidate()
            binding.searchMenu.invisible()
            ReadBook.clearSearchResult()
            binding.readView.cancelSelect(true)
        }
    }

    /* 恢复到 全文搜索/进度条跳转前的位置 */
    private fun restoreLastBookProcess() {
        if (confirmRestoreProcess == true) {
            ReadBook.restoreLastBookProgress()
        } else if (confirmRestoreProcess == null) {
            alert(R.string.draw) {
                setMessage(R.string.restore_last_book_process)
                yesButton {
                    confirmRestoreProcess = true
                    ReadBook.restoreLastBookProgress() //恢复启动全文搜索前的进度
                }
                noButton {
                    ReadBook.lastBookProgress = null
                    confirmRestoreProcess = false
                }
                onCancelled {
                    ReadBook.lastBookProgress = null
                    confirmRestoreProcess = false
                }
            }
        }
    }

    override fun showLogin() {
        ReadBook.bookSource?.let {
            startActivity<SourceLoginActivity> {
                putExtra("type", "bookSource")
                putExtra("key", it.bookSourceUrl)
            }
        }
    }

    override fun payAction() {
        val book = ReadBook.book ?: return
        if (book.isLocal) return
        val chapter = appDb.bookChapterDao.getChapter(book.bookUrl, ReadBook.durChapterIndex)
        if (chapter == null) {
            toastOnUi("no chapter")
            return
        }
        alert(R.string.chapter_pay) {
            setMessage(chapter.title)
            yesButton {
                Coroutine.async(lifecycleScope) {
                    val source =
                        ReadBook.bookSource ?: throw NoStackTraceException("no book source")
                    val payAction = source.getContentRule().payAction
                    if (payAction.isNullOrBlank()) {
                        throw NoStackTraceException("no pay action")
                    }
                    val analyzeRule = AnalyzeRule(book, source)
                    analyzeRule.setCoroutineContext(coroutineContext)
                    analyzeRule.setBaseUrl(chapter.url)
                    analyzeRule.setChapter(chapter)
                    analyzeRule.evalJS(payAction).toString()
                }.onSuccess(IO) {
                    if (it.isAbsUrl()) {
                        startActivity<WebViewActivity> {
                            val bookSource = ReadBook.bookSource
                            putExtra("title", getString(R.string.chapter_pay))
                            putExtra("url", it)
                            putExtra("sourceOrigin", bookSource?.bookSourceUrl)
                            putExtra("sourceName", bookSource?.bookSourceName)
                            putExtra("sourceType", bookSource?.getSourceType())
                        }
                    } else if (it.isTrue()) {
                        //购买成功后刷新目录
                        ReadBook.book?.let {
                            ReadBook.curTextChapter = null
                            BookHelp.delContent(book, chapter)
                            loadChapterList(book)
                        }
                    }
                }.onError {
                    AppLog.put("执行购买操作出错\n${it.localizedMessage}", it, true)
                }
            }
            noButton()
        }
    }

    override fun showHelp() {
        showHelp("readMenuHelp")
    }

    /**
     * 长按图片
     */
    @SuppressLint("RtlHardcoded")
    override fun onImageLongPress(x: Float, y: Float, src: String) {
        popupAction.setItems(
            listOf(
                SelectItem(getString(R.string.show), "show"),
                SelectItem(getString(R.string.refresh), "refresh"),
                SelectItem(getString(R.string.action_save), "save"),
                SelectItem(getString(R.string.menu), "menu"),
                SelectItem(getString(R.string.select_folder), "selectFolder")
            )
        )
        popupAction.onActionClick = {
            when (it) {
                "show" -> showDialogFragment(PhotoDialog(src))
                "refresh" -> viewModel.refreshImage(src)
                "save" -> {
                    val path = ACache.get().getAsString(AppConst.imagePathKey)
                    if (path.isNullOrEmpty()) {
                        selectImageDir.launch {
                            value = src
                        }
                    } else {
                        viewModel.saveImage(src, path.toUri())
                    }
                }

                "menu" -> showActionMenu()
                "selectFolder" -> selectImageDir.launch()
            }
            popupAction.dismiss()
        }
        val navigationBarHeight =
            if (!ReadBookConfig.hideNavigationBar && navigationBarGravity == Gravity.BOTTOM)
                binding.navigationBar.height else 0
        popupAction.showAtLocation(
            binding.readView, Gravity.BOTTOM or Gravity.LEFT, x.toInt(),
            binding.root.height + navigationBarHeight - y.toInt()
        )
    }

    /**
     * colorSelectDialog
     */
    override fun onColorSelected(dialogId: Int, color: Int) = ReadBookConfig.durConfig.run {
        when (dialogId) {
            TEXT_COLOR -> {
                setCurTextColor(color)
                postEvent(EventBus.UP_CONFIG, arrayListOf(2, 6, 9, 11))
                if (AppConfig.readBarStyleFollowPage) {
                    postEvent(EventBus.UPDATE_READ_ACTION_BAR, true)
                }
            }

            BG_COLOR -> {
                setCurBg(0, "#${color.hexString}")
                postEvent(EventBus.UP_CONFIG, arrayListOf(1))
                if (AppConfig.readBarStyleFollowPage) {
                    postEvent(EventBus.UPDATE_READ_ACTION_BAR, true)
                }
            }

            TIP_COLOR -> {
                ReadTipConfig.tipColor = color
                postEvent(EventBus.TIP_COLOR, "")
                postEvent(EventBus.UP_CONFIG, arrayListOf(2))
            }

            TIP_DIVIDER_COLOR -> {
                ReadTipConfig.tipDividerColor = color
                postEvent(EventBus.TIP_COLOR, "")
                postEvent(EventBus.UP_CONFIG, arrayListOf(2))
            }
        }
    }

    /**
     * colorSelectDialog
     */
    override fun onDialogDismissed(dialogId: Int) = Unit

    override fun onTocRegexDialogResult(tocRegex: String) {
        ReadBook.book?.let {
            it.tocUrl = tocRegex
            loadChapterList(it)
        }
    }

    private fun sureSyncProgress(progress: BookProgress) {
        alert(R.string.get_book_progress) {
            setMessage(R.string.current_progress_exceeds_cloud)
            okButton {
                ReadBook.setProgress(progress)
            }
            noButton()
        }
    }

    /* 进度条跳转到指定章节 */
    override fun skipToChapter(index: Int) {
        ReadBook.saveCurrentBookProgress() //退出章节跳转恢复此时进度
        viewModel.openChapter(index)
    }

    /* 全文搜索跳转 */
    override fun navigateToSearch(searchResult: SearchResult, index: Int) {
        viewModel.searchResultIndex = index
        skipToSearch(searchResult)
    }

    override fun onMenuShow() {
        binding.readView.autoPager.pause()
    }

    override fun onMenuHide() {
        binding.readView.autoPager.resume()
    }

    override fun onLayoutPageCompleted(index: Int, page: TextPage) {
        upSeekBarThrottle.invoke()
        binding.readView.onLayoutPageCompleted(index, page)
    }

    /* 全文搜索跳转 */
    private fun skipToSearch(searchResult: SearchResult) {
        if (searchResult.chapterIndex != ReadBook.durChapterIndex) {
            viewModel.openChapter(searchResult.chapterIndex) {
                jumpToPosition(searchResult)
            }
        } else {
            jumpToPosition(searchResult)
        }
    }

    private fun jumpToPosition(searchResult: SearchResult) {
        val curTextChapter = ReadBook.curTextChapter ?: return
        binding.searchMenu.updateSearchInfo()
        val (pageIndex, lineIndex, charIndex, addLine, charIndex2) =
            viewModel.searchResultPositions(curTextChapter, searchResult)
        ReadBook.skipToPage(pageIndex) {
            isSelectingSearchResult = true
            binding.readView.curPage.selectStartMoveIndex(0, lineIndex, charIndex)
            when (addLine) {
                0 -> binding.readView.curPage.selectEndMoveIndex(
                    0,
                    lineIndex,
                    charIndex + viewModel.searchContentQuery.length - 1
                )

                1 -> binding.readView.curPage.selectEndMoveIndex(
                    0, lineIndex + 1, charIndex2
                )
                //consider change page, jump to scroll position
                -1 -> binding.readView.curPage.selectEndMoveIndex(1, 0, charIndex2)
            }
            binding.readView.isTextSelected = true
            isSelectingSearchResult = false
        }
    }

    override fun addBookmark() {
        val book = ReadBook.book
        val page = ReadBook.curTextChapter?.getPage(ReadBook.durPageIndex)
        if (book != null && page != null) {
            val bookmark = book.createBookMark().apply {
                chapterIndex = ReadBook.durChapterIndex
                chapterPos = ReadBook.durChapterPos
                chapterName = page.title
                bookText = page.text.trim()
            }
            showDialogFragment(BookmarkDialog(bookmark))
        }
    }

    override fun changeReplaceRuleState() {
        ReadBook.book?.let {
            it.setUseReplaceRule(!it.getUseReplaceRule())
            ReadBook.saveRead()
            menu?.findItem(R.id.menu_enable_replace)?.isChecked = it.getUseReplaceRule()
            viewModel.replaceRuleChanged()
        }
    }

    private fun startBackupJob() {
        backupJob?.cancel()
        backupJob = lifecycleScope.launch(IO) {
            delay(300000)
            // 万象书屋: 已移除 WebDav 进度同步与自动备份, 仅保留本地持久化
            ReadBook.book?.update()
        }
    }

    override fun sureNewProgress(progress: BookProgress) {
        syncDialog?.dismiss()
        syncDialog = alert(R.string.get_book_progress) {
            setMessage(R.string.cloud_progress_exceeds_current)
            okButton {
                ReadBook.setProgress(progress)
            }
            noButton()
        }
    }

    override fun finish() {
        // 万象书屋: singleTask Activity 兜底回主界面, 防止 finish 后退到桌面
        val realFinish = {
            ensureMainActivityIfTaskRoot()
            super.finish()
        }
        val book = ReadBook.book ?: return realFinish()

        if (ReadBook.inBookshelf) {
            return realFinish()
        }

        if (!AppConfig.showAddToShelfAlert) {
            viewModel.removeFromBookshelf { realFinish() }
        } else {
            alert(title = getString(R.string.add_to_bookshelf)) {
                setMessage(getString(R.string.check_add_bookshelf, book.name))
                okButton {
                    ReadBook.book?.removeType(BookType.notShelf)
                    ReadBook.book?.save()
                    ReadBook.inBookshelf = true
                    setResult(RESULT_OK)
                }
                noButton { viewModel.removeFromBookshelf { realFinish() } }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        textActionMenu.dismiss()
        popupAction.dismiss()
        binding.readView.onDestroy()
        ReadBook.unregister(this)
        if (!ReadBook.inBookshelf && !isChangingConfigurations) {
            viewModel.removeFromBookshelf(null)
        }
        // 万象书屋: 已移除自动备份
    }

    override fun observeLiveBus() = binding.run {
        observeEvent<String>(EventBus.TIME_CHANGED) { readView.upTime() }
        observeEvent<Int>(EventBus.BATTERY_CHANGED) { readView.upBattery(it) }
        observeEvent<ArrayList<Int>>(EventBus.UP_CONFIG) {
            it.forEach { value ->
                when (value) {
                    0 -> upSystemUiVisibility()
                    1 -> readView.upBg()
                    2 -> readView.upStyle()
                    3 -> readView.upBgAlpha()
                    4 -> readView.upPageSlopSquare()
                    5 -> if (isInitFinish) ReadBook.loadContent(resetPageOffset = false)
                    6 -> readView.upContent(resetPageOffset = false)
                    8 -> ChapterProvider.upStyle()
                    9 -> readView.invalidateTextPage()
                    10 -> ChapterProvider.upLayout()
                    11 -> readView.submitRenderTask()
                    12 -> upPageAnim()
                }
            }
        }
        observeEvent<Boolean>(PreferKey.keepLight) {
            upScreenTimeOut()
        }
        observeEvent<Boolean>(PreferKey.textSelectAble) {
            readView.curPage.upSelectAble(it)
        }
        observeEvent<String>(PreferKey.showBrightnessView) {
            readMenu.upBrightnessState()
        }
        observeEvent<List<SearchResult>>(EventBus.SEARCH_RESULT) {
            viewModel.searchResultList = it
        }
        observeEvent<Boolean>(EventBus.UPDATE_READ_ACTION_BAR) {
            readMenu.reset()
        }
        observeEvent<Boolean>(EventBus.UP_SEEK_BAR) {
            readMenu.upSeekBar()
        }
    }

    private fun upScreenTimeOut() {
        val keepLightPrefer = getPrefString(PreferKey.keepLight)?.toInt() ?: 0
        screenTimeOut = keepLightPrefer * 1000L
        screenOffTimerStart()
    }

    /**
     * 重置黑屏时间
     */
    override fun screenOffTimerStart() {
        handler.post {
            if (screenTimeOut < 0) {
                keepScreenOn(true)
                return@post
            }
            val t = screenTimeOut - sysScreenOffTime
            if (t > 0) {
                keepScreenOn(true)
                handler.removeCallbacks(screenOffRunnable)
                handler.postDelayed(screenOffRunnable, screenTimeOut)
            } else {
                keepScreenOn(false)
            }
        }
    }

    companion object {
        const val RESULT_DELETED = 100
    }

}
