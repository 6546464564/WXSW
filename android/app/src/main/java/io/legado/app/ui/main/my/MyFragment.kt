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
import io.legado.app.utils.getPrefString
import io.legado.app.utils.putPrefString
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

            // 万象书屋 D-18: 主题模式 UI 简化为 "跟随系统" 开关.
            //   开 -> themeMode = "0"  (跟随系统)
            //   关 -> themeMode = "1"  (强制亮色)
            //   旧 SP 里 themeMode == "2" 暗色 / "3" EInk 仍合法, 这里同步 UI 初始状态.
            val themeFollowPref =
                findPreference<androidx.preference.SwitchPreferenceCompat>(PreferKey.themeFollowSystem)
            themeFollowPref?.let { sw ->
                // 初始化 UI: 旧 themeMode 为 "0" 时默认开, 其它 ("1"/"2"/"3") 默认关
                val curMode = requireContext().getPrefString(PreferKey.themeMode, "0")
                sw.isChecked = curMode == "0"
                sw.setOnPreferenceChangeListener { _, newValue ->
                    val follow = newValue as Boolean
                    requireContext().putPrefString(
                        PreferKey.themeMode,
                        if (follow) "0" else "1"
                    )
                    view?.post { ThemeConfig.applyDayNight(requireContext()) }
                    true
                }
            }

            // 万象书屋 D-18: 护眼模式开关. 切换时不需要 recreate, 直接重 apply 当前 Activity overlay
            // 即可立即生效 (无闪屏). EyeCareHelper.apply 是幂等的, 读 SP 决定加/移除 overlay.
            findPreference<androidx.preference.SwitchPreferenceCompat>(PreferKey.eyeCareMode)
                ?.setOnPreferenceChangeListener { _, _ ->
                    view?.post {
                        // SwitchPreferenceCompat 在 listener return true 后才更新 SP, 这里 post 确保 SP 已写
                        activity?.let { io.legado.app.help.EyeCareHelper.apply(it) }
                    }
                    true
                }

            // 万象书屋: "我的" 页运营精简模式. 默认只保留 3 项:
            //   themeMode  - 主题模式
            //   readRecord - 阅读记录
            //   legal_feedback - 意见反馈
            //
            // !! 上架合规警告: 下面这一份"隐藏列表"里的 5 个 legal_* 项是
            //    《App 个人信息保护合规审核指南 2025》强制要求的入口,正式
            //    提交国内应用商店审核前必须把对应行删掉/或全表清空, 否则
            //    会以"未提供隐私政策入口/账号注销渠道"等理由被拒审.
            //    legal_privacy / legal_user_agreement / legal_collect_list
            //    / legal_sdk_list / legal_account_delete - 这 5 个一定要恢复.
            val hiddenKeys = listOf(
                "txtTocRuleManage",       // txt 目录规则
                "replaceManage",          // 替换净化
                "dictRuleManage",         // 词典规则
                "setting",                // 其他设置
                "fileManage",             // 文件管理
                "theme_setting",          // 主题设置 (D-17: 用户要求隐藏, 主题模式已含核心切换功能)
                "bookmark",               // 书签 (D-17: 用户要求隐藏)
                "legal_about",            // 关于
                "legal_privacy",          // 隐私政策          [上架必备]
                "legal_user_agreement",   // 用户协议          [上架必备]
                "legal_collect_list",     // 个人信息收集清单  [上架必备]
                "legal_sdk_list",         // 第三方 SDK 列表   [上架必备]
                "legal_open_source",      // 开源信息
                "legal_account_delete",   // 账号注销          [上架必备]
            )
            hiddenKeys.forEach { findPreference<Preference>(it)?.isVisible = false }

            // 万象书屋: 三个分组标题全部清空, 视觉扁平化 (跟运营要求一致 - 5 项扁平排列,
            // 不要"设置 / 其它 / 关于 法律"这种分类标签). 只保留分类内的 children 显示.
            findPreference<androidx.preference.PreferenceCategory>("settingCategory")?.title = ""
            findPreference<androidx.preference.PreferenceCategory>("aboutCategory")?.title = ""
            findPreference<androidx.preference.PreferenceCategory>("legalCategory")?.title = ""
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