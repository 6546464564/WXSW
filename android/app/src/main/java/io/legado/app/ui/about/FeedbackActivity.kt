package io.legado.app.ui.about

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.Toolbar
import androidx.lifecycle.lifecycleScope
import io.legado.app.R
import io.legado.app.databinding.ActivityFeedbackBinding
import io.legado.app.help.WanxiangBackend
import io.legado.app.utils.toastOnUi
import io.legado.app.utils.viewbindingdelegate.viewBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 万象书屋: 反馈与举报页.
 * 国内应用商店硬性要求所有 App 必须提供"用户内容投诉/举报"渠道, 这里走自建后端.
 *
 * 类型:
 *   - bug: 应用 bug
 *   - content: 内容举报 (盗版 / 违规 / 色情 / 政治敏感)
 *   - suggest: 功能建议
 *   - other: 其他
 *
 * 不收集您的真实身份信息. 您可以选填邮箱用于回复, 不填我们也会在后台处理但无法回复您.
 */
class FeedbackActivity : AppCompatActivity() {

    private val binding by viewBinding(ActivityFeedbackBinding::inflate)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(binding.root)
        setSupportActionBar(binding.toolbar as Toolbar)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        supportActionBar?.title = getString(R.string.about_feedback)

        binding.btnSubmit.setOnClickListener { submit() }
    }

    private fun submit() {
        // 万象书屋: 立即 disable, 防止用户在校验弹 toast 的几十毫秒内连点多次发请求
        if (!binding.btnSubmit.isEnabled) return
        binding.btnSubmit.isEnabled = false

        val type = when (binding.radioGroupType.checkedRadioButtonId) {
            R.id.radioContent -> "content"
            R.id.radioSuggest -> "suggest"
            R.id.radioOther -> "other"
            else -> "bug"
        }
        val content = binding.etContent.text.toString().trim()
        val contact = binding.etContact.text.toString().trim()
        if (content.length < 5) {
            toastOnUi(R.string.feedback_too_short)
            binding.btnSubmit.isEnabled = true
            return
        }
        if (content.length > 2000) {
            toastOnUi(R.string.feedback_too_long)
            binding.btnSubmit.isEnabled = true
            return
        }
        lifecycleScope.launch {
            val ok = withContext(Dispatchers.IO) {
                WanxiangBackend.submitFeedback(type, content, contact)
            }
            if (ok) {
                toastOnUi(R.string.feedback_thanks)
                finish()
            } else {
                binding.btnSubmit.isEnabled = true
                toastOnUi(R.string.feedback_failed)
            }
        }
    }

    override fun onSupportNavigateUp(): Boolean { finish(); return true }
}
