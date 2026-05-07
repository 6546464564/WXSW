package io.legado.app.ad.provider

import android.app.Activity
import android.content.Context
import android.view.ViewGroup
import io.legado.app.ad.AdProvider
import io.legado.app.utils.LogUtils

/**
 * 占位广告 Provider.
 *
 * 应用场景:
 *   - 开发期 / Debug 包: 没接真实 SDK, Stub 只打 log 不弹任何东西
 *   - 真实 SDK 反射检测失败 (用户没把 SDK aar 放进 libs/): fallback 到 Stub
 *
 * 这个类故意**永远** available = true, 但实际行为是立即 onError "unavailable",
 * 让上层知道"找不到任何能用的真实 SDK", 走 fallback (开屏直接进主界面 / 激励对话框不弹).
 */
internal class StubAdProvider(override val name: String = "stub") : AdProvider {

    override var available: Boolean = true
        private set

    override fun init(appContext: Context, appId: String) {
        LogUtils.d(TAG, "stub init (appId=$appId), no real SDK linked")
    }

    override fun loadSplashAd(
        activity: Activity,
        posId: String,
        timeoutMs: Int,
        listener: AdProvider.SplashAdListener
    ) {
        LogUtils.d(TAG, "stub loadSplashAd posId=$posId -> error (no SDK)")
        listener.onError(-1, "stub: no real SDK linked")
    }

    override fun loadRewardedAd(
        activity: Activity,
        posId: String,
        listener: AdProvider.RewardedAdListener
    ) {
        LogUtils.d(TAG, "stub loadRewardedAd posId=$posId -> error (no SDK)")
        listener.onError(-1, "stub: no real SDK linked")
    }

    companion object { private const val TAG = "AdStub" }
}
