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
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
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

    // 万象书屋: 平台标识. 后端 (006_multi_platform.sql) 通过 X-Platform header 区分
    // android / ios / web. 老 App 不发的话后端默认 android, 兼容存量数据.
    private const val PLATFORM = "android"

    private val baseUrl: String? get() = BuildConfig.BACKEND_BASE_URL.takeIf { it.isNotBlank() }

    /**
     * 设备唯一标识 (Settings.Secure.ANDROID_ID), 用于后端去重统计.
     * 不上传任何其他设备信息.
     *
     * 万象书屋 D-16 (A-7): ANDROID_ID 拿不到时 fallback 走 anon ID, 持久化到 SP wanxiang_anon
     * (与 WanxiangAnalytics 共用同一 KV, 保证两侧 deviceId 一致). 旧实现用 currentTimeMillis()
     * 作 anon ID, 进程重启就换, 后端把同一台设备识别为多个新设备 → DAU 5-10x 虚高.
     */
    private val deviceId: String by lazy {
        @Suppress("HardwareIds")
        val real = runCatching {
            Settings.Secure.getString(appCtx.contentResolver, Settings.Secure.ANDROID_ID)
                ?.takeIf { it.isNotEmpty() && it != "9774d56d682e549c" }
        }.getOrNull()
        if (real != null) return@lazy real
        val sp = appCtx.getSharedPreferences("wanxiang_anon", android.content.Context.MODE_PRIVATE)
        sp.getString("anon_id", null)?.takeIf { it.isNotBlank() } ?: run {
            val newId = "anon-" + java.util.UUID.randomUUID().toString().take(20)
            sp.edit().putString("anon_id", newId).apply()
            LogUtils.d(TAG, "generated new anon_id (ANDROID_ID unavailable)")
            newId
        }
    }

    /**
     * 万象书屋: 后端给本设备签发的 HMAC token, 用于防 device_id 伪造.
     *
     * 来源 SP wanxiang_device_token, 由 [registerDeviceIfNeeded] 在首次启动时拉取.
     * 一旦后端 device_tokens 表有该设备记录, 后端的 verifyDeviceToken 中间件
     * 会要求所有受保护接口 (sources / ping / ad-event / crash / feedback / redeem) 都带这个 token.
     * 没接线的话生产环境 device_tokens 表一旦有数据, 客户端立刻全线 401.
     */
    private const val DEVICE_TOKEN_SP = "wanxiang_device"
    private const val DEVICE_TOKEN_KEY = "token"
    private val deviceToken: String?
        get() {
            val sp = appCtx.getSharedPreferences(DEVICE_TOKEN_SP, android.content.Context.MODE_PRIVATE)
            return sp.getString(DEVICE_TOKEN_KEY, null)?.takeIf { it.isNotBlank() }
        }
    private fun saveDeviceToken(token: String) {
        // 万象书屋: 用 commit() 而非 apply(), register 完成后立即被 fetchSources 读取,
        // apply() 异步写盘可能让中间几十毫秒读到 null (虽然内存层应该立即生效, 实测有概率丢).
        appCtx.getSharedPreferences(DEVICE_TOKEN_SP, android.content.Context.MODE_PRIVATE)
            .edit().putString(DEVICE_TOKEN_KEY, token).commit()
    }

    // 万象书屋 D-15 修复 (A-1): 持久化"上次拉到的远端 URL 集合", 用于 fetchAndApplySources 做精确 reconcile.
    //
    // 旧实现 BUG: 把所有"不在当前远端列表"的本地 enabled 源全部 disable, 包括用户自己导入的私人源.
    // 用户每次冷启动后发现书架阅读源全失效, 必须手动逐个开启.
    //
    // 新实现: 只 disable "之前是远端推过的, 现在远端不再返回" (即"远端撤源")的源.
    // 第一次启动 (SP 空) 永远不 disable 任何本地源, 安全降级.
    // 升级用户的私人源不会被误关; 远端撤源仍能正确同步.
    private const val REMOTE_URLS_SP = "wanxiang_remote_sources"
    private const val REMOTE_URLS_KEY = "urls_v1"

    private fun readPreviousRemoteUrls(): Set<String> {
        return appCtx.getSharedPreferences(REMOTE_URLS_SP, android.content.Context.MODE_PRIVATE)
            .getStringSet(REMOTE_URLS_KEY, emptySet()) ?: emptySet()
    }

    private fun savePreviousRemoteUrls(urls: Set<String>) {
        // apply() 即可, 这个 SP 即使丢一两次写也只影响下次同步精确度, 不阻塞业务.
        appCtx.getSharedPreferences(REMOTE_URLS_SP, android.content.Context.MODE_PRIVATE)
            .edit().putStringSet(REMOTE_URLS_KEY, urls).apply()
    }

    /**
     * 万象书屋: 设备首次启动时 (本地无 token) 调 /api/device/register 拿 HMAC token.
     * 失败不阻塞业务: 后端兼容老 App (token 表里没记录的设备允许通过), 拉到 token 是更强保护.
     * 已拿到 token 的设备每次启动只读 SP, 不重复 register (后端 409).
     *
     * 万象书屋 D-16 (B-6): 区分 4xx vs 5xx —
     *   - 200: 成功
     *   - 409: 已注册 (后端 device_tokens 里有 + App 本地 SP 没了, 走 reissue=1)
     *   - 其它 4xx (400 invalid / 429 limit): 真错误, 不 reissue (浪费名额)
     *   - 5xx / 网络: 服务端故障, 不 reissue (本次放弃, 下次启动再试)
     *
     * 万象书屋 D-16 (API-1): 用 GSON 解析 token, 替代脆弱的 Regex 提取.
     */
    private suspend fun registerDeviceIfNeeded(url: String) = withContext(Dispatchers.IO) {
        if (deviceToken != null) return@withContext  // 已注册过, 跳过

        /** @return Pair(token?, httpCode). httpCode==-1 表示网络异常 / 0 表示成功. */
        suspend fun tryRegister(reissue: Boolean): Pair<String?, Int> {
            return runCatching {
                val body = """{"device_id":"$deviceId"}""".toRequestBody("application/json".toMediaType())
                val urlStr = "$url/api/device/register" + if (reissue) "?reissue=1" else ""
                val resp = okHttpClient.newCallStrResponse(retry = 0) {
                    url(urlStr)
                    header("X-Platform", PLATFORM)
                    post(body)
                }
                val code = resp.raw.code
                if (code != 200) {
                    LogUtils.d(TAG, "register http $code reissue=$reissue")
                    return@runCatching null to code
                }
                val raw = resp.body ?: return@runCatching null to code
                val token = runCatching {
                    GSON.fromJson(raw, com.google.gson.JsonObject::class.java)
                        ?.get("token")?.takeIf { !it.isJsonNull }?.asString
                }.getOrNull()
                token to code
            }.getOrElse { e ->
                LogUtils.d(TAG, "register network err: ${e.message}")
                null to -1
            }
        }

        val (token1, code1) = tryRegister(reissue = false)
        var finalToken = token1
        if (finalToken.isNullOrBlank()) {
            // B-6: 仅 409 (Conflict — 后端表已存) 才 reissue; 4xx/5xx/网络错全部放弃, 不浪费限速.
            if (code1 == 409) {
                LogUtils.d(TAG, "register got 409, retrying with reissue=1")
                val (token2, _) = tryRegister(reissue = true)
                finalToken = token2
            } else {
                LogUtils.d(TAG, "register code=$code1, skip reissue (only 409 retries)")
            }
        }
        if (!finalToken.isNullOrBlank()) {
            saveDeviceToken(finalToken)
            LogUtils.d(TAG, "device registered, token=${finalToken.take(8)}***")
        } else {
            LogUtils.d(TAG, "device register failed (code=$code1), fall back to no-token mode")
        }
    }


    fun start() {
        val url = baseUrl ?: run {
            LogUtils.d(TAG, "BACKEND_BASE_URL not configured, skip remote sync & heartbeat")
            return
        }
        LogUtils.d(TAG, "backend = $url, device = ${deviceId.take(8)}***")
        Coroutine.async {
            // 万象书屋: 首次启动注册设备拿 HMAC token, 后续上报全部带 X-Device-Token.
            // 已注册过的设备只读 SP, 不重复 register.
            runCatching { registerDeviceIfNeeded(url) }
                .onFailure { LogUtils.d(TAG, "device register failed: ${it.message}") }
            // 1) 拉取远端书源覆盖本地
            runCatching { fetchAndApplySources(url) }
                .onFailure { LogUtils.d(TAG, "fetch sources failed: ${it.message}") }
        }
        startHeartbeatLoop(url)
    }

    // ===== 万象书屋 (方案 G' 客户端): X-Sources-Etag 被动同步 =====
    //
    // 思路: 任何 backend API 响应都会带 `X-Sources-Etag: <当前服务端 sources etag>` header.
    // OkHttp 拦截器 (HttpHelper.kt) 在收到响应时调 [noteServerSourcesEtag], 这里比对内存里
    // 的 lastKnownEtag, 不一致才静默拉一次 /api/sources. 一致就完全不动 (零流量, 零延迟).
    //
    // 配合切前台 [refreshOnBecameForeground] 兜底, 撤源延迟 ≤ 1 个心跳周期 (4 分钟).

    @Volatile
    private var lastKnownSourcesEtag: String? = null

    @Volatile
    private var refreshInflight: Boolean = false

    /**
     * 由全局 OkHttp 响应拦截器调. 任何带 backend host 的响应都会顺路捎回 etag header.
     * 不阻塞调用方; etag 一致直接跳过, 不一致才起 coroutine 后台 sync.
     */
    fun noteServerSourcesEtag(remoteEtag: String?) {
        if (remoteEtag.isNullOrBlank()) return
        val url = baseUrl ?: return
        // 冷启时 start() 会自己拉一次, 这里不抢跑. 用 lastKnownSourcesEtag != null 当"已初始化"信号 —
        // 第一次 fetchAndApplySources 成功后会设, 之后任何 etag drift 才走这条路径.
        if (lastKnownSourcesEtag == null) return
        if (remoteEtag == lastKnownSourcesEtag) return
        // 防并发: 已经在跑了不重复
        if (refreshInflight) return
        refreshInflight = true
        Coroutine.async {
            runCatching {
                LogUtils.d(TAG, "etag drift (local=$lastKnownSourcesEtag server=$remoteEtag), refreshing sources")
                fetchAndApplySources(url)
                lastKnownSourcesEtag = remoteEtag
            }.onFailure {
                LogUtils.d(TAG, "etag-driven refresh failed: ${it.message}")
            }
        }.onFinally {
            refreshInflight = false
        }
    }

    /**
     * App 切回前台兜底刷新一次. 调用方应在 ProcessLifecycleOwner ON_START 时触发.
     * 冷启时 [start] 已经会跑 fetchAndApplySources, 这里加 guard 避免冷启重复跑两次浪费 160KB.
     */
    fun refreshOnBecameForeground() {
        val url = baseUrl ?: return
        // 等 start() 至少跑过一次 (lastKnownSourcesEtag 非空) 才走前台兜底, 避免冷启 onStart 抢跑
        if (lastKnownSourcesEtag == null) return
        if (refreshInflight) return
        refreshInflight = true
        Coroutine.async {
            runCatching { fetchAndApplySources(url) }
                .onFailure { LogUtils.d(TAG, "foreground refresh failed: ${it.message}") }
        }.onFinally {
            refreshInflight = false
        }
    }

    private suspend fun fetchAndApplySources(url: String) = withContext(Dispatchers.IO) {
        // 万象书屋 PIPL 合规: 撤回隐私同意后, 不应再向后端发送 device_id.
        // 拉取书源不需要个人身份, 撤回时只匿名拉取 (后端的限速/黑名单按 IP 即可).
        val consented = io.legado.app.ad.AdManager.isConsented()
        val tok = deviceToken
        LogUtils.d(TAG, "fetchSources: consented=$consented, tokenLen=${tok?.length ?: 0}")
        val cachedEtag = lastKnownSourcesEtag
        val resp = okHttpClient.newCallStrResponse(retry = 1) {
            url("$url/api/sources")
            header("X-Platform", PLATFORM)
            if (consented) header("X-Device-Id", deviceId)
            if (!tok.isNullOrBlank()) header("X-Device-Token", tok)
            header("Accept", "application/json")
            // 万象书屋 (方案 G'): 主动带 If-None-Match. 服务端 ETag 不变 → 304, 1 KB 0 改动.
            // 仅在内存里有 etag 时才带 (冷启 first run 拿不到 304 优化, 但这是符合预期的).
            if (!cachedEtag.isNullOrBlank()) header("If-None-Match", cachedEtag)
        }
        LogUtils.d(TAG, "fetchSources resp: code=${resp.raw.code}, bodyLen=${resp.body?.length ?: 0}")

        // 万象书屋 (方案 G'): 304 = "你的还是最新", 不动本地 sources, 仅 etag 已确认.
        if (resp.raw.code == 304) {
            LogUtils.d(TAG, "fetchSources 304 (etag stable), keep local")
            return@withContext
        }

        val body = resp.body ?: return@withContext
        // 万象书屋 (方案 G'): 记下当前服务端 sources etag, 给 noteServerSourcesEtag 用作"基线".
        // 第一次设上后, 后续任何接口响应里的 X-Sources-Etag 一致就跳过, 不一致才主动重拉.
        resp.raw.header("ETag")?.takeIf { it.isNotBlank() }?.let { lastKnownSourcesEtag = it }
        val sources = GSON.fromJsonArray<BookSource>(body).getOrDefault(emptyList())
        if (sources.isEmpty()) {
            LogUtils.d(TAG, "remote returned 0 sources, keep local. body sample: ${body.take(200)}")
            return@withContext
        }
        // 万象书屋: 后端是书源权威源, 做精确 reconcile.
        //
        // 当前策略 (跟 iOS `BookSourceRegistry.refresh` 对齐):
        //   1. 读上次保存的"远端 URL 集合" prevRemoteUrls (首次启动为空集)
        //   2. 把当前远端列表批量 upsert (覆盖名称/规则, enabled 字段以远端为准)
        //   3. **直接删除** "url ∈ prevRemoteUrls AND url ∉ currentRemoteUrls" 的源 →
        //      命中"之前由远端推过, 现在远端撤回"的源 (后端 disable / 删除 / 调整 platforms 后不再下发).
        //      用户从未由远端推过的私人源 (不在 prev 集合) 永远不动 → 本地 JSON 导入安全.
        //   4. 把 currentRemoteUrls 持久化, 给下次比对.
        //
        // 历史: 之前是 "撤源 → disable" (留个壳子), 但用户希望"之前的不要留存了",
        //   所以本次改成 hard delete. 已经被错误 disable 的旧源, 在升级用户首次 reconcile
        //   时如果它的 url 仍然在 prevRemoteUrls 里 (上一版本写入的), 就会自动被删掉; 否则
        //   保持 disabled 状态.
        //
        // 首次启动 / 升级首次跑: prevRemoteUrls = ∅ → 不删任何本地源, 安全降级.
        val remoteUrls: Set<String> = sources.map { it.bookSourceUrl }.toHashSet()
        val previousRemoteUrls = readPreviousRemoteUrls()
        appDb.bookSourceDao.insert(*sources.toTypedArray())

        var deletedCount = 0
        if (previousRemoteUrls.isNotEmpty()) {
            // 求差集: 之前远端推过, 现在远端不再返回 = 后端撤源
            val withdrawn = previousRemoteUrls - remoteUrls
            if (withdrawn.isNotEmpty()) {
                appDb.runInTransaction {
                    for (url in withdrawn) {
                        // 复用 SourceHelp.deleteBookSourceInternal 等价行为, 但跨模块直接调 dao
                        // 避免 SourceHelp 在测试时拉到 SourceConfig / AppCacheManager 等重量级依赖.
                        appDb.bookSourceDao.delete(url)
                        deletedCount++
                    }
                }
            }
        }
        savePreviousRemoteUrls(remoteUrls)
        LogUtils.d(
            TAG,
            "applied ${sources.size} remote sources, " +
                "deleted $deletedCount withdrawn (prev=${previousRemoteUrls.size})"
        )
    }

    private fun startHeartbeatLoop(url: String) {
        Coroutine.async {
            // 启动后等 5 秒再开始上报,避免和首次拉取竞争
            delay(5_000)
            // 万象书屋: 失败指数退避, 后端宕机时避免 App 每 4 分钟无脑重试浪费流量/电.
            // 成功后重置为正常间隔.
            var backoffMs = PING_INTERVAL_MS
            while (true) {
                val ok = runCatching { sendPing(url) }
                    .onFailure { LogUtils.d(TAG, "ping failed: ${it.message}") }
                    .isSuccess
                if (ok) {
                    backoffMs = PING_INTERVAL_MS
                } else {
                    // 2 倍退避, 最多 30 分钟
                    backoffMs = (backoffMs * 2).coerceAtMost(30 * 60 * 1000L)
                }
                delay(backoffMs)
            }
        }
    }

    private suspend fun sendPing(url: String) = withContext(Dispatchers.IO) {
        // 万象书屋 PIPL 合规: 撤回同意后停止上报 device_id (心跳本质是 DAU 统计, 没同意不能用个人标识).
        // 完全停掉心跳会破坏后端在线统计, 但跟产品/合规口径一致 — 撤回 = 不再被识别为活跃用户.
        if (!io.legado.app.ad.AdManager.isConsented()) {
            LogUtils.d(TAG, "ping: consent revoked, skip")
            return@withContext
        }
        val body = """{"device_id":"$deviceId"}""".toRequestBody("application/json".toMediaType())
        okHttpClient.newCallStrResponse(retry = 0) {
            url("$url/api/ping")
            header("X-Platform", PLATFORM)
            header("X-Device-Id", deviceId)
            deviceToken?.let { header("X-Device-Token", it) }
            post(body)
        }
    }

    // === 万象书屋: 广告事件 / 崩溃上报 ===

    /**
     * 广告事件上报 (fire-and-forget), 失败吞掉不影响业务.
     * type: load / show / click / close / reward / error
     *
     * 万象书屋 PIPL: 用户撤回隐私同意后立即停止上报 deviceId, 否则隐私违规.
     */
    fun reportAdEvent(
        placement: String,
        provider: String,
        type: String,
        errCode: Int? = null,
        errMsg: String? = null,
    ) {
        if (!io.legado.app.ad.AdManager.isConsented()) return
        val url = baseUrl ?: return
        Coroutine.async {
            runCatching {
                val json = buildString {
                    append('{')
                    append("\"placement\":").append(jsonStr(placement)).append(',')
                    append("\"provider\":").append(jsonStr(provider)).append(',')
                    append("\"type\":").append(jsonStr(type)).append(',')
                    if (errCode != null) append("\"errCode\":").append(errCode).append(',')
                    if (errMsg != null) append("\"errMsg\":").append(jsonStr(errMsg)).append(',')
                    append("\"deviceId\":").append(jsonStr(deviceId)).append(',')
                    append("\"appVer\":").append(jsonStr(BuildConfig.VERSION_NAME))
                    append('}')
                }
                okHttpClient.newCallStrResponse(retry = 0) {
                    url("$url/api/ad-event")
                    header("X-Platform", PLATFORM)
                    header("X-Device-Id", deviceId)
                    deviceToken?.let { header("X-Device-Token", it) }
                    post(json.toRequestBody("application/json".toMediaType()))
                }
            }.onFailure { LogUtils.d(TAG, "ad event drop: ${it.message}") }
        }
    }

    /**
     * 崩溃上报: mini Sentry, 只在进程即将终止时的 CrashHandler 调用.
     * 内部 runBlocking 跑 suspend 版 OkHttp + 5s 超时, 调用方已在独立线程.
     * 万象书屋 PIPL: 用户撤回隐私同意后停止上报 deviceId.
     */
    fun reportCrashSync(
        exception: String,
        stack: String,
        brand: String?,
        model: String?,
        sdkInt: Int?,
        appVer: String?,
    ) {
        if (!io.legado.app.ad.AdManager.isConsented()) return
        val url = baseUrl ?: return
        runCatching {
            val payload = buildString {
                append('{')
                append("\"exception\":").append(jsonStr(exception)).append(',')
                append("\"stack\":").append(jsonStr(stack)).append(',')
                append("\"deviceId\":").append(jsonStr(deviceId)).append(',')
                if (!brand.isNullOrEmpty()) append("\"brand\":").append(jsonStr(brand)).append(',')
                if (!model.isNullOrEmpty()) append("\"model\":").append(jsonStr(model)).append(',')
                if (sdkInt != null) append("\"sdkInt\":").append(sdkInt).append(',')
                append("\"appVer\":").append(jsonStr(appVer ?: ""))
                append('}')
            }
            runBlocking {
                withTimeoutOrNull(5_000) {
                    okHttpClient.newCallStrResponse(retry = 0) {
                        url("$url/api/crash-log")
                        header("X-Platform", PLATFORM)
                        header("X-Device-Id", deviceId)
                        deviceToken?.let { header("X-Device-Token", it) }
                        post(payload.toRequestBody("application/json".toMediaType()))
                    }
                }
            }
        }
    }

    /**
     * 万象书屋: 提交用户反馈/举报. 调用方在 IO 线程内 await.
     * @return true=提交成功, false=网络/校验失败 / 用户撤回隐私同意
     *
     * PIPL 一致性: 跟 reportAdEvent / reportCrashSync 保持同一策略,
     * 用户撤回同意后不带 deviceId 上报. (反馈本身用户主动行为, 但因为 payload
     * 含 deviceId, 仍受同意策略约束)
     */
    suspend fun submitFeedback(type: String, content: String, contact: String): Boolean {
        if (!io.legado.app.ad.AdManager.isConsented()) return false
        val url = baseUrl ?: return false
        return runCatching {
            val payload = buildString {
                append('{')
                append("\"type\":").append(jsonStr(type)).append(',')
                append("\"content\":").append(jsonStr(content)).append(',')
                if (contact.isNotEmpty()) append("\"contact\":").append(jsonStr(contact)).append(',')
                append("\"deviceId\":").append(jsonStr(deviceId)).append(',')
                append("\"appVer\":").append(jsonStr(BuildConfig.VERSION_NAME))
                append('}')
            }
            val resp = okHttpClient.newCallStrResponse(retry = 0) {
                url("$url/api/feedback")
                header("X-Platform", PLATFORM)
                header("X-Device-Id", deviceId)
                deviceToken?.let { header("X-Device-Token", it) }
                post(payload.toRequestBody("application/json".toMediaType()))
            }
            // 万象书屋: 用 JSON parse 替代 contains, 避免后端将来加嵌套 "ok":true 引发误判
            val body = resp.body ?: return@runCatching false
            val obj = runCatching { GSON.fromJson(body, com.google.gson.JsonObject::class.java) }.getOrNull()
            obj?.get("ok")?.takeIf { !it.isJsonNull }?.asBoolean == true
        }.getOrElse { false }
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
}
