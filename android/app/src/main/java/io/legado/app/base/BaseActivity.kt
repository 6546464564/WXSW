package io.legado.app.base

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.graphics.drawable.BitmapDrawable
import android.os.Build
import android.os.Bundle
import android.util.AttributeSet
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import androidx.activity.addCallback
import androidx.annotation.RequiresApi
import androidx.appcompat.app.AppCompatActivity
import androidx.viewbinding.ViewBinding
import io.legado.app.R
import io.legado.app.constant.AppConst
import io.legado.app.constant.AppLog
import io.legado.app.constant.Theme
import io.legado.app.help.WanxiangAnalytics
import io.legado.app.help.config.AppConfig
import io.legado.app.help.config.ThemeConfig
import io.legado.app.lib.theme.ThemeStore
import io.legado.app.lib.theme.backgroundColor
import io.legado.app.lib.theme.primaryColor
import io.legado.app.ui.widget.TitleBar
import io.legado.app.utils.ColorUtils
import io.legado.app.utils.applyBackgroundTint
import io.legado.app.utils.applyOpenTint
import io.legado.app.utils.applyTint
import io.legado.app.utils.disableAutoFill
import io.legado.app.utils.fullScreen
import io.legado.app.utils.hideSoftInput
import io.legado.app.utils.setLightStatusBar
import io.legado.app.utils.setNavigationBarColorAuto
import io.legado.app.utils.setStatusBarColorAuto
import io.legado.app.utils.toastOnUi
import io.legado.app.utils.windowSize


