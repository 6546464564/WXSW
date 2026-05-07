@file:Suppress("DEPRECATION")

package io.legado.app.ui.main

import android.content.Intent
import android.os.Bundle
import android.view.MenuItem
import android.view.ViewGroup
import androidx.activity.addCallback
import androidx.activity.viewModels
import androidx.core.view.get
import androidx.core.view.postDelayed
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentManager
import androidx.fragment.app.FragmentStatePagerAdapter
import androidx.lifecycle.lifecycleScope
import androidx.viewpager.widget.ViewPager
import com.google.android.material.bottomnavigation.BottomNavigationView
import io.legado.app.BuildConfig
import io.legado.app.R
import io.legado.app.base.VMBaseActivity
import io.legado.app.constant.AppConst.appInfo
import io.legado.app.constant.EventBus
import io.legado.app.constant.PreferKey
import io.legado.app.data.appDb
import io.legado.app.databinding.ActivityMainBinding
import io.legado.app.help.book.BookHelp
import io.legado.app.help.config.AppConfig
import io.legado.app.help.config.LocalConfig
import io.legado.app.help.coroutine.Coroutine
import io.legado.app.lib.dialogs.alert
import io.legado.app.lib.theme.elevation
import io.legado.app.lib.theme.primaryColor
import io.legado.app.ui.about.CrashLogsDialog
import io.legado.app.ui.book.read.ReadBookActivity
import io.legado.app.ui.main.bookshelf.BaseBookshelfFragment
import io.legado.app.ui.main.bookshelf.style1.BookshelfFragment1
import io.legado.app.ui.main.bookshelf.style2.BookshelfFragment2
import io.legado.app.ui.main.bookstore.BookStoreFragment
import io.legado.app.ui.main.my.MyFragment
import io.legado.app.ui.widget.text.BadgeView
import io.legado.app.utils.getPrefBoolean
import io.legado.app.utils.isCreated
import io.legado.app.utils.navigationBarHeight
import io.legado.app.utils.observeEvent
import io.legado.app.utils.setEdgeEffectColor
import io.legado.app.utils.setOnApplyWindowInsetsListenerCompat
import io.legado.app.utils.showDialogFragment
import io.legado.app.utils.startActivity
import io.legado.app.utils.toastOnUi
import io.legado.app.utils.viewbindingdelegate.viewBinding
import kotlinx.coroutines.Dispatchers.IO
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import splitties.views.bottomPadding
import kotlin.coroutines.resume

/**
 * 主界面
 */
