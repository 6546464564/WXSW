package io.legado.app.ad

import android.app.Activity
import android.content.Context
import android.view.ViewGroup
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import io.legado.app.ad.provider.CsjProvider
import io.legado.app.ad.provider.StubAdProvider
import io.legado.app.ad.provider.YlhProvider
import io.legado.app.help.WanxiangBackend
import io.legado.app.help.coroutine.Coroutine
import io.legado.app.utils.LogUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 广告统一调度入口.
 *
 * 责任划分:
 *   - [bootstrap] App 进程启动时调用一次, 拉远端配置 + 按需 init 三家 SDK
 *   - [showSplash] / [showRewardedReadingUnlock] 业务侧主动调用, 负责选 provider + 加载 + 展示
 *   - 频次 / 解锁状态由 [AdRateLimiter] 单独维护, 这里只负责"能不能展示这次"
 *
 * 不会做的事:
 *   - 不会强制弹出激励视频 (合规底线: 激励视频必须用户主动点)
 *   - 不会忽略远端 disabled 标志
 *   - 不会在用户没同意隐私政策时初始化任何 SDK (由调用方传 [hasConsent] 控制)
 */
object AdManager {

    private const val TAG = "AdManager"
    /**
     * 万象书屋: 开屏广告展示阶段硬兜底超时.
     *
     * 设为 180s (3 分钟) 仅用于防 SDK bug (回调不触发卡死), 正常情况下完全信任 SDK 的
     * onAdClosed. 之前设 30s 会切断 fallback 到 interstitial-as-splash 的广告
     * (CSJ 40019 后回退的全屏视频通常 30-60s, 30s 超时永远看不到完结).
     *
     * 关键: 一旦 SDK 调 onAdReadyToShow, SHOW_TIMEOUT_MS 就只是兜底, **不应该作为
     * 主流程**. 主流程是 SDK 的 onAdClosed/onError.
     */
    private const val SHOW_TIMEOUT_MS = 180_000L

    /**
     * 当前接入的 SDK 适配器 + 兜底 stub.
     *  - csj: 真实接入 (open_ad_sdk.aar 已在 app/libs/ad/)
     *  - ylh: 真实接入 (GDTSDK.unionNormal aar 已在 app/libs/ad/)
     *  - stub: 永远 unavailable, 用于 fallback
     *
     * 注: 远端配置里如果出现 name="ks"/"baidu" 等没在这里登记的 provider,
     * pickProvider 会因为找不到 available=true 的实例而自动跳过.
     */
    private val providers: Map<String, AdProvider> by lazy {
        mapOf(
            "csj" to CsjProvider(),
            "ylh" to YlhProvider(),
            "stub" to StubAdProvider(),
        )
    }

    @Volatile private var bootstrapped = false
    @Volatile private var consented = false

    // 万象书屋 D-6 修复: bootstrap 互斥, 防止多次 setConsent + bootstrap 并发触发
    // 多个 refreshFromRemote / initOnDemand 交错. 用 Mutex 单飞行.
    private val bootstrapMutex = kotlinx.coroutines.sync.Mutex()

    /**
     * 进程级初始化. 通常在 App.onCreate 之后、主界面冷启动时调用.
     *
     * @param hasConsent 用户是否已同意隐私政策. 未同意时**不**初始化任何三方 SDK,
     *   等用户在欢迎页 / 首启同意后再次调用 [bootstrap].
     *
     * 多次调用安全: 内部 Mutex 序列化, 同时多个 setConsent(true) 触发也只有一条 bootstrap 在跑.
     */
    fun bootstrap(appContext: Context, hasConsent: Boolean) {
        consented = hasConsent
        Coroutine.async {
            // 万象书屋 D-6 修复: 用 lock/unlock 取代 withLock { suspend block }, 避免
            // inline 推导问题 (kotlin 1.x mutex.withLock 的 lambda 推导 suspend context 不稳).
            bootstrapMutex.lock()
            try {
                val initial = AdRepository.current()
                initOnDemand(appContext, initial.config)
                if (AdRepository.shouldRefresh()) {
                    val refreshed = AdRepository.refreshFromRemote()
                    if (refreshed.version != initial.version) {
                        initOnDemand(appContext, refreshed.config)
                    }
                }
                bootstrapped = true
            } finally {
                bootstrapMutex.unlock()
            }
        }
    }

