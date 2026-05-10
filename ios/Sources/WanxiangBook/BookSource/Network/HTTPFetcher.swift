//
//  HTTPFetcher.swift
//  万象书屋 iOS · 书源专用 HTTP 客户端
//
//  对应 Android: io.legado.app.help.http.* (基于 OkHttp)
//
//  职责:
//   - GET / POST / 表单 / multipart
//   - UA 伪装 (默认伪装 Chrome 移动版)
//   - cookie 持久化 (按源隔离, 每源独立 cookie 仓库)
//   - 重试 (3 次, 指数退避)
//   - 编码探测: HTTP header → meta charset → BOM → 启发式 GBK/UTF-8/Big5
//   - 并发限速 (按源 concurrentRate)
//   - 超时 (默认 15s)
//
//  对应规则字段:
//   - searchUrl 形如:
//     "https://x.com/search?q={{key}}"                          ← 简单 GET
//     "https://x.com,{method:'POST',body:'q={{key}}'}"          ← legado JSON 选项
//     "@js:..."                                                  ← JS 计算 URL
//

import Foundation
import zlib

/// 万象书屋: HTTP 响应包装
public struct HTTPResponse: Sendable {
    public let url: URL
    public let statusCode: Int
    public let bodyData: Data
    public let bodyText: String
    public let detectedEncoding: String
    public let headers: [String: String]
    public let finalURL: URL?
}

/// 万象书屋: 改为 final class 让多源 HTTP 抓真并发跑.
/// 之前 `actor` 把所有 fetch 调用串行化, 32 源搜索 = 32 次 HTTP 排队 = 30s+;
/// URLSession 本身是 thread-safe (内部已用 dispatch queue), 包 actor 是冗余.
/// `cookieJars` 是 dead 字段从未被读写, 一并删掉.
public final class HTTPFetcher: @unchecked Sendable {

    public static let shared = HTTPFetcher()

    private let session: URLSession

    public static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private init() {
        let cfg = URLSessionConfiguration.default
        // 万象书屋 (M2.4 perf): 单次 HTTP 抓 8s 超时 (之前 15). 配合 BookSourceEngine.searchAll
        // 的 12s 单源硬超时 + retries 默认 1, 让多源搜索整体能在 ~12s 内出齐结果, 跟 Android 体感
        // 持平. 之前 15s × 3 retry × 32 源串行 (actor 之前) ⇒ 90s+, 改并发后仍受单源 49s 拖累.
        cfg.timeoutIntervalForRequest = 8
        // 万象书屋 (M2.6 fix): 资源级超时给到 60s — 这是"task 总时长"上限, 包含
        // retry 间隔 + 可能的 25s per-request × 3 retries. 之前 16s 让 content
        // 在第二次 retry 中途被杀, 用户报"阅读不了".
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.httpMaximumConnectionsPerHost = 6
        // 万象书屋: 用 delegate 拦截 cross-origin redirect (反爬源会 302 跳到 google.com / baidu.com)
        let delegate = AntiHijackDelegate()
        self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    // MARK: - Fetch

    /// 主要 fetch 方法
    /// - Parameters:
    ///   - urlString: 目标 URL (可含 {{var}} 模板, 调用方已经 substituted)
    ///   - method: GET / POST
    ///   - body: POST body
    ///   - headers: 自定义 header
    ///   - sourceKey: bookSourceUrl, 用来隔离 cookie
    ///   - retries: 失败重试次数
    ///   - requestTimeoutSec: 单次请求超时 (覆盖 session 全局 8s).
    ///     万象书屋 (M2.6 fix): 8s 全局超时是给 search 用的 (慢源快速 skip),
    ///     但 fetchContent/fetchToc 一章正文要拉完整 HTML, 8s 经常不够 →
    ///     retry 3 次全超时 = 用户"阅读不了". info/toc/content 路径主动传 25s.
    public func fetch(
        urlString: String,
        method: String = "GET",
        body: Data? = nil,
        headers: [String: String] = [:],
        sourceKey: String? = nil,
        retries: Int = 3,
        requestTimeoutSec: TimeInterval? = nil
    ) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw BookSourceEngineError.httpFailed("非法 URL: \(urlString)")
        }