@Suppress("PrivatePropertyName")
class MainActivity : VMBaseActivity<ActivityMainBinding, MainViewModel>(),
    BottomNavigationView.OnNavigationItemSelectedListener,
    BottomNavigationView.OnNavigationItemReselectedListener {

    override val binding by viewBinding(ActivityMainBinding::inflate)
    override val viewModel by viewModels<MainViewModel>()
    private val idBookshelf = 0
    private val idBookshelf1 = 11
    private val idBookshelf2 = 12
    private val idBookStore = 1
    private val idMy = 2
    private var exitTime: Long = 0
    private var bookshelfReselected: Long = 0
    private var pagePosition = 0
    private val fragmentMap = hashMapOf<Int, Fragment>()
    private var bottomMenuCount = 3
    private val EXIT_INTERVAL = 2000L
    // 万象书屋：底部 3 Tab = 书架 / 书城 / 我的
    private val realPositions = arrayOf(idBookshelf, idBookStore, idMy)
    private val adapter by lazy {
        TabFragmentPageAdapter(supportFragmentManager)
    }
    private var onUpBooksBadgeView: BadgeView? = null

    override fun onActivityCreated(savedInstanceState: Bundle?) {
        upBottomMenu()
        initView()
        upHomePage()
        // 万象书屋: 已移除独立 WelcomeActivity, 将「启动直接进入上次阅读」逻辑迁移到这里
        // 注: 如果带 EXTRA_SELECT_TAB 跳转过来, 跳过自动进阅读, 让用户先看引导目标
        val hasSelectTab = !intent.getStringExtra(EXTRA_SELECT_TAB).isNullOrEmpty()
        if (savedInstanceState == null
            && !hasSelectTab
            && getPrefBoolean(PreferKey.defaultToRead)
            && appDb.bookDao.lastReadBook != null
        ) {
            startActivity<ReadBookActivity>()
        }
        applySelectTab(intent)
        onBackPressedDispatcher.addCallback(this) {
            if (pagePosition != 0) {
                binding.viewPagerMain.currentItem = 0
                return@addCallback
            }
            (fragmentMap[getFragmentId(0)] as? BookshelfFragment2)?.let {
                if (it.back()) {
                    return@addCallback
                }
            }
            if (System.currentTimeMillis() - exitTime > EXIT_INTERVAL) {
                toastOnUi(R.string.double_click_exit)
                exitTime = System.currentTimeMillis()
            } else {
                moveTaskToBack(true)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 万象书屋: Android 标准做法, 让后续 getIntent() 拿到最新 intent.
        // 否则 lifecycle 事件里读到的还是 onCreate 时的旧 intent, 埋坑.
        setIntent(intent)
        // 外部通过 putExtra(EXTRA_SELECT_TAB, ...) 拉起 Main 时, 切到对应 Tab.
        applySelectTab(intent)
    }

    /**
     * 万象书屋: 把 [EXTRA_SELECT_TAB] 解析成 viewPager 索引并切过去.
     * 支持 "shelf" / "store" / "my" 三个值; 其他值忽略.
     */
    private fun applySelectTab(intent: Intent?) {
        val tab = intent?.getStringExtra(EXTRA_SELECT_TAB) ?: return
        val targetIdx = when (tab) {
            TAB_BOOKSHELF -> realPositions.indexOf(idBookshelf)
            TAB_BOOKSTORE -> realPositions.indexOf(idBookStore)
            TAB_MY -> realPositions.indexOf(idMy)
            else -> -1
        }
        if (targetIdx >= 0) {
            binding.viewPagerMain.post { binding.viewPagerMain.setCurrentItem(targetIdx, false) }
        }
    }

    override fun onPostCreate(savedInstanceState: Bundle?) {
        super.onPostCreate(savedInstanceState)
        lifecycleScope.launch {
            //隐私协议
            if (!privacyPolicy()) return@launch
            //版本更新
            upVersion()
            //设置本地密码
            setLocalPassword()
            notifyAppCrash()
            //备份同步
            backupSync()
            //自动更新书籍
            val isAutoRefreshedBook = savedInstanceState?.getBoolean("isAutoRefreshedBook") ?: false
            if (AppConfig.autoRefreshBook && !isAutoRefreshedBook) {
                binding.viewPagerMain.postDelayed(1000) {
                    viewModel.upAllBookToc()
                }
            }
            binding.viewPagerMain.postDelayed(3000) {
                viewModel.postLoad()
            }
        }
    }

    override fun onNavigationItemSelected(item: MenuItem): Boolean = binding.run {
        when (item.itemId) {
            R.id.menu_bookshelf ->
                viewPagerMain.setCurrentItem(0, false)

            R.id.menu_book_store ->
                viewPagerMain.setCurrentItem(realPositions.indexOf(idBookStore), false)

            R.id.menu_my_config ->
                viewPagerMain.setCurrentItem(realPositions.indexOf(idMy), false)
        }
        return false
    }

    override fun onNavigationItemReselected(item: MenuItem) {
        when (item.itemId) {
            R.id.menu_bookshelf -> {
                if (System.currentTimeMillis() - bookshelfReselected > 300) {
                    bookshelfReselected = System.currentTimeMillis()
                } else {
                    (fragmentMap[getFragmentId(0)] as? BaseBookshelfFragment)?.gotoTop()
                }
            }
        }
    }

    private fun initView() = binding.run {
        viewPagerMain.setEdgeEffectColor(primaryColor)
        viewPagerMain.offscreenPageLimit = 3
        viewPagerMain.adapter = adapter
        viewPagerMain.addOnPageChangeListener(PageChangeCallback())
        bottomNavigationView.elevation = elevation
        bottomNavigationView.setOnNavigationItemSelectedListener(this@MainActivity)
        bottomNavigationView.setOnNavigationItemReselectedListener(this@MainActivity)
        if (AppConfig.isEInkMode) {
            bottomNavigationView.setBackgroundResource(R.drawable.bg_eink_border_top)
        }
        bottomNavigationView.setOnApplyWindowInsetsListenerCompat { view, windowInsets ->
            val height = windowInsets.navigationBarHeight
            view.bottomPadding = height
            windowInsets.inset(0, 0, 0, height)
        }
    }

    /**
     * 万象书屋: 不再弹「用户隐私与协议」对话框,直接默认同意
     */
    private fun privacyPolicy(): Boolean {
        if (!LocalConfig.privacyPolicyOk) {
            LocalConfig.privacyPolicyOk = true
        }
        return true
    }

    /**
     * 万象书屋: 不再弹版本更新日志/首次帮助文档,只静默更新本地版本号并消费首次标识
     */
    private fun upVersion() {
        if (LocalConfig.versionCode != appInfo.versionCode) {
            LocalConfig.versionCode = appInfo.versionCode
        }
        // 消费 isFirstOpenApp 内部 firstOpen 标识,避免任何旧逻辑再依赖
        @Suppress("UNUSED_VARIABLE") val consumed = LocalConfig.isFirstOpenApp
    }

    /**
     * 万象书屋: 不再弹「设置本地密码」对话框,直接默认空密码
     */
    private fun setLocalPassword() {
        if (LocalConfig.password == null) {
            LocalConfig.password = ""
        }
    }

    private fun notifyAppCrash() {
        if (!LocalConfig.appCrash || BuildConfig.DEBUG) {
            return
        }
        LocalConfig.appCrash = false
        alert(getString(R.string.draw), "检测到阅读发生了崩溃，是否打开崩溃日志以便报告问题？") {
            yesButton {
                showDialogFragment<CrashLogsDialog>()
            }
            noButton()
        }
    }

    /**
     * 万象书屋: 已移除 WebDav 备份同步, 此方法保留为空占位
     */
    private fun backupSync() {
        // no-op
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (AppConfig.autoRefreshBook) {
            outState.putBoolean("isAutoRefreshedBook", true)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        Coroutine.async {
            BookHelp.clearInvalidCache()
        }
    }

    /**
     * 如果重启太快fragment不会重建,这里更新一下书架的排序
     */
    override fun recreate() {
        (fragmentMap[getFragmentId(0)] as? BaseBookshelfFragment)?.run {
            upSort()
        }
        super.recreate()
    }

    override fun observeLiveBus() {
        viewModel.onUpBooksLiveData.observe(this) {
            if (onUpBooksBadgeView == null) {
                onUpBooksBadgeView = binding.bottomNavigationView.addBadgeView(0)
            }
            onUpBooksBadgeView!!.setBadgeCount(it)
        }
        observeEvent<String>(EventBus.RECREATE) {
            recreate()
        }
        observeEvent<Boolean>(EventBus.NOTIFY_MAIN) {
            binding.apply {
                if (it) {
                    bottomNavigationView.menu.clear()
                    bottomNavigationView.inflateMenu(R.menu.main_bnv)
                    onUpBooksBadgeView = null
                }
                upBottomMenu()
                if (it) {
                    viewPagerMain.setCurrentItem(bottomMenuCount - 1, false)
                }
            }
        }
        observeEvent<String>(PreferKey.threadCount) {
            viewModel.upPool()
        }
    }

    private fun upBottomMenu() {
        // 万象书屋：固定 3 Tab（书架 / 书城 / 我的），不再支持隐藏
        realPositions[0] = idBookshelf
        realPositions[1] = idBookStore
        realPositions[2] = idMy
        bottomMenuCount = 3
        adapter.notifyDataSetChanged()
    }

    private fun upHomePage() {
        when (AppConfig.defaultHomePage) {
            "bookshelf" -> {}
            "bookStore" -> binding.viewPagerMain.setCurrentItem(realPositions.indexOf(idBookStore), false)
            "my" -> binding.viewPagerMain.setCurrentItem(realPositions.indexOf(idMy), false)
        }
    }

    private fun getFragmentId(position: Int): Int {
        val id = realPositions[position]
        if (id == idBookshelf) {
            return if (AppConfig.bookGroupStyle == 1) idBookshelf2 else idBookshelf1
        }
        return id
    }

    private inner class PageChangeCallback : ViewPager.SimpleOnPageChangeListener() {

        override fun onPageSelected(position: Int) {
            pagePosition = position
            binding.bottomNavigationView.menu[realPositions[position]].isChecked = true
        }

    }

    @Suppress("DEPRECATION")
    private inner class TabFragmentPageAdapter(fm: FragmentManager) :
        FragmentStatePagerAdapter(fm, BEHAVIOR_RESUME_ONLY_CURRENT_FRAGMENT) {

        private fun getId(position: Int): Int {
            return getFragmentId(position)
        }

        override fun getItemPosition(any: Any): Int {
            val position = (any as MainFragmentInterface).position
                ?: return POSITION_NONE
            val fragmentId = getId(position)
            if ((fragmentId == idBookshelf1 && any is BookshelfFragment1)
                || (fragmentId == idBookshelf2 && any is BookshelfFragment2)
                || (fragmentId == idBookStore && any is BookStoreFragment)
                || (fragmentId == idMy && any is MyFragment)
            ) {
                return POSITION_UNCHANGED
            }
            return POSITION_NONE
        }

        override fun getItem(position: Int): Fragment {
            return when (getId(position)) {
                idBookshelf1 -> BookshelfFragment1(position)
                idBookshelf2 -> BookshelfFragment2(position)
                idBookStore -> BookStoreFragment(position)
                else -> MyFragment(position)
            }
        }

        override fun getCount(): Int {
            return bottomMenuCount
        }

        override fun instantiateItem(container: ViewGroup, position: Int): Any {
            var fragment = super.instantiateItem(container, position) as Fragment
            if (fragment.isCreated && getItemPosition(fragment) == POSITION_NONE) {
                destroyItem(container, position, fragment)
                fragment = super.instantiateItem(container, position) as Fragment
            }
            fragmentMap[getId(position)] = fragment
            return fragment
        }

    }

    companion object {
        /** 万象书屋: 外部 Activity 跳 Main 时通过此 extra 指定要展示的 Tab. */
        const val EXTRA_SELECT_TAB = "select_tab"
        const val TAB_BOOKSHELF = "shelf"
        const val TAB_BOOKSTORE = "store"
        const val TAB_MY = "my"
    }

}