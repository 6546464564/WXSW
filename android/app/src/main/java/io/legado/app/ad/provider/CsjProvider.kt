package io.legado.app.ad.provider

import android.app.Activity
import android.content.Context
import android.os.Bundle
import android.view.ViewGroup
import com.bytedance.sdk.openadsdk.AdSlot
import com.bytedance.sdk.openadsdk.CSJAdError
import com.bytedance.sdk.openadsdk.CSJSplashAd
import com.bytedance.sdk.openadsdk.TTAdConfig
import com.bytedance.sdk.openadsdk.TTAdLoadType
import com.bytedance.sdk.openadsdk.TTAdNative
import com.bytedance.sdk.openadsdk.TTAdSdk
import com.bytedance.sdk.openadsdk.TTFullScreenVideoAd
import com.bytedance.sdk.openadsdk.TTRewardVideoAd
import io.legado.app.ad.AdProvider
import io.legado.app.utils.LogUtils
import java.util.Collections
import java.util.WeakHashMap

/**
 * 万象书屋: 穿山甲 (CSJ / Pangle) 真实接入.
 *
 * 接入版本: open_ad_sdk 7.x (zip 中带的版本).
 * 用法对齐 demo `CSJSplashActivity` / `RewardVideoActivity`, 略.
 *
 * SDK 状态:
 *   - [available] 在 [init] 成功 (TTAdSdk.start 回调) 才置 true
 *   - 未 init 完成时 [loadSplashAd] / [loadRewardedAd] 直接 onError, 上层 fallback
 */
internal class CsjProvider : AdProvider {

