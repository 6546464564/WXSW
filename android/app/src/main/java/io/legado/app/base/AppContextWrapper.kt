package io.legado.app.base

import android.annotation.SuppressLint
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import android.os.LocaleList
import io.legado.app.constant.PreferKey
import io.legado.app.utils.getPrefInt
import io.legado.app.utils.getPrefString
import io.legado.app.utils.sysConfiguration
import java.util.*


@Suppress("unused")
object AppContextWrapper {

    @SuppressLint("ObsoleteSdkInt")
    fun wrap(context: Context): Context {
        val resources: Resources = context.resources
        val configuration: Configuration = resources.configuration
        val targetLocale = getSetLocale(context)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            configuration.setLocale(targetLocale)
            configuration.setLocales(LocaleList(targetLocale))
        } else {
            @Suppress("DEPRECATION")
            configuration.locale = targetLocale
        }
        configuration.fontScale = getFontScale(context)
        return context.createConfigurationContext(configuration)
    }

    fun getFontScale(context: Context): Float {
        var fontScale = context.getPrefInt(PreferKey.fontScale) / 10f
        if (fontScale !in 0.8f..1.6f) {
            fontScale = sysConfiguration.fontScale
        }
        return fontScale
    }

    /**
     * 当前系统语言
     */
    @SuppressLint("ObsoleteSdkInt")
    private fun getSystemLocale(): Locale {
        val locale: Locale
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) { //7.0有多语言设置获取顶部的语言
            locale = sysConfiguration.locales.get(0)
        } else {
            @Suppress("DEPRECATION")
            locale = sysConfiguration.locale
        }
        return locale
    }

    /**
     * 当前App语言
     */
    @SuppressLint("ObsoleteSdkInt")
    private fun getAppLocale(context: Context): Locale {
        val locale: Locale
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            locale = context.resources.configuration.locales[0]
        } else {
            @Suppress("DEPRECATION")
            locale = context.resources.configuration.locale
        }
        return locale

    }

    /**
     * 当前设置语言
     *
     * 万象书屋: 默认锁定简体中文, 不再跟随系统.
     *   - 国内 App 标准做法 (微信 / 支付宝 / 网易云 / 起点 等都是这样).
     *   - 解决了 default values/strings.xml 里部分 key 直接写中文 + 部分 key
     *     是英文导致的"中英混杂"视觉 bug, 以及 values-zh 里缺翻译时英文 fallback
     *     的真 bug. 让中文用户在英文系统设备 (开发机, 海外华人) 上也是中文 UI.
     *   - 用户仍可在「我的 → 设置 → 语言」手动切到 English / 繁体, 设置写 SP 后
     *     当然依旧生效.
     */
    private fun getSetLocale(context: Context): Locale {
        // 万象书屋: "auto" 不再 = 跟系统, 改 = 简中. 用户没选过 (null/auto) 一律简中.
        // 想跟随系统得显式选 "system" (UI 现没该选项, 是给高级用户 / 调试用的隐藏值).
        return when (context.getPrefString(PreferKey.language)) {
            "zh" -> Locale.SIMPLIFIED_CHINESE
            "tw" -> Locale.TRADITIONAL_CHINESE
            "en" -> Locale.ENGLISH
            "system" -> getSystemLocale()
            else -> Locale.SIMPLIFIED_CHINESE
        }
    }

    /**
     * 判断App语言和设置语言是否相同
     */
    fun isSameWithSetting(context: Context): Boolean {
        val locale = getAppLocale(context)
        val language = locale.language
        val country = locale.country
        val pfLocale = getSetLocale(context)
        val pfLanguage = pfLocale.language
        val pfCountry = pfLocale.country
        return language == pfLanguage && country == pfCountry
    }

}