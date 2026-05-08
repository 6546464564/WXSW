@file:Suppress("unused")

package io.legado.app.utils

import android.content.res.Configuration
import android.content.res.Resources

/**
 * 万象书屋 D-21 (#THEME-FOLLOW-ROOT): 之前是 top-level val, App 启动时只 evaluate 一次,
 * 系统切换 dark/light 后这个值不会更新, 导致 AppConfig.isNightTheme 永远停留在启动时的状态,
 * "跟随系统"主题模式实际不工作. 改成 getter, 每次读取最新 system Configuration.
 */
val sysConfiguration: Configuration
    get() = Resources.getSystem().configuration

val Configuration.isNightMode: Boolean
    get() {
        val mode = uiMode and Configuration.UI_MODE_NIGHT_MASK
        return mode == Configuration.UI_MODE_NIGHT_YES
    }