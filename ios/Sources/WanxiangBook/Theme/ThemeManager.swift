//
//  ThemeManager.swift
//  万象书屋 iOS · 主题模式管理 (M2.1.6)
//
//  对应 Android: io.legado.app.constant.PreferKey.themeMode + AppConfig.isNightTheme
//
//  3 种模式:
//   - system  跟随系统 (默认)
//   - day     强制日间
//   - night   强制夜间
//

import SwiftUI
import Combine

@MainActor
final class ThemeManager: ObservableObject {

    static let shared = ThemeManager()

    enum Mode: String, CaseIterable, Identifiable {
        case system = "system"
        case day = "day"
        case night = "night"

        var id: String { rawValue }

        /// 跟 Android `arrays.xml` `theme_mode` 对齐 ("跟随系统/日间/夜间")
        var displayName: String {
            switch self {
            case .system: return "跟随系统"
            case .day: return "日间"
            case .night: return "夜间"
            }
        }

        /// 转 SwiftUI ColorScheme (system → nil 让系统决定)
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .day: return .light
            case .night: return .dark
            }
        }
    }

    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.kThemeMode)
        }
    }

    private static let kThemeMode = "wanxiang.theme_mode"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.kThemeMode) ?? Mode.system.rawValue
        self.mode = Mode(rawValue: raw) ?? .system
    }
}

// MARK: - View 修饰器: 全局应用主题色 + 主题模式

extension View {

    /// 万象书屋: 给整个 View 应用品牌色 (主色 / accent / 背景),并响应主题模式
    func wanxiangThemed(_ theme: ThemeManager = .shared) -> some View {
        self
            .preferredColorScheme(theme.mode.colorScheme)
            .accentColor(WanxiangColors.primary)
            .tint(WanxiangColors.primary)
    }
}