    override val name: String = "csj"

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
            val cfg = TTAdConfig.Builder()
                .appId(appId)
                .appName("万象书屋")
                .debug(false)
                .useMediation(false) // 后续接入 mediation 时改 true 并补打 ADN aar
                .build()
            TTAdSdk.init(appContext, cfg)
            TTAdSdk.start(object : TTAdSdk.Callback {
                override fun success() {
                    available = true
                    LogUtils.d(TAG, "TTAdSdk.start success, ready=${TTAdSdk.isSdkReady()}")
                }

                override fun fail(code: Int, msg: String?) {
                    available = false
                    // 万象书屋: 失败要把 initStarted 重置, 否则下次 bootstrap 同 appId 不会重试,
                    // 网络抖动导致一次 init 失败 → 整个进程内永远没广告.
                    initStarted = false
                    LogUtils.d(TAG, "TTAdSdk.start fail code=$code msg=$msg")
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
            listener.onError(-1, "csj not ready or empty posId")
            return
        }
        LogUtils.d(TAG, "loadSplashAd posId=$posId timeoutMs=$timeoutMs")
        runCatching {
            val ttAdNative: TTAdNative = TTAdSdk.getAdManager().createAdNative(activity)
            val dm = activity.resources.displayMetrics
            val widthPx = dm.widthPixels
            val heightPx = dm.heightPixels
            val widthDp = widthPx / dm.density
            val heightDp = heightPx / dm.density
            val adSlot = AdSlot.Builder()
                .setCodeId(posId)
                .setExpressViewAcceptedSize(widthDp, heightDp)
                .setImageAcceptedSize(widthPx, heightPx)
                .build()
            ttAdNative.loadSplashAd(adSlot, object : TTAdNative.CSJSplashAdListener {
                override fun onSplashLoadSuccess(ad: CSJSplashAd?) {
                    LogUtils.d(TAG, "splash loaded")
                }
                override fun onSplashLoadFail(error: CSJAdError?) {
                    val code = error?.code ?: -1
                    LogUtils.d(TAG, "splash load fail: $code ${error?.msg}")
                    // 万象书屋: CSJ 现在新流量主默认不发开屏代码位 (40006/40020 等),
                    // 自动 fallback 用「新插屏 (插屏全屏视频)」当伪开屏, 把它的 view 填进 ad_container.
                    // 这样配置里的 splash.csj.posId 即使填的是"新插屏"代码位, 流程仍然走通.
                    // 万象书屋: CSJ 7.x 新流量主默认不发开屏代码位, 调 splash API 会返:
                    //   40006 / 40016 / 40019 / 40020 = posId 类型不匹配 / 广告位不存在
                    // 自动 fallback 用「新插屏 (loadFullScreenVideoAd)」代替, 流程仍走通.
                    if (code == 40006 || code == 40020 || code == 40016 || code == 40019) {
                        LogUtils.d(TAG, "posId not splash type ($code), fallback to interstitial-as-splash")
                        loadInterstitialAsSplash(activity, ttAdNative, posId, widthDp, heightDp, listener)
                    } else {
                        listener.onError(code, error?.msg ?: "splash load fail")
                    }
                }
                override fun onSplashRenderSuccess(ad: CSJSplashAd?) {
                    if (ad == null) { listener.onError(-1, "ad null"); return }
                    // 万象书屋: SDK 异步回调可能晚于 Activity destroy, 此时 findViewById 拿不到 ad_container, 抛错.
                    if (activity.isFinishing || activity.isDestroyed) {
                        listener.onError(-3, "activity destroyed before render")
                        return
                    }
                    val container = runCatching { getContainerOrThrow(activity) }.getOrElse {
                        listener.onError(-3, "ad_container not found"); return
                    }
                    container.removeAllViews()
                    ad.setSplashAdListener(object : CSJSplashAd.SplashAdListener {
                        override fun onSplashAdShow(ad: CSJSplashAd?) {}
                        override fun onSplashAdClick(ad: CSJSplashAd?) {
                            // 万象书屋: 上报 click 事件 (CTR 计算用)
                            listener.onAdClicked()
                        }
                        override fun onSplashAdClose(ad: CSJSplashAd?, closeType: Int) {
                            LogUtils.d(TAG, "splash close type=$closeType")
                            listener.onAdClosed()
                        }
                    })
                    runCatching { ad.showSplashView(container) }
                        .onFailure { listener.onError(-2, "showSplashView crash: ${it.message}"); return }
                    listener.onAdReadyToShow(container) {}
                }
                override fun onSplashRenderFail(ad: CSJSplashAd?, error: CSJAdError?) {
                    LogUtils.d(TAG, "splash render fail: ${error?.code} ${error?.msg}")
                    listener.onError(error?.code ?: -1, error?.msg ?: "splash render fail")
                }
            }, timeoutMs)
        }.onFailure {
            LogUtils.d(TAG, "loadSplashAd crashed: ${it.message}")
            listener.onError(-2, it.message ?: "loadSplashAd crash")
        }
    }

    /**
     * CSJ 新流量主目前默认不发"开屏"代码位, 只能创建"新插屏 / 信息流 / Banner / 激励".
     * 这里用"新插屏 (loadFullScreenVideoAd)"当伪开屏: SDK 自带全屏弹窗样式,
     * 用户关闭后我们通知上层跳 Main.
     */
    private fun loadInterstitialAsSplash(
        activity: Activity,
        ttAdNative: TTAdNative,
        posId: String,
        @Suppress("UNUSED_PARAMETER") widthDp: Float,
        @Suppress("UNUSED_PARAMETER") heightDp: Float,
        listener: AdProvider.SplashAdListener
    ) {
        val adSlot = AdSlot.Builder()
            .setCodeId(posId)
            .setAdLoadType(TTAdLoadType.LOAD)
            .build()
        ttAdNative.loadFullScreenVideoAd(adSlot, object : TTAdNative.FullScreenVideoAdListener {
            override fun onError(code: Int, msg: String?) {
                LogUtils.d(TAG, "interstitial-as-splash load fail: $code $msg")
                listener.onError(code, msg ?: "interstitial-as-splash load fail")
            }
            override fun onFullScreenVideoAdLoad(ad: TTFullScreenVideoAd?) {
                if (ad == null) {
                    listener.onError(-1, "interstitial-as-splash null ad")
                    return
                }
                if (activity.isFinishing || activity.isDestroyed) {
                    listener.onError(-3, "activity destroyed before show")
                    return
                }
                ad.setFullScreenVideoAdInteractionListener(object :
                    TTFullScreenVideoAd.FullScreenVideoAdInteractionListener {
                    override fun onAdShow() { LogUtils.d(TAG, "interstitial-as-splash onAdShow") }
                    override fun onAdVideoBarClick() { listener.onAdClicked() }
                    override fun onAdClose() {
                        LogUtils.d(TAG, "interstitial-as-splash onAdClose")
                        listener.onAdClosed()
                    }
                    override fun onVideoComplete() {}
                    override fun onSkippedVideo() {}
                })
                LogUtils.d(TAG, "interstitial-as-splash loaded, showing")
                runCatching { ad.showFullScreenVideoAd(activity) }
                    .onFailure { listener.onError(-2, "showFullScreen crash: ${it.message}"); return }
                val container = runCatching { getContainerOrThrow(activity) }.getOrNull()
                if (container != null) listener.onAdReadyToShow(container) {}
            }
            override fun onFullScreenVideoCached() { /* deprecated */ }
            override fun onFullScreenVideoCached(ad: TTFullScreenVideoAd?) {
                // 缓存好后再展示更流畅; 如果 onFullScreenVideoAdLoad 已经触发, 这里跳过
                LogUtils.d(TAG, "interstitial-as-splash cached")
            }
        })
    }

    override fun loadRewardedAd(
        activity: Activity,
        posId: String,
        listener: AdProvider.RewardedAdListener
    ) {
        if (!available || posId.isBlank()) {
            listener.onError(-1, "csj not ready or empty posId")
            return
        }
        runCatching {
            val ttAdNative: TTAdNative = TTAdSdk.getAdManager().createAdNative(activity)
            val adSlot = AdSlot.Builder()
                .setCodeId(posId)
                .setAdLoadType(TTAdLoadType.LOAD)
                .setRewardName("纯净阅读")
                .setRewardAmount(1)
                .build()
            ttAdNative.loadRewardVideoAd(adSlot, object : TTAdNative.RewardVideoAdListener {
                override fun onError(code: Int, message: String?) {
                    listener.onError(code, message ?: "rewarded load fail")
                }
                override fun onRewardVideoAdLoad(ad: TTRewardVideoAd?) {
                    if (ad == null) { listener.onError(-1, "ad null"); return }
                    bindAndDeliver(ad, activity, listener)
                }
                override fun onRewardVideoCached() { /* deprecated 重载 */ }
                override fun onRewardVideoCached(ad: TTRewardVideoAd?) {
                    // 缓存好了再展示更流畅; 这里如果第一次 onRewardVideoAdLoad 已展示就忽略
                    if (ad != null) bindAndDeliver(ad, activity, listener)
                }
            })
        }.onFailure {
            LogUtils.d(TAG, "loadRewardedAd crashed: ${it.message}")
            listener.onError(-2, it.message ?: "loadRewardedAd crash")
        }
    }

    /**
     * 把"加载好"的激励视频与上层 listener 桥起来. 同一支广告只会兑现一次:
     * 第一次到达 (onAdLoaded 或 onRewardVideoCached) 直接 setup + show, 之后同一 ad 再回调直接忽略.
     *
     * 万象书屋: 用 module 级 WeakHashMap<ad, Boolean> 做真防重.
     * 之前版本的 `tag()` / `markDelivered()` 是 no-op, 防重失效, 导致 listener 被 set 两次.
     */
    private fun bindAndDeliver(
        ad: TTRewardVideoAd,
        activity: Activity,
        listener: AdProvider.RewardedAdListener
    ) {
        synchronized(deliveredAds) {
            if (deliveredAds.containsKey(ad)) return
            deliveredAds[ad] = true
        }
        ad.setRewardAdInteractionListener(object : TTRewardVideoAd.RewardAdInteractionListener {
            @Volatile private var rewarded = false
            override fun onAdShow() {}
            override fun onAdVideoBarClick() { listener.onAdClicked() }
            override fun onAdClose() { listener.onAdClosed() }
            override fun onVideoComplete() {}
            override fun onVideoError() {
                listener.onError(-3, "video error")
            }
            override fun onRewardVerify(verify: Boolean, amount: Int, name: String?, errCode: Int, errMsg: String?) {
                // 已废弃, 走 onRewardArrived
            }
            override fun onRewardArrived(isRewardValid: Boolean, rewardType: Int, extraInfo: Bundle?) {
                if (isRewardValid && !rewarded) {
                    rewarded = true
                    listener.onRewardVerified()
                }
            }
            override fun onSkippedVideo() { /* 用户跳过, 不算奖励 */ }
        })
        listener.onAdLoaded {
            // 万象书屋: Activity 已销毁时 showRewardVideoAd 抛 IllegalStateException,
            // 之前是 runCatching 静默吞掉, 用户进度条转圈到超时. 现在显式走 onError, 上层 dispatch(false) 保证回调.
            if (activity.isFinishing || activity.isDestroyed) {
                LogUtils.d(TAG, "show skipped: activity destroyed")
                listener.onError(-3, "activity destroyed before show")
                return@onAdLoaded
            }
            runCatching { ad.showRewardVideoAd(activity) }
                .onFailure {
                    LogUtils.d(TAG, "showRewardVideoAd crashed: ${it.message}")
                    listener.onError(-2, it.message ?: "show crash")
                }
        }
    }

    /**
     * SplashAdActivity 的 ad_container FrameLayout. 找不到就抛, 因为约定该位置必有.
     */
    private fun getContainerOrThrow(activity: Activity): ViewGroup {
        val id = activity.resources.getIdentifier("ad_container", "id", activity.packageName)
        return activity.findViewById<ViewGroup>(id)
            ?: error("SplashAdActivity has no @id/ad_container")
    }

    companion object {
        private const val TAG = "AdCsj"
        /**
         * 已经派发过 listener 的广告对象. WeakHashMap 让 SDK 广告对象被回收时自动清,
         * 不会长期持有内存. 同步访问因为 CSJ SDK 的回调可能跨线程.
         */
        private val deliveredAds: MutableMap<TTRewardVideoAd, Boolean> =
            Collections.synchronizedMap(WeakHashMap())
    }
}
