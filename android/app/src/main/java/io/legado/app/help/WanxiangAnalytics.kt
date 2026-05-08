package io.legado.app.help

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.legado.app.BuildConfig
import io.legado.app.ad.AdManager
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.http.okHttpClient
import io.legado.app.utils.LogUtils
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import splitties.init.appCtx
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * 万象书屋: 自建埋点 SDK (替代友盟/神策)
 *
 * 用法:
 *   WanxiangAnalytics.track("btn_search", type = "click")
 *   WanxiangAnalytics.track("page_main", type = "pv", params = mapOf("from" to "splash"))
 *   WanxiangAnalytics.flush()  // 切后台时手动调
 *
 * 特性:
 *   - 内存队列 (ConcurrentLinkedQueue), 多线程 track() 不阻塞
 *   - 触发 flush 条件:
 *       a) 队列 >= 20 条
 *       b) 距上次 flush >= 30 秒 (定时器)
 *       c) 切后台时调 flush()
 *   - 单次最多 100 条 / 请求 (后端限制)
 *   - 失败把 batch 放回队首, 下次重试 (网络偶尔抖动不丢数据)
 *   - 队列上限 500 条溢出时丢最早的 (防止离线积累过多)
 *   - PIPL 一致性: 用户拒绝隐私协议时 track() 静默丢弃 (跟 reportAdEvent 同步)
 *
 * 隐私: 客户端只发 deviceId + 事件字段, 不上传任何其他设备识别码.
 *       服务端按 deviceId 聚合 PV/UV/留存.
 */
object WanxiangAnalytics {

    private const val TAG = "WxAnalytics"

    private const val MAX_QUEUE = 500
    private const val FLUSH_THRESHOLD = 20
    private const val FLUSH_INTERVAL_MS = 30_000L
    private const val MAX_PER_REQUEST = 100
    // A-3: 失败 batch 单独队列容量 (2 个 batch 量, 满了丢最早的 retry)
    private const val MAX_RETRY_QUEUE = 200
    // A-2: 失败退避上限 60 秒 (避免长时间无网络浪费电)
    private const val MAX_BACKOFF_MS = 60_000L

    private val queue = ConcurrentLinkedQueue<Event>()
    private val flushing = java.util.concurrent.atomic.AtomicBoolean(false)
    private val lastFlush = AtomicLong(0)

    // 万象书屋 D-16 (A-2): 连续失败计数, 用于指数退避.
    //   旧实现 finally 里 if (queue.size >= 20) flush() 立即递归, 断网时形成失败风暴.
    //   新实现: 失败 N 次 → 等 min(2^N, 60) 秒再 flush; 成功后清零.
    private val consecutiveFails = AtomicInteger(0)

    // 万象书屋 D-16 (A-3): 失败 batch 单独队列, 避免和新 track 事件混在一起.
    //   旧实现把失败 batch offer 回主队列尾, 后续溢出可能丢"中间"事件 (顺序错乱).
    //   新实现: 失败的 batch 整批存到 retryQueue, 下次 flush 优先处理 retry; 主 queue 保持纯净.
    //   retry 上限 200 条 (2 个 batch 量), 满了就丢弃最早的失败 batch.
    private val retryQueue = ConcurrentLinkedQueue<Event>()
    private val retryQueueSize = AtomicInteger(0)

    private val baseUrl: String? get() = BuildConfig.BACKEND_BASE_URL.takeIf { it.isNotBlank() }

    // 万象书屋 D-16 (A-7): anon ID 持久化到 SP, 避免每次进程重启变 ID 造成 DAU 严重虚高.
    //   旧实现: ANDROID_ID 拿不到时 fallback 'anon-${ts/1000}', 进程重启就换;
    //          从而后端 events 里同一台设备被识别为"很多新设备", DAU 飘高 5~10x.
    //   新实现: 第一次生成 anon ID 后存 SP, 后续启动复用.
    @Suppress("HardwareIds")
    private val deviceId: String by lazy {
        val real = runCatching {
            Settings.Secure.getString(appCtx.contentResolver, Settings.Secure.ANDROID_ID)
                ?.takeIf { it.isNotEmpty() && it != "9774d56d682e549c" }
        }.getOrNull()
        if (real != null) return@lazy real
        // 持久化 anon ID
        val sp = appCtx.getSharedPreferences("wanxiang_anon", Context.MODE_PRIVATE)
        sp.getString("anon_id", null)?.takeIf { it.isNotBlank() } ?: run {
            val newId = "anon-" + UUID.randomUUID().toString().take(20)
            sp.edit().putString("anon_id", newId).apply()
            LogUtils.d(TAG, "generated new anon_id (ANDROID_ID unavailable)")
            newId
        }
    }

