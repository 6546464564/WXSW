package io.legado.app.ad.ui

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.FrameLayout
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import io.legado.app.R
import io.legado.app.ad.AdConsent
import io.legado.app.ad.AdManager
import io.legado.app.base.AppContextWrapper
import io.legado.app.ui.main.MainActivity
import io.legado.app.utils.LogUtils

/**
 * 万象书屋开屏 / 启动门面.
 *
 * 之前没有独立 SplashActivity (MainActivity 直接是 LAUNCHER), 接广告必须有一个独立容器,
 * 否则开屏广告 View 会卡在主界面上方影响 BottomNavigation 等核心交互.
 *
 * 设计:
 *   1. 用户首启 -> 弹隐私同意 -> 同意后 bootstrap AdManager -> 走广告流程 -> 进 Main
 *   2. 用户拒绝同意 -> 不 init 任何 SDK -> 直接进 Main
 *   3. 已经同意过 -> 直接走广告流程 -> 进 Main
 *
 * 任何分支最终都通过 [proceedToMain] 进 Main, 用 OnceGuard 防双跳.
 */
class SplashAdActivity : AppCompatActivity() {

    /**
     * 万象书屋: SplashAdActivity 不继承 BaseActivity (启动路径要尽量轻),
     * 但 i18n 锁定依赖 attachBaseContext 包一层 AppContextWrapper.
     * 不覆盖的话同意弹窗会跟着系统语言, 出现"AGREE / DECLINE"等英文 -
     * 跟正文 UI 全中文不一致. 这里手动 wrap, 保持和 BaseActivity 一致.
     */
    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppContextWrapper.wrap(newBase))
    }

    private var jumped = false

    /** 用户是否点过隐私同意 dialog 的任一按钮 (避免旋转时重弹) */
    private var consentResolved = false

    /** 是否已经开始播广告内容 (决定 Back 键是否屏蔽) */
    private var adShowing = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_splash_ad)
        // 万象书屋: 旋转/配置变更时 Activity 重建, restore 状态避免重复走 decideFlow
        if (savedInstanceState != null) {
            jumped = savedInstanceState.getBoolean(STATE_JUMPED, false)
            consentResolved = savedInstanceState.getBoolean(STATE_CONSENT_RESOLVED, false)
            adShowing = savedInstanceState.getBoolean(STATE_AD_SHOWING, false)
            if (jumped) { proceedToMain(); return }
            // 万象书屋 D-5 修复: 重建场景下若广告已经在播 (adShowing=true), 跳过 decideFlow,
            // 直接 proceedToMain. 否则会重新调 setConsent + bootstrap + showSplashOrSkip,
            // 跑两遍开屏协程, 多份 SDK init 竞争, 资源占用瞬时翻倍.
            // 实际场景: 旋转屏幕 / 切换主题 / 系统配置变更触发的 destroy+create.
            if (adShowing) {
                LogUtils.d(TAG, "recreated while ad showing, skip re-bootstrap")
                proceedToMain()
                return
            }
        }
        // 万象书屋: targetSdk 33+ 应使用 OnBackPressedDispatcher, onBackPressed 已 deprecated
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (!adShowing) {
                    proceedToMain()
                } else {
                    // 广告展示中按 Back: 让 SDK 自己接管 (CSJ/YLH 都会触发 onADDismissed)
                    // 这里临时 disable 自己, 让默认 Back 行为生效
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                }
            }
        })
        decideFlow()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_JUMPED, jumped)
        outState.putBoolean(STATE_CONSENT_RESOLVED, consentResolved)
        outState.putBoolean(STATE_AD_SHOWING, adShowing)
    }

    private fun decideFlow() {
        if (AdConsent.isGranted() || consentResolved) {
            // 已同意过, 或者本次 session 已经处理过同意态 (拒绝)
            if (AdConsent.isGranted()) {
                AdManager.bootstrap(applicationContext, true)
                showSplashOrSkip()
            } else {
                proceedToMain()
            }
            return
        }
        // 首启: 不立刻拉广告, 先弹隐私同意
        AdConsent.ensureConsent(this) { granted ->
            consentResolved = true
            AdManager.setConsent(applicationContext, granted)
            if (granted) showSplashOrSkip() else proceedToMain()
        }
    }

    private fun showSplashOrSkip() {
        adShowing = true
        val container = findViewById<FrameLayout>(R.id.ad_container)
        // AdManager 内部已经做硬超时, 这里只关心"什么时候可以走"
        AdManager.showSplash(this, container) { proceedToMain() }
    }

    private fun proceedToMain() {
        if (jumped) return
        // 万象书屋: 已 destroyed 的 Activity 调 startActivity 会抛 IllegalStateException, 直接 return
        if (isFinishing || isDestroyed) {
            jumped = true
            return
        }
        jumped = true
        LogUtils.d(TAG, "splash done, jump to MainActivity")
        runCatching {
            startActivity(Intent(this, MainActivity::class.java).apply {
                // 把传给我们的 deeplink/extras 透传给 Main, 复用现有外部入口逻辑
                intent?.data?.let { data = it }
                intent?.extras?.let { putExtras(it) }
            })
        }.onFailure { LogUtils.d(TAG, "startActivity MainActivity failed: ${it.message}") }
        finish()
        overridePendingTransition(0, 0)
    }

    companion object {
        private const val TAG = "SplashAd"
        private const val STATE_JUMPED = "jumped"
        private const val STATE_CONSENT_RESOLVED = "consentResolved"
        private const val STATE_AD_SHOWING = "adShowing"
    }
}
