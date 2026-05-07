package io.legado.app.ad

import splitties.init.appCtx

/**
 * 阅读激励位的节奏控制.
 *
 * v2 章节级付费墙模式 (强制变现):
 *   - 用户本次启动**累计读 [freeChapters] 章** 后进入"付费墙"
 *   - 付费墙触发后, 直接弹激励广告 (不再询问); 用户看完解锁 [unlockMinutes] 分钟
 *   - 解锁期内任何章节都不再触发
 *   - 用户没看完(SDK 自带关闭/网络挂/跳过) → 锁屏页, 阻止翻下一章
 *
 * v1 时间制 (canPromptRewarded) 保留兼容, 但默认走 v2 章节制.
 *
 * 这里只负责"现在能不能弹 / 是不是要拦截"的纯函数判断 + 时间记账,
 * 不耦合任何 UI / SDK.
 */
object AdRateLimiter {

    private const val SP_NAME = "wanxiang_ad_rate"
    private const val KEY_FIRST_ENTER_READ_MS = "first_enter_read_ms"
    private const val KEY_LAST_PROMPT_MS = "last_prompt_ms"
    private const val KEY_LAST_REWARDED_MS = "last_rewarded_ms"
    private const val KEY_UNLOCK_UNTIL_MS = "unlock_until_ms"

    private val sp by lazy {
        appCtx.getSharedPreferences(SP_NAME, android.content.Context.MODE_PRIVATE)
    }

    // 万象书屋: 本次冷启动累计已读章节数. 内存计数, 进程重启清零.
    @Volatile private var chaptersOpenedThisSession: Int = 0
    private val seenChapterKeys = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

    // 万象书屋: 连续广告加载失败次数. 防止广告 SDK 配置问题 (例如 YLH 报 107030 包名错误)
    // 让用户彻底卡死. 达到阈值时自动给一个短期解锁让用户继续读.
    // 用 AtomicInteger 保证多 provider 并发回调时的计数原子性.
    private val consecutiveAdFailures = java.util.concurrent.atomic.AtomicInteger(0)
    const val AD_FAILURE_GRACE_THRESHOLD = 3
    const val AD_FAILURE_GRACE_MINUTES = 5

    /** 阅读器 onCreate / onResume 时调用一次, 仅在第一次写入. */
    fun markEnterReader() {
        if (sp.getLong(KEY_FIRST_ENTER_READ_MS, 0L) == 0L) {
            sp.edit().putLong(KEY_FIRST_ENTER_READ_MS, System.currentTimeMillis()).apply()
        }
    }

    /**
     * 万象书屋: 用户进入新章节时调一次, 同一章节多次进入只算一次 (内存去重).
     * @param uniqueKey "${bookUrl}|${chapterIndex}" 之类
     */
    fun markChapterOpened(uniqueKey: String) {
        if (seenChapterKeys.add(uniqueKey)) {
            chaptersOpenedThisSession++
        }
    }

    /** 当前会话累计阅读的不同章节数 */
    fun chaptersOpenedCount(): Int = chaptersOpenedThisSession

    /**
     * 万象书屋: 是否需要触发"付费墙" (拦截阅读, 强制看广告).
     *
     * 规则:
     *   1. 已在解锁窗口内 → false (不拦)
     *   2. 累计已读章节 < freeChapters → false (头 N 章免费)
     *   3. 否则 → true (必须看广告)
     *
     * 调用方在 ReadBookActivity 切章节时检查, true 时显示锁屏 + 主动调激励视频
     */
    fun shouldRequireUnlock(freeChapters: Int): Boolean {
        if (isInUnlockWindow()) return false
        return chaptersOpenedThisSession > freeChapters.coerceAtLeast(0)
    }

    fun isInUnlockWindow(): Boolean {
        val until = sp.getLong(KEY_UNLOCK_UNTIL_MS, 0L)
        return System.currentTimeMillis() < until
    }

    /**
     * 查询当前是否可以弹激励对话框 (旧的时间制, 保留兼容).
     */
    fun canPromptRewarded(cooldownMinutes: Int = 30): Boolean {
        val now = System.currentTimeMillis()
        val unlockUntil = sp.getLong(KEY_UNLOCK_UNTIL_MS, 0L)
        if (now < unlockUntil) return false
        val firstEnter = sp.getLong(KEY_FIRST_ENTER_READ_MS, now)
        val cooldownMs = cooldownMinutes.coerceAtLeast(1) * 60_000L
        if (now - firstEnter < cooldownMs) return false
        val lastPrompt = sp.getLong(KEY_LAST_PROMPT_MS, 0L)
        val lastRewarded = sp.getLong(KEY_LAST_REWARDED_MS, 0L)
        val lastAny = maxOf(lastPrompt, lastRewarded)
        return now - lastAny >= cooldownMs
    }