    /**
     * 同意态变化时调用 (如从隐私页返回后).
     * 万象书屋: 撤回时必须立刻让 pickProvider 返回 null + 阻断 reportAdEvent,
     * 由后端 ad-config 在下次拉取时根据 consent 决定是否 init SDK.
     * 已经 init 过的 SDK 实例不能"反 init", 但只要 consented=false,
     * pickProvider 永远返 null, 不会再触发任何展示/上报.
     */
    fun setConsent(appContext: Context, granted: Boolean) {
        consented = granted
        if (granted) bootstrap(appContext, true)
    }

    /** 万象书屋: WanxiangBackend / CrashHandler 上报前的隐私门, 一行检查即可. */
    fun isConsented(): Boolean = consented

    /**
     * 按云端权重路由出一个 provider + posId. 只在权重和 > 0 时返回, 否则 null.
     *
     * 万象书屋: 公平性. 之前只看 `provider.available` 过滤候选, 但 SDK init 是异步的,
     * 各家 SDK init 完成时间差几十~几百毫秒, 造成"先 ready 的家被独占选中"的不公.
     * 现在把"配置上有效"和"运行时 ready"分开:
     *   - 配置上 weight>0+posId 的 provider 都进入候选 (allCandidates)
     *   - 运行时 available 的子集 (readyCandidates) 才参与权重抽签
     *   - 但是当 ready 子集只有一家, 而配置上还有别的"未 ready", 上层应当再等一会
     *     (showSplash 轮询会自动重试). 这里只返回 readyCandidates 中按权重抽到的;
     *     如果想触发上层等待, 让上层判断 [allCandidatesReady].
     */
    fun pickProvider(placement: AdPlacement): Pair<AdProvider, String>? {
        val cfg = AdRepository.current().config
        if (cfg.effectivelyDisabled() || !consented) return null
        val placementCfg = when (placement) {
            AdPlacement.Splash -> cfg.placements.splash.takeIf { it.enabled }
                ?.let { it.providers to true }
            AdPlacement.RewardedReadingUnlock -> cfg.placements.rewardedReadingUnlock.takeIf { it.enabled }
                ?.let { it.providers to true }
        } ?: return null
        val candidates = placementCfg.first.filter {
            it.weight > 0 && it.posId.isNotBlank() && (providers[it.name]?.available == true)
        }
        if (candidates.isEmpty()) return null
        val totalWeight = candidates.sumOf { it.weight }
        if (totalWeight <= 0) return null
        var roll = (0 until totalWeight).random()
        for (c in candidates) {
            roll -= c.weight
            if (roll < 0) return providers[c.name]!! to c.posId
        }
        return providers[candidates.last().name]!! to candidates.last().posId
    }

    /**
     * 万象书屋: 当前 placement 在配置中**所有** weight>0 的 provider 是否都已 init ready.
     * showSplash 轮询用此判断"是不是值得再等一会让其他 SDK init 完". 用于公平选择.
     */
    private fun allCandidatesReady(placement: AdPlacement): Boolean {
        val cfg = AdRepository.current().config
        if (cfg.effectivelyDisabled() || !consented) return true
        val list = when (placement) {
            AdPlacement.Splash -> cfg.placements.splash.providers
            AdPlacement.RewardedReadingUnlock -> cfg.placements.rewardedReadingUnlock.providers
        }
        return list.filter { it.weight > 0 && it.posId.isNotBlank() }
            .all { providers[it.name]?.available == true }
    }

