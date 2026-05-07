package io.legado.app.ad

import io.legado.app.BuildConfig
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.http.okHttpClient
import io.legado.app.utils.GSON
import io.legado.app.utils.LogUtils
import io.legado.app.utils.fromJsonObject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import splitties.init.appCtx

/**
 * 广告配置仓库.
 *
 * 数据流: 远端 `/api/ad-config` 优先 -> SP 缓存 -> assets 兜底.
 *
 * 故意不引入 androidx-datastore 依赖, 用项目里已有的 SharedPreferences 完成持久化:
 * 改一个键就够, 没有必要为此增包。
 */
object AdRepository {

    private const val TAG = "AdRepository"
    private const val SP_NAME = "wanxiang_ad"
    private const val KEY_CONFIG_JSON = "config_json"
    private const val KEY_CONFIG_VERSION = "config_version"
    private const val KEY_CONFIG_ETAG = "config_etag"
    private const val KEY_LAST_FETCH_MS = "last_fetch_ms"
    private const val DEFAULT_ASSET = "default_ad_config.json"

    private val sp by lazy {
        appCtx.getSharedPreferences(SP_NAME, android.content.Context.MODE_PRIVATE)
    }

    /** 内存缓存, 减少 SP / asset 反复 IO. 由 [refreshFromRemote] 与 [loadCached] 维护. */
    @Volatile
    private var cached: AdConfigEnvelope? = null

    /**
     * 同步获取最近一次的配置. 优先内存 -> SP -> assets 兜底.
     * 这是 UI / AdManager 在主线程也能直接调用的快路径.
     */
    fun current(): AdConfigEnvelope {
        cached?.let { return it }
        val fromSp = readSp()
        if (fromSp != null) {
            cached = fromSp
            return fromSp
        }
        val fromAsset = readAsset()
        cached = fromAsset
        return fromAsset
    }

    // 万象书屋 D-7 修复: single-flight 防多协程并发拉取覆盖 cached.
    // 多个调用方同时调 refreshFromRemote, 共享同一个 inFlight Deferred,
    // 减少网络请求 + 避免后到者覆盖 (etag/version 倒退体感).
    @Volatile
    private var inFlightRefresh: kotlinx.coroutines.Deferred<AdConfigEnvelope>? = null
    private val refreshMutex = kotlinx.coroutines.sync.Mutex()
    private val refreshScope = kotlinx.coroutines.CoroutineScope(
        kotlinx.coroutines.SupervisorJob() + Dispatchers.IO
    )

    /**
     * 后台拉取最新配置, 成功则覆盖 SP + 内存. 失败保留旧值.
     * 调用方负责放在协程里; 这里只做 IO.
     *
     * Single-flight: 多协程同时调用共享同一次 HTTP 请求. 适合 SplashAdActivity / AdManager.bootstrap /
     * showSplash isStale 兜底等同时触发的场景.
     */
    suspend fun refreshFromRemote(): AdConfigEnvelope {
        // 已有飞行中的刷新, 等它完成
        inFlightRefresh?.let { existing ->
            if (existing.isActive) return existing.await()
        }
        // 用 lock/unlock 不用 withLock, 避免 lambda suspend 推导问题
        refreshMutex.lock()
        val deferred: kotlinx.coroutines.Deferred<AdConfigEnvelope> = try {
            // double-check, 进 lock 之前可能别人已经发起
            inFlightRefresh?.takeIf { it.isActive }
                ?: refreshScope.async { doRefreshFromRemote() }.also { inFlightRefresh = it }
        } finally {
            refreshMutex.unlock()
        }
        try {
            return deferred.await()
        } finally {
            if (inFlightRefresh === deferred) inFlightRefresh = null
        }
    }

    private suspend fun doRefreshFromRemote(): AdConfigEnvelope = withContext(Dispatchers.IO) {
        val baseUrl = BuildConfig.BACKEND_BASE_URL.takeIf { it.isNotBlank() }
            ?: run {
                LogUtils.d(TAG, "BACKEND_BASE_URL not set, skip remote ad config")
                return@withContext current()
            }
        val cur = current()
        runCatching {
            val resp = okHttpClient.newCallStrResponse(retry = 1) {
                url("$baseUrl/api/ad-config")
                if (cur.etag.isNotEmpty()) header("If-None-Match", cur.etag)
                header("Accept", "application/json")
            }
            val code = resp.raw.code
            if (code == 304) {
                LogUtils.d(TAG, "ad config 304 (etag=${cur.etag}), keep cached")
                sp.edit().putLong(KEY_LAST_FETCH_MS, System.currentTimeMillis()).apply()
                return@runCatching cur
            }
            val body = resp.body ?: return@runCatching cur
            val env = GSON.fromJsonObject<AdConfigEnvelope>(body).getOrNull()
                ?: return@runCatching cur
            cached = env
            sp.edit()
                .putString(KEY_CONFIG_JSON, GSON.toJson(env))
                .putLong(KEY_CONFIG_VERSION, env.version)
                .putString(KEY_CONFIG_ETAG, env.etag)
                .putLong(KEY_LAST_FETCH_MS, System.currentTimeMillis())
                .apply()
            LogUtils.d(TAG, "ad config refreshed: v${env.version} etag=${env.etag}")
            env
        }.getOrElse {
            LogUtils.d(TAG, "refresh ad config failed: ${it.message}")
            cur
        }
    }

    /** 是否到了下次远程拉取的时刻. AdManager 用它决定要不要触发 [refreshFromRemote]. */
    fun shouldRefresh(): Boolean {
        val pollSec = current().config.pollIntervalSec.coerceAtLeast(60L)
        val last = sp.getLong(KEY_LAST_FETCH_MS, 0L)
        return System.currentTimeMillis() - last >= pollSec * 1000L
    }

    private fun readSp(): AdConfigEnvelope? {
        val json = sp.getString(KEY_CONFIG_JSON, null) ?: return null
        return GSON.fromJsonObject<AdConfigEnvelope>(json).getOrNull()
    }

    private fun readAsset(): AdConfigEnvelope {
        return runCatching {
            appCtx.assets.open(DEFAULT_ASSET).bufferedReader().use { it.readText() }
        }.mapCatching { GSON.fromJsonObject<AdConfigEnvelope>(it).getOrNull() }
            .getOrNull()
            ?: AdConfigEnvelope() // 兜底的兜底: 全默认 (disabled=true)
    }
}
