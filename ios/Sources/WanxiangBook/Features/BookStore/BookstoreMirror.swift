//
//  BookstoreMirror.swift
//  万象书屋 iOS · 书城 mirror cache (D-23 同 Android)
//
//  对应 Android: io.legado.app.help.WanxiangBookstoreMirror
//
//  工作流:
//   1. App 进书城 → QidianRepository 调 fetch() → GET <backend>/api/bookstore/mirror
//   2. 命中 304 用上次 cache, 200 解析新 JSON 缓存到内存
//   3. 后端不可用 / 返 503 / 空 cache → fetch() 返 nil → QidianRepository 降级直抓 m.qidian
//
//  节流策略:
//   - 内存缓存: 5 分钟内 hit 同一份 JSON, 不发任何请求
//   - HTTP ETag: 5 分钟过后发请求带 If-None-Match, 命中 304 不传 body 节省流量
//

import Foundation
import os

/// 后端 /api/bookstore/mirror 客户端
///
/// 跟 Android `WanxiangBookstoreMirror.kt` 行为完全对齐:
///   * `X-Device-Token` / `If-None-Match` / `Accept: application/json`
///   * 200 缓存到内存 + 记 ETag, 304 续期, 503 / 异常返 nil 让上层降级
///   * 弱网失败重试 1 次 (Android `okHttpClient.newCallStrResponse(retry = 1)`)
actor BookstoreMirror {

    private let log = Logger(subsystem: "com.wanxiang.reader", category: "BookstoreMirror")

    static let shared = BookstoreMirror()

    private let path = "/api/bookstore/mirror"
    private let memCacheTtl: TimeInterval = 5 * 60   // 5 分钟

    private var cachedPayload: [String: Any]?
    private var cachedAt: Date = .distantPast
    private var cachedEtag: String?

    /// 拉 mirror payload (JSON object).
    /// - parameter forceRefresh: true 时跳过内存 cache 强制发请求 (下拉刷新)
    /// - returns: 后端 cache JSON; nil = 后端不可用 / cache 全空 / 网络失败 — 调用方应降级直抓 m.qidian
    func fetch(forceRefresh: Bool = false) async -> [String: Any]? {
        if !forceRefresh,
           let mem = cachedPayload,
           Date().timeIntervalSince(cachedAt) < memCacheTtl {
            return mem
        }

        // retry = 1 (与 Android okHttpClient retry=1 对齐). 仅 transient (transport)
        // 错误重试; 503 / 200-但-body-坏 等"definitive"错误直接降级, 不浪费第二次请求.
        for attempt in 0..<2 {
            switch await fetchOnce() {
            case .ok(let payload):
                return payload
            case .definitive(let reason):
                log.debug("\(reason)")
                return nil
            case .transient(let reason):
                if attempt == 0 {
                    log.debug("transient \(reason), retry...")
                }
            }
        }
        return nil
    }

    private enum FetchOutcome {
        case ok([String: Any])
        case definitive(String)   // 不重试 (503 / non-2xx / 解析失败)
        case transient(String)    // 重试 (网络异常 / timeout / 连接断)
    }

    /// 专用 session: 禁用协议层 HTTP cache.
    /// `URLSession.shared` 默认 useProtocolCachePolicy 会把上次 200 + ETag 写 disk,
    /// 即使我们 cachedEtag = nil, 系统层也会自动加 If-None-Match → 永远 304 → 内存 cache
    /// 是空 → 死循环走 fallback. 这里专门用 reload 策略, 每次都发完整请求拿 body.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 6
        return URLSession(configuration: cfg)
    }()

    private func fetchOnce() async -> FetchOutcome {
        var mutable = WanxiangAPI.shared.request(path: path, method: "GET")
        // 注: 我们手动管理 etag (cachedEtag), 不依赖 URLSession 协议缓存. 上面 session 已禁用 urlCache.
        if let etag = cachedEtag {
            mutable.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        mutable.setValue("application/json", forHTTPHeaderField: "Accept")
        mutable.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, resp) = try await Self.session.data(for: mutable)
            guard let http = resp as? HTTPURLResponse else {
                return .transient("no HTTPURLResponse")
            }
            switch http.statusCode {
            case 304:
                cachedAt = Date()
                if let mem = cachedPayload {
                    return .ok(mem)
                }
                // 万象书屋 (perf P0): 冷启动场景下 cachedEtag 是上次进程持久化的 (or 错误持久化),
                // 但 cachedPayload 因为只在内存所以是 nil. 这时返 definitive 让上层 fallback 直抓
                // m.qidian.com — 那玩意儿对 iOS UA 经常 6-15s 不响应, 用户感知"书城一直在转圈".
                // 修法: 清掉 etag, 标 transient → 上层重试时不带 If-None-Match 走 200 body 路径,
                // 直接吃到 backend 内存里的 mirror, ~10ms 拿完.
                cachedEtag = nil
                return .transient("304 cold start (no in-mem cache), refetch without If-None-Match")
            case 200:
                guard !data.isEmpty,
                      let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .definitive("200 but body invalid")
                }
                cachedPayload = obj
                cachedAt = Date()
                cachedEtag = http.value(forHTTPHeaderField: "ETag")
                return .ok(obj)
            case 503:
                return .definitive("503 mirror not ready, fallback")
            default:
                return .definitive("unexpected code=\(http.statusCode), fallback")
            }
        } catch {
            return .transient(error.localizedDescription)
        }
    }

    /// 给单测 / 紧急排查用: 清掉内存 cache 让下次请求全新
    func clearCache() {
        cachedPayload = nil
        cachedAt = .distantPast
        cachedEtag = nil
    }
}
