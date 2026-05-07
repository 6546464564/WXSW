//
//  WanxiangColors.swift
//  万象书屋 iOS · 设计系统
//
//  跟 Android `app/src/main/res/values/colors.xml` 的 wanxiang_primary 对齐.
//  主品牌色: 棕金 #B8956B (实测 Android 现网值, 不是 0xc8922a)
//

import SwiftUI

enum WanxiangColors {

    /// 主色: 棕金 #B8956B
    static let primary = Color(red: 0xB8/255.0, green: 0x95/255.0, blue: 0x6B/255.0)

    /// 强调色 (链接 / 按钮悬停): 比 primary 深一档
    static let accent = Color(red: 0xA6/255.0, green: 0x93/255.0, blue: 0x74/255.0)

    /// 默认背景 (羊皮纸感)
    static let background = Color(red: 0xF5/255.0, green: 0xEF/255.0, blue: 0xE6/255.0)

    /// 卡片背景
    static let card = Color(red: 0xFF/255.0, green: 0xFA/255.0, blue: 0xF3/255.0)

    /// 主文本色 (深棕)
    static let textPrimary = Color(red: 0x3E/255.0, green: 0x2D/255.0, blue: 0x1B/255.0)

    /// 次要文本色
    static let textSecondary = Color(red: 0x7B/255.0, green: 0x6A/255.0, blue: 0x55/255.0)

    /// 分隔线
    static let divider = Color(red: 0xE0/255.0, green: 0xD3/255.0, blue: 0xBC/255.0)

    /// 阅读器夜间主题色 (M2.5.4 用)
    enum Night {
        static let background = Color(red: 0x16/255.0, green: 0x16/255.0, blue: 0x16/255.0)
        static let text = Color(red: 0x9B/255.0, green: 0x96/255.0, blue: 0x8C/255.0)
    }

    /// 阅读器护眼主题色 (M2.5.4 用)
    enum Eye {
        static let background = Color(red: 0xC7/255.0, green: 0xED/255.0, blue: 0xCC/255.0)
        static let text = Color(red: 0x33/255.0, green: 0x33/255.0, blue: 0x33/255.0)
    }
}
