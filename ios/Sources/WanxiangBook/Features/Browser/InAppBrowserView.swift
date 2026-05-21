//
//  InAppBrowserView.swift
//  万象书屋 iOS · 内置 WebView (M2.9.5)
//
//  对应 Android: io.legado.app.ui.browser.WebViewActivity
//
//  用途:
//   - 选词菜单"在浏览器打开"
//   - 词典查词 (DictDialog)
//   - 书源登录 (M1-12, 暂留)
//

import SwiftUI
import WebKit

struct InAppBrowserView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.allowsBackForwardNavigationGestures = true
        // 万象书屋: 暗模式下 WKWebView 默认用黑色背景填底，页面加载前显示为黑屏。
        // 设为透明让父视图白色背景透出，消除"黑闪"。
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let req = URLRequest(url: url)
        if uiView.url != url {
            uiView.load(req)
        }
    }
}

struct InAppBrowserScreen: View {
    let url: URL
    let title: String?

    @Environment(\.dismiss) private var dismiss

    init(url: URL, title: String? = nil) {
        self.url = url
        self.title = title
    }

    var body: some View {
        NavigationStack {
            InAppBrowserView(url: url)
                .background(Color(.systemBackground))  // WKWebView 透明时的保底背景色
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title ?? url.host ?? "浏览器")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Image(systemName: "safari")
                        }
                    }
                }
        }
    }
}