    /** 弹出对话框 (无论用户点不点) 立刻记账, 防止短时间反复弹 */
    fun markPrompted() {
        sp.edit().putLong(KEY_LAST_PROMPT_MS, System.currentTimeMillis()).apply()
    }

    /**
     * 用户成功看完激励视频, **累加** [unlockMinutes] 分钟纯净阅读 (而非覆盖).
     *
     * 累加逻辑:
     *   - 当前剩余 25 分 + 看 1 次广告 → 25 + 30 = 55 分钟
     *   - 当前剩余 0 分钟 + 看 1 次广告 → 30 分钟
     *   - 上限 [maxAccumulatedMinutes] (默认 1440 = 24 小时), 防恶意刷量
     *
     * @param unlockMinutes 本次广告兑现的时长 (默认 30, 后端可配)
     * @param maxAccumulatedMinutes 累积上限 (默认 1440 = 24h)
     */
    fun markRewardedSuccess(unlockMinutes: Int, maxAccumulatedMinutes: Int = 1440) {
        val now = System.currentTimeMillis()
        val currentUntil = sp.getLong(KEY_UNLOCK_UNTIL_MS, 0L)
        // 当前还在解锁窗口内 → 在剩余基础上加; 已过期 → 从现在开始加
        val baseTime = if (currentUntil > now) currentUntil else now
        val deltaMs = unlockMinutes.coerceAtLeast(1) * 60_000L
        val cap = now + maxAccumulatedMinutes.coerceAtLeast(1) * 60_000L
        val newUntil = (baseTime + deltaMs).coerceAtMost(cap)
        sp.edit()
            .putLong(KEY_LAST_REWARDED_MS, now)
            .putLong(KEY_UNLOCK_UNTIL_MS, newUntil)
            .apply()
        consecutiveAdFailures.set(0)
    }

    /**
     * 万象书屋: 是否可以"现在主动看广告续期" (受冷却时间限制).
     * 章节付费墙锁屏路径**不受此限制** (锁屏中冷却=用户卡死), 只对主动入口生效.
     *
     * @param cooldownSec 两次激励视频间最小间隔秒数 (默认 180=3分钟)
     */
    fun canShowRewardedAdNow(cooldownSec: Int = 180): Boolean {
        val last = sp.getLong(KEY_LAST_REWARDED_MS, 0L)
        return System.currentTimeMillis() - last >= cooldownSec * 1000L
    }

    /** 距下次允许看广告还剩多少秒 (0=已可看). 用于 UI 倒计时显示. */
    fun secondsUntilNextRewardedAllowed(cooldownSec: Int = 180): Long {
        val last = sp.getLong(KEY_LAST_REWARDED_MS, 0L)
        val nextAllowed = last + cooldownSec * 1000L
        return ((nextAllowed - System.currentTimeMillis()).coerceAtLeast(0L) / 1000L)
    }

    /**
     * 万象书屋: 广告加载失败 +1.
     * 连续达到 [AD_FAILURE_GRACE_THRESHOLD] 次 → 触发兜底: 给 [AD_FAILURE_GRACE_MINUTES] 分钟解锁,
     * 让用户至少能继续读, 不至于因为广告平台配置问题 (例如新 posId 还在冷启动 / 包名校验失败)
     * 完全卡死无法使用 App.
     *
     * @return true=触发了兜底解锁, false=还没到阈值
     */
    fun recordAdFailureAndCheckGrace(): Boolean {
        val n = consecutiveAdFailures.incrementAndGet()
        if (n >= AD_FAILURE_GRACE_THRESHOLD) {
            val now = System.currentTimeMillis()
            val until = now + AD_FAILURE_GRACE_MINUTES * 60_000L
            sp.edit().putLong(KEY_UNLOCK_UNTIL_MS, until).apply()
            consecutiveAdFailures.set(0)  // 兜底后重置, 5 分钟后再次拦截
            return true
        }
        return false
    }

    /** 注销账号 / 调试时调, 把所有计时 + 章节计数清零 */
    fun reset() {
        sp.edit().clear().apply()
        chaptersOpenedThisSession = 0
        seenChapterKeys.clear()
        consecutiveAdFailures.set(0)
    }

    /** 当前解锁窗口剩余毫秒数, 0 表示没在解锁中 */
    fun remainingUnlockMs(): Long {
        val until = sp.getLong(KEY_UNLOCK_UNTIL_MS, 0L)
        val now = System.currentTimeMillis()
        return if (until > now) until - now else 0L
    }
}
