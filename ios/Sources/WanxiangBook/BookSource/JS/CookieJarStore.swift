//
//  CookieJarStore.swift
//  万象书屋 iOS · cookie 存储 (对应 Android CookieStore)
//
//  legado JS 用 cookie.getCookie(url) / cookie.setCookie(url, val) 读写 cookie.
//  iOS 实现: 包装 HTTPCookieStorage.shared (URLSession 默认就用它),
//  这样 JS 设的 cookie 会被后续 fetch 自动带上.
//

import Foundation

public enum CookieJarStore {

    /// 取某 URL 的 cookie 字符串 (用 ", " 拼; 跟 Android Legado 一致)
    public static func getCookie(url: String) -> String {
        guard let u = URL(string: url) else { return "" }
        let cookies = HTTPCookieStorage.shared.cookies(for: u) ?? []
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 取 cookie 中某字段
    public static func getCookieValue(url: String, key: String) -> String {
        guard let u = URL(string: url) else { return "" }
        let cookies = HTTPCookieStorage.shared.cookies(for: u) ?? []
        for c in cookies where c.name == key { return c.value }
        return ""
    }

    /// 写 cookie (可以是 "key=val" 或 "key1=v1; key2=v2")
    public static func setCookie(url: String, cookie: String?) {
        guard let u = URL(string: url), let host = u.host else { return }
        if cookie == nil || cookie?.isEmpty == true {
            removeCookie(url: url)
            return
        }
        let parts = cookie!.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for p in parts {
            let kv = p.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let props: [HTTPCookiePropertyKey: Any] = [
                .name: String(kv[0]),
                .value: String(kv[1]),
                .domain: host,
                .path: "/",
                .expires: Date().addingTimeInterval(86400 * 30) // 30 天
            ]
            if let c = HTTPCookie(properties: props) {
                HTTPCookieStorage.shared.setCookie(c)
            }
        }
    }

    public static func removeCookie(url: String) {
        guard let u = URL(string: url) else { return }
        let cookies = HTTPCookieStorage.shared.cookies(for: u) ?? []
        for c in cookies { HTTPCookieStorage.shared.deleteCookie(c) }
    }

    /// 清所有 cookie (debug / 退出登录用)
    public static func clearAll() {
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }
}
