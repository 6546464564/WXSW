package io.legado.app

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.os.Build
import com.github.liuyueyi.quick.transfer.constants.TransType
import com.jeremyliao.liveeventbus.LiveEventBus
import com.jeremyliao.liveeventbus.logger.DefaultLogger
import com.script.rhino.ReadOnlyJavaObject
import com.script.rhino.RhinoScriptEngine
import com.script.rhino.RhinoWrapFactory
import io.legado.app.api.ShortCuts
import io.legado.app.base.AppContextWrapper
import io.legado.app.constant.AppConst.channelIdAudio
import io.legado.app.constant.AppConst.channelIdDownload
import io.legado.app.constant.AppConst.channelIdWeb
import io.legado.app.constant.PreferKey
import io.legado.app.data.appDb
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.RssSource
import io.legado.app.data.entities.rule.BookInfoRule
import io.legado.app.data.entities.rule.ContentRule
import io.legado.app.data.entities.rule.ExploreRule
import io.legado.app.data.entities.rule.SearchRule
import io.legado.app.help.AppFreezeMonitor
import io.legado.app.help.CrashHandler
import io.legado.app.help.DefaultData
import io.legado.app.help.DispatchersMonitor
import io.legado.app.help.LifecycleHelp
import io.legado.app.help.RuleBigDataHelp
import io.legado.app.help.WanxiangBackend
import io.legado.app.help.book.BookHelp
import io.legado.app.help.config.AppConfig
import io.legado.app.help.config.ReadBookConfig
import io.legado.app.help.config.ThemeConfig
import io.legado.app.help.config.ThemeConfig.applyDayNight
import io.legado.app.help.config.ThemeConfig.applyDayNightInit
import io.legado.app.help.coroutine.Coroutine
import io.legado.app.help.http.Cronet
import io.legado.app.help.http.ObsoleteUrlFactory
import io.legado.app.help.http.okHttpClient
import io.legado.app.help.rhino.NativeBaseSource
import io.legado.app.help.source.SourceHelp
import io.legado.app.model.BookCover
import io.legado.app.utils.ChineseUtils
import io.legado.app.utils.LogUtils
import io.legado.app.utils.defaultSharedPreferences
import io.legado.app.utils.getPrefBoolean
import io.legado.app.utils.isDebuggable
import kotlinx.coroutines.launch
import org.chromium.base.ThreadUtils
import splitties.init.appCtx
import splitties.systemservices.notificationManager
import java.net.URL
import java.util.concurrent.TimeUnit
import java.util.logging.Level

class App : Application() {

    private lateinit var oldConfig: Configuration

