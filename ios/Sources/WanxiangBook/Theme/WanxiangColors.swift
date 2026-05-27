//
//  WanxiangColors.swift
//  万象书屋 iOS · 设计系统
//
//  跟 Android `app/src/main/res/values/colors.xml` 的 wanxiang_primary 对齐.
//  主品牌色: 棕金 #B8956B (实测 Android 现网值, 不是 0xc8922a)
//
//  日间/夜间/跟随系统: 通过 UIColor dynamic provider 随 colorScheme 切换;
//  ThemeManager 的 preferredColorScheme 决定解析到 light 还是 dark 分支.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum WanxiangColors {

    /// 主色: 棕金 #B8956B (夜间略提亮保证对比度)
    static let primary = adaptive(
        light: rgb(0xB8, 0x95, 0x6B),
        dark: rgb(0xC9, 0xA6, 0x7A)
    )

    /// 强调色 (链接 / 按钮悬停)
    static let accent = adaptive(
        light: rgb(0xA6, 0x93, 0x74),
        dark: rgb(0xB8, 0xA5, 0x88)
    )

    /// 默认背景 (羊皮纸感 / 夜间深棕灰)
    static let background = adaptive(
        light: rgb(0xF5, 0xEF, 0xE6),
        dark: rgb(0x16, 0x16, 0x16)
    )

    /// 卡片背景
    static let card = adaptive(
        light: rgb(0xFF, 0xFA, 0xF3),
        dark: rgb(0x22, 0x20, 0x1D)
    )

    /// 主文本色
    static let textPrimary = adaptive(
        light: rgb(0x3E, 0x2D, 0x1B),
        dark: rgb(0xE8, 0xE0, 0xD4)
    )

    /// 次要文本色
    static let textSecondary = adaptive(
        light: rgb(0x7B, 0x6A, 0x55),
        dark: rgb(0x9B, 0x96, 0x8C)
    )

    /// 分隔线
    static let divider = adaptive(
        light: rgb(0xE0, 0xD3, 0xBC),
        dark: rgb(0x3A, 0x35, 0x30)
    )

    /// 阅读器夜间主题色 (M2.5.4 用 — 固定色, 不随 App 主题变)
    enum Night {
        static let background = Color(red: 0x16/255.0, green: 0x16/255.0, blue: 0x16/255.0)
        static let text = Color(red: 0x9B/255.0, green: 0x96/255.0, blue: 0x8C/255.0)
    }

    /// 阅读器护眼主题色 (M2.5.4 用)
    enum Eye {
        static let background = Color(red: 0xC7/255.0, green: 0xED/255.0, blue: 0xCC/255.0)
        static let text = Color(red: 0x33/255.0, green: 0x33/255.0, blue: 0x33/255.0)
    }

    #if canImport(UIKit)
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
    #else
    private static func adaptive(light: Color, dark: Color) -> Color { light }
    #endif
}