    /**
     * 在 [container] 中展示开屏广告. 强制开屏: 用户每次冷启动必看, 直到广告自然结束.
     *
     * 超时拆两段:
     *   - **加载超时** = splash.timeoutMs (5s): SDK 没拿到广告就 fallback 跳 MainActivity
     *   - **展示超时** = SHOW_TIMEOUT_MS (30s): 广告已经在播 (onAdReadyToShow 触发后),
     *     等用户看完 / 点跳过 / SDK 倒计时结束才走 onFinished. 30s 是兜底防 SDK 死锁.
     *
     * @param onFinished 不论展示成功 / 跳过 / 失败 / 超时, 最终都调用一次 (主线程).
     */
    fun showSplash(activity: Activity, container: ViewGroup, onFinished: () -> Unit) {
        if (!consented) {
            LogUtils.d(TAG, "showSplash: no consent, skip")
            onFinished(); return
        }
        // 万象书屋: 冷启时序保护.
        //
        // 之前 BUG: 用户 pm clear / 首次安装后, AdRepository.current() 返回 asset 默认配置
        // (etag="asset" disabled=true). 此时 SplashAdActivity 已经在等待 splash, 但
        // showSplash 里 cfg.effectivelyDisabled()==true 直接 return, 进 MainActivity,
        // 几百毫秒后才 refreshFromRemote 拉到真配置 (v25 disabled=false). 导致**首次启动永远没 splash**.
        //
        // 修复: 如果当前 cached 是 asset 默认 (etag="asset"||空 || version=0), 给 refresh 一个
        // 同步等待窗口 (最多 2.5s). 这是用户安装/清数据后**第一次启动**才会触发的兜底, 后续启动 SP 已有缓存,
        // 走快路径 (current() 一进来就是 v25), 这段 await 会立即通过. 不影响正常启动速度.
        val initial = AdRepository.current()
        val isStale = initial.etag.isEmpty() || initial.etag == "asset" || initial.version == 0L
        if (isStale && activity is LifecycleOwner) {
            activity.lifecycleScope.launch {
                val refreshed = kotlinx.coroutines.withTimeoutOrNull(2500) {
                    AdRepository.refreshFromRemote()
                }
                if (refreshed != null && refreshed.version != initial.version) {
                    // 拉到新配置, 触发 SDK init (initOnDemand 内部 idempotent, 重复调安全)
                    initOnDemand(activity.applicationContext, refreshed.config)
                }
                showSplashAfterConfigReady(activity, container, onFinished)
            }
            return
        }
        showSplashAfterConfigReady(activity, container, onFinished)
    }

