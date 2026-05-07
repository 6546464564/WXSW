//
//  BrowserBridge.swift
//  万象书屋 iOS · 反爬浏览器桥
//
//  对应 Android: io.legado.app.help.http.WebViewHelper + BrowserUtil
//
//  legado `java.startBrowserAwait(url, keyword)` 语义:
//   1. 用一个真浏览器加载 URL (跑 JS, 接受 cookies)
//   2. 等到 page DOM 包含 expectedKeyword 字符串 (说明反爬通过)
//   3. 返回当前 page 的 outerHTML 作为新 source
//   4. 同时把 cookies 持久化到 cookie store
//
//  iOS / macOS 实现: WKWebView (heavy 但唯一能绕 Cloudflare/JS 反爬的办法)
//
//  超时策略: 30 秒等不到 keyword 就 timeout, 返当前 outerHTML 让上层选择器重试
//

import Foundation

/// 浏览器桥协议. 真实现在 WKWebViewBridge, 测试可注 mock
public protocol BrowserBridge: Sendable {
    /// 加载 url, 等到页面源含 expectedKeyword 后返回 outerHTML
    /// - parameter timeout: 等待秒数, 默认 30
    /// - returns: page outerHTML 或 nil (超时/失败)
    func loadAndWait(url: String, expectedKeyword: String?, timeout: TimeInterval) async -> String?
}

/// 默认 stub: 直接返 nil. 用于 actor 测试和 fallback
public struct NoopBrowserBridge: BrowserBridge {
    public init() {}
    public func loadAndWait(url: String, expectedKeyword: String?, timeout: TimeInterval) async -> String? {
        return nil
    }
}

/// 全局桥注册. App 启动时注 WKWebViewBridge, CLI 用 NoopBrowserBridge
public actor BrowserBridgeRegistry {
    public static let shared = BrowserBridgeRegistry()
    private var bridge: any BrowserBridge = NoopBrowserBridge()

    public func set(_ b: any BrowserBridge) {
        self.bridge = b
    }

    public func get() -> any BrowserBridge {
        return bridge
    }
}