        var lastError: Error?
        for attempt in 0..<max(1, retries) {
            // 万象书屋 (M2.4 perf): 每次 retry 前响应外层 Task cancellation,
            // 否则 searchAll 的 12s 单源超时根本起不了作用 (3 次 retry × 15s = 49s 实际跑满).
            try Task.checkCancellation()
            if ProcessInfo.processInfo.environment["WX_LOG_FETCH"] != nil {
                print("[fetch] attempt \(attempt) GET \(url.absoluteString.prefix(60))")
            }
            do {
                return try await fetchOnce(url: url, method: method, body: body, headers: headers,
                                           sourceKey: sourceKey, requestTimeoutSec: requestTimeoutSec)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                // 万象书屋: NSURLErrorCancelled 也按 cancellation 处理, URLSession 把 task cancel
                // 翻译成 NSError(domain=NSURLErrorDomain code=-999), 而非 CancellationError.
                let nsErr = error as NSError
                if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                    throw CancellationError()
                }
                if attempt < retries - 1 {
                    // 指数退避: 0.5s, 1s, 2s
                    let backoffMs = UInt64(500 * (1 << attempt))
                    // 万象书屋: 不用 try?, 让 cancellation 真正抛上去
                    try await Task.sleep(nanoseconds: backoffMs * 1_000_000)
                }
            }
        }
        throw lastError ?? BookSourceEngineError.httpFailed("unknown")
    }

    private func fetchOnce(url: URL, method: String, body: Data?,
                           headers: [String: String], sourceKey: String?,
                           requestTimeoutSec: TimeInterval?) async throws -> HTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method.uppercased()
        // 万象书屋 (M2.6 fix): per-request 超时覆盖 session 全局 8s.
        // URLRequest.timeoutInterval 优先级高于 URLSessionConfiguration.timeoutIntervalForRequest.
        if let t = requestTimeoutSec {
            req.timeoutInterval = t
        }
        if let body { req.httpBody = body }
        // 万象书屋: 不主动加 Content-Type, legado 大部分源不带 header 也能 work
        // (强制加 application/x-www-form-urlencoded 反而会让某些 PHP 站 400)
        req.setValue(Self.defaultUA, forHTTPHeaderField: "User-Agent")
        // 万象书屋: 默认请求 identity.
        // 有些老站 (如 shukuge) 会返回 gzip 原始字节但漏 `Content-Encoding: gzip`,
        // URLSession 不会自动解压, 选择器就会在乱码上跑空。除非书源自带 header 覆盖,
        // 默认不要求压缩最稳。
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw BookSourceEngineError.httpFailed("非 HTTP 响应")
        }
        // 万象书屋: AntiHijackDelegate 拦截了 cross-origin redirect, 此时 status 仍是 3xx
        // 把它当反爬错误抛出, 让 SearchParser 知道是"被劫持"而非"无结果"
        if (300..<400).contains(http.statusCode) {
            throw BookSourceEngineError.httpFailed("反爬重定向 (status \(http.statusCode))")
        }
        let decodedBody = maybeGunzip(data) ?? data
        let detected = detectEncoding(headers: http.allHeaderFields, body: decodedBody)
        let text = decodeText(data: decodedBody, encoding: detected)
        let respHeaders = (http.allHeaderFields as? [String: String]) ?? [:]

        return HTTPResponse(
            url: url,
            statusCode: http.statusCode,
            bodyData: decodedBody,
            bodyText: text,
            detectedEncoding: detected,
            headers: respHeaders,
            finalURL: http.url
        )
    }

    // MARK: - gzip / 编码探测

    /// 某些老站会返回 gzip 原始字节但漏 `Content-Encoding: gzip`.
    /// URLSession 不会自动解压, 这里按 gzip magic 手动兜底。
    nonisolated private func maybeGunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b else { return nil }
        return inflateGzip(data)
    }

    /// zlib inflate with gzip header support (`windowBits = 16 + MAX_WBITS`).
    nonisolated private func inflateGzip(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        var output = Data()
        let chunkSize = 64 * 1024
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        return data.withUnsafeBytes { srcRaw -> Data? in
            guard let srcBase = srcRaw.bindMemory(to: Bytef.self).baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: srcBase)
            stream.avail_in = uInt(data.count)

            let dst = UnsafeMutablePointer<Bytef>.allocate(capacity: chunkSize)
            defer { dst.deallocate() }

            var status: Int32
            repeat {
                stream.next_out = dst
                stream.avail_out = uInt(chunkSize)
                status = inflate(&stream, Z_NO_FLUSH)
                if status != Z_OK && status != Z_STREAM_END { return nil }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(dst, count: produced) }
            } while status != Z_STREAM_END

            return output
        }
    }

    /// 编码探测顺序 (跟 Android okhttp 行为一致):
    /// 1. HTTP Content-Type charset=
    /// 2. HTML <meta charset=> 或 <meta http-equiv="content-type" content="charset=">
    /// 3. UTF-8 / UTF-16 BOM
    /// 4. 启发式: 字节高位看 GBK / Big5 / UTF-8
    nonisolated func detectEncoding(headers: [AnyHashable: Any], body: Data) -> String {
        // 1. HTTP header
        if let ct = headers["Content-Type"] as? String,
           let charset = parseCharsetFromContentType(ct) {
            return normalizeEncoding(charset)
        }
        // 2. <meta charset=>
        // 万象书屋 (P0 fix): 用 isoLatin1 (单字节) 不会因 0x80+ GBK 字节而 decode fail
        // 关键 ASCII 字符 (charset="gbk" 等) 仍可识别
        if let preview = String(data: body.prefix(2048), encoding: .isoLatin1) {
            if let r = preview.range(of: #"charset\s*=\s*['"]?([\w-]+)"#, options: [.regularExpression, .caseInsensitive]) {
                let m = String(preview[r])
                if let c = parseCharsetFromContentType(m) {
                    return normalizeEncoding(c)
                }
            }
        }
        // 3. BOM
        if body.count >= 3, body[0] == 0xEF, body[1] == 0xBB, body[2] == 0xBF {
            return "utf-8"
        }
        if body.count >= 2 {
            if body[0] == 0xFF, body[1] == 0xFE { return "utf-16le" }
            if body[0] == 0xFE, body[1] == 0xFF { return "utf-16be" }
        }
        // 4. 启发式: 简化判断, 试 utf8 → gbk → big5 哪个 decode 出来"中文字符比例"最高
        if String(data: body.prefix(1024), encoding: .utf8) != nil {
            return "utf-8"
        }
        // GBK fallback (中文站常见)
        return "gbk"
    }

    /// 把字节按编码 decode 成 String. 失败时降级 utf-8 lossy.
    nonisolated func decodeText(data: Data, encoding: String) -> String {
        let enc = nsEncoding(for: encoding)
        if let s = String(data: data, encoding: enc) { return s }
        // 失败 fallback utf-8 替换错码
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated func parseCharsetFromContentType(_ ct: String) -> String? {
        // "text/html; charset=GBK"  →  "GBK"
        guard let r = ct.range(of: #"charset\s*=\s*['"]?([\w-]+)"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let m = String(ct[r])
        guard let eq = m.firstIndex(of: "=") else { return nil }
        var v = String(m[m.index(after: eq)...])
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "'\"\t\n "))
        return v.isEmpty ? nil : v
    }

    private nonisolated func normalizeEncoding(_ s: String) -> String {
        let l = s.lowercased()
        switch l {
        case "gb2312", "gb_2312-80", "x-gbk": return "gbk"
        case "iso-8859-1", "latin1": return "iso-8859-1"
        default: return l
        }
    }

    private nonisolated func nsEncoding(for name: String) -> String.Encoding {
        switch name.lowercased() {
        case "utf-8": return .utf8
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "gbk", "gb2312":
            // CFStringEncodings.GB_18030_2000 涵盖 GBK
            let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
        case "big5":
            let cfEnc = CFStringEncoding(CFStringEncodings.big5.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
        case "iso-8859-1": return .isoLatin1
        default: return .utf8
        }
    }
}

