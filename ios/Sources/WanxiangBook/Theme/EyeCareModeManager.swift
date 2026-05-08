//
//  EyeCareModeManager.swift
//  万象书屋 iOS · 护眼模式 — 全屏暖色滤镜
//
//  对应 Android: io.legado.app.help.EyeCareHelper (D-18 v1 + D-20 自适应)
//
//  实现策略:
//   - SwiftUI 顶层 ZStack 加一个 .allowsHitTesting(false) 的 Color overlay
//   - 颜色 #FAF0DC (跟 Android v1 完全一致)
//   - **alpha 自适应** (D-20 iOS 等价):
//       Android 用 Sensor.TYPE_LIGHT (lux) → alpha 映射;
//       iOS 没公开 ALS API, 用 UIScreen.main.brightness (0.0-1.0) 间接推断:
//          系统开了"自动亮度"时, brightness 跟环境光高度相关 (Apple ALS 输出)
//          用户没开自动亮度时, brightness 反映用户主观偏好 (深夜调暗, 白天调亮)
//          两种场景下 brightness 越低 → alpha 越高 (越暗的环境下加强滤镜) 都成立.
//
//   - 监听 UIScreen.brightnessDidChangeNotification, 跨档 (>0.05 差异) 才更新 alpha
//     避免 brightness slider 微调时 overlay 频繁刷新.
//
//  开关存 UserDefaults `wanxiang.eye_care_mode`
//

import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class EyeCareModeManager: ObservableObject {

    static let shared = EyeCareModeManager()

    /// 开/关. UI 直接 `$EyeCareModeManager.shared.enabled` 双向绑.
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.kKey)
            // 开/关时立即重算 alpha (避免开了之后还是默认 30%)
            recomputeAlphaFromBrightness()
        }
    }

    /// 当前应用的 alpha (0.0-1.0). 0.30 是默认 (跟 Android DEFAULT_ALPHA 0x4D 同).
    @Published private(set) var currentAlpha: Double = 0x4D / 255.0

    private static let kKey = "wanxiang.eye_care_mode"

    /// 跟 Android `BASE_RGB = 0xFAF0DC` 等价
    let baseColor: Color = Color(red: 0xFA / 255.0, green: 0xF0 / 255.0, blue: 0xDC / 255.0)

    /// 节流: alpha 跨 0.05 (≈ Android 0x10/255) 才重算
    private static let alphaStepThreshold: Double = 0.05

    private var brightnessObserver: NSObjectProtocol?

    private init() {
        self.enabled = UserDefaults.standard.bool(forKey: Self.kKey)
        installBrightnessObserver()
        recomputeAlphaFromBrightness()
    }

    // MARK: - Brightness adaptive

    /// 跟 Android `LightSensorMonitor.computeAlphaFromLux` 等价 — 输入空间不同 (brightness 0-1
    /// 而不是 lux), 但映射档位语义对齐:
    ///   brightness < 0.10 (深夜暗室)  → alpha 0x66 (40%)
    ///   brightness < 0.30 (昏暗)      → alpha 0x4D (30%)  ← 默认
    ///   brightness < 0.60 (普通室内)  → alpha 0x40 (25%)
    ///   brightness < 0.85 (明亮)      → alpha 0x33 (20%)
    ///   brightness >= 0.85 (强光/户外) → alpha 0x26 (15%)
    private static func computeAlpha(forBrightness b: Double) -> Double {
        switch b {
        case ..<0.10: return 0x66 / 255.0
        case ..<0.30: return 0x4D / 255.0
        case ..<0.60: return 0x40 / 255.0
        case ..<0.85: return 0x33 / 255.0
        default:      return 0x26 / 255.0
        }
    }

    private func installBrightnessObserver() {
        #if canImport(UIKit)
        brightnessObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recomputeAlphaFromBrightness() }
        }
        #endif
    }

    private func recomputeAlphaFromBrightness() {
        #if canImport(UIKit)
        let b = Double(UIScreen.main.brightness)
        let newAlpha = Self.computeAlpha(forBrightness: b).coerceIn(min: 0.12, max: 0.50)
        // 节流: 跨档才更新 (避免亮度滑块连续滑动时 overlay 闪烁)
        if abs(newAlpha - currentAlpha) >= Self.alphaStepThreshold {
            currentAlpha = newAlpha
        }
        #endif
    }
}

private extension Double {
    func coerceIn(min lo: Double, max hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, self))
    }
}

// MARK: - View 修饰器: 给 Root 树加全屏暖色 overlay

extension View {

    /// 万象书屋: 在视图最顶层叠一层暖色滤镜 (跟 Android EyeCareHelper.apply 等价).
    /// 调用方应把它放在 RootView body 最外层, 让所有子页面都受影响.
    @ViewBuilder
    func wanxiangEyeCareOverlay(_ manager: EyeCareModeManager = .shared) -> some View {
        self.overlay {
            if manager.enabled {
                manager.baseColor
                    .opacity(manager.currentAlpha)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
        }
    }
}