abstract class BaseActivity<VB : ViewBinding>(
    val fullScreen: Boolean = true,
    private val theme: Theme = Theme.Auto,
    private val toolBarTheme: Theme = Theme.Auto,
    private val transparent: Boolean = false,
    private val imageBg: Boolean = true
) : AppCompatActivity() {

    protected abstract val binding: VB

    val isInMultiWindow: Boolean
        @SuppressLint("ObsoleteSdkInt")
        get() {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                isInMultiWindowMode
            } else {
                false
            }
        }

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppContextWrapper.wrap(newBase))
    }

    override fun onCreateView(
        parent: View?,
        name: String,
        context: Context,
        attrs: AttributeSet
    ): View? {
        if (AppConst.menuViewNames.contains(name) && parent?.parent is FrameLayout) {
            (parent.parent as View).setBackgroundColor(backgroundColor)
        }
        return super.onCreateView(parent, name, context, attrs)
    }

    @SuppressLint("ObsoleteSdkInt")
    override fun onCreate(savedInstanceState: Bundle?) {
        window.decorView.disableAutoFill()
        initTheme()
        super.onCreate(savedInstanceState)
        setupSystemBar()
        setContentView(binding.root)
        upBackgroundImage()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            findViewById<TitleBar>(R.id.title_bar)
                ?.onMultiWindowModeChanged(isInMultiWindowMode, fullScreen)
        }
        onBackPressedDispatcher.addCallback(this) {
            finish()
        }
        observeLiveBus()
        onActivityCreated(savedInstanceState)
    }

    // 万象书屋: 自动 PV 埋点. 每个 Activity onResume 上报 page_<simpleName>,
    // onPause 时计算 stay_ms (停留时长), 用于做"页面热度排行"和"流失漏斗".
    // 不希望被埋点的 Activity 重写 trackPageName() 返回 null.
    private var pageStartMs: Long = 0L

    /**
     * 万象书屋 D-16 (A-5): 缓存 simpleName → pageName 转换结果.
     *   旧实现每次 onResume + onPause 都跑一次 Regex.compile + 字符串 replace,
     *   每页切换 2 次 Regex 编译 ~10-30 微秒. 30+ 个 Activity 累积 ~毫秒级 CPU.
     * 新实现: 用 ConcurrentHashMap 缓存, 每个 Activity 类只算一次.
     */
    open fun trackPageName(): String? {
        val simple = javaClass.simpleName
        return PAGE_NAME_CACHE.getOrPut(simple) {
            "page_" + simple
                .replace("Activity", "")
                .replace(PAGE_NAME_CAMEL_REGEX, "$1_$2")
                .lowercase()
        }
    }

    override fun onResume() {
        super.onResume()
        // 万象书屋 D-19: 护眼模式滤镜统一在 App.kt 的 ActivityLifecycleCallbacks 注入,
        //   不再每个 Activity 单独 apply (旧 D-18 方案漏覆盖 SplashAdActivity 等不继承 BaseActivity 的页面).
        //   这里仅做兜底, 防止 Application 注入失败时仍能在主流页面生效.
        io.legado.app.help.EyeCareHelper.apply(this)
        trackPageName()?.let { name ->
            pageStartMs = System.currentTimeMillis()
            WanxiangAnalytics.track(name, type = "pv")
        }
    }

    override fun onPause() {
        super.onPause()
        val name = trackPageName() ?: return
        if (pageStartMs > 0) {
            val stayMs = System.currentTimeMillis() - pageStartMs
            // 万象书屋 D-16 (A-6): 上界从 1h 放宽到 24h, 真实阅读会话经常 >1h, 不该被过滤丢失.
            if (stayMs in 100..STAY_MS_MAX) {
                WanxiangAnalytics.track(
                    name + "_leave", type = "pv",
                    params = mapOf("stay_ms" to stayMs)
                )
            }
            pageStartMs = 0L
        }
        // 切到后台时强制 flush, 不让事件留在内存里被进程回收丢掉
        if (isFinishing || !hasWindowFocus()) WanxiangAnalytics.flush()
    }

    @RequiresApi(Build.VERSION_CODES.O)
    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        findViewById<TitleBar>(R.id.title_bar)
            ?.onMultiWindowModeChanged(isInMultiWindowMode, fullScreen)
        setupSystemBar()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        findViewById<TitleBar>(R.id.title_bar)
            ?.onMultiWindowModeChanged(isInMultiWindow, fullScreen)
        setupSystemBar()
    }

    abstract fun onActivityCreated(savedInstanceState: Bundle?)

    final override fun onCreateOptionsMenu(menu: Menu): Boolean {
        val bool = onCompatCreateOptionsMenu(menu)
        menu.applyTint(this, toolBarTheme)
        return bool
    }

    override fun onMenuOpened(featureId: Int, menu: Menu): Boolean {
        menu.applyOpenTint(this)
        return super.onMenuOpened(featureId, menu)
    }

    open fun onCompatCreateOptionsMenu(menu: Menu) = super.onCreateOptionsMenu(menu)

    final override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (item.itemId == android.R.id.home) {
            supportFinishAfterTransition()
            return true
        }
        return onCompatOptionsItemSelected(item)
    }

    open fun onCompatOptionsItemSelected(item: MenuItem) = super.onOptionsItemSelected(item)

    open fun initTheme() {
        when (theme) {
            Theme.Transparent -> setTheme(R.style.AppTheme_Transparent)
            Theme.Dark -> {
                setTheme(R.style.AppTheme_Dark)
                window.decorView.applyBackgroundTint(backgroundColor)
            }

            Theme.Light -> {
                setTheme(R.style.AppTheme_Light)
                window.decorView.applyBackgroundTint(backgroundColor)
            }

            else -> {
                if (ColorUtils.isColorLight(primaryColor)) {
                    setTheme(R.style.AppTheme_Light)
                } else {
                    setTheme(R.style.AppTheme_Dark)
                }
                window.decorView.applyBackgroundTint(backgroundColor)
            }
        }
    }

    open fun upBackgroundImage() {
        if (imageBg) {
            try {
                ThemeConfig.getBgImage(this, windowManager.windowSize)?.let {
                    window.decorView.background = BitmapDrawable(resources, it)
                }
            } catch (e: OutOfMemoryError) {
                toastOnUi("背景图片太大,内存溢出")
            } catch (e: Exception) {
                AppLog.put("加载背景出错\n${e.localizedMessage}", e)
            }
        }
    }

    open fun setupSystemBar() {
        if (fullScreen && !isInMultiWindow) {
            fullScreen()
        }
        val isTransparentStatusBar = AppConfig.isTransparentStatusBar
        val statusBarColor = ThemeStore.statusBarColor(this, isTransparentStatusBar)
        setStatusBarColorAuto(statusBarColor, isTransparentStatusBar, fullScreen)
        if (toolBarTheme == Theme.Dark) {
            setLightStatusBar(false)
        } else if (toolBarTheme == Theme.Light) {
            setLightStatusBar(true)
        }
        upNavigationBarColor()
    }

    open fun upNavigationBarColor() {
        if (AppConfig.immNavigationBar) {
            setNavigationBarColorAuto(ThemeStore.navigationBarColor(this))
        } else {
            val nbColor = ColorUtils.darkenColor(ThemeStore.navigationBarColor(this))
            setNavigationBarColorAuto(nbColor)
        }
    }

    open fun observeLiveBus() {
    }

    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        return try {
            super.dispatchTouchEvent(ev)
        } catch (e: IllegalArgumentException) {
            e.printStackTrace()
            false
        }
    }

    override fun finish() {
        currentFocus?.hideSoftInput()
        super.finish()
    }

    companion object {
        // 万象书屋 D-16 (A-5): page_name 缓存, 进程内只算一次.
        private val PAGE_NAME_CACHE = java.util.concurrent.ConcurrentHashMap<String, String>()
        private val PAGE_NAME_CAMEL_REGEX = Regex("([a-z])([A-Z])")
        // 万象书屋 D-16 (A-6): stay_ms 上界从 1h 改 24h, 长会话不丢
        private const val STAY_MS_MAX = 24L * 3600L * 1000L
    }
}