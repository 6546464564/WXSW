package io.legado.app.help

import android.provider.Settings
import io.legado.app.BuildConfig
import io.legado.app.data.appDb
import io.legado.app.data.entities.BookSource
import io.legado.app.help.coroutine.Coroutine
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.http.okHttpClient
import io.legado.app.utils.GSON
import io.legado.app.utils.LogUtils
import io.legado.app.utils.fromJsonArray
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import splitties.init.appCtx

/**
 * 万象书屋后端集成
 *
 * 职责:
 *   1. 启动时从后端拉取最新书源,落库覆盖本地默认源 (失败则用 assets 内置源回退)
 *   2. 启动 + 定期向后端上报 device_id 心跳, 用于实时在线 / DAU 统计
 *
 * 后端 URL 通过 BuildConfig.BACKEND_BASE_URL 注入,空字符串则全部禁用 (本地纯离线模式)
 */
object WanxiangBackend {

    private const val TAG = "WanxiangBackend"
    private const val PING_INTERVAL_MS = 4 * 60 * 1000L // 4 分钟一次心跳, 后端 5 分钟窗内识别为在线

    private val baseUrl: String? get() = BuildConfig.BACKEND_BASE_URL.takeIf { it.isNotBlank() }

    /**
     * 设备唯一标识(Settings.Secure.ANDROID_ID),用于后端去重统计.
     * 不上传任何其他设备信息.
     */
    private val deviceId: String by lazy {
        @Suppress("HardwareIds")
        runCatching {
            Settings.Secure.getString(appCtx.contentResolver, Settings.Secure.ANDROID_ID)
                ?.takeIf { it.isNotEmpty() && it != "9774d56d682e549c" }
        }.getOrNull() ?: "anon-${System.currentTimeMillis() / 1000}"
    }

    fun start() {
        val url = baseUrl ?: run {
            LogUtils.d(TAG, "BACKEND_BASE_URL not configured, skip remote sync & heartbeat")
            return
        }
        LogUtils.d(TAG, "backend = $url, device = ${deviceId.take(8)}***")
        Coroutine.async {
            // 1) 拉取远端书源覆盖本地
            runCatching { fetchAndApplySources(url) }
                .onFailure { LogUtils.d(TAG, "fetch sources failed: ${it.message}") }
        }
        startHeartbeatLoop(url)
    }

    private suspend fun fetchAndApplySources(url: String) = withContext(Dispatchers.IO) {
        val resp = okHttpClient.newCallStrResponse(retry = 1) {
            url("$url/api/sources")
            header("X-Device-Id", deviceId)
            header("Accept", "application/json")
        }
        val body = resp.body ?: return@withContext
        val sources = GSON.fromJsonArray<BookSource>(body).getOrDefault(emptyList())
        if (sources.isEmpty()) {
            LogUtils.d(TAG, "remote returned 0 sources, keep local")
            return@withContext
        }
        // INSERT REPLACE 即可, 后端是权威源
        appDb.bookSourceDao.insert(*sources.toTypedArray())
        LogUtils.d(TAG, "applied ${sources.size} remote sources")
    }

    private fun startHeartbeatLoop(url: String) {
        Coroutine.async {
            // 启动后等 5 秒再开始上报,避免和首次拉取竞争
            delay(5_000)
            while (true) {
                runCatching { sendPing(url) }
                    .onFailure { LogUtils.d(TAG, "ping failed: ${it.message}") }
                delay(PING_INTERVAL_MS)
            }
        }
    }

    private suspend fun sendPing(url: String) = withContext(Dispatchers.IO) {
        val body = """{"device_id":"$deviceId"}""".toRequestBody("application/json".toMediaType())
        okHttpClient.newCallStrResponse(retry = 0) {
            url("$url/api/ping")
            header("X-Device-Id", deviceId)
            post(body)
        }
    }
}
