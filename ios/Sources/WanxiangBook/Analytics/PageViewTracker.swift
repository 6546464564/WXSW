//
//  PageViewTracker.swift
//  万象书屋 iOS · 页面级 PV 埋点
//
//  对应 Android: BaseActivity.onResume / onPause 自动 track + flush 流程
//
//  用法:
//   var body: some View {
//       BookshelfContent()
//           .trackPageView("page_bookshelf")
//   }
//
//  会自动:
//   - onAppear: track(name, type="pv"), 记录 startMs
//   - onDisappear: track(name + "_leave", type="pv", params=["stay_ms": xxx])
//                  + 触发 flush()
//

import SwiftUI

/// 页面 PV 埋点 modifier — 跟 Android `BaseActivity.onResume/onPause` 自动行为对齐
private struct PageViewTrackerModifier: ViewModifier {
    let pageName: String
    @State private var startedAt: Date?

    func body(content: Content) -> some View {
        content
            .onAppear {
                startedAt = Date()
                WanxiangAnalytics.shared.track(pageName, type: "pv")
            }
            .onDisappear {
                if let start = startedAt {
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    // 万象书屋 D-16 (A-6): 上界 24h (避免长会话被异常过滤丢失)
                    if ms >= 100 && ms <= 24 * 60 * 60 * 1000 {
                        WanxiangAnalytics.shared.track(
                            "\(pageName)_leave",
                            type: "pv",
                            params: ["stay_ms": ms]
                        )
                    }
                    startedAt = nil
                }
                // 切到后台或 view 销毁时强制 flush
                Task { await WanxiangAnalytics.shared.flush() }
            }
    }
}

public extension View {
    /// 标记当前 View 为埋点页面. 跟 Android `trackPageName` 一致 (snake_case 命名).
    func trackPageView(_ name: String) -> some View {
        self.modifier(PageViewTrackerModifier(pageName: name))
    }
}
