package io.legado.app.ad.provider

import android.app.Activity
import android.content.Context
import android.view.ViewGroup
import com.qq.e.ads.rewardvideo.RewardVideoAD
import com.qq.e.ads.rewardvideo.RewardVideoADListener
import com.qq.e.ads.splash.SplashAD
import com.qq.e.ads.splash.SplashADListener
import com.qq.e.comm.managers.GDTAdSdk
import com.qq.e.comm.managers.setting.GlobalSetting
import com.qq.e.comm.managers.status.SDKStatus
import com.qq.e.comm.util.AdError
import io.legado.app.ad.AdProvider
import io.legado.app.utils.LogUtils

/**
 * 万象书屋: 优量汇 (YLH / GDT, 4.680.1550) 真实接入.
 *
 * 4.560+ 起 GDTAdSdk.init 被废弃, 必须用 initWithoutStart + start.
 * SDKStatus.getIntegrationSDKVersion 验证 SDK 已 link.
 */
internal class YlhProvider : AdProvider {

    override val name: String = "ylh"

    @Volatile
    override var available: Boolean = false
        private set

    @Volatile private var initStarted = false
    @Volatile private var lastAppId: String = ""

    override fun init(appContext: Context, appId: String) {
        if (appId.isBlank()) {
            LogUtils.d(TAG, "init skipped: empty appId")
            return
        }
        if (available && appId == lastAppId) return
        if (initStarted && appId == lastAppId) return
        lastAppId = appId
        initStarted = true
        runCatching {
            // 4.680.1550 推荐设置, init 之前调
            runCatching { GlobalSetting.setEnableMediationTool(false) }
            runCatching { GlobalSetting.setEnableCollectAppInstallStatus(false) } // 隐私敏感, 默认关
            // initWithoutStart: 不会采集用户信息, 等 user-consent 后再 start
            GDTAdSdk.initWithoutStart(appContext, appId)
            GDTAdSdk.start(object : GDTAdSdk.OnStartListener {
                override fun onStartSuccess() {
                    available = true
                    LogUtils.d(TAG, "GDT start success, sdkVer=${SDKStatus.getIntegrationSDKVersion()}")
                }
                override fun onStartFailed(e: Exception?) {
                    available = false
                    // 万象书屋: 同 CSJ, 失败时重置 initStarted 让下次能重试
                    initStarted = false
                    LogUtils.d(TAG, "GDT start failed: ${e?.message}")
                }
            })
        }.onFailure {
            available = false
            initStarted = false
            LogUtils.d(TAG, "init crashed: ${it.message}")
        }
    }

    override fun loadSplashAd(
        activity: Activity,
        posId: String,
        timeoutMs: Int,
        listener: AdProvider.SplashAdListener
    ) {
        if (!available || posId.isBlank()) {
            listener.onError(-1, "ylh not ready or empty posId")
            return
        }
        LogUtils.d(TAG, "loadSplashAd posId=$posId timeout=${timeoutMs}ms")
        runCatching {
            // SplashAD 第 4 个参数 fetchDelay (ms): 0 = SDK 默认 (3000-5000),
            // 自定义需在 SDK 允许范围内 (3000~5000), 否则 SDK 内部 clamp.
            val fetchDelay = timeoutMs.coerceIn(3000, 5000)
            lateinit var splashAd: SplashAD
            splashAd = SplashAD(activity, posId, object : SplashADListener {
                override fun onADLoaded(expireTimestamp: Long) {
                    LogUtils.d(TAG, "onADLoaded, show in container")
                    if (activity.isFinishing || activity.isDestroyed) {
                        listener.onError(-3, "activity destroyed before show"); return
                    }
                    val container = runCatching { getContainerOrThrow(activity) }.getOrElse {
                        listener.onError(-3, "ad_container not found"); return
                    }
                    container.removeAllViews()
                    runCatching { splashAd.showAd(container) }
                        .onFailure { listener.onError(-2, "showAd crash: ${it.message}"); return }
                    listener.onAdReadyToShow(container) {}
                }
                override fun onNoAD(error: AdError?) {
                    LogUtils.d(TAG, "onNoAD: ${error?.errorCode} ${error?.errorMsg}")
                    listener.onError(error?.errorCode ?: -1, error?.errorMsg ?: "ylh splash no ad")
                }
                override fun onADPresent() { LogUtils.d(TAG, "onADPresent") }
                override fun onADExposure() {}
                override fun onADClicked() { listener.onAdClicked() }
                override fun onADTick(millis: Long) {}
                // 万象书屋: 用户跳过 / 倒计时结束 / 点击离开都走 onADDismissed - 算 close 不算 error
                override fun onADDismissed() {
                    LogUtils.d(TAG, "onADDismissed")
                    listener.onAdClosed()
                }
            }, fetchDelay)
            // **关键**: 4.680 起 fetchAndShowIn 已 private, 必须显式调 fetchAdOnly() 触发拉取,
            // 然后 onADLoaded 里再 showAd(container)
            splashAd.fetchAdOnly()
        }.onFailure {
            LogUtils.d(TAG, "loadSplashAd crashed: ${it.message}")
            listener.onError(-2, it.message ?: "ylh splash crash")
        }
    }

    override fun loadRewardedAd(
        activity: Activity,
        posId: String,
        listener: AdProvider.RewardedAdListener
    ) {
        if (!available || posId.isBlank()) {
            listener.onError(-1, "ylh not ready or empty posId")
            return
        }
        runCatching {
            // 万象书屋: 用 AtomicBoolean 保证 onReward 可能跨 SDK 线程的并发安全
            val rewardedFlag = java.util.concurrent.atomic.AtomicBoolean(false)
            lateinit var rvad: RewardVideoAD
            rvad = RewardVideoAD(activity, posId, object : RewardVideoADListener {
                override fun onADLoad() {
                    // 加载好, 等缓存或者直接 show
                    listener.onAdLoaded {
                        // 万象书屋: 跟 CSJ 一致, Activity destroy 后显式 onError 而非静默, 让上层 dispatch
                        if (activity.isFinishing || activity.isDestroyed) {
                            listener.onError(-3, "activity destroyed before show")
                            return@onAdLoaded
                        }
                        runCatching { rvad.showAD(activity) }
                            .onFailure { listener.onError(-2, it.message ?: "ylh show crash") }
                    }
                }
                override fun onVideoCached() { /* 已缓存, 可以更流畅展示 */ }
                override fun onADShow() {}
                override fun onADExpose() {}
                override fun onADClick() { listener.onAdClicked() }
                override fun onReward(map: MutableMap<String, Any>?) {
                    if (rewardedFlag.compareAndSet(false, true)) {
                        listener.onRewardVerified()
                    }
                }
                override fun onVideoComplete() {}
                override fun onADClose() { listener.onAdClosed() }
                override fun onError(error: AdError?) {
                    listener.onError(error?.errorCode ?: -1, error?.errorMsg ?: "ylh rewarded error")
                }
            }, true) // volumeOn=true 默认有声; 后续可由 Config 控制
            rvad.loadAD()
        }.onFailure {
            LogUtils.d(TAG, "loadRewardedAd crashed: ${it.message}")
            listener.onError(-2, it.message ?: "ylh rewarded crash")
        }
    }

    private fun getContainerOrThrow(activity: Activity): ViewGroup {
        val id = activity.resources.getIdentifier("ad_container", "id", activity.packageName)
        return activity.findViewById<ViewGroup>(id)
            ?: error("SplashAdActivity has no @id/ad_container")
    }

    companion object { private const val TAG = "AdYlh" }
}
