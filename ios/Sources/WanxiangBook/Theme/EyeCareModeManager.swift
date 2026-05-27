//
//  EyeCareModeManager.swift
//  万象书屋 iOS · 护眼模式 — 暖色滤镜 + 节律 + 阅读联动
//
//  对应 Android: io.legado.app.help.EyeCareHelper (D-18~D-22)
//  强度由亮度 + 时段自动决定, 不提供手动档位.
//

import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 阅读器 overlay 衰减 (Environment)

private struct WanxiangInReaderKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 当前在 ReaderView 内 — overlay 强度 ×0.35, 避免与阅读主题双重滤镜
    var wanxiangInReader: Bool {
        get { self[WanxiangInReaderKey.self] }
        set { self[WanxiangInReaderKey.self] = newValue }
    }
}

// MARK: - Manager

@MainActor
final class EyeCareModeManager: ObservableObject {

    static let shared = EyeCareModeManager()

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.kEnabled)
            if enabled {
                applySmartReaderTheme()
            }
            recomputeOverlay()
        }
    }

    @Published private(set) var currentAlpha: Double = 0x4D / 255.0
    @Published private(set) var baseColor: Color = Color(red: 0xFA / 255.0, green: 0xF0 / 255.0, blue: 0xDC / 255.0)

    private static let kEnabled = "wanxiang.eye_care_mode"
    private static let alphaStepThreshold: Double = 0.05
    private static let readerOverlayFactor: Double = 0.35

    private static let standardTint = Color(red: 0xFA / 255.0, green: 0xF0 / 255.0, blue: 0xDC / 255.0)
    private static let deepNightTint = Color(red: 1.0, green: 0.88, blue: 0.70)

    private var brightnessObserver: NSObjectProtocol?
    private var timer: Timer?

    private init() {
        self.enabled = UserDefaults.standard.bool(forKey: Self.kEnabled)
        installBrightnessObserver()
        startCircadianTimer()
        recomputeOverlay()
    }

    func overlayAlpha(inReader: Bool) -> Double {
        guard enabled else { return 0 }
        var alpha = currentAlpha
        if inReader { alpha *= Self.readerOverlayFactor }
        return alpha
    }

    // MARK: - 自动强度 (亮度 + 时段)

    private static func computeBaseAlpha(forBrightness b: Double) -> Double {
        switch b {
        case ..<0.10: return 0x66 / 255.0
        case ..<0.30: return 0x4D / 255.0
        case ..<0.60: return 0x40 / 255.0
        case ..<0.85: return 0x33 / 255.0
        default:      return 0x26 / 255.0
        }
    }

    private static func circadianMultiplier() -> Double {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 22...23, 0...6: return 1.15
        case 7...17: return 0.85
        default: return 1.0
        }
    }

    /// 深夜 / 极暗环境略加强暖色; 白天保持标准色
    private static func autoTint(forBrightness b: Double) -> Color {
        let hour = Calendar.current.component(.hour, from: Date())
        let deepNight = hour >= 22 || hour < 6 || b < 0.15
        return deepNight ? deepNightTint : standardTint
    }

    private func recomputeOverlay() {
        #if canImport(UIKit)
        let b = Double(UIScreen.main.brightness)
        baseColor = Self.autoTint(forBrightness: b)
        let raw = Self.computeBaseAlpha(forBrightness: b) * Self.circadianMultiplier()
        let newAlpha = raw.coerceIn(min: 0.10, max: 0.55)
        if abs(newAlpha - currentAlpha) >= Self.alphaStepThreshold {
            currentAlpha = newAlpha
        }
        #endif
    }

    private func installBrightnessObserver() {
        #if canImport(UIKit)
        brightnessObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recomputeOverlay() }
        }
        #endif
    }

    private func startCircadianTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recomputeOverlay() }
        }
    }

    // MARK: - 阅读主题联动

    private func applySmartReaderTheme() {
        #if canImport(UIKit)
        let b = Double(UIScreen.main.brightness)
        #else
        let b = 0.5
        #endif
        let hour = Calendar.current.component(.hour, from: Date())
        let isNightContext = b < 0.35 || hour >= 20 || hour < 7
        ReadConfig.shared.theme = isNightContext ? .night : .parchment
    }
}

private extension Double {
    func coerceIn(min lo: Double, max hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, self))
    }
}

// MARK: - View 修饰器

extension View {

    @ViewBuilder
    func wanxiangEyeCareOverlay(_ manager: EyeCareModeManager = .shared) -> some View {
        modifier(WanxiangEyeCareOverlayModifier(manager: manager))
    }
}

private struct WanxiangEyeCareOverlayModifier: ViewModifier {
    @ObservedObject var manager: EyeCareModeManager
    @Environment(\.wanxiangInReader) private var inReader

    func body(content: Content) -> some View {
        content.overlay {
            if manager.enabled {
                manager.baseColor
                    .opacity(manager.overlayAlpha(inReader: inReader))
                    .blendMode(.multiply)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
        }
    }
}
