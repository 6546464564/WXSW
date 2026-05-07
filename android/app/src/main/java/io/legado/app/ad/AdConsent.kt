package io.legado.app.ad

import android.app.Activity
import android.content.Context
import androidx.appcompat.app.AlertDialog
import io.legado.app.R
import splitties.init.appCtx

/**
 * PIPL 强制要求: 接入会采集个人信息的三方 SDK 前, 必须取得用户的明示同意.
 *
 * 这里只做最小实现: 一次性弹窗, 用户明确点击「同意」后才标记同意态,
 * 之后 [AdManager] 才会去 init 真实 SDK / 拉远端配置.
 *
 * 同意态用 SP 持久化, key = ad_consent_v1; 想重置版本号即可重新弹.
 */
object AdConsent {

    private const val SP = "wanxiang_ad_consent"
    private const val KEY = "consent_v1"

    private val sp by lazy {
        appCtx.getSharedPreferences(SP, Context.MODE_PRIVATE)
    }

    fun isGranted(): Boolean = sp.getBoolean(KEY, false)

    /**
     * 在指定 Activity 上弹一次同意对话框.
     *
     * @param onResult 用户点同意 -> true; 拒绝 / 取消 -> false. 回调在主线程.
     *
     * 已经同意过的, 直接 onResult(true) 不再打扰.
     */
    fun ensureConsent(activity: Activity, onResult: (Boolean) -> Unit) {
        if (isGranted()) { onResult(true); return }
        AlertDialog.Builder(activity)
            .setTitle(R.string.ad_consent_title)
            .setMessage(R.string.ad_consent_message)
            .setCancelable(false)
            .setPositiveButton(R.string.ad_consent_agree) { d, _ ->
                d.dismiss()
                sp.edit().putBoolean(KEY, true).apply()
                onResult(true)
            }
            .setNegativeButton(R.string.ad_consent_disagree) { d, _ ->
                d.dismiss()
                onResult(false)
            }
            .show()
    }

    /**
     * "撤回同意" 入口 (设置里可调).
     * 万象书屋: 撤回后必须立即同步通知 AdManager 翻 consented=false,
     * 否则进程内 AdManager 还会调 reportAdEvent 上报 deviceId, 隐私违规.
     */
    fun revoke() {
        sp.edit().putBoolean(KEY, false).apply()
        AdManager.setConsent(appCtx, false)
    }

    /** 在设置里"重新授权"时调用, 等价于用户主动点同意框的"同意". */
    fun grantForUser() {
        sp.edit().putBoolean(KEY, true).apply()
        AdManager.setConsent(appCtx, true)
    }
}
