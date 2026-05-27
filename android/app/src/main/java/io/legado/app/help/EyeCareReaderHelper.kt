package io.legado.app.help

import io.legado.app.help.config.ReadBookConfig
import io.legado.app.utils.getPrefInt
import io.legado.app.utils.putPrefInt
import splitties.init.appCtx

/**
 * 万象书屋 D-22: 护眼开关联动阅读排版 — 切羊皮纸预设.
 * 只改 readStyleSelect, 不动全局 themeMode.
 */
object EyeCareReaderHelper {

    private const val KEY_SAVED_STYLE = "wanxiang.eye_care.saved_read_style"

    fun onEyeCareEnabledChanged(enabled: Boolean) {
        if (enabled) {
            appCtx.putPrefInt(KEY_SAVED_STYLE, ReadBookConfig.readStyleSelect)
            // 预设2: 羊皮纸 / 夜间深灰 (#DDC090 / #3C3F43), 夜间变体仍跟用户全局主题
            ReadBookConfig.readStyleSelect = 2
        } else {
            val savedStyle = appCtx.getPrefInt(KEY_SAVED_STYLE, -1)
            if (savedStyle >= 0) {
                ReadBookConfig.readStyleSelect = savedStyle
            }
        }
    }
}
