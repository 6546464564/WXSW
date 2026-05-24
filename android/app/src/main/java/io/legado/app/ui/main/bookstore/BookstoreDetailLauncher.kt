package io.legado.app.ui.main.bookstore

import android.content.Context
import io.legado.app.ui.book.info.BookInfoActivity
import io.legado.app.utils.startActivity

/**
 * 万象书屋: 书城 → 详情 stub 启动器 (跟 iOS BookStoreView.tapBookCell → BookDetailView 对齐).
 *
 * stub 模式: origin 空 + 临时 bookUrl → BookInfoViewModel 后台 resolveSourceIfNeeded.
 * feed 有 source_origin + target_url 时直接带真源进详情.
 */
object BookstoreDetailLauncher {

    const val EXTRA_FROM_BOOKSTORE = "fromBookstore"
    const val EXTRA_COVER = "coverUrl"
    const val EXTRA_INTRO = "intro"
    const val EXTRA_KIND = "kind"
    const val EXTRA_WORD_COUNT = "wordCount"
    const val EXTRA_ORIGIN = "origin"
    const val EXTRA_ORIGIN_NAME = "originName"

    fun open(context: Context, book: QidianBook) {
        context.startActivity<BookInfoActivity> {
            putExtra("name", book.name)
            putExtra("author", book.author)
            putExtra(EXTRA_FROM_BOOKSTORE, true)
            putExtra(EXTRA_COVER, book.coverUrl)
            putExtra(EXTRA_INTRO, book.intro)
            putExtra(EXTRA_KIND, buildKind(book))
            putExtra(EXTRA_WORD_COUNT, book.wordCount)
            putExtra(EXTRA_ORIGIN_NAME, "起点书城")
        }
    }

    fun open(context: Context, pick: BookstoreFeedPick) {
        context.startActivity<BookInfoActivity> {
            putExtra("name", pick.book.name)
            putExtra("author", pick.book.author)
            putExtra(EXTRA_FROM_BOOKSTORE, true)
            putExtra(EXTRA_COVER, pick.book.coverUrl)
            putExtra(EXTRA_INTRO, pick.book.intro)
            putExtra(EXTRA_KIND, pick.book.category)
            if (pick.targetURL.isNotBlank()) putExtra("bookUrl", pick.targetURL)
            if (pick.sourceOrigin.isNotBlank()) putExtra(EXTRA_ORIGIN, pick.sourceOrigin)
            putExtra(EXTRA_ORIGIN_NAME, "出版书城")
        }
    }

    fun buildKind(book: QidianBook): String {
        val tags = listOf(book.category, book.subCategory).filter { it.isNotBlank() }
        var kind = tags.joinToString(" · ")
        if (book.bookId.isNotEmpty()) {
            val marker = "qd:${book.bookId}"
            kind = if (kind.isEmpty()) marker else "$kind · $marker"
        }
        return kind
    }

    fun stubBookUrl(qidianId: String?, name: String): String {
        if (!qidianId.isNullOrBlank()) return "wanxiang://bookstore/stub/qd/$qidianId"
        return "wanxiang://bookstore/stub/${name.hashCode()}"
    }

    fun extractQidianId(kind: String?): String? {
        if (kind.isNullOrBlank()) return null
        for (part in kind.split('·').map { it.trim() }) {
            if (part.startsWith("qd:")) {
                val id = part.removePrefix("qd:").trim()
                if (id.isNotEmpty()) return id
            }
        }
        return null
    }
}
