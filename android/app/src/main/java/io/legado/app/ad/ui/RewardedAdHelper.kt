package io.legado.app.ad.ui

import android.app.Activity
import android.app.AlertDialog
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import io.legado.app.R
import io.legado.app.ad.AdConsent
import io.legado.app.ad.AdManager
import io.legado.app.ad.AdRateLimiter
import io.legado.app.ad.AdRepository
import io.legado.app.utils.toastOnUi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 阅读器内"看广告解锁纯净阅读" 触发器.
 *
 * 由 ReadBookActivity 在合适时机 (例如 onResume / 翻页结束) 调用 [tryPrompt].
 * 自身完成所有节奏判断 + 隐私态判断 + 弹框 + Lifecycle 安全收尾.
 */
object RewardedAdHelper {

    /**
     * 尝试弹"看广告解锁 30min" 对话框.
     *
     * 调用方频率不限 (每帧也 OK), 不满足节奏 / 没有同意 / 远端关位 都会安静返回.
     */
    fun tryPrompt(activity: Activity) {
        if (activity.isFinishing || activity.isDestroyed) return
        if (!AdConsent.isGranted()) return
        val cfg = AdRepository.current().config
        val rwd = cfg.placements.rewardedReadingUnlock
        if (cfg.effectivelyDisabled() || !rwd.enabled) return
        if (!AdRateLimiter.canPromptRewarded(rwd.cooldownMinutes)) return
        // 必须确认确实有可用 provider, 否则别白弹
        if (AdManager.pickProvider(io.legado.app.ad.AdPlacement.RewardedReadingUnlock) == null) return

        AdRateLimiter.markPrompted()
        AlertDialog.Builder(activity)
            .setTitle(R.string.ad_rewarded_title)
            .setMessage(activity.getString(R.string.ad_rewarded_message, rwd.unlockMinutes))
            .setPositiveButton(R.string.ad_rewarded_watch) { d, _ ->
                d.dismiss()
                playRewardedSafely(activity, rwd.unlockMinutes)
            }
            .setNegativeButton(R.string.ad_rewarded_skip) { d, _ -> d.dismiss() }
            .setCancelable(true)
            .show()
    }

    private fun playRewardedSafely(activity: Activity, unlockMinutes: Int) {
        // 用 lifecycleScope 把成功回调绑死在当前 Activity, 防止 Activity destroy 后仍触发奖励逻辑
        val owner = activity as? LifecycleOwner
        AdManager.loadAndShowRewarded(
            activity,
            onSkipped = {
                // 加载失败 / 用户中途退出: 给个简短反馈, 不解锁
                if (activity.isFinishing) return@loadAndShowRewarded
                activity.runOnUiThread { activity.toastOnUi(R.string.ad_rewarded_failed) }
            },
            onRewarded = {
                if (owner == null || owner.lifecycle.currentState == Lifecycle.State.DESTROYED) return@loadAndShowRewarded
                owner.lifecycleScope.launch {
                    // 让 SDK 关闭动画走完, 再 toast 提示
                    delay(150)
                    AdRateLimiter.markRewardedSuccess(unlockMinutes)
                    activity.toastOnUi(activity.getString(R.string.ad_rewarded_unlocked, unlockMinutes))
                }
            }
        )
    }
}
