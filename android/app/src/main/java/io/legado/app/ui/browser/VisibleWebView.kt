package io.legado.app.ui.browser

import android.content.Context
import android.util.AttributeSet
import android.view.View
import android.webkit.WebView

/**
 * 万象书屋: WebView 子类, 强制 onWindowVisibilityChanged 走 VISIBLE 让后台 hide 不让
 * WebView 暂停 JS / 网络. 给 WebViewActivity 用 (反爬 challenge / 章节内嵌外链).
 *
 * 原 io.legado.app.ui.rss.read.VisibleWebView, RSS 整套下线后迁到 ui.browser 包.
 */
class VisibleWebView(
    context: Context,
    attrs: AttributeSet? = null
) : WebView(context, attrs) {

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(View.VISIBLE)
    }

}
