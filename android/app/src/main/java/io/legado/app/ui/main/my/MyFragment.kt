package io.legado.app.ui.main.my

import android.content.SharedPreferences
import android.os.Bundle
import android.view.View
import androidx.lifecycle.lifecycleScope
import androidx.preference.Preference
import io.legado.app.R
import io.legado.app.ad.AdManager
import io.legado.app.ad.AdRateLimiter
import io.legado.app.ad.AdRepository
import io.legado.app.base.BaseFragment
import io.legado.app.constant.PreferKey
import io.legado.app.databinding.FragmentMyConfigBinding
import io.legado.app.help.config.ThemeConfig
import io.legado.app.lib.prefs.NameListPreference
import io.legado.app.lib.prefs.fragment.PreferenceFragment
import io.legado.app.lib.theme.primaryColor
import io.legado.app.ui.about.AccountDeleteActivity
import io.legado.app.ui.about.FeedbackActivity
import io.legado.app.ui.about.LegalActivity
import io.legado.app.ui.about.ReadRecordActivity
import io.legado.app.ui.book.bookmark.AllBookmarkActivity
import io.legado.app.ui.book.toc.rule.TxtTocRuleActivity
import io.legado.app.ui.config.ConfigActivity
import io.legado.app.ui.config.ConfigTag
import io.legado.app.ui.dict.rule.DictRuleActivity
import io.legado.app.ui.file.FileManageActivity
import io.legado.app.ui.main.MainFragmentInterface
import io.legado.app.ui.replace.ReplaceRuleActivity
import io.legado.app.utils.LogUtils
import io.legado.app.utils.setEdgeEffectColor
import io.legado.app.utils.startActivity
import io.legado.app.utils.toastOnUi
import io.legado.app.utils.viewbindingdelegate.viewBinding
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class MyFragment() : BaseFragment(R.layout.fragment_my_config), MainFragmentInterface {

    constructor(position: Int) : this() {
        val bundle = Bundle()
        bundle.putInt("position", position)
        arguments = bundle
    }

    override val position: Int? get() = arguments?.getInt("position")

    private val binding by viewBinding(FragmentMyConfigBinding::bind)
    private var unlockCardJob: Job? = null

    override fun onFragmentCreated(view: View, savedInstanceState: Bundle?) {
        setSupportToolbar(binding.titleBar.toolbar)
        val fragmentTag = "prefFragment"
        var preferenceFragment = childFragmentManager.findFragmentByTag(fragmentTag)
        if (preferenceFragment == null) preferenceFragment = MyPreferenceFragment()
        childFragmentManager.beginTransaction()
            .replace(R.id.pre_fragment, preferenceFragment, fragmentTag).commit()
    }

    override fun onResume() {
        super.onResume()
        // 万象书屋: 启动纯净阅读状态卡更新, 每秒一次. 不在解锁窗口或全局禁用时卡片自动隐藏.
        startUnlockCardUpdater()
    }

    override fun onPause() {
        super.onPause()
        unlockCardJob?.cancel()
        unlockCardJob = null
    }

    private fun startUnlockCardUpdater() {
        unlockCardJob?.cancel()
        unlockCardJob = lifecycleScope.launch {
            while (isActive) {
                refreshUnlockCard()
                // 万象书屋 D-13 修复: 只有真的有倒计时变化时才每秒刷新, 否则间隔放大到 5s.
                // 解锁窗口内剩余时间 / 冷却倒计时都按秒变化, 这两种情况才需 1s 刷新文案.
                // 闲置场景 (无解锁 + 无冷却) 5s 一次, 减少电池/CPU.
                val cfg = AdRepository.current().config
                val rwd = cfg.placements.rewardedReadingUnlock
                val needFastRefresh = AdRateLimiter.remainingUnlockMs() > 0 ||
                    AdRateLimiter.secondsUntilNextRewardedAllowed(rwd.cooldownSec) > 0
                delay(if (needFastRefresh) 1000 else 5000)
            }
        }
    }

    private fun refreshUnlockCard() {
        val cfg = AdRepository.current().config
        val rwd = cfg.placements.rewardedReadingUnlock
        if (!rwd.enabled || cfg.effectivelyDisabled() || !AdManager.isConsented()) {
            binding.cardUnlockStatus.visibility = View.GONE
            return
        }
        val remainMs = AdRateLimiter.remainingUnlockMs()
        if (remainMs <= 0) {
            // 卡片显示但提示"暂无解锁时长", 用户可以主动看广告获取
            binding.cardUnlockStatus.visibility = View.VISIBLE
            binding.tvUnlockCardRemaining.text = getString(R.string.unlock_card_remaining_zero)
        } else {
            binding.cardUnlockStatus.visibility = View.VISIBLE
            binding.tvUnlockCardRemaining.text =
                getString(R.string.unlock_card_remaining, formatHms(remainMs))
        }

        val cooldownLeft = AdRateLimiter.secondsUntilNextRewardedAllowed(rwd.cooldownSec)
        if (cooldownLeft > 0) {
            binding.btnUnlockCardExtend.text =
                getString(R.string.unlock_card_button_cooldown, formatMs(cooldownLeft))
            binding.btnUnlockCardExtend.alpha = 0.5f
            binding.btnUnlockCardExtend.isEnabled = false
            binding.btnUnlockCardExtend.setOnClickListener(null)
        } else {
            binding.btnUnlockCardExtend.text =
                getString(R.string.unlock_card_button_extend, rwd.unlockMinutes)
            binding.btnUnlockCardExtend.alpha = 1.0f
            binding.btnUnlockCardExtend.isEnabled = true
            binding.btnUnlockCardExtend.setOnClickListener {
                val act = activity ?: return@setOnClickListener
                AdManager.loadAndShowRewarded(act,
                    onSkipped = { /* 静默 */ },
                    onRewarded = {
                        AdRateLimiter.markRewardedSuccess(rwd.unlockMinutes, rwd.maxAccumulatedMinutes)
                        val totalMs = AdRateLimiter.remainingUnlockMs()
                        act.toastOnUi(
                            getString(R.string.unlock_extended_toast, rwd.unlockMinutes, formatHms(totalMs))
                        )
                        refreshUnlockCard()
                    }
                )
            }
        }
    }

    private fun formatHms(ms: Long): String {
        val totalSec = (ms / 1000).coerceAtLeast(0)
        val h = totalSec / 3600
        val m = (totalSec % 3600) / 60
        val s = totalSec % 60
        return if (h > 0) "${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}"
        else "${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}"
    }

    private fun formatMs(seconds: Long): String {
        val m = seconds / 60
        val s = seconds % 60
        return "${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}"
    }

    /**
     * 配置
     */
    class MyPreferenceFragment : PreferenceFragment(),
        SharedPreferences.OnSharedPreferenceChangeListener {

        override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?) {
            addPreferencesFromResource(R.xml.pref_main)
            findPreference<NameListPreference>(PreferKey.themeMode)?.let {
                it.setOnPreferenceChangeListener { _, _ ->
                    view?.post { ThemeConfig.applyDayNight(requireContext()) }
                    true
                }
            }
        }

        override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
            super.onViewCreated(view, savedInstanceState)
            listView.setEdgeEffectColor(primaryColor)
        }

        override fun onResume() {
            super.onResume()
            preferenceManager.sharedPreferences?.registerOnSharedPreferenceChangeListener(this)
        }

        override fun onPause() {
            preferenceManager.sharedPreferences?.unregisterOnSharedPreferenceChangeListener(this)
            super.onPause()
        }

        override fun onSharedPreferenceChanged(
            sharedPreferences: SharedPreferences?,
            key: String?
        ) {
            when (key) {
                "recordLog" -> LogUtils.upLevel()
            }
        }

        override fun onPreferenceTreeClick(preference: Preference): Boolean {
            when (preference.key) {
                "replaceManage" -> startActivity<ReplaceRuleActivity>()
                "dictRuleManage" -> startActivity<DictRuleActivity>()
                "txtTocRuleManage" -> startActivity<TxtTocRuleActivity>()
                "bookmark" -> startActivity<AllBookmarkActivity>()
                "setting" -> startActivity<ConfigActivity> {
                    putExtra("configTag", ConfigTag.OTHER_CONFIG)
                }

                "theme_setting" -> startActivity<ConfigActivity> {
                    putExtra("configTag", ConfigTag.THEME_CONFIG)
                }

                "fileManage" -> startActivity<FileManageActivity>()
                "readRecord" -> startActivity<ReadRecordActivity>()

                // 万象书屋: 上架合规入口
                "legal_about" -> openLegal("legal/license.md", R.string.about_title)
                "legal_privacy" -> openLegal("legal/privacyPolicy.md", R.string.about_privacy_policy)
                "legal_user_agreement" -> openLegal("legal/userAgreement.md", R.string.about_user_agreement)
                "legal_collect_list" -> openLegal("legal/collectList.md", R.string.about_collect_list)
                "legal_sdk_list" -> openLegal("legal/sdkList.md", R.string.about_sdk_list)
                "legal_open_source" -> openLegal("legal/license.md", R.string.about_open_source)
                "legal_feedback" -> startActivity<FeedbackActivity>()
                "legal_account_delete" -> startActivity<AccountDeleteActivity>()
            }
            return super.onPreferenceTreeClick(preference)
        }

        private fun openLegal(file: String, titleRes: Int) {
            startActivity<LegalActivity> {
                putExtra(LegalActivity.EXTRA_FILE, file)
                putExtra(LegalActivity.EXTRA_TITLE, getString(titleRes))
            }
        }


    }
}