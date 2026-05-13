//
//  CloudflareCookieStore.swift
//  万象书屋 iOS · Cloudflare cookie 跨进程持久化
//
//  问题:
//   - WKWebView 跑完 CF challenge 拿到 `cf_clearance` 等 cookie, syncCookies 拷到
//     HTTPCookieStorage.shared 后, 当前进程内 HTTPFetcher / SyncHTTP 都能读.
//   - 但 iOS App 沙盒下 HTTPCookieStorage.shared 持久化行为不可靠 — 进程被系统杀死或
//     用户主动退出后 cookie 可能丢, 下次开 App 又得跑 webview challenge (25s+).
//
//  方案:
//   - App 启动时 restoreFromDisk(), 把 ~30 分钟内的 cookie 写回 HTTPCookieStorage.shared
//   - WKWebViewBridge.syncCookies 完成时 persistToDisk()
//   - 磁盘格式: Caches/wanxiang-cf-cookies.plist, NSDictionary 序列化 (HTTPCookie.properties)
//   - 自动过滤过期 cookie / 仅保留反爬关键 cookie (cf_clearance / __cf_bm / PHPSESSID 等)
//
//  对应 Android: Legado 用 OkHttp PersistentCookieJar (内置 SharedPreferences 持久化),
//  iOS 默认 NSHTTPCookieStorage 没有同等保证, 这里手搓一层.
//

import Foundation

public final class CloudflareCookieStore: @unchecked Sendable {
    public static let shared = CloudflareCookieStore()

    /// 反爬关键 cookie name 白名单 — 不在这里的不持久化, 减少敏感信息泄露面.
    /// (用户登录态 cookie 不持久化, 防被异常 share)
    private let antiBotCookieNames: Set<String> = [
        "cf_clearance",        // Cloudflare 5 秒挑战
        "__cf_bm",             // Cloudflare bot manager
        "__cflb",              // Cloudflare load balancer
        "PHPSESSID",           // 通用 PHP session, 爱下电子书等
        "session",             // 通用
        "JSESSIONID",          // 通用 Java session
        "ASP.NET_SessionId",   // 通用 ASP session
    ]

    private let lock = NSLock()
    private let storeURL: URL

    private init() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { fatalError("cachesDirectory unavailable") }
        self.storeURL = caches.appendingPathComponent("wanxiang-cf-cookies.plist")
    }

    // MARK: - 持久化

    /// App 启动时调一次, 把 disk 上的 cookie 写回 HTTPCookieStorage.shared.
    /// 已过期的 cookie 自动跳过.
    public func restoreFromDisk() {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let arr = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [[HTTPCookiePropertyKey: Any]] else { return }

        let now = Date()
        var restored = 0
        for props in arr {
            // 转 raw key=AnyHashable → HTTPCookiePropertyKey
            var typed: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in props {
                typed[HTTPCookiePropertyKey(rawValue: k.rawValue)] = v
            }
            guard let cookie = HTTPCookie(properties: typed) else { continue }
            // 过滤过期
            if let expiry = cookie.expiresDate, expiry < now { continue }
            HTTPCookieStorage.shared.setCookie(cookie)
            restored += 1
        }
        NSLog("[CFCookieStore] restored \(restored) cookies from disk")
    }

    /// WKWebView syncCookies 后调一次, 把 HTTPCookieStorage.shared 中的反爬 cookie 写盘.
    /// 仅持久化白名单 name 的 cookie (cf_clearance / PHPSESSID 等), 不存登录 cookie.
    public func persistToDisk() {
        lock.lock()
        defer { lock.unlock() }
        let all = HTTPCookieStorage.shared.cookies ?? []
        let now = Date()
        let candidates = all.filter { c in
            // 必须在白名单
            guard antiBotCookieNames.contains(c.name) else { return false }
            // 必须未过期
            if let expiry = c.expiresDate, expiry < now { return false }
            // session cookie (无 expiresDate) 也持久化, 大部分反爬 cookie 是 session 形式
            return true
        }
        let serialized = candidates.compactMap { c -> [HTTPCookiePropertyKey: Any]? in
            return c.properties
        }
        // 转 [HTTPCookiePropertyKey] → [String] 让 plist 序列化能吃
        let plistReady: [[String: Any]] = serialized.map { props in
            var d: [String: Any] = [:]
            for (k, v) in props { d[k.rawValue] = v }
            return d
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plistReady, format: .binary, options: 0) else { return }
        try? data.write(to: storeURL, options: .atomic)
        NSLog("[CFCookieStore] persisted \(plistReady.count) cookies to disk")
    }

    /// 调试用 — 看当前持久化的 cookie 列表
    public func debugListCookies() -> [String] {
        let all = HTTPCookieStorage.shared.cookies ?? []
        return all
            .filter { antiBotCookieNames.contains($0.name) }
            .map { "\($0.domain):\($0.name)" }
    }

    /// 清掉所有持久化的 CF cookie (用户报"读不了" 工具时调).
    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: storeURL)
        let all = HTTPCookieStorage.shared.cookies ?? []
        for c in all where antiBotCookieNames.contains(c.name) {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
    }
}
