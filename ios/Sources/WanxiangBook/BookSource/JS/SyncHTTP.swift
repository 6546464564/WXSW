//
//  SyncHTTP.swift
//  万象书屋 iOS · 同步 HTTP (给 java.get / java.post / java.ajax / java.connect 用)
//
//  对应 Android: io.legado.app.help.JsExtensions.get/post/connect/ajax (基于 OkHttp 同步 newCall)
//
//  设计:
//   - 阻塞当前线程 (DispatchSemaphore)
//   - 跟随 redirect / 自动 cookie / 默认 12s 超时
//   - 返回 body + statusCode + headers dict
//
//  注意: 必须不在 main thread 上调用 (会卡 UI). JSEngine 在 actor 里调, 自动跑在 cooperative pool.
//

import Foundation

public struct SyncHTTPResponse: Sendable {
    public let body: String
    public let statusCode: Int
    public let headers: [String: String]
}

/// 万象书屋: 阻止跟随重定向, 让 java.get 能拿 location header
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)   // nil = 不跟随
    }
}

public enum SyncHTTP {

    /// 万象书屋: legado 源 JS 用 `resp.header("location")` 探 302 跳转地址,
    /// 所以 java.get/post 不能默认跟随 redirect — 让 caller 拿到原始 302 响应.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    /// GET 请求
    public static func get(url: String, headers: [String: String] = [:]) -> SyncHTTPResponse? {
        return execute(url: url, method: "GET", body: nil, headers: headers)
    }

    /// POST 请求
    public static func post(url: String, body: String, headers: [String: String] = [:]) -> SyncHTTPResponse? {
        return execute(url: url, method: "POST", body: body.data(using: .utf8), headers: headers)
    }

    private static func execute(url: String, method: String, body: Data?,
                                 headers: [String: String]) -> SyncHTTPResponse? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.httpMethod = method
        if let body = body { req.httpBody = body }
        // 默认 UA, 防止某些站点 403 空 UA
        // 万象书屋 (M2.8 fix bug): UA 不能含中文 — 之前结尾 "万象书屋" 让某些站点 (如
        // 爱下电子书 ixdzs8.com) 反爬规则把请求拒掉或返 challenge 页. 改成跟 HTTPFetcher
        // 一致的标准 iOS Safari UA.
        if headers["User-Agent"] == nil && headers["user-agent"] == nil {
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
                         "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        }
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if method == "POST" && headers["Content-Type"] == nil && headers["content-type"] == nil {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        if ProcessInfo.processInfo.environment["WX_DEBUG_HTTP"] != nil {
            let cookies = HTTPCookieStorage.shared.cookies(for: u) ?? []
            let cookieStr = cookies.map { "\($0.name)=\($0.value.prefix(10))" }.joined(separator: "; ")
            print("[SyncHTTP] \(method) \(url.prefix(120)) | cookies=\(cookieStr)")
        }
        let sema = DispatchSemaphore(value: 0)
        var result: SyncHTTPResponse? = nil
        let task = session.dataTask(with: req) { data, resp, _ in
            defer { sema.signal() }
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            var headerDict: [String: String] = [:]
            if let h = http?.allHeaderFields {
                for (k, v) in h {
                    headerDict[String(describing: k).lowercased()] = String(describing: v)
                }
            }
            // 万象书屋: 优先 utf-8, 失败 isoLatin1 (拿到原 byte 给上层 charset detect)
            let bodyStr: String
            if let d = data {
                bodyStr = String(data: d, encoding: .utf8)
                    ?? String(data: d, encoding: .isoLatin1)
                    ?? ""
            } else {
                bodyStr = ""
            }
            result = SyncHTTPResponse(body: bodyStr, statusCode: status, headers: headerDict)
        }
        task.resume()
        let res = sema.wait(timeout: .now() + 12)
        if res == .timedOut {
            task.cancel()
            return nil
        }
        return result
    }
}
