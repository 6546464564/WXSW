package io.legado.app.ui.about

import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
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
 * 万象书屋: 意见反馈页 (单页表单)
 *
 * 国内应用商店硬性要求所有 App 必须提供"用户内容投诉/举报"渠道,
 * 这里走自建后端 POST /api/feedback (deviceId + content + contact + type).
 *
 * type 字段后端兼容 bug/content/suggest/other; 新版 UI 统一用 "suggest".
 *
 * 反馈历史 tab 已下线 (后端无 GET /api/feedback/mine 接口, 用户也几乎不会回看).
 */
class FeedbackActivity : AppCompatActivity() {

    private val binding by viewBinding(ActivityFeedbackBinding::inflate)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(binding.root)

        binding.btnBack.setOnClickListener { finish() }
        binding.btnSubmit.setOnClickListener { submit() }

        binding.etContent.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                binding.tvCount.text = "${s?.length ?: 0}/$MAX_CONTENT"
            }
        })
    }

    private fun submit() {
        if (!binding.btnSubmit.isEnabled) return

        val content = binding.etContent.text.toString().trim()
        val contact = binding.etContact.text.toString().trim()

        if (content.isEmpty()) {
            toastOnUi(R.string.feedback_content_required)
            return
        }
        // 万象书屋 D-16 (L4): 后端要求 content >= 5 字符, 旧前端没校验, 输入 1~4 字提交后
        // 后端 400 + WanxiangBackend.submitFeedback 返 false → 用户看到模糊的"提交失败"
        // 不知道是什么原因. 前端在客户端就拦截 + 给具体提示.
        if (content.length < MIN_CONTENT) {
            toastOnUi(R.string.feedback_too_short)
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
        private const val MIN_CONTENT = 5     // 万象书屋 D-16 (L4): 与后端 db.recordFeedback 阈值一致
        private const val MAX_CONTENT = 120
    }
}
