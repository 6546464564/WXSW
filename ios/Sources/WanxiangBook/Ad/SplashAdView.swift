//
//  SplashAdView.swift
//  万象书屋 iOS · 开屏页 / 启动门面
//
//  对应 Android: io.legado.app.ad.ui.SplashAdActivity
//
//  设计 (跟 Android `SplashAdActivity.decideFlow` 对齐):
//   1. App 启动先显示这个 View (Launch Screen 显示完后)
//   2. 检查 AdManager.consented:
//      - 未同意 → 不展示广告, 短暂品牌停留 1.0s 后 dismiss
//      - 已同意但 enabled=false / reviewMode=true → 同上 (跟 Android `effectivelyDisabled` 等价)
//      - 已同意且 enabled=true → 调 AdManager.showSplash (M3 接真 SDK 后才真正展示)
//   3. 任何分支最多停留 [maxDurationSec]; 超时强制 onFinish() 进 RootView
//   4. 用 jumped flag 防止双跳 (Android `jumped` boolean 等价)
//
//  视觉:
//   - 跟 Info.plist UILaunchScreen 用同款 LaunchLogo + LaunchBackground, 切换无缝
//   - 底部小字"万象书屋·阅读自由"品牌位 (审核期临时关广告时也有内容可看)
//

import SwiftUI

struct SplashAdView: View {

    /// Splash 完成后回调; 调用方应该在这里把 splash 隐藏并展示 RootView
    let onFinish: () -> Void

    /// 最长停留时长. 跟 Android `splash.timeoutMs` (通常 5000ms) 同款.
    /// 万象书屋 (M2.4 perf): 没 AD 时从 1.0s 缩到 0.4s — 系统 LaunchScreen 已经覆盖
    /// 启动 ~0.3-0.5s 黑屏期, 我们再叠一个 0.4s 品牌渐隐过渡足够"无缝"; 1.0s 反而让
    /// 用户感觉"App 在加载", Android 也没这么长.
    private static let brandOnlyDurationSec: Double = 0.4
    private static let withAdDurationSec: Double = 5.0

    /// 万象书屋 (M2.4 perf): 任何 deeplink 触发的启动 (--Search / --OpenBook / --OpenTts /
    /// --AddDemoBook 等) 直接跳过 splash 进 RootView. 这些场景用户/外部脚本目标明确是某个具体
    /// 功能, splash 只增加等待时间, 没意义.
    private static var hasDeeplinkArg: Bool {
        let triggers = ["--Search", "-Search", "--OpenBook", "-OpenBook",
                        "--OpenTts", "-OpenTts", "--AddDemoBook", "-AddDemoBook"]
        let args = ProcessInfo.processInfo.arguments
        return args.contains(where: { triggers.contains($0) })
    }

    @State private var jumped = false
    @State private var adShowing = false

    var body: some View {
        ZStack {
            // 跟 Info.plist UILaunchScreen.UIColorName 对齐 — 启动屏色块无缝过渡
            Color("LaunchBackground").ignoresSafeArea()

            VStack(spacing: 18) {
                // 优先用 Asset 里的 LaunchLogo (跟 system splash 同款), 没有时 fallback SF Symbol
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                Text("万象书屋")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(WanxiangColors.textPrimary)
                Text("阅读自由")
                    .font(.system(size: 14))
                    .foregroundStyle(WanxiangColors.textSecondary)
            }
        }
        .task {
            await runSplashFlow()
        }
    }

    @MainActor
    private func runSplashFlow() async {
        guard !jumped else { return }

        // 万象书屋 (M2.4 perf): deeplink 模式直接进 RootView, 跳过任何 splash 停留.
        if Self.hasDeeplinkArg {
            finish()
            return
        }

        let ad = AdManager.shared

        // 对齐 Android 冷启动配置同步等待:
        // 如果 bootstrap 尚未完成 (首次安装 / 清数据), 给 refreshConfig 一个 2.5s 窗口
        // 确保远程配置到位后再判断是否展示广告, 避免"首次启动永远没 splash".
        if !ad.bootstrapped {
            await withTimeout(seconds: 2.5) {
                await ad.bootstrap()
                return true
            }
        }

        let consented = ad.consented
        let enabled = ad.enabled
        let reviewMode = ad.reviewMode

        if consented && enabled && !reviewMode {
            adShowing = true
            let _ = await withTimeout(seconds: Self.withAdDurationSec) {
                _ = await ad.showSplash(container: EmptyView())
                return true
            }
        } else {
            try? await Task.sleep(nanoseconds: UInt64(Self.brandOnlyDurationSec * 1e9))
        }

        finish()
    }

    private func finish() {
        guard !jumped else { return }
        jumped = true
        WanxiangAnalytics.shared.track("page_splash_done", type: "pv")
        onFinish()
    }

    /// 简单 timeout race — 主任务超时时返回 false, 让 finish() 提前触发
    private func withTimeout<T: Sendable>(
        seconds: Double, work: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return nil
        }
    }
}

#Preview {
    SplashAdView(onFinish: {})
}