    private fun showSplashAfterConfigReady(activity: Activity, container: ViewGroup, onFinished: () -> Unit) {
        val cfg = AdRepository.current().config
        val splash = cfg.placements.splash
        if (cfg.effectivelyDisabled() || !splash.enabled) {
            LogUtils.d(TAG, "showSplash: disabled in cfg, skip")
            onFinished(); return
        }
        // 冷启情况下 SDK init 是异步的, refresh 之后 initOnDemand 还在跑.
        // 这里不需要再等 SDK ready - showSplash 内部本来就有 5s 轮询 pickProvider, 自动等 SDK init 完.
        // 万象书屋: 上限 10s (从 5s 提升).
        // 实测: ylh GDT 首次 init 需要 4-5s, 之前 5s 上限导致冷启时
        // 经常 "no provider ready within 5000ms" 错过 ylh. 提升到 10s 给 SDK 充分时间.
        // 上限不能太大, 否则用户感受到长白屏. 8s 是体验和成功率的平衡点.
        val loadTimeoutMs = splash.timeoutMs.coerceIn(800, 10000)
        val onceFinished = OnceRunnable(onFinished)

        // 加载阶段标志: 一旦 SDK 调 onAdReadyToShow, 切到展示阶段, 加载 timeout 不再触发兜底
        val adShownFlag = java.util.concurrent.atomic.AtomicBoolean(false)

        if (activity is LifecycleOwner) {
            // 加载超时: 在 [loadTimeoutMs] 内还没 onAdReadyToShow 就放弃, 跳 MainActivity
            activity.lifecycleScope.launch {
                delay(loadTimeoutMs.toLong())
                if (!adShownFlag.get() && !onceFinished.isDone()) {
                    LogUtils.d(TAG, "showSplash: load timeout ${loadTimeoutMs}ms, skip")
                    onceFinished.run("load-timeout")
                }
            }
            // 展示超时兜底: 30s 后就算 SDK 没回 close, 也强制结束防卡死
            activity.lifecycleScope.launch {
                delay(SHOW_TIMEOUT_MS)
                if (!onceFinished.isDone()) {
                    LogUtils.d(TAG, "showSplash: show hard timeout ${SHOW_TIMEOUT_MS}ms")
                    onceFinished.run("show-timeout")
                }
            }
            // SDK init 是 async, 等 provider ready 轮询窗 = 加载超时窗
            // 公平性: 第一次拿到非 null pick 后再多等 200ms (FAIRNESS_WINDOW_MS),
            // 让其他 SDK 也有机会 ready, 然后再权重抽签. 避免"快家独占".
            activity.lifecycleScope.launch {
                val deadline = System.currentTimeMillis() + (loadTimeoutMs - 200).coerceAtLeast(400)
                val fairnessDeadline = System.currentTimeMillis() + 800  // 最多等所有 SDK ready 800ms
                while (System.currentTimeMillis() < deadline && !onceFinished.isDone()) {
                    val pick = pickProvider(AdPlacement.Splash)
                    if (pick != null) {
                        // 公平窗口: 如果第一次能 pick 但还有其他配置的 provider 未 ready, 多等一会
                        val now = System.currentTimeMillis()
                        if (now < fairnessDeadline && !allCandidatesReady(AdPlacement.Splash)) {
                            delay(100)
                            continue
                        }
                        // 重新 pick 一次, 让所有 ready 的 provider 都参与抽签
                        val finalPick = pickProvider(AdPlacement.Splash) ?: pick
                        triggerSplash(activity, finalPick.first, finalPick.second, loadTimeoutMs, onceFinished, adShownFlag)
                        return@launch
                    }
                    delay(150)
                }
                if (!onceFinished.isDone() && !adShownFlag.get()) {
                    LogUtils.d(TAG, "showSplash: no provider ready within ${loadTimeoutMs}ms, skip")
                    // 万象书屋: 上报"SDK 没及时 ready"事件, 让后端运营知道这种情况
                    // (之前没埋点, 数据失真 — 排查时找不到为啥总没 splash).
                    // provider="none" 表示"轮询都没抢到 SDK ready"
                    WanxiangBackend.reportAdEvent("splash", "none", "error", -100, "no provider ready within ${loadTimeoutMs}ms")
                    onceFinished.run("no-provider")
                }
            }
        } else {
            // 兜底: 不是 LifecycleOwner, 同步路径
            val pick = pickProvider(AdPlacement.Splash)
            if (pick == null) { onceFinished.run("no-provider-sync"); return }
            triggerSplash(activity, pick.first, pick.second, loadTimeoutMs, onceFinished, adShownFlag)
        }
    }

    private fun triggerSplash(
        activity: Activity,
        provider: AdProvider,
        posId: String,
        loadTimeoutMs: Int,
        onceFinished: OnceRunnable,
        adShownFlag: java.util.concurrent.atomic.AtomicBoolean
    ) {
        if (onceFinished.isDone() || activity.isFinishing || activity.isDestroyed) {
            LogUtils.d(TAG, "triggerSplash skipped: already finished")
            return
        }
        WanxiangBackend.reportAdEvent("splash", provider.name, "load")
        provider.loadSplashAd(activity, posId, loadTimeoutMs, object : AdProvider.SplashAdListener {
            override fun onAdReadyToShow(container: ViewGroup, onFinished: () -> Unit) {
                if (activity.isFinishing || activity.isDestroyed) return
                // 万象书屋: 切到"展示阶段", 加载超时不再触发. 等 SDK 自己 onAdClosed/onError 才结束.
                adShownFlag.set(true)
                WanxiangBackend.reportAdEvent("splash", provider.name, "show")
                onFinished()
            }
            override fun onAdClicked() {
                // 万象书屋: CTR 关键指标. 用户点广告内容 (CTA / 跳转 / 下载) 触发.
                WanxiangBackend.reportAdEvent("splash", provider.name, "click")
            }
            override fun onAdClosed() {
                // 用户正常关闭 / 倒计时结束 — 这才是"广告看完了"信号
                WanxiangBackend.reportAdEvent("splash", provider.name, "close")
                onceFinished.run("closed-${provider.name}")
            }
            override fun onError(code: Int, msg: String) {
                LogUtils.d(TAG, "splash ${provider.name} error: $code $msg")
                WanxiangBackend.reportAdEvent("splash", provider.name, "error", code, msg)
                onceFinished.run("error-${provider.name}")
            }
        })
    }

