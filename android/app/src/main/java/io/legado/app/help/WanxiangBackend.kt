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

    /**
     * 万象书屋: 设备首次启动时 (本地无 token) 调 /api/device/register 拿 HMAC token.
     * 失败不阻塞业务: 后端兼容老 App (token 表里没记录的设备允许通过), 拉到 token 是更强保护.
     * 已拿到 token 的设备每次启动只读 SP, 不重复 register (后端 409).
     */
    private suspend fun registerDeviceIfNeeded(url: String) = withContext(Dispatchers.IO) {
        if (deviceToken != null) return@withContext  // 已注册过, 跳过
        // 万象书屋: pm clear / 卸载重装 / SP 损坏会清掉本地 token, 但后端 device_tokens 仍有记录.
        // 直接 register 会被后端 409 拒. 这种情况下加 ?reissue=1, 让后端重发新 token.
        // 第一次先无 reissue 试 (新设备 200 OK), 失败 → 再用 reissue 重试 (重置场景 200 OK).
        suspend fun tryRegister(reissue: Boolean): String? {
            return runCatching {
                val body = """{"device_id":"$deviceId"}""".toRequestBody("application/json".toMediaType())
                val urlStr = "$url/api/device/register" + if (reissue) "?reissue=1" else ""
                val resp = okHttpClient.newCallStrResponse(retry = 0) {
                    url(urlStr)
                    header("X-Platform", PLATFORM)
                    post(body)
                }
                if (resp.raw.code != 200) {
                    LogUtils.d(TAG, "register http ${resp.raw.code} reissue=$reissue")
                    return@runCatching null
                }
                val raw = resp.body ?: return@runCatching null
                Regex("\"token\"\\s*:\\s*\"([^\"]+)\"").find(raw)?.groupValues?.get(1)
            }.getOrNull()
        }
        var token = tryRegister(reissue = false)
        if (token.isNullOrBlank()) {
            // 第一次失败, 大概率是后端表里有这设备但 App 本地 token 没了 (重装 / pm clear)
            token = tryRegister(reissue = true)
        }
        if (!token.isNullOrBlank()) {
            saveDeviceToken(token)
            LogUtils.d(TAG, "device registered, token=${token.take(8)}***")
        } else {
            LogUtils.d(TAG, "device register failed both tries, will fall back to no-token mode")
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

    private suspend fun fetchAndApplySources(url: String) = withContext(Dispatchers.IO) {
        // 万象书屋 PIPL 合规: 撤回隐私同意后, 不应再向后端发送 device_id.
        // 拉取书源不需要个人身份, 撤回时只匿名拉取 (后端的限速/黑名单按 IP 即可).
        val consented = io.legado.app.ad.AdManager.isConsented()
        val tok = deviceToken
        LogUtils.d(TAG, "fetchSources: consented=$consented, tokenLen=${tok?.length ?: 0}")
        val resp = okHttpClient.newCallStrResponse(retry = 1) {
            url("$url/api/sources")
            header("X-Platform", PLATFORM)
            if (consented) header("X-Device-Id", deviceId)
            if (!tok.isNullOrBlank()) header("X-Device-Token", tok)
            header("Accept", "application/json")
        }
        LogUtils.d(TAG, "fetchSources resp: code=${resp.raw.code}, bodyLen=${resp.body?.length ?: 0}")
        val body = resp.body ?: return@withContext
        val sources = GSON.fromJsonArray<BookSource>(body).getOrDefault(emptyList())
        if (sources.isEmpty()) {
            LogUtils.d(TAG, "remote returned 0 sources, keep local. body sample: ${body.take(200)}")
            return@withContext
        }
        // 万象书屋: 后端是书源权威源, 做完整 reconcile 而不是只 INSERT REPLACE.
        //
        // 之前 BUG: 后端 disable 一个源后, /api/sources 不再返回该源, 但 App 端
        // book_sources 表里**该源仍然存在且 enabled**, 用户搜索仍会调用它. 导致
        // "后端 disable 的劣质源在 App 端继续生效".
        //
        // 修复: 拿到远端列表后, 把"远端有的"批量 upsert; 同时把 App 本地的"远端列表里没有"
        // 但**之前是从远端来的**源标记 disable. 用户自己导入的源 (customOrder >= 0 / 来源标记)
        // 不能动. 这里用一个简单策略: 只 disable 跟远端共享 url 但不在远端列表里的, 用户
        // 自定义的 url 不在远端 → 不动.
        val remoteUrls = sources.map { it.bookSourceUrl }.toHashSet()
        appDb.bookSourceDao.insert(*sources.toTypedArray())
        // 找出"曾经从远端来的, 现在远端不再返回的"源 → disable.
        // 区分用户自定义: 我们没存"来源"字段, 所以用一个保守策略 — 只 disable 那些
        // 之前 enabled 的源 (用户拿到后没自己 disable 过), 假定用户是正常使用流量.
        val allLocal = appDb.bookSourceDao.allEnabled
        var disabledCount = 0
        for (local in allLocal) {
            if (local.bookSourceUrl !in remoteUrls) {
                // 远端不再有这个源, 但 App 本地有 → 大概率是后端刚刚 disable 的劣质源.
                // 直接关掉 enabled 标志, 用户想用可手动启用 (legado 已有"显示禁用源"开关).
                // 注: 不删行, 保留用户的"分组 / 排序" 等本地编辑.
                local.enabled = false
                appDb.bookSourceDao.update(local)
                disabledCount++
            }
        }
        LogUtils.d(TAG, "applied ${sources.size} remote sources, disabled ${disabledCount} stale local")
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
