package io.legado.app.help

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import io.legado.app.BuildConfig
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.http.wanxiangSecureOkHttpClient
import io.legado.app.utils.LogUtils
import kotlinx.coroutines.async
import splitties.init.appCtx
import java.io.File

/**
 * 万象书屋 D-23: 拉后端 mirror cache (替代直抓 m.qidian.com).
 *
 * iOS [BookstoreMirror.swift] 对齐:
 *   - 内存 7 天 TTL + 磁盘 payload (最多 30 天) + SP etag
 *   - 304 冷启动无内存 cache → 清 etag 重试拿 200 body (避免一直 fallback 直抓起点)
 *   - transient 错误 retry 1 次
 */
object WanxiangBookstoreMirror {

    private const val TAG = "BookstoreMirror"
    private const val PATH = "/api/bookstore/mirror"
    private const val DEVICE_TOKEN_SP = "wanxiang_device"
    private const val DEVICE_TOKEN_KEY = "token"
    private const val ETAG_SP = "wanxiang_bookstore_mirror"
    private const val ETAG_KEY = "etag"
    private const val MEM_CACHE_TTL_MS = 7L * 24 * 60 * 60_000L   // 7 天, 手动更新 mirror 时减少重复拉取
    private const val DISK_MAX_AGE_MS = 30L * 24 * 60 * 60_000L
    private const val PLATFORM = "android"

    @Volatile
    private var cachedPayload: JsonObject? = null

    @Volatile
    private var cachedAt: Long = 0L

    @Volatile
    private var cachedEtag: String? = null

    // 万象书屋: 单飞状态 — 同一时间只允许一个 mirror 拉取任务在跑.
    // 启动期 WanxiangBackend.start 的 prefetch 与 BookStorePrewarm.prewarm 会并发调 fetch,
    // 加上 QidianRepository 各方法 / 书城下拉刷新也会触发, 之前会出现多个并发 HTTP 拉取
    // 同时写 cachedPayload/cachedEtag/磁盘文件 (丢数据 / 重复拉取). 现在重复触发复用同一个
    // 在跑任务的结果.
    private val singleFlightMutex = kotlinx.coroutines.sync.Mutex()
    @Volatile
    private var inFlightFetch: kotlinx.coroutines.Deferred<JsonObject?>? = null

    private val diskFile: File
        get() = File(appCtx.filesDir, "bookstore_mirror.json")

    private val baseUrl: String?
        get() = BuildConfig.BACKEND_BASE_URL.takeIf { it.isNotBlank() }?.trimEnd('/')

    private val deviceToken: String?
        get() = appCtx.getSharedPreferences(DEVICE_TOKEN_SP, android.content.Context.MODE_PRIVATE)
            .getString(DEVICE_TOKEN_KEY, null)?.takeIf { it.isNotBlank() }

    suspend fun fetch(forceRefresh: Boolean = false): JsonObject? {
        val base = baseUrl ?: run {
            LogUtils.d(TAG, "no BACKEND_BASE_URL, fallback")
            return null
        }
        WanxiangBackend.ensureDeviceRegistered()
        loadDiskCacheIfNeeded()
        if (!forceRefresh &&
            cachedPayload != null &&
            System.currentTimeMillis() - cachedAt < MEM_CACHE_TTL_MS
        ) {
            return cachedPayload
        }
    val url = "$base$PATH"
    // 单飞: 已有任务在跑则直接等它的结果, 不重复发 HTTP.
    singleFlightMutex.lock()
    val running = inFlightFetch
    if (running != null) {
        singleFlightMutex.unlock()
        return running.await()
    }
    val job = kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO)
        .async { doFetch(url) }
    inFlightFetch = job
    singleFlightMutex.unlock()
    return try {
        job.await()
    } finally {
        // 只有创建者才清 inFlightFetch, 避免把后进来的任务的引用误清
        if (inFlightFetch === job) inFlightFetch = null
    }
}