    /**
     * 弹"看广告解锁 30 分钟纯净阅读" 流程. 前置已经经过 [AdRateLimiter.canPromptRewarded].
     *
     * @param onSkipped 用户拒绝看 / 加载失败时回调
     * @param onRewarded 用户完整看完, 上层调用 [AdRateLimiter.markRewardedSuccess] 解锁
     */
    fun loadAndShowRewarded(
        activity: Activity,
        onSkipped: () -> Unit,
        onRewarded: () -> Unit
    ) {
        if (!consented) { onSkipped(); return }
        // 万象书屋: 等 SDK init 完成轮询 (跟 splash 路径一致).
        // 之前 BUG: 用户点"看广告"按钮时, 如果 ylh GDT 还没 init 完 (冷启 4-7s),
        // pickProvider 返回 null, 直接 onSkipped, 用户体验是"按钮点了没反应",
        // 而且后端一条上报都没有, 数据失真.
        // 现在: 5s 轮询窗口等 SDK ready; 5s 后还没 ready 才 skip + 上报.
        val firstPick = pickProvider(AdPlacement.RewardedReadingUnlock)
        if (firstPick == null && activity is LifecycleOwner) {
            activity.lifecycleScope.launch {
                val deadline = System.currentTimeMillis() + 5000L
                while (System.currentTimeMillis() < deadline) {
                    val pick = pickProvider(AdPlacement.RewardedReadingUnlock)
                    if (pick != null) {
                        loadAndShowRewardedInner(activity, pick.first, pick.second, onSkipped, onRewarded)
                        return@launch
                    }
                    delay(150)
                }
                LogUtils.d(TAG, "rewarded: no provider ready within 5000ms, skip")
                WanxiangBackend.reportAdEvent("rewardedReadingUnlock", "none", "error", -100, "no provider ready within 5000ms")
                onSkipped()
            }
            return
        }
        if (firstPick == null) { onSkipped(); return }
        loadAndShowRewardedInner(activity, firstPick.first, firstPick.second, onSkipped, onRewarded)
    }

