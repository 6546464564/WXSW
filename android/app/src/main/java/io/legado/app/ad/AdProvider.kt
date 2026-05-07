package io.legado.app.ad

import android.app.Activity
import android.view.ViewGroup

/**
 * 广告 SDK 适配器抽象.
 *
 * 业务代码只面向这个接口编程, 不直接 import 任何 SDK 类型.
 *
 * 设计要点:
 *   - SDK init / load / show 都允许失败, 失败必须走对应的 *Listener.onError
 *     而不是抛异常, 防止把崩溃抛回业务层.
 *   - 同一个广告位的"加载"和"展示"分两步, 让上层有机会做超时/取消.
 *   - 不假设 SDK 是否真的进了 APK: 实现方在 init 时如果 classpath 缺类, 直接置 [available] = false.
 */
interface AdProvider {

    /** SDK 名: "csj" / "ylh" / "ks" / "stub" */
    val name: String

    /**
     * 当前进程内 SDK 是否可用 (init 成功 + classpath 存在).
     * 由 [init] 内部决定, 失败请保持 false.
     */
    val available: Boolean

    /**
     * 异步初始化 SDK. 多次调用应当幂等; init 失败不抛, 静默置 available = false.
     */
    fun init(appContext: android.content.Context, appId: String)

    fun loadSplashAd(activity: Activity, posId: String, timeoutMs: Int, listener: SplashAdListener)

    fun loadRewardedAd(activity: Activity, posId: String, listener: RewardedAdListener)

    interface SplashAdListener {
        /** 拉到广告, 期望 provider 立刻在 [container] 中展示. provider 内部接管点击/跳过/超时. */
        fun onAdReadyToShow(container: ViewGroup, onFinished: () -> Unit)
        /** 用户点击广告内容 (CTA / 跳转 / 下载等). 关键转化指标, 用于计算 CTR. */
        fun onAdClicked() {}
        /** 用户跳过 / 倒计时结束 / 点击关闭等正常退出. 万象书屋: 不算 error, 不进熔断分母. */
        fun onAdClosed()
        fun onError(code: Int, msg: String)
    }

    interface RewardedAdListener {
        /** 视频已经准备好, 调用 [show] 立即播放. */
        fun onAdLoaded(show: () -> Unit)
        /** 用户点击广告内容 (CTA / 跳转 / 下载等). */
        fun onAdClicked() {}
        /** 用户完整看完了视频, 应当发奖励. */
        fun onRewardVerified()
        /** 视频从展示到关闭的全流程结束. */
        fun onAdClosed()
        fun onError(code: Int, msg: String)
    }
}
