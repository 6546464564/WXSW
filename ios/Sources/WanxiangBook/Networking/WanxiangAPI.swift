//
//  WanxiangAPI.swift
//  万象书屋 iOS · 后端 HTTP 客户端
//
//  跟 Android `app/src/main/java/io/legado/app/help/WanxiangBackend.kt` 1:1 对齐 header 协议.
//
//  设计:
//   - 单例 actor, 线程安全
//   - 全部请求自动带 X-Platform: ios + X-Device-Id + X-Device-Token (有的话)
//   - async/await, 不用 callback
//   - 设备 ID 存 Keychain, App 卸载重装也保留 (除非用户清 Keychain)
//   - 错误用 enum APIError 区分网络 / 服务端 / 401 重新注册
//
//  M0-I3 阶段实现:
//   - registerDeviceIfNeeded()   ← M0 必须
//   - fetchSources()             ← M0 必须 (验证后端 platform 过滤)
//   - sendPing()                 ← M0 必须 (心跳)
//   - 其余 M2 各阶段补
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

actor WanxiangAPI {

    static let shared = WanxiangAPI()

    // 万象书屋: 后端 URL.
    // 优先级: launch arg `--BackendURL <url>` > UserDefaults `wx.backendURL` > 默认生产
    // 本地开发可在 Scheme/launch args 加: --BackendURL http://localhost:3000
    // M0 联调用 IP, M5 备案完成切 https://api.wanxiangbook.com (Info.plist ATS 例外可删)
    static let baseURL: URL = {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--BackendURL"), i + 1 < args.count,
           let u = URL(string: args[i + 1]) {
            return u
        }
        if let s = UserDefaults.standard.string(forKey: "wx.backendURL"),
           let u = URL(string: s) {
            return u
        }
        return URL(string: "http://104.224.156.240")!
    }()

    /// 平台标识. 跟 Android PLATFORM = "android" 对齐
    static let platform = "ios"

    // MARK: - 设备身份

    /// 设备 ID. 优先 Keychain (重装保留), 没有则用 IDFV (Identifier for Vendor)
    nonisolated var deviceId: String {
        if let cached = Keychain.read(.deviceId) {
            return cached
        }
        // 万象书屋: IDFV 作为初次种子, 写入 Keychain. 重装 IDFV 会变, 但 Keychain 有了就稳
        let id = currentIDFV() ?? UUID().uuidString
        Keychain.write(.deviceId, id)
        return id
    }

    /// 后端签发的 HMAC token, 由 registerDevice 写入
    nonisolated var deviceToken: String? {
        get { Keychain.read(.deviceToken) }
    }

    // MARK: - URLSession

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": Self.userAgent,
        ]
        self.session = URLSession(configuration: cfg)
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - 通用请求

    /// 构造一个带通用 header 的 URLRequest
    /// 万象书屋: path 可含 query (`?a=b&c=d`), 不会被 URL-encode 成 `%3F`
    /// bug #11 fix: 用 URLComponents resolve, 避免畸形 path 静默落到 root
    nonisolated func request(path: String, method: String = "GET") -> URLRequest {
        let baseStr = Self.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let p = path.hasPrefix("/") ? path : "/" + path
        let candidate = baseStr + p
        var full: URL
        if let u = URL(string: candidate), u.host != nil {
            full = u
        } else if let comp = URLComponents(string: candidate), let u = comp.url, u.host != nil {
            full = u
        } else {
            // 真正畸形: 至少把 path 显式加到 baseURL 下
            full = Self.baseURL.appendingPathComponent(p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            print("[WanxiangAPI] WARNING: malformed path \"\(path)\", fallback to \(full)")
        }
        var r = URLRequest(url: full)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Self.platform, forHTTPHeaderField: "X-Platform")
        r.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        if let tok = deviceToken {
            r.setValue(tok, forHTTPHeaderField: "X-Device-Token")
        }
        return r
    }

    /// 通用 send: 状态码校验 + JSON 解析
    func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpStatus(http.statusCode, body: body)
        }
        return try decoder.decode(T.self, from: data)
    }

    /// 不关心结果的 fire-and-forget POST (心跳 / 广告事件)
    nonisolated func sendIgnoreResult(_ req: URLRequest) {
        Task.detached { [weak self] in
            _ = try? await self?.session.data(for: req)
        }
    }

    // MARK: - Endpoints

    /// 注册设备 (没 token 时调; 失败可重试). 跟后端 `/api/device/register` 对齐.
    func registerDeviceIfNeeded() async throws {
        if deviceToken != nil { return }   // 已有 token, 跳过
        var r = request(path: "/api/device/register", method: "POST")
        let body = ["device_id": deviceId]
        r.httpBody = try encoder.encode(body)

        struct RegResp: Decodable {
            let ok: Bool
            let token: String?
            let platform: String?
            let msg: String?
        }
        do {
            let resp = try await send(r, as: RegResp.self)
            guard resp.ok, let token = resp.token else {
                throw APIError.serverRejected(resp.msg ?? "register failed")
            }
            // 写 Keychain
            Keychain.write(.deviceToken, token)
            print("[WanxiangAPI] device registered, token=\(token.prefix(8))*** platform=\(resp.platform ?? "?")")
        } catch APIError.httpStatus(409, _) {
            // 万象书屋: 后端拒重复注册. 这意味着 device_id 已经被注册过但 Keychain 没存 token,
            // 走 reissue 路径
            try await reissueToken()
        }
    }

    /// 服务端拒了重复注册 → 用 ?reissue=1 重新拿 token (Android 同款流程)
    private func reissueToken() async throws {
        var r = request(path: "/api/device/register?reissue=1", method: "POST")
        let body = ["device_id": deviceId]
        r.httpBody = try encoder.encode(body)
        struct RegResp: Decodable { let ok: Bool; let token: String? }
        let resp = try await send(r, as: RegResp.self)
        guard resp.ok, let token = resp.token else { throw APIError.serverRejected("reissue failed") }
        Keychain.write(.deviceToken, token)
    }

    /// 拉远端书源. 后端会按 X-Platform: ios 过滤 (M0-B2).
    /// 返回原始 JSON 数组 (具体解析在 M1 BookSourceEngine 完成)
    func fetchSources(ifNoneMatch etag: String? = nil) async throws -> (sources: [Any], etag: String?) {
        var r = request(path: "/api/sources", method: "GET")
        if let e = etag { r.setValue(e, forHTTPHeaderField: "If-None-Match") }

        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }

        let newEtag = http.value(forHTTPHeaderField: "ETag")
        if http.statusCode == 304 { return ([], etag) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let any = try JSONSerialization.jsonObject(with: data) as? [Any] ?? []
        return (any, newEtag)
    }

    /// 心跳, 4 分钟一次. AppState.startHeartbeatLoop 调.
    /// 后端 /api/ping 限速 10s/次, 我们 4 min 一次远低于上限.
    func sendPing() async {
        var r = request(path: "/api/ping", method: "POST")
        // 万象书屋: 后端要求 body 含 device_id, header 也要 X-Device-Id
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": deviceId])
        _ = try? await session.data(for: r)
    }

    /// 拉公告 (启动后展示一次, UserDefaults 记 last_seen_id 不重复弹)
    func fetchAnnouncement() async throws -> AnnouncementInfo? {
        let r = request(path: "/api/announcement", method: "GET")
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = dict["announcement"] as? [String: Any] ?? (dict["data"] as? [String: Any]),
              let id = (payload["id"] as? Int) ?? Int(payload["id"] as? String ?? ""),
              let title = payload["title"] as? String else {
            return nil
        }
        return AnnouncementInfo(
            id: id,
            title: title,
            body: (payload["body"] as? String) ?? (payload["content"] as? String) ?? "",
            url: payload["url"] as? String
        )
    }

    /// 拉版本信息 (启动后比对当前版本, 提示升级)
    func fetchVersionCheck(current: String) async throws -> VersionUpdateInfo? {
        // 万象书屋: query 用 URLComponents 拼, 别走 path 模板 (避免 %3F 问题)
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent("/api/version-check"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "version", value: current),
        ]
        var r = URLRequest(url: comps.url!)
        r.setValue(Self.platform, forHTTPHeaderField: "X-Platform")
        r.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let payload = (dict["version"] as? [String: Any]) ?? dict
        let latest = (payload["latest"] as? String)
            ?? (payload["latestVersion"] as? String)
            ?? (payload["version"] as? String) ?? current
        let notes = (payload["releaseNotes"] as? String)
            ?? (payload["notes"] as? String) ?? ""
        let downloadUrl = (payload["downloadUrl"] as? String) ?? (payload["url"] as? String)
        let mandatory = (payload["mandatory"] as? Bool) ?? (payload["force"] as? Bool) ?? false
        return VersionUpdateInfo(
            latestVersion: latest, currentVersion: current,
            releaseNotes: notes, downloadUrl: downloadUrl, mandatory: mandatory
        )
    }

    // MARK: - 后续 M2 阶段补的方法 (占位)

    /// 上报广告事件 (M3 接广告后用)
    nonisolated func reportAdEvent(placement: String, provider: String, type: String) {
        var r = request(path: "/api/ad-event", method: "POST")
        let body: [String: Any] = [
            "deviceId": deviceId,
            "placement": placement,
            "provider": provider,
            "type": type
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        sendIgnoreResult(r)
    }

    /// 万象书屋: iOS 解析失败上报. 服务端会写 `source_error_events`,
    /// 并聚合到 `source_health` 让 admin 面板和 `/api/sources?healthy=1` 可见.
    /// fire-and-forget, 不阻塞解析路径.
    /// - parameter status: ok / zero / error / timeout / skip
    /// - parameter stage: search / info / toc / content
    nonisolated func reportSourceError(
        sourceUrl: String,
        sourceName: String? = nil,
        stage: String,
        status: String,
        errorMessage: String? = nil,
        sampleKeyword: String? = nil,
        sampleUrl: String? = nil
    ) {
        guard !sourceUrl.isEmpty else { return }
        var r = request(path: "/api/source-error", method: "POST")
        // 截断防滥用 / 后端 1KB 上限
        var body: [String: Any] = [
            "sourceUrl": String(sourceUrl.prefix(500)),
            "platform": Self.platform,
            "stage": stage,
            "status": status
        ]
        if let n = sourceName, !n.isEmpty { body["sourceName"] = String(n.prefix(120)) }
        if let m = errorMessage, !m.isEmpty { body["errorMessage"] = String(m.prefix(800)) }
        if let k = sampleKeyword, !k.isEmpty { body["sampleKeyword"] = String(k.prefix(120)) }
        if let u = sampleUrl, !u.isEmpty { body["sampleUrl"] = String(u.prefix(800)) }
        if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            body["appVer"] = ver
        }
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        sendIgnoreResult(r)
    }

    /// 拉书城 feed (M2.3.1, M2.3 真实接口)
    /// 跟后端 `/api/bookstore/feed?channel=male` 对齐
    func fetchBookstoreFeed(channel: String) async throws -> [[String: Any]] {
        // 万象书屋: 后端要求 verifyDeviceToken, 没 token 时先注册
        if deviceToken == nil {
            try? await registerDeviceIfNeeded()
        }
        var (data, http) = try await sendFeedRequest(channel: channel)
        // 健壮性: 401 (token 无效/Keychain 读到老 token) → reissue 重试一次
        if http.statusCode == 401 {
            try? await reissueToken()
            (data, http) = try await sendFeedRequest(channel: channel)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpStatus(http.statusCode, body: "")
        }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = dict["items"] as? [[String: Any]] else {
            return []
        }
        return items
    }

    private func sendFeedRequest(channel: String) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent("/api/bookstore/feed"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "channel", value: channel)]
        var r = URLRequest(url: comps.url!)
        r.httpMethod = "GET"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Self.platform, forHTTPHeaderField: "X-Platform")
        r.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        if let tok = deviceToken { r.setValue(tok, forHTTPHeaderField: "X-Device-Token") }
        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        return (data, http)
    }

    /// 提交反馈 (M2.10.7)
    /// - 跟 Android `WanxiangBackend.submitFeedback` 字段格式一致
    func submitFeedback(type: String, content: String, contact: String) async throws -> Bool {
        var r = request(path: "/api/feedback", method: "POST")
        var body: [String: Any] = [
            "type": type,
            "content": content,
            "deviceId": deviceId,
            "appVer": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0",
        ]
        if !contact.isEmpty { body["contact"] = contact }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return dict?["ok"] as? Bool ?? false
    }

    /// PIPL: 用户主动删除其在后端的所有数据 (M2.10.8)
    /// 跟 Android `AccountDeleteActivity` 行为一致: 调 `/api/me/wipe-data` (HTTP DELETE)
    func wipeServerData() async throws -> Bool {
        var r = request(path: "/api/me/wipe-data", method: "DELETE")
        // 后端要求 body 里再带 device_id (跟 header 双重校验)
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["device_id": deviceId])

        let (data, resp) = try await session.data(for: r)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return dict?["ok"] as? Bool ?? false
    }

    /// 上报崩溃 (M2.1.7 接 NSSetUncaughtExceptionHandler 后用)
    nonisolated func reportCrash(exception: String, stack: String) {
        var r = request(path: "/api/crash-log", method: "POST")
        let body: [String: Any] = [
            "exception": exception,
            "stack": stack,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "0.0",
        ]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        sendIgnoreResult(r)
    }

    // MARK: - Helpers

    private nonisolated static var userAgent: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "WanxiangBook-iOS/\(v).\(b)"
    }

    private nonisolated func currentIDFV() -> String? {
        #if canImport(UIKit)
        // 万象书屋: identifierForVendor 在初次 launch 可能为 nil, 兜底 UUID
        return UIDevice.current.identifierForVendor?.uuidString
        #else
        return nil
        #endif
    }
}

// MARK: - 错误类型

enum APIError: Error, LocalizedError {
    case invalidResponse
    case unauthorized
    case httpStatus(Int, body: String)
    case serverRejected(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无效响应"
        case .unauthorized: return "未授权 (401)"
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body.prefix(120))"
        case .serverRejected(let msg): return "服务端拒绝: \(msg)"
        case .decodeFailed(let msg): return "解析失败: \(msg)"
        }
    }
}
