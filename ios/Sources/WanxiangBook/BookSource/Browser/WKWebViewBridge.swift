//
//  WKWebViewBridge.swift
//  万象书屋 iOS · WKWebView 实现的反爬桥
//
//  原理:
//   1. WKWebView load(URLRequest)
//   2. 监听 navigation finish + DOM mutation
//   3. 每 500ms 拉一次 outerHTML, 检查是否含 expectedKeyword
//   4. 含 → resolve / 30s 超时 → 也 resolve (返当前 DOM 试一下)
//   5. cookie 自动同步 (WKWebsiteDataStore.default 跟 NSHTTPCookieStorage 互通)
//
//  线程: 必须 main queue 操作 WKWebView (init/load/eval). 用 @MainActor.
//  并发: 全局复用一个 WKWebView, 多源并发 search 时必须串行 load, 否则 load 互相覆盖 → 卡死/闪退.
//

#if canImport(WebKit)
import Foundation
import WebKit

@MainActor
public final class WKWebViewBridge: BrowserBridge {

    /// 万象书屋: 复用一个 webview 跑所有反爬, 避免反复创建
    private let webView: WKWebView
    /// 串行化 loadAndWait — 等上一轮完全结束再开始下一轮
    private var lastLoad: Task<String?, Never>?

    public init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        self.webView = wv
    }

    nonisolated public func loadAndWait(url: String, expectedKeyword: String?, timeout: TimeInterval) async -> String? {
        await enqueueLoad(url: url, keyword: expectedKeyword, timeout: timeout)
    }

    @MainActor
    private func enqueueLoad(url: String, keyword: String?, timeout: TimeInterval) async -> String? {
        let predecessor = lastLoad
        let current = Task<String?, Never> { @MainActor in
            if let predecessor { _ = await predecessor.value }
            return await self.runOnMain(url: url, keyword: keyword, timeout: timeout)
        }
        lastLoad = current
        return await current.value
    }

    private func runOnMain(url: String, keyword: String?, timeout: TimeInterval) async -> String? {
        guard let urlObj = URL(string: url) else { return nil }
        let req = URLRequest(url: urlObj, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        webView.load(req)

        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: TimeInterval = 0.5
        var lastHtml: String? = nil

        let challengeMarkers = [
            "Just a moment", "Just a Moment", "请稍候", "正在验证",
            "Verifying you are human", "Checking your browser",
            "请确认您的身份", "安全验证", "反机器人",
        ]
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            let html = await dumpOuterHTML()
            lastHtml = html
            if let html, html.count > 100 {
                let isChallenge = challengeMarkers.contains { html.contains($0) }
                if isChallenge { continue }
                if let kw = keyword, !kw.isEmpty {
                    if html.contains(kw) {
                        await syncCookies(for: urlObj)
                        return LegadoHTMLParse.clampSource(html)
                    }
                    if !webView.isLoading && html.count > 1000 {
                        await syncCookies(for: urlObj)
                        return LegadoHTMLParse.clampSource(html)
                    }
                } else {
                    if !webView.isLoading {
                        await syncCookies(for: urlObj)
                        return LegadoHTMLParse.clampSource(html)
                    }
                }
            }
        }
        await syncCookies(for: urlObj)
        return lastHtml.map { LegadoHTMLParse.clampSource($0) }
    }

    private func dumpOuterHTML() async -> String? {
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            webView.evaluateJavaScript("document.documentElement.outerHTML") { v, _ in
                cont.resume(returning: v as? String)
            }
        }
    }

    private func syncCookies(for url: URL) async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for c in cookies {
            HTTPCookieStorage.shared.setCookie(c)
        }
        CloudflareCookieStore.shared.persistToDisk()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

#endif