/// 万象书屋: 反劫持 redirect delegate
/// 一些反爬站会用 302 把请求扔到 google.com / baidu.com / about:blank 等无关 URL
/// 检测到 cross-origin redirect 时直接 return nil 让 session 用原 response 而不 follow
final class AntiHijackDelegate: NSObject, URLSessionTaskDelegate {
    /// 万象书屋: 显式劫持黑名单 (跳到这些 = 99% 是反爬陷阱)
    /// 其它跨域跳转 (含网站换域名: aqxsw555 → aiqu225) 都允许 follow,
    /// 让 SearchParser 自己去判内容是否有效.
    private let blacklistHosts: Set<String> = [
        "www.google.com", "google.com",
        "www.baidu.com", "baidu.com",
        "www.bing.com", "bing.com",
        "www.yandex.com",
        "about:blank",
    ]

    /// 万象书屋: 防短期重复 redirect 死循环 (legado 源偶遇 captcha 会循环跳)
    /// 这里加最大跳数 8, 跳够了就 reject 让 fetchOnce 抛 3xx
    private static let maxRedirects = 8

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let newURL = request.url, let newHost = newURL.host?.lowercased() else {
            completionHandler(request)
            return
        }
        // 1. 黑名单 host 直接拒
        if blacklistHosts.contains(newHost) {
            completionHandler(nil)
            return
        }
        // 2. about:blank / data: / file: 等非 http(s) 直接拒
        if let scheme = newURL.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            completionHandler(nil)
            return
        }
        // 3. 跳转链长度限制 (用关联对象计数, URLSession 自带的没暴露)
        let count = (objc_getAssociatedObject(task, &Self.redirectCountKey) as? Int) ?? 0
        if count + 1 >= Self.maxRedirects {
            completionHandler(nil)
            return
        }
        objc_setAssociatedObject(task, &Self.redirectCountKey, count + 1, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        // 4. 其它跨域 (含 同站 / 换域名 / http→https) 一律 follow
        completionHandler(request)
    }

    private static var redirectCountKey: UInt8 = 0
}
