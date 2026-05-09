package io.legado.app.lib.theme.view

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.util.AttributeSet
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.core.view.ViewCompat
import com.google.android.material.bottomnavigation.BottomNavigationView
import androidx.core.content.ContextCompat
import io.legado.app.R
import io.legado.app.databinding.ViewNavigationBadgeBinding
import io.legado.app.help.config.AppConfig
import io.legado.app.lib.theme.Selector
import io.legado.app.lib.theme.ThemeStore
import io.legado.app.lib.theme.bottomBackground
import io.legado.app.lib.theme.getSecondaryTextColor
import io.legado.app.ui.widget.text.BadgeView
import io.legado.app.utils.ColorUtils

class ThemeBottomNavigationVIew(context: Context, attrs: AttributeSet) :
    BottomNavigationView(context, attrs) {

    init {
        val bgColor = context.bottomBackground
        setBackgroundColor(bgColor)
        val textIsDark = ColorUtils.isColorLight(bgColor)
        val textColor = context.getSecondaryTextColor(textIsDark)
        // 万象书屋: 底部导航选中色统一用品牌主色 (wanxiang_brand_primary),
        //   不再用 accentColor (ThemeStore 里可能被用户改成偏淡的色,
        //   导致选中态和默认态视觉差异不足).
        //   icon/label 同色 + bold 字重, 提升导航 affordance.
        val activeColor = ContextCompat.getColor(context, R.color.wanxiang_brand_primary)
        val colorStateList = Selector.colorBuild()
            .setDefaultColor(textColor)
            .setSelectedColor(activeColor).create()
        itemIconTintList = colorStateList
        itemTextColor = colorStateList

        if (AppConfig.isEInkMode) {
            isItemHorizontalTranslationEnabled = false
            itemBackground = ColorDrawable(Color.TRANSPARENT)
        }

        ViewCompat.setOnApplyWindowInsetsListener(this, null)
    }

    fun addBadgeView(index: Int): BadgeView {
        //获取底部菜单view
        val menuView = getChildAt(0) as ViewGroup
        //获取第index个itemView
        val itemView = menuView.getChildAt(index) as ViewGroup
        val badgeBinding = ViewNavigationBadgeBinding.inflate(LayoutInflater.from(context))
        itemView.addView(badgeBinding.root)
        return badgeBinding.viewBadge
    }

}