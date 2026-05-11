//
//  ReadingSettings.swift
//  万象书屋 iOS · 阅读行为开关 (UserDefaults)
//
//  对齐 Android: PreferKey.autoChangeSource / AppConfig.autoChangeSource (默认 true)
//

import Foundation

public enum ReadingSettings {
    /// 与 `ThemeSettingsView` 中 `@AppStorage("wanxiang.read.auto_change_source")` 同一键; 默认 true (对齐 Android).
    private static let autoChangeSourceKey = "wanxiang.read.auto_change_source"

    /// 无可用源时自动换源、正文失败时静默尝试换源 — 与 Legado「自动换源」一致, 默认开启.
    public static var autoChangeSourceEnabled: Bool {
        UserDefaults.standard.object(forKey: autoChangeSourceKey) as? Bool ?? true
    }
}