/** 万象书屋: 纯网络拉取逻辑, 由 fetch 单飞保护 */
private suspend fun doFetch(url: String): JsonObject? {
    for (attempt in 0..1) {
        when (val outcome = fetchOnce(url, allowTokenReissue = attempt == 0)) {
            is Outcome.Ok -> return outcome.payload
            is Outcome.Definitive -> {
                LogUtils.d(TAG, outcome.reason)
                return staleDiskPayloadIfFresh(outcome.reason)
            }
            is Outcome.Transient -> {
                if (attempt == 0) {
                    LogUtils.d(TAG, "transient ${outcome.reason}, retry...")
                }
            }
        }
    }
    return staleDiskPayloadIfFresh("network exhausted")
}

    private sealed class Outcome {
        data class Ok(val payload: JsonObject) : Outcome()
        data class Definitive(val reason: String) : Outcome()
        data class Transient(val reason: String) : Outcome()
    }

    private suspend fun fetchOnce(url: String, allowTokenReissue: Boolean = true): Outcome {
        return try {
            val resp = wanxiangSecureOkHttpClient.newCallStrResponse(retry = 0) {
                url(url)
                header("Accept", "application/json")
                header("X-Platform", PLATFORM)
                header("X-Device-Id", WanxiangBackend.backendDeviceId)
                deviceToken?.let { header("X-Device-Token", it) }
                cachedEtag?.let { header("If-None-Match", it) }
            }
            if (resp.raw.code == 401 && allowTokenReissue && WanxiangBackend.reissueDeviceToken()) {
                return fetchOnce(url, allowTokenReissue = false)
            }
            when (resp.raw.code) {
                304 -> {
                    loadDiskCacheIfNeeded()
                    cachedAt = System.currentTimeMillis()
                    cachedPayload?.let { return Outcome.Ok(it) }
                    // 冷启动: SP 有 etag 但内存/磁盘空 → 清 etag 重试拿 200
                    cachedEtag = null
                    appCtx.getSharedPreferences(ETAG_SP, android.content.Context.MODE_PRIVATE)
                        .edit().remove(ETAG_KEY).apply()
                    Outcome.Transient("304 cold start (no cache), refetch without If-None-Match")
                }
                200 -> {
                    val body = resp.body
                    if (body.isNullOrBlank()) {
                        Outcome.Definitive("200 but empty body, fallback")
                    } else {
                        val obj = runCatching { JsonParser.parseString(body).asJsonObject }.getOrNull()
                        if (obj == null) {
                            Outcome.Definitive("JSON parse failed, fallback")
                        } else {
                            cachedPayload = obj
                            cachedAt = System.currentTimeMillis()
                            cachedEtag = resp.raw.header("ETag")
                            persistDisk(body, cachedEtag)
                            LogUtils.d(
                                TAG,
                                "200 fresh cache version=${obj.get("version")?.asLong} size=${body.length}"
                            )
                            Outcome.Ok(obj)
                        }
                    }
                }
                503 -> Outcome.Definitive("503 mirror not ready, fallback")
                else -> Outcome.Definitive("unexpected code=${resp.raw.code}, fallback")
            }
        } catch (t: Throwable) {
            Outcome.Transient("${t.javaClass.simpleName}: ${t.message}")
        }
    }

    private fun staleDiskPayloadIfFresh(reason: String): JsonObject? {
        loadDiskCacheIfNeeded()
        if (cachedPayload != null && isDiskCacheFresh()) {
            LogUtils.d(TAG, "using stale disk cache after $reason")
            return cachedPayload
        }
        return null
    }

    private fun isDiskCacheFresh(): Boolean {
        val file = diskFile
        if (!file.exists()) return false
        return System.currentTimeMillis() - file.lastModified() < DISK_MAX_AGE_MS
    }

    private fun loadDiskCacheIfNeeded() {
        if (cachedPayload != null) return
        if (cachedEtag == null) {
            cachedEtag = appCtx.getSharedPreferences(ETAG_SP, android.content.Context.MODE_PRIVATE)
                .getString(ETAG_KEY, null)?.takeIf { it.isNotBlank() }
        }
        val file = diskFile
        if (!file.exists() || !isDiskCacheFresh()) return
        runCatching {
            val body = file.readText()
            JsonParser.parseString(body).asJsonObject
        }.getOrNull()?.let { obj ->
            cachedPayload = obj
            cachedAt = file.lastModified().coerceAtLeast(System.currentTimeMillis() - MEM_CACHE_TTL_MS)
        }
    }

    private fun persistDisk(body: String, etag: String?) {
        runCatching { diskFile.writeText(body) }
        if (!etag.isNullOrBlank()) {
            appCtx.getSharedPreferences(ETAG_SP, android.content.Context.MODE_PRIVATE)
                .edit().putString(ETAG_KEY, etag).apply()
        }
    }

    fun clearCache() {
        cachedPayload = null
        cachedAt = 0L
        cachedEtag = null
        runCatching { diskFile.delete() }
        appCtx.getSharedPreferences(ETAG_SP, android.content.Context.MODE_PRIVATE)
            .edit().remove(ETAG_KEY).apply()
    }
}