    override fun onCreate() {
        super.onCreate()
        CrashHandler(this)
        if (isDebuggable) {
            ThreadUtils.setThreadAssertsDisabledForTesting(true)
        }
        oldConfig = Configuration(resources.configuration)
        applyDayNightInit(this)
        registerActivityLifecycleCallbacks(LifecycleHelp)
        // 万象书屋 D-19: 护眼模式 Application 级覆盖 — Activity 进 onResume 时统一调 EyeCareHelper.apply,
        //   覆盖所有 Activity (含 SplashAdActivity / 任何第三方库 Activity), 不漏 corner case.
        registerActivityLifecycleCallbacks(io.legado.app.help.EyeCareLifecycleCallback)
        // 万象书屋 (方案 G'): App 切回前台兜底刷一次书源 etag.
        //   - X-Sources-Etag 拦截器已经在任何 backend 响应时被动同步, 这里只是兜底,
        //     防"用户切回前台后没任何接口被调"的极端弱网情况.
        //   - 心跳本身也会调 fetchAndApplySources 顺带刷, 这里的兜底只在心跳失败的 corner case 起作用.
        androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(
            object : androidx.lifecycle.DefaultLifecycleObserver {
                override fun onStart(owner: androidx.lifecycle.LifecycleOwner) {
                    WanxiangBackend.refreshOnBecameForeground()
                }
            }
        )
        defaultSharedPreferences.registerOnSharedPreferenceChangeListener(AppConfig)
        // 万象书屋: 在 Application.onCreate 同步隐私同意态.
        //
        // 之前 BUG: AdManager.consented 是内存变量, 只有 SplashAdActivity 走 setConsent(true) 才赋值.
        //   - 进程被杀重启后, 如果用户从 deeplink/notification/recents 直接进 MainActivity,
        //     不经过 SplashAdActivity, AdManager.consented 始终 false
        //   - 我的页"纯净阅读"卡片不显示, 阅读器顶部条不显示
        //   - 任何 reportAdEvent 都被 isConsented() 短路, 后端收不到一条激励上报
        // 修复: 进程启动即从 SP 读取持久化的同意态恢复内存. SplashAdActivity 的 setConsent
        //   仍是首次同意时的入口, 这里只做"恢复"不重新征求.
        if (io.legado.app.ad.AdConsent.isGranted()) {
            io.legado.app.ad.AdManager.setConsent(this, true)
        }
        Coroutine.async {
            LogUtils.init(this@App)
            LogUtils.d("App", "onCreate")
            LogUtils.logDeviceInfo()
            //预下载Cronet so
            Cronet.preDownload()
            createNotificationChannels()
            LiveEventBus.config()
                .lifecycleObserverAlwaysActive(true)
                .autoClear(false)
                .enableLogger(BuildConfig.DEBUG || AppConfig.recordLog)
                .setLogger(EventLogger())
            DefaultData.upVersion()
            // 万象书屋: 桌面快捷方式注册 (原本由 ReaderProvider.onCreate 触发,
            // ReaderProvider 已删除, 改为 App 启动时主动注册)
            ShortCuts.buildShortCuts(this@App)
            // 万象书屋: 启动远程书源同步 + 心跳上报 (后端 URL 在 BuildConfig.BACKEND_BASE_URL)
            WanxiangBackend.start()
            // 万象书屋: 自建埋点 SDK 启动 (内存队列 + 30s 定时 flush)
            io.legado.app.help.WanxiangAnalytics.init()
            AppFreezeMonitor.init(this@App)
            DispatchersMonitor.init()
            URL.setURLStreamHandlerFactory(ObsoleteUrlFactory(okHttpClient))
            launch { installGmsTlsProvider(appCtx) }
            initRhino()
            //初始化封面
            BookCover.toString()
            //清除过期数据
            appDb.cacheDao.clearDeadline(System.currentTimeMillis())
            if (getPrefBoolean(PreferKey.autoClearExpired, true)) {
                val clearTime = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(1)
                appDb.searchBookDao.clearExpired(clearTime)
            }
            RuleBigDataHelp.clearInvalid()
            BookHelp.clearInvalidCache()
            ReadBookConfig.clearBgAndCache()
            ThemeConfig.clearBg()
            //初始化简繁转换引擎
            when (AppConfig.chineseConverterType) {
                1 -> {
                    ChineseUtils.fixT2sDict()
                    ChineseUtils.preLoad(true, TransType.TRADITIONAL_TO_SIMPLE)
                }

                2 -> ChineseUtils.preLoad(true, TransType.SIMPLE_TO_TRADITIONAL)
            }
            //调整排序序号
            SourceHelp.adjustSortNumber()
            // 万象书屋: 已移除 WebDav 阅读记录同步
        }
    }

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(AppContextWrapper.wrap(base))
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        val diff = newConfig.diff(oldConfig)
        if ((diff and ActivityInfo.CONFIG_UI_MODE) != 0) {
            // 万象书屋 D-21 (#THEME-FOLLOW-2): 系统切换 dark/light 时:
            //
            // themeMode="0" (跟随系统):
            //   1. AppCompatDelegate 已是 MODE_NIGHT_FOLLOW_SYSTEM, AppCompat 会自动 recreate Activity
            //      (manifest 已不拦截 uiMode)
            //   2. 但 ThemeStore (基于 SP 的动态主题色) 不会自动切换 — 它保存的是用户 day/night 各自的偏好色,
            //      需要进程级重算: 调用 applyTheme(this) 让 ThemeConfig 根据新的 isNightTheme 写入对应 SP 值,
            //      Activity recreate 后读 SP 拿到 night 主题色, 颜色全切换.
            //   3. BookCover 默认封面也跟主题相关, 一并刷新.
            //
            // themeMode="1"/"2"/"3" (用户固定模式): AppCompat 已锁定 NO/YES, 系统变化跟用户选择无关, 完全 ignore.
            if (AppConfig.themeMode == "0") {
                io.legado.app.help.config.ThemeConfig.applyTheme(this)
                BookCover.upDefaultCover()
            }
        }
        oldConfig = Configuration(newConfig)
    }

    /**
     * 尝试在安装了GMS的设备上(GMS或者MicroG)使用GMS内置的Conscrypt
     * 作为首选JCE提供程序，而使Okhttp在低版本Android上
     * 能够启用TLSv1.3
     * https://f-droid.org/zh_Hans/2020/05/29/android-updates-and-tls-connections.html
     * https://developer.android.google.cn/reference/javax/net/ssl/SSLSocket
     *
     * @param context
     * @return
     */
    private fun installGmsTlsProvider(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return
        }
        try {
            val gmsPackageName = "com.google.android.gms"
            val appInfo = packageManager.getApplicationInfo(gmsPackageName, 0)
            if ((appInfo.flags and ApplicationInfo.FLAG_SYSTEM) == 0) {
                return
            }
            val gms = context.createPackageContext(
                gmsPackageName,
                CONTEXT_INCLUDE_CODE or CONTEXT_IGNORE_SECURITY
            )
            gms.classLoader
                .loadClass("com.google.android.gms.common.security.ProviderInstallerImpl")
                .getMethod("insertProvider", Context::class.java)
                .invoke(null, gms)
        } catch (e: java.lang.Exception) {
            e.printStackTrace()
        }
    }

    /**
     * 创建通知ID
     */
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val downloadChannel = NotificationChannel(
            channelIdDownload,
            getString(R.string.action_download),
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        val audioChannel = NotificationChannel(
            channelIdAudio,
            getString(R.string.audio),
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        val webChannel = NotificationChannel(
            channelIdWeb,
            getString(R.string.web_service),
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        //向notification manager 提交channel
        notificationManager.createNotificationChannels(
            listOf(
                downloadChannel,
                audioChannel,
                webChannel
            )
        )
    }

    private fun initRhino() {
        RhinoScriptEngine
        RhinoWrapFactory.register(BookSource::class.java, NativeBaseSource.factory)
        RhinoWrapFactory.register(RssSource::class.java, NativeBaseSource.factory)
        RhinoWrapFactory.register(ExploreRule::class.java, ReadOnlyJavaObject.factory)
        RhinoWrapFactory.register(SearchRule::class.java, ReadOnlyJavaObject.factory)
        RhinoWrapFactory.register(BookInfoRule::class.java, ReadOnlyJavaObject.factory)
        RhinoWrapFactory.register(ContentRule::class.java, ReadOnlyJavaObject.factory)
        RhinoWrapFactory.register(BookChapter::class.java, ReadOnlyJavaObject.factory)
        RhinoWrapFactory.register(Book.ReadConfig::class.java, ReadOnlyJavaObject.factory)
    }

    class EventLogger : DefaultLogger() {

        override fun log(level: Level, msg: String) {
            super.log(level, msg)
            LogUtils.d(TAG, msg)
        }

        override fun log(level: Level, msg: String, th: Throwable?) {
            super.log(level, msg, th)
            LogUtils.d(TAG, "$msg\n${th?.stackTraceToString()}")
        }

        companion object {
            private const val TAG = "[LiveEventBus]"
        }
    }

    companion object {
        init {
            if (BuildConfig.DEBUG) {
                System.setProperty("kotlinx.coroutines.debug", "on")
            }
        }
    }

}