    /** 客户端会话 ID. 进程存活期内固定; 进程重启换新. */
    private val sessionId: String = "s${System.currentTimeMillis()}-${(0..9999).random()}"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }
    private val flushRunnable = object : Runnable {
        override fun run() {
            if (queue.isNotEmpty()) flush()
            mainHandler.postDelayed(this, FLUSH_INTERVAL_MS)
        }
    }

    /** 在 Application.onCreate 里调一次, 启动周期性 flush. */
    fun init() {
        if (baseUrl == null) {
            LogUtils.d(TAG, "no backend url, analytics disabled")
            return
        }
        mainHandler.postDelayed(flushRunnable, FLUSH_INTERVAL_MS)
        LogUtils.d(TAG, "init done, sessionId=$sessionId")
    }

    /** 上报一个事件. 高频调用, 入队不阻塞. */
    @JvmStatic
    fun track(name: String, type: String = "custom", params: Map<String, Any?>? = null) {
        if (name.isBlank()) return
        if (baseUrl == null) return
        if (!AdManager.isConsented()) return  // PIPL: 用户撤回同意 -> 不再采集

        if (queue.size >= MAX_QUEUE) {
            // 溢出丢最早的, 让出空间
            queue.poll()
        }
        queue.offer(Event(System.currentTimeMillis(), type, name, params, sessionId))
        if (queue.size >= FLUSH_THRESHOLD) flush()
    }

    /**
     * 强制立即上报. 切后台 / 退出时调.
     *
     * 万象书屋 D-16 (A-2): 失败时不再立即递归 flush, 改为 [consecutiveFails] 指数退避 1-60s.
     * 万象书屋 D-16 (A-3): 失败 batch 进 [retryQueue] 单独排队, 不再污染主 [queue] 的顺序.
     */
    @JvmStatic
    fun flush() {
        if (queue.isEmpty() && retryQueue.isEmpty()) return
        if (!flushing.compareAndSet(false, true)) return
        scope.launch {
            try {
                // 优先发 retry batch (重试上次失败的)
                val batch = ArrayList<Event>(MAX_PER_REQUEST)
                while (batch.size < MAX_PER_REQUEST) {
                    val e = retryQueue.poll() ?: break
                    retryQueueSize.decrementAndGet()
                    batch.add(e)
                }
                // 如果 retry 装不满, 再从主队列取
                while (batch.size < MAX_PER_REQUEST) {
                    val e = queue.poll() ?: break
                    batch.add(e)
                }
                if (batch.isEmpty()) return@launch

                val ok = sendBatch(batch)
                if (!ok) {
                    val fails = consecutiveFails.incrementAndGet()
                    // 把这批送进 retryQueue (有限容量, 满了丢最早)
                    for (e in batch) {
                        if (retryQueueSize.get() >= MAX_RETRY_QUEUE) {
                            retryQueue.poll()?.let { retryQueueSize.decrementAndGet() }
                        }
                        retryQueue.offer(e)
                        retryQueueSize.incrementAndGet()
                    }
                    val backoffMs = (1000L shl minOf(fails - 1, 6))   // 1s, 2s, 4s ... 64s
                        .coerceAtMost(MAX_BACKOFF_MS)
                    LogUtils.d(TAG, "flush fail #$fails, retry size=${retryQueueSize.get()}, backoff=${backoffMs}ms")
                    // 异步等待退避, 不阻塞 finally / 不递归
                    flushing.set(false)
                    scheduleBackoffFlush(backoffMs)
                    return@launch
                }
                consecutiveFails.set(0)
                lastFlush.set(System.currentTimeMillis())
                LogUtils.d(TAG, "flush ok, sent ${batch.size}, remaining ${queue.size}+retry=${retryQueueSize.get()}")
            } finally {
                flushing.set(false)
                // 成功路径下: 主 queue 仍然有 >= FLUSH_THRESHOLD 条, 继续 flush (大批量场景).
                // 失败路径已 return @launch, 不会跑到这里.
                if (queue.size >= FLUSH_THRESHOLD && consecutiveFails.get() == 0) flush()
            }
        }
    }

    /** A-2: 安排 backoffMs 后再 flush 一次, 不递归. */
    private fun scheduleBackoffFlush(backoffMs: Long) {
        scope.launch {
            delay(backoffMs)
            // 不直接递归 flush(), 而是检查队列再决定 — 期间用户可能切到前台 + 手动 flush 已成功
            if (queue.isNotEmpty() || retryQueue.isNotEmpty()) flush()
        }
    }

    /**
     * 直接读 SP 拿 device token (跟 WanxiangBackend 同 KV).
     * 避免 Analytics 调 WanxiangBackend 形成循环依赖.
     */
    private fun readDeviceToken(): String? {
        return appCtx.getSharedPreferences("wanxiang_device", android.content.Context.MODE_PRIVATE)
            .getString("token", null)?.takeIf { it.isNotBlank() }
    }

    private suspend fun sendBatch(batch: List<Event>): Boolean {
        val url = baseUrl ?: return false
        return runCatching {
            val payload = buildJson(batch)
            val resp = okHttpClient.newCallStrResponse(retry = 0) {
                url("$url/api/events")
                header("X-Platform", "android")
                header("X-Device-Id", deviceId)
                readDeviceToken()?.let { header("X-Device-Token", it) }
                post(payload.toRequestBody("application/json".toMediaType()))
            }
            val body = resp.body ?: return@runCatching false
            body.contains("\"ok\":true")
        }.getOrElse {
            LogUtils.d(TAG, "sendBatch error: ${it.message}")
            false
        }
    }

    private fun buildJson(batch: List<Event>): String {
        val sb = StringBuilder(batch.size * 200)
        sb.append('{').append("\"sessionId\":\"").append(sessionId).append("\",")
        sb.append("\"appVer\":\"").append(BuildConfig.VERSION_NAME).append("\",")
        sb.append("\"events\":[")
        batch.forEachIndexed { i, e ->
            if (i > 0) sb.append(',')
            sb.append('{')
            sb.append("\"ts\":").append(e.ts).append(',')
            sb.append("\"type\":").append(jsonStr(e.type)).append(',')
            sb.append("\"name\":").append(jsonStr(e.name))
            if (e.params != null && e.params.isNotEmpty()) {
                sb.append(",\"params\":").append(paramsToJson(e.params))
            }
            sb.append('}')
        }
        sb.append("]}")
        return sb.toString()
    }

    private fun paramsToJson(p: Map<String, Any?>): String {
        val sb = StringBuilder()
        sb.append('{')
        var first = true
        for ((k, v) in p) {
            if (!first) sb.append(','); first = false
            sb.append(jsonStr(k)).append(':')
            when (v) {
                null -> sb.append("null")
                is Number, is Boolean -> sb.append(v.toString())
                else -> sb.append(jsonStr(v.toString()))
            }
        }
        sb.append('}')
        return sb.toString()
    }

    private fun jsonStr(s: String): String {
        val sb = StringBuilder(s.length + 2)
        sb.append('"')
        for (c in s) {
            when (c) {
                '\\' -> sb.append("\\\\")
                '"' -> sb.append("\\\"")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                in '\u0000'..'\u001F' -> sb.append("\\u%04x".format(c.code))
                else -> sb.append(c)
            }
        }
        sb.append('"')
        return sb.toString()
    }

    private data class Event(
        val ts: Long,
        val type: String,
        val name: String,
        val params: Map<String, Any?>?,
        val sessionId: String,
    )
}