    private fun loadAndShowRewardedInner(
        activity: Activity,
        provider: AdProvider,
        posId: String,
        onSkipped: () -> Unit,
        onRewarded: () -> Unit
    ) {
        WanxiangBackend.reportAdEvent("rewardedReadingUnlock", provider.name, "load")
        // 万象书屋: 防双触发 (例如 SDK 既调 onError 又调 onAdClosed) + 兜底超时.
        //
        // 激励视频实际时长统计 (含各种诱导玩法):
        //   - 标准激励: 30s (倒计时跳过)
        //   - "Plus" 加速激励: 30s + endcard 4-10s
        //   - 互动激励: 玩 30-60s 小游戏才发奖
        //   - 诱导下载激励: 60-120s (视频 + endcard + 二次确认)
        //
        // 历史: 之前设 90s 会切断"诱导下载"路径, 用户看完没拿到奖励. 改 180s 兜底.
        // 这只是兜底超时防 SDK bug, 正常 SDK 一定会调 onRewardVerified / onAdClosed / onError.
        val dispatched = java.util.concurrent.atomic.AtomicBoolean(false)
        val shownFlag = java.util.concurrent.atomic.AtomicBoolean(false)
        var timeoutJob: kotlinx.coroutines.Job? = null

        fun dispatch(rewarded: Boolean) {
            if (!dispatched.compareAndSet(false, true)) return
            timeoutJob?.cancel()
            if (rewarded) onRewarded() else onSkipped()
        }

        if (activity is LifecycleOwner) {
            timeoutJob = activity.lifecycleScope.launch {
                delay(180_000)  // 3 分钟兜底, 诱导下载类激励可能长达 2 分钟
                if (!dispatched.get()) {
                    LogUtils.d(TAG, "rewarded ${provider.name} hard timeout 180s, SDK is dead, treat as skip")
                    dispatch(false)
                }
            }
        }
        provider.loadRewardedAd(activity, posId, object : AdProvider.RewardedAdListener {
            @Volatile private var rewarded = false
            override fun onAdLoaded(show: () -> Unit) {
                if (shownFlag.compareAndSet(false, true)) {
                    WanxiangBackend.reportAdEvent("rewardedReadingUnlock", provider.name, "show")
                }
                show()
            }
            override fun onAdClicked() {
                // 万象书屋: 激励视频里点 CTA / endcard 跳转都算 click.
                WanxiangBackend.reportAdEvent("rewardedReadingUnlock", provider.name, "click")
            }
            override fun onRewardVerified() {
                rewarded = true
                WanxiangBackend.reportAdEvent("rewardedReadingUnlock", provider.name, "reward")
                // 万象书屋: 立即 dispatch reward, 不等 onAdClosed.
                // 某些 SDK 在 reward 与 close 之间可能有几秒延迟, 用户视觉上"看完了广告"
                // 但锁屏还在, 体验差. 收到 reward 信号就立即兑现.
                dispatch(true)
            }
            override fun onAdClosed() {
                WanxiangBackend.reportAdEvent("rewardedReadingUnlock", provider.name, "close")
                // 兜底: 如果 onRewardVerified 因为某些 SDK 实现差异没调, 但 close 时 rewarded 标志确实是 true
                // (CSJ 走 onRewardArrived 我们已转 rewarded), 仍然能兑现.
                if (rewarded) dispatch(true) else dispatch(false)
            }
            override fun onError(code: Int, msg: String) {
                LogUtils.d(TAG, "rewarded ${provider.name} error: $code $msg")
                WanxiangBackend.reportAdEvent("rewardedReadingUnlock", provider.name, "error", code, msg)
                dispatch(false)
            }
        })
    }

    private suspend fun initOnDemand(appContext: Context, cfg: AdConfig) = withContext(Dispatchers.Main) {
        if (!consented) {
            LogUtils.d(TAG, "no consent, skip SDK init")
            return@withContext
        }
        if (cfg.effectivelyDisabled()) return@withContext
        // 只 init "云端权重 > 0 且 appId 非空" 的 SDK
        val needNames = mutableSetOf<String>()
        listOf(cfg.placements.splash.providers, cfg.placements.rewardedReadingUnlock.providers)
            .flatten()
            .filter { it.weight > 0 && it.posId.isNotBlank() }
            .forEach { needNames += it.name }
        for (name in needNames) {
            val p = providers[name] ?: continue
            val appId = when (name) {
                "csj" -> cfg.sdk.csj.appId
                "ylh" -> cfg.sdk.ylh.appId
                else -> ""
            }
            if (appId.isBlank()) continue
            runCatching { p.init(appContext, appId) }
                .onFailure { LogUtils.d(TAG, "init ${p.name} crashed: ${it.message}") }
        }
    }

    /** 给 ReadBookActivity / SplashAdActivity 安全用的"只跑一次"包装 */
    private class OnceRunnable(private val r: () -> Unit) {
        @Volatile private var done = false
        fun isDone(): Boolean = done
        fun run(reason: String) {
            if (done) return
            synchronized(this) {
                if (done) return
                done = true
            }
            LogUtils.d(TAG, "OnceRunnable fired: $reason")
            r()
        }
    }
}
