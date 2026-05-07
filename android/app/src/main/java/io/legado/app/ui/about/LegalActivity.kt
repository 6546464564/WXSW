package io.legado.app.ui.about

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.Toolbar
import androidx.core.view.isVisible
import androidx.lifecycle.lifecycleScope
import io.legado.app.R
import io.legado.app.databinding.ActivityLegalBinding
import io.legado.app.utils.viewbindingdelegate.viewBinding
import io.noties.markwon.Markwon
import io.noties.markwon.ext.tables.TablePlugin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 万象书屋: 法律 / 合规文档展示页.
 *
 * 通过 Intent extra 决定加载哪个文档:
 *   - LegalActivity.EXTRA_FILE = "legal/privacyPolicy.md"
 *   - LegalActivity.EXTRA_TITLE 显示在 toolbar
 *
 * 渲染策略: 用 Markwon (commonmark + table 扩展) 把 assets 里的 markdown
 * 渲染成富文本: 标题分级 / 表格 / 加粗 / 列表 / 链接全部正确显示.
 */
class LegalActivity : AppCompatActivity() {

    companion object {
        const val EXTRA_FILE = "legal_file"
        const val EXTRA_TITLE = "legal_title"
    }

    private val binding by viewBinding(ActivityLegalBinding::inflate)

    private val markwon by lazy {
        Markwon.builder(this)
            .usePlugin(TablePlugin.create(this))
            .build()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar as Toolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        val title = intent.getStringExtra(EXTRA_TITLE) ?: getString(R.string.about_title)
        supportActionBar?.title = title

        val file = intent.getStringExtra(EXTRA_FILE)
        // 万象书屋: 路径白名单, 防止 Intent 被恶意构造去读 assets 别处文件 (虽然 exported=false 风险已小)
        if (file.isNullOrBlank() || !file.startsWith("legal/") || file.contains("..")) {
            binding.textView.setText(R.string.legal_load_failed)
            return
        }
        loadContent(file)
    }

    private fun loadContent(path: String) {
        binding.progress.isVisible = true
        lifecycleScope.launch {
            val text = withContext(Dispatchers.IO) {
                runCatching {
                    assets.open(path).bufferedReader(Charsets.UTF_8).use { it.readText() }
                }.getOrNull()
            }
            binding.progress.isVisible = false
            if (text == null) {
                binding.textView.setText(R.string.legal_load_failed)
                return@launch
            }
            // Markwon 在主线程把 markdown 解析 + 应用到 TextView. 35KB 的 LICENSE 也只需 ~30ms.
            markwon.setMarkdown(binding.textView, text)
        }
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }
}
