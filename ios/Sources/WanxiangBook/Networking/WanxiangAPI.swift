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
    // 优先级: launch arg `--BackendURL <url>` > UserDefaults `wx.backendURL` > 默认
    // 默认值: DEBUG build 走 localhost:3000 (开发期默认连本地, 拿全量源 2000+ 条);
    //         Release build 走生产 IP (M5 备案完成切 https://api.wanxiangbook.com).
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
        #if DEBUG && targetEnvironment(simulator)
        return URL(string: "http://localhost:3000")!
        #else
        return URL(string: "https://wxsw.app")!
        #endif
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

    /// 万象书屋 (2026-05-25): 启动时一次性缓存 IDFV.
    /// 各路上报跨线程读取, 避免 DispatchQueue.main.sync 跨线程死锁.
    /// 由 AppDelegate.application(_:didFinishLaunchingWithOptions:) 主线程调用 prefillCache.
    nonisolated(unsafe) private static var _cachedIDFV: String?
    nonisolated(unsafe) private static var deviceCachePrefilled = false

    /// 在 AppDelegate.didFinishLaunching 主线程调用一次, 之后任意线程无锁读 cachedXxx.
    public static func prefillDeviceCache() {
        #if canImport(UIKit)
        // 仅在主线程调用; 防止意外在后台线程跑.
        assert(Thread.isMainThread, "prefillDeviceCache must be called on main thread")
        _cachedIDFV = UIDevice.current.identifierForVendor?.uuidString
        #endif
        deviceCachePrefilled = true
    }

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = true
        // 万象书屋 (perf P1): 禁用 URLSession 协议层 disk cache.
        //   - 否则系统会把 GET 响应 + ETag 写 disk, 下次自动加 If-None-Match → 多数业务接口
        //     的 ETag/304 控制全由我们自己 (BookSourceRegistry.lastSourcesEtag /
        //     BookstoreMirror.cachedEtag 等) 管理, 系统层缓存只会污染我们的状态机
        //     (e.g. /api/sources 冷启动 304 + 内存 cache 空 → 走 bundle fallback 拿 32 条
        //     而不是后端 1889 条).
        //   - urlCache = nil + 默认 cachePolicy=useProtocolCachePolicy 共同保证: 不本地缓存 body,
        //     不自动加 If-None-Match. 我们要 etag 时显式 setValue.
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
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

    /// 万象书屋 (方案 G' 客户端): 统一 HTTP helper, 在收到任意响应时 sniff `X-Sources-Etag`,
    /// 发现 server 当前 sources etag 跟客户端最近一次拿到的不一致, 就后台静默触发 BookSourceRegistry.refresh.
    /// - 不阻塞业务请求, 也不影响调用方拿数据.
    /// - 替代裸用 `session.data(for:)` 让所有 API 调用自动参与源同步.
    func httpData(for req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidResponse }
        if let etag = http.value(forHTTPHeaderField: "X-Sources-Etag"), !etag.isEmpty {
            // 跳到 main actor 让 BookSourceRegistry 处理, 不阻塞当前 request
            Task { @MainActor in
                BookSourceRegistry.shared.noteServerSourcesEtag(etag)
            }
        }
        return (data, http)
    }

    /// 通用 send: 状态码校验 + JSON 解析
    func send<T: Decodable>(_ req: URLRequest, as: T.Type) async throws -> T {
        let (data, http) = try await httpData(for: req)
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
            // 万象书屋: 心跳 / 上报也走 httpData, 顺便消费 X-Sources-Etag header.
            // 失败就吞掉, 但 etag 还是要尝试读 (即使响应 4xx/5xx 也会有 header).
            _ = try? await self?.httpData(for: req)
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
        // 万象书屋 (方案 G'): /api/sources 必须每次都到 server, 让 server 用 ETag/304 控制是否回 body.
        //   - 默认 URLSession 见 `Cache-Control: public, max-age=300` 会在 5min 内完全不发请求, 直接返回 cached body
        //     ⇒ "本地不保存源" / "etag piggyback" 都失效, 客户端用 5 分钟前的旧源.
        //   - 用 .reloadIgnoringLocalCacheData 强制走网络, 但仍带 If-None-Match (URLSession 会自动管理 ETag, 但既然
        //     我们已经显式 set 一次, 命中 304 就 1 KB 返回零成本).
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let e = etag { r.setValue(e, forHTTPHeaderField: "If-None-Match") }

        let (data, http) = try await httpData(for: r)

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
        // 走 httpData 让响应里的 X-Sources-Etag 被读到 (即使 ping 没拿到 200, header 也尝试 sniff)
        _ = try? await httpData(for: r)
    }

    /// 拉公告 (启动后展示一次, UserDefaults 记 last_seen_id 不重复弹)
    func fetchAnnouncement() async throws -> AnnouncementInfo? {
        let buildCode = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent("/api/announcement"),
                                  resolvingAgainstBaseURL: false) ?? URLComponents()
        if buildCode > 0 {
            comps.queryItems = [URLQueryItem(name: "versionCode", value: String(buildCode))]
        }
        guard let url = comps.url else { return nil }
        var r = URLRequest(url: url)
        r.setValue(Self.platform, forHTTPHeaderField: "X-Platform")
        r.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        let (data, http) = try await httpData(for: r)
        guard (200..<300).contains(http.statusCode) else { return nil }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = dict["list"] as? [[String: Any]],
              let payload = list.first,
              let id = (payload["id"] as? Int) ?? Int(payload["id"] as? String ?? ""),
              let title = payload["title"] as? String else {
            return nil
        }
        return AnnouncementInfo(
            id: id,
            title: title,
            body: (payload["content"] as? String) ?? (payload["body"] as? String) ?? "",
            url: payload["url"] as? String
        )
    }

    /// 拉版本信息 (启动后比对当前版本, 提示升级)
    func fetchVersionCheck(current: String) async throws -> VersionUpdateInfo? {
        let buildCode = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent("/api/version-check"),
                                  resolvingAgainstBaseURL: false) ?? URLComponents()
        comps.queryItems = [URLQueryItem(name: "code", value: String(buildCode))]
        guard let compsUrl = comps.url else { return nil }
        var r = URLRequest(url: compsUrl)
        r.setValue(Self.platform, forHTTPHeaderField: "X-Platform")
        r.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        let (data, http) = try await httpData(for: r)
        guard (200..<300).contains(http.statusCode) else { return nil }
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let latest = (dict["latestName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? current
        let needUpgrade = dict["needUpgrade"] as? Bool ?? false
        let forceUpgrade = dict["forceUpgrade"] as? Bool ?? false
        let changelog = dict["changelog"] as? String ?? ""
        let marketUrl = (dict["marketUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VersionUpdateInfo(
            latestVersion: latest.isEmpty ? current : latest,
            currentVersion: current,
            releaseNotes: changelog,
            downloadUrl: marketUrl?.isEmpty == false ? marketUrl : nil,
            mandatory: forceUpgrade,
            needUpgrade: needUpgrade || forceUpgrade
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

        let (data, http) = try await httpData(for: r)
        guard (200..<300).contains(http.statusCode) else {
            return false
        }
        let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return dict?["ok"] as? Bool ?? false
    }

    // MARK: - Helpers

    private nonisolated static var userAgent: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "WanxiangBook-iOS/\(v).\(b)"
    }

    private nonisolated func currentIDFV() -> String? {
        #if canImport(UIKit)
        // 万象书屋 (2026-05-25): 启动 prefillDeviceCache 后直接读缓存, 避免任何 main.sync 路径.
        // 即使没 prefill (单元测试/兜底), 也只在主线程同步读 — 跨线程返回 nil 让上层走 UUID fallback.
        if let cached = Self._cachedIDFV { return cached }
        if Thread.isMainThread {
            let id = UIDevice.current.identifierForVendor?.uuidString
            Self._cachedIDFV = id
            return id
        }
        // 后台线程且未 prefill: 不阻塞, 让上层退化到 UUID 种子 (Keychain 还会再写一次, 之后稳定).
        return nil
        #else
        return nil
        #endif
    }

    // MARK: - 书库 (本地缓存源)

    struct LibraryBook: Decodable, Sendable {
        let id: Int
        let qidianId: String?
        let title: String
        let author: String
        let category: String?
        let coverUrl: String?
        let intro: String?
        let totalChapters: Int
        let cachedChapters: Int
    }

    struct LibrarySearchResponse: Decodable { let ok: Bool; let count: Int; let books: [LibraryBook] }
    struct LibraryChapter: Decodable, Sendable { let idx: Int; let title: String; let wordCount: Int; let status: String }
    struct LibraryChaptersResponse: Decodable { let ok: Bool; let bookId: Int; let title: String; let chapters: [LibraryChapter] }
    struct LibraryContentResponse: Decodable { let ok: Bool; let bookId: Int; let idx: Int; let title: String; let wordCount: Int; let content: String }

    func searchLibrary(keyword: String) async throws -> [LibraryBook] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let r = request(path: "/api/cache/search?keyword=\(encoded)")
        let resp = try await send(r, as: LibrarySearchResponse.self)
        return resp.books
    }

    func fetchLibraryChapters(bookId: Int) async throws -> [LibraryChapter] {
        let r = request(path: "/api/cache/books/\(bookId)/chapters")
        let resp = try await send(r, as: LibraryChaptersResponse.self)
        return resp.chapters
    }

    func fetchLibraryContent(bookId: Int, chapterIdx: Int) async throws -> LibraryContentResponse {
        let r = request(path: "/api/cache/books/\(bookId)/chapters/\(chapterIdx)")
        return try await send(r, as: LibraryContentResponse.self)
    }

    // MARK: - 服务端代搜

    struct ProxySearchBook: Decodable, Sendable {
        let origin: String
        let originName: String
        let name: String
        let author: String
        let bookUrl: String
        let coverUrl: String?
        let intro: String?
        let kind: String?
        let lastChapter: String?
        let mergedSourceURLs: [String]?
        let mergedSourceNames: [String]?
    }

    struct ProxySearchResponse: Decodable {
        let ok: Bool
        let count: Int
        let fromCache: Bool
        let sourceCount: Int
        let books: [ProxySearchBook]
    }

    func searchProxy(keyword: String) async throws -> [SearchBook] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        var r = request(path: "/api/search/proxy?keyword=\(encoded)")
        r.timeoutInterval = 30
        let resp = try await send(r, as: ProxySearchResponse.self)
        return resp.books.map { pb in
            SearchBook(
                origin: pb.origin,
                originName: pb.originName,
                name: pb.name,
                author: pb.author,
                bookUrl: pb.bookUrl,
                coverUrl: pb.coverUrl,
                intro: pb.intro,
                kind: pb.kind,
                lastChapter: pb.lastChapter,
                mergedSourceURLs: pb.mergedSourceURLs ?? [],
                mergedSourceNames: pb.mergedSourceNames ?? []
            )
        }
    }

    // MARK: - 换源代搜

    struct ChangeSourceResponse: Decodable {
        let ok: Bool
        let count: Int
        let fromCache: Bool
        let sourceCount: Int
        let candidates: [ProxySearchBook]
    }

    func changeSourceProxy(name: String, author: String) async throws -> [SearchBook] {
        let eName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        let eAuthor = author.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? author
        var r = request(path: "/api/search/changesource?name=\(eName)&author=\(eAuthor)")
        r.timeoutInterval = 30
        let resp = try await send(r, as: ChangeSourceResponse.self)
        return resp.candidates.map { pb in
            SearchBook(
                origin: pb.origin,
                originName: pb.originName,
                name: pb.name,
                author: pb.author,
                bookUrl: pb.bookUrl,
                coverUrl: pb.coverUrl,
                intro: pb.intro,
                kind: pb.kind,
                lastChapter: pb.lastChapter,
                mergedSourceURLs: [],
                mergedSourceNames: []
            )
        }
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
