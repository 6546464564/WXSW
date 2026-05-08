package io.legado.app.ui.about

import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.View
import androidx.appcompat.app.AppCompatActivity
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
 * 万象书屋: 意见反馈页 (双 tab: 我要反馈 / 反馈历史)
 *
 * 国内应用商店硬性要求所有 App 必须提供"用户内容投诉/举报"渠道,
 * 这里走自建后端 POST /api/feedback (deviceId + content + contact + type).
 *
 * 历史 tab 目前为占位,等后端 GET /api/feedback/mine 上线后再补 RecyclerView.
 *
 * type 字段后端兼容 bug/content/suggest/other; 新版 UI 不再让用户选,统一用 "suggest".
 */
class FeedbackActivity : AppCompatActivity() {

    private val binding by viewBinding(ActivityFeedbackBinding::inflate)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(binding.root)

        binding.btnBack.setOnClickListener { finish() }
        binding.tabSubmit.setOnClickListener { selectTab(submit = true) }
        binding.tabHistory.setOnClickListener { selectTab(submit = false) }
        binding.btnSubmit.setOnClickListener { submit() }

        binding.etContent.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                binding.tvCount.text = "${s?.length ?: 0}/$MAX_CONTENT"
            }
        })

        selectTab(submit = true)
    }

    private fun selectTab(submit: Boolean) {
        binding.pageSubmit.visibility = if (submit) View.VISIBLE else View.GONE
        binding.pageHistory.visibility = if (submit) View.GONE else View.VISIBLE

        val activeColor = 0xFF222222.toInt()
        val inactiveColor = 0xFF888888.toInt()
        val indicator = 0xFF1E88FF.toInt()
        val transparent = 0x00000000

        binding.tabSubmitText.setTextColor(if (submit) activeColor else inactiveColor)
        binding.tabSubmitIndicator.setBackgroundColor(if (submit) indicator else transparent)
        binding.tabHistoryText.setTextColor(if (!submit) activeColor else inactiveColor)
        binding.tabHistoryIndicator.setBackgroundColor(if (!submit) indicator else transparent)

        binding.tabSubmitText.paint.isFakeBoldText = submit
        binding.tabHistoryText.paint.isFakeBoldText = !submit
    }

    private fun submit() {
        if (!binding.btnSubmit.isEnabled) return

        val content = binding.etContent.text.toString().trim()
        val contact = binding.etContact.text.toString().trim()

        if (content.isEmpty()) {
            toastOnUi(R.string.feedback_content_required)
            return
        }
        if (content.length > MAX_CONTENT) {
            toastOnUi(R.string.feedback_too_long)
            return
        }
        if (contact.isEmpty()) {
            toastOnUi(R.string.feedback_contact_required)
            return
        }

        binding.btnSubmit.isEnabled = false
        lifecycleScope.launch {
            val ok = withContext(Dispatchers.IO) {
                WanxiangBackend.submitFeedback("suggest", content, contact)
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

    companion object {
        private const val MAX_CONTENT = 120
    }
}
