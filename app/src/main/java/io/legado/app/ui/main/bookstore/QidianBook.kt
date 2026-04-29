package io.legado.app.ui.main.bookstore

/**
 * 书城内每个书目卡片仅显示「封面 + 书名」(用户要求)
 * 不包含作者/简介/字数等其他信息
 */
data class QidianBook(
    val name: String,
    val coverUrl: String,
)
