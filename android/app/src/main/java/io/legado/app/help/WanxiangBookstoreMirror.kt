package io.legado.app.help

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.legado.app.BuildConfig
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.http.okHttpClient
import io.legado.app.utils.LogUtils
import splitties.init.appCtx

/**
 * 万象书屋 D-23 (2026-05-08): 拉后端 mirror cache (替代直抓 m.qidian.com).
 *
 * 工作流:
 *   1. App 进书城 → QidianRepository 调 fetch() → GET <backend>/api/bookstore/mirror
 *   2. 命中 304 用上次 cache, 200 解析新 JSON 缓存到内存
 *   3. 后端不可用 / 返 503 / 空 cache → fetch() 返 null → QidianRepository 降级直抓 m.qidian
 *
 * 节流策略:
 *   - 内存缓存: 5 分钟内 hit 同一份 JSON, 不发任何请求
 *   - HTTP ETag: 5 分钟过后发请求带 If-None-Match, 命中 304 不传 body 节省流量
 *
 * 跟 WanxiangBackend 共享:
 *   - baseUrl 通过 BuildConfig.BACKEND_BASE_URL 取
 *   - deviceToken 通过 SP wanxiang_device.token 取 (跟 WanxiangBackend 同 SP)
 */
object WanxiangBookstoreMirror {

    private const val TAG = "BookstoreMirror"
    private const val PATH = "/api/bookstore/mirror"
    private const val DEVICE_TOKEN_SP = "wanxiang_device"
    private const val DEVICE_TOKEN_KEY = "token"
    private const val MEM_CACHE_TTL_MS = 5 * 60_000L

    @Volatile
    private var cachedPayload: JsonObject? = null
    @Volatile
    private var cachedAt: Long = 0L
    @Volatile
    private var cachedEtag: String? = null

    private val baseUrl: String?
        get() = BuildConfig.BACKEND_BASE_URL.takeIf { it.isNotBlank() }?.trimEnd('/')

    private val deviceToken: String?
        get() = appCtx.getSharedPreferences(DEVICE_TOKEN_SP, android.content.Context.MODE_PRIVATE)
            .getString(DEVICE_TOKEN_KEY, null)?.takeIf { it.isNotBlank() }

    /**
     * 拉 mirror payload (JSON object).
     * @param forceRefresh true 时跳过内存 cache 强制发请求 (下拉刷新场景)
     * @return 后端 cache JSON; null = 后端不可用 / cache 全空 / 网络失败 — 调用方应降级直抓 m.qidian
     */
    suspend fun fetch(forceRefresh: Boolean = false): JsonObject? {
        val base = baseUrl ?: run {
            LogUtils.d(TAG, "no BACKEND_BASE_URL, fallback")
            return null
        }
        // 命中内存 cache
        val mem = cachedPayload
        if (!forceRefresh && mem != null && System.currentTimeMillis() - cachedAt < MEM_CACHE_TTL_MS) {
            return mem
        }
        val url = "$base$PATH"
        return try {
            val resp = okHttpClient.newCallStrResponse(retry = 1) {
                url(url)
                deviceToken?.let { header("X-Device-Token", it) }
                cachedEtag?.let { header("If-None-Match", it) }
                header("Accept", "application/json")
            }
            when (resp.raw.code) {
                304 -> {
                    LogUtils.d(TAG, "304 hit cache (etag=$cachedEtag)")
                    cachedAt = System.currentTimeMillis()
                    mem
                }
                200 -> {
                    val body = resp.body
                    if (body.isNullOrBlank()) {
                        LogUtils.d(TAG, "200 but empty body, fallback")
                        null
                    } else {
                        val obj = runCatching { JsonParser.parseString(body).asJsonObject }.getOrNull()
                        if (obj == null) {
                            LogUtils.d(TAG, "JSON parse failed, fallback")
                            null
                        } else {
                            cachedPayload = obj
                            cachedAt = System.currentTimeMillis()
                            cachedEtag = resp.raw.header("ETag")
                            LogUtils.d(
                                TAG,
                                "200 fresh cache version=${obj.get("version")?.asLong} size=${body.length}"
                            )
                            obj
                        }
                    }
                }
                503 -> {
                    LogUtils.d(TAG, "503 mirror not ready, fallback")
                    null
                }
                else -> {
                    LogUtils.d(TAG, "unexpected code=${resp.raw.code}, fallback")
                    null
                }
            }
        } catch (t: Throwable) {
            LogUtils.d(TAG, "fetch failed: ${t.javaClass.simpleName}: ${t.message}, fallback")
            null
        }
    }

    /** 给单测 / 紧急排查用: 清掉内存 cache 让下次请求全新 */
    @Suppress("unused")
    fun clearCache() {
        cachedPayload = null
        cachedAt = 0L
        cachedEtag = null
    }
}
