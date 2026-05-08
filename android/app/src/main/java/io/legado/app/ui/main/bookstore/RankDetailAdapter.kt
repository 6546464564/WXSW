package io.legado.app.ui.main.bookstore

import android.content.Context
import android.view.View
import android.view.ViewGroup
import io.legado.app.R
import io.legado.app.base.adapter.ItemViewHolder
import io.legado.app.base.adapter.RecyclerAdapter
import io.legado.app.databinding.ItemRankDetailBinding
import io.legado.app.help.glide.ImageLoader

/**
 * 万象书屋 D-22.1: 完整榜单 / 完本书库 列表 adapter.
 *
 * 列表项: 大封面 (左) + 书名 / 作者 / 分类 chip / 字数 / 简介 (右)
 * 排名: 1-3 用红色徽章, 4+ 灰色数字
 */
class RankDetailAdapter(
    context: Context,
    private val onBookClick: (QidianBook) -> Unit,
) : RecyclerAdapter<QidianBook, ItemRankDetailBinding>(context) {

    fun submit(books: List<QidianBook>) {
        setItems(books)
    }

    override fun getViewBinding(parent: ViewGroup): ItemRankDetailBinding {
        return ItemRankDetailBinding.inflate(inflater, parent, false)
    }

    override fun convert(
        holder: ItemViewHolder,
        binding: ItemRankDetailBinding,
        item: QidianBook,
        payloads: MutableList<Any>,
    ) {
        binding.run {
            // 万象书屋 D-22.4: 排名用列表位置 (1-N), 不用 item.rank.
            // 因为完本书库等场景把多个榜单合并 (each starts from 1), 用 item.rank 会出现 #14 后跟 #1 → #2.
            // 用 layoutPosition+1 保证列表里 1-50 连续递增, 跟用户对"排行榜"的视觉预期一致.
            val rank = holder.layoutPosition + 1
            tvRank.text = rank.toString()
            tvRank.setBackgroundResource(
                when (rank) {
                    1 -> R.drawable.bs_rank_badge_1
                    2 -> R.drawable.bs_rank_badge_2
                    3 -> R.drawable.bs_rank_badge_3
                    else -> R.drawable.bs_rank_badge_n
                }
            )
            tvName.text = item.name
            tvAuthor.text = item.author.ifBlank { context.getString(R.string.author) }
            // 分类 chip: 优先 subCat, 兜底 cat; 都空时隐藏
            val tagText = item.subCategory.ifBlank { item.category }
            if (tagText.isNotBlank()) {
                tvCategory.text = tagText
                tvCategory.visibility = View.VISIBLE
            } else {
                tvCategory.visibility = View.GONE
            }
            tvWordCount.text = item.wordCount.ifBlank { "" }
            tvWordCount.visibility =
                if (item.wordCount.isNotBlank()) View.VISIBLE else View.GONE

            // rankCount: "12.04万月票" / "7.08万推荐" — 部分榜单有
            tvRankCount.text = item.rankCount
            tvRankCount.visibility =
                if (item.rankCount.isNotBlank()) View.VISIBLE else View.GONE

            tvIntro.text = item.intro

            ImageLoader.load(context, item.coverUrl)
                .placeholder(R.drawable.bs_cover_placeholder)
                .error(R.drawable.bs_cover_placeholder)
                .into(ivCover)
        }
    }

    override fun registerListener(holder: ItemViewHolder, binding: ItemRankDetailBinding) {
        holder.itemView.setOnClickListener {
            getItem(holder.layoutPosition)?.let { onBookClick(it) }
        }
    }
}
