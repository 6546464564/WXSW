package io.legado.app.ad

import com.google.gson.annotations.SerializedName

/**
 * 万象书屋广告配置.
 *
 * 与后端 `/api/ad-config` 返回的 `config` 字段结构一一对应, 也与
 * `assets/default_ad_config.json` 保持一致 (作为离线兜底).
 *
 * 设计要点:
 * - 三家 SDK 的真实 appId / posId **不在客户端硬编码**, 一律由后端下发,
 *   客户端默认空字符串. 这样万一某家账号被封, 后端改一行立刻切到备用账号或备用 SDK.
 * - [disabled] 是应急总开关, 任何场景下命中 true 都不出广告.
 * - [pollIntervalSec] 决定客户端多久拉一次远端配置.
 *
 * 兼容性: 字段都给了默认值, Gson 反序列化老/新版本不会崩.
 */
data class AdConfig(
    @SerializedName("disabled") val disabled: Boolean = true,
    @SerializedName("sdk") val sdk: SdkAppIds = SdkAppIds(),
    @SerializedName("placements") val placements: Placements = Placements(),
    @SerializedName("pollIntervalSec") val pollIntervalSec: Long = 6 * 3600L,
    // 万象书屋: 章节级付费墙. 头 N 章免费, 之后必须看广告解锁 M 分钟
    @SerializedName("chapterUnlock") val chapterUnlock: ChapterUnlock = ChapterUnlock()
) {
    data class SdkAppIds(
        @SerializedName("csj") val csj: SdkAppId = SdkAppId(),
        @SerializedName("ylh") val ylh: SdkAppId = SdkAppId()
    )

    data class SdkAppId(@SerializedName("appId") val appId: String = "")

    data class Placements(
        @SerializedName("splash") val splash: SplashPlacement = SplashPlacement(),
        @SerializedName("rewardedReadingUnlock")
        val rewardedReadingUnlock: RewardedPlacement = RewardedPlacement()
    )

    data class SplashPlacement(
        @SerializedName("enabled") val enabled: Boolean = false,
        @SerializedName("timeoutMs") val timeoutMs: Int = 3000,
        // 万象书屋: "独家投放" 应急开关. 后端在 getAdConfig 出口处把非选中 provider 的 weight 强制 0.
        // 空串 = 默认按 weight 抽签, "csj"/"ylh" = 仅这家. 优先级低于 breaker (熔断仍生效).
        @SerializedName("soloProvider") val soloProvider: String = "",
        @SerializedName("providers") val providers: List<ProviderSlot> = emptyList()
    )

    data class RewardedPlacement(
        @SerializedName("enabled") val enabled: Boolean = false,
        @SerializedName("unlockMinutes") val unlockMinutes: Int = 30,
        @SerializedName("cooldownMinutes") val cooldownMinutes: Int = 30,
        // 万象书屋累积奖励:
        // cooldownSec - 两次主动激励视频之间最小间隔, 防刷防 SDK 风控 (默认 180 = 3 分钟)
        // maxAccumulatedMinutes - 累积纯净阅读上限, 防恶意刷量 (默认 1440 = 24 小时)
        // showCountdownBar - 阅读器顶部是否显示倒计时条 + 看广告续期按钮
        @SerializedName("cooldownSec") val cooldownSec: Int = 180,
        @SerializedName("maxAccumulatedMinutes") val maxAccumulatedMinutes: Int = 1440,
        @SerializedName("showCountdownBar") val showCountdownBar: Boolean = true,
        // 万象书屋: 独家投放, 同 SplashPlacement.soloProvider
        @SerializedName("soloProvider") val soloProvider: String = "",
        @SerializedName("providers") val providers: List<ProviderSlot> = emptyList()
    )

    data class ProviderSlot(
        @SerializedName("name") val name: String,
        @SerializedName("weight") val weight: Int = 0,
        @SerializedName("posId") val posId: String = ""
    )

    /**
     * 万象书屋: 章节级付费墙. 用户读完头 [freeChapters] 章后必须看广告解锁;
     * 看完解锁 [unlockMinutes] 分钟内任意章节免费; 时间到再次拦截.
     *
     * 配合 RewardedPlacement 使用: 强制弹激励视频, 用户没看完 → 锁屏页 + 阻止翻下一章.
     */
    data class ChapterUnlock(
        @SerializedName("enabled") val enabled: Boolean = false,
        @SerializedName("freeChapters") val freeChapters: Int = 3,
        @SerializedName("unlockMinutes") val unlockMinutes: Int = 30,
        @SerializedName("blockOnSkip") val blockOnSkip: Boolean = true
    )

    /**
     * 是否对外完全不出广告: 总开关 / 拉到的远端表完全为空 都视为 disabled.
     *
     * 万象书屋: chapterUnlock 启用时即使 splash + rewarded 都关, 也不能算 effectivelyDisabled,
     * 否则付费墙的"立即弹激励"路径会因为 effectivelyDisabled=true 被短路, 导致用户被永久锁屏.
     * 反之, 任何"启用的功能"都视为 ad system 在工作.
     */
    fun effectivelyDisabled(): Boolean {
        if (disabled) return true
        val s = placements.splash
        val r = placements.rewardedReadingUnlock
        // 任意一个 placement 启用都不算 disabled
        return !s.enabled && !r.enabled && !chapterUnlock.enabled
    }
}

/** 后端 wrapping: { version, etag, config } */
data class AdConfigEnvelope(
    @SerializedName("version") val version: Long = 0,
    @SerializedName("etag") val etag: String = "",
    @SerializedName("config") val config: AdConfig = AdConfig()
)

/** 抽象出的"广告位类型", App 端只在这两个枚举值中触发 */
enum class AdPlacement(val key: String) {
    Splash("splash"),
    RewardedReadingUnlock("rewardedReadingUnlock"),
}
