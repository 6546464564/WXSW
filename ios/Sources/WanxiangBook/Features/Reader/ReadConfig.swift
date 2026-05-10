//
//  ReadConfig.swift
//  万象书屋 iOS · 阅读偏好 (M2.5.4 + M2.10.1)
//
//  对应 Android: io.legado.app.help.config.ReadBookConfig + ReadConfig
//
//  字段 (跟 Android 一一对应):
//   - 字号 textSize 12-32 sp
//   - 行间距 lineSpacing 0.8-2.5
//   - 段间距 paragraphSpacing 0-30
//   - 字间距 letterSpacing 0-3
//   - 上下左右页边距 padding* 0-50
//   - 首行缩进 indentChars 0-4
//   - 翻页方式 pageAnim
//   - 主题 theme
//   - 亮度 brightness 0-100
//   - 自动亮度 autoBrightness
//

import SwiftUI
import UIKit
import Combine

// MARK: - 翻页方式 (5 种, 跟 Android arrays.xml page_anim 对齐)

public enum PageAnim: Int, CaseIterable, Sendable {
    case cover = 0       // 覆盖
    case slide = 1       // 滑动
    case simulate = 2    // 仿真翻书 (M2.5.3.5, ⭐⭐⭐⭐⭐ 难,可延后到 v1.5)
    case scroll = 3      // 滚动 (垂直无限)
    case none = 4        // 无动画

    public var displayName: String {
        switch self {
        case .cover: return "覆盖"
        case .slide: return "滑动"
        case .simulate: return "仿真"
        case .scroll: return "滚动"
        case .none: return "无动画"
        }
    }
}

// MARK: - 主题

public enum ReaderThemeKind: Int, CaseIterable, Sendable {
    case `default` = 0   // 万象羊皮纸 #F5EFE6
    case eye = 1         // 护眼 (淡绿)
    case night = 2       // 夜间 (深灰)
    case parchment = 3   // 羊皮纸 (米黄)

    public var displayName: String {
        switch self {
        case .default: return "默认"
        case .eye: return "护眼"
        case .night: return "夜间"
        case .parchment: return "羊皮纸"
        }
    }

    public var background: Color {
        switch self {
        case .default:    return Color(red: 0xF5/255, green: 0xEF/255, blue: 0xE6/255)
        case .eye:        return Color(red: 0xC7/255, green: 0xED/255, blue: 0xCC/255)
        case .night:      return Color(red: 0x16/255, green: 0x16/255, blue: 0x16/255)
        case .parchment:  return Color(red: 0xEF/255, green: 0xDF/255, blue: 0xB6/255)
        }
    }

    public var textColor: Color {
        switch self {
        case .default:    return Color(red: 0x3E/255, green: 0x2D/255, blue: 0x1B/255)
        case .eye:        return Color(red: 0x33/255, green: 0x33/255, blue: 0x33/255)
        case .night:      return Color(red: 0x9B/255, green: 0x96/255, blue: 0x8C/255)
        case .parchment:  return Color(red: 0x4A/255, green: 0x35/255, blue: 0x1B/255)
        }
    }

    public var isDark: Bool { self == .night }
}

// MARK: - 阅读偏好 ObservableObject

@MainActor
public final class ReadConfig: ObservableObject {

    public static let shared = ReadConfig()

    // 字号 (sp/pt 单位通用, 12-32)
    @Published public var textSize: CGFloat {
        didSet { UserDefaults.standard.set(textSize, forKey: K.textSize) }
    }
    // 行间距 (倍数 0.8-2.5)
    @Published public var lineSpacing: CGFloat {
        didSet { UserDefaults.standard.set(lineSpacing, forKey: K.lineSpacing) }
    }
    // 段间距 (pt, 0-30)
    @Published public var paragraphSpacing: CGFloat {
        didSet { UserDefaults.standard.set(paragraphSpacing, forKey: K.paragraphSpacing) }
    }
    // 字间距 (pt, 0-3)
    @Published public var letterSpacing: CGFloat {
        didSet { UserDefaults.standard.set(letterSpacing, forKey: K.letterSpacing) }
    }
    // 边距 (pt, 0-50)
    @Published public var paddingTop: CGFloat {
        didSet { UserDefaults.standard.set(paddingTop, forKey: K.paddingTop) }
    }
    @Published public var paddingBottom: CGFloat {
        didSet { UserDefaults.standard.set(paddingBottom, forKey: K.paddingBottom) }
    }
    @Published public var paddingHorizontal: CGFloat {
        didSet { UserDefaults.standard.set(paddingHorizontal, forKey: K.paddingHorizontal) }
    }
    // 首行缩进字符数 (0-4)
    @Published public var indentChars: Int {
        didSet { UserDefaults.standard.set(indentChars, forKey: K.indentChars) }
    }
    // 翻页方式
    @Published public var pageAnim: PageAnim {
        didSet { UserDefaults.standard.set(pageAnim.rawValue, forKey: K.pageAnim) }
    }
    // 主题
    @Published public var theme: ReaderThemeKind {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: K.theme) }
    }
    // 亮度 (0-100, -1 = 跟随系统)
    @Published public var brightness: Int {
        didSet { UserDefaults.standard.set(brightness, forKey: K.brightness) }
    }
    @Published public var autoBrightness: Bool {
        didSet { UserDefaults.standard.set(autoBrightness, forKey: K.autoBrightness) }
    }
    // 保持常亮
    @Published public var keepScreenOn: Bool {
        didSet { UserDefaults.standard.set(keepScreenOn, forKey: K.keepScreenOn) }
    }
    /// 万象书屋 (M2.8): 字体. 空字符串 = 系统默认 (动态适配 iOS 系统语言).
    /// 实际值是 UIFont.familyName (e.g. "PingFang SC", "Songti SC").
    @Published public var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: K.fontFamily) }
    }

    enum K {
        static let textSize = "wanxiang.read.textSize"
        static let lineSpacing = "wanxiang.read.lineSpacing"
        static let paragraphSpacing = "wanxiang.read.paragraphSpacing"
        static let letterSpacing = "wanxiang.read.letterSpacing"
        static let paddingTop = "wanxiang.read.paddingTop"
        static let paddingBottom = "wanxiang.read.paddingBottom"
        static let paddingHorizontal = "wanxiang.read.paddingHorizontal"
        static let indentChars = "wanxiang.read.indentChars"
        static let pageAnim = "wanxiang.read.pageAnim"
        static let theme = "wanxiang.read.theme"
        static let brightness = "wanxiang.read.brightness"
        static let autoBrightness = "wanxiang.read.autoBrightness"
        static let keepScreenOn = "wanxiang.read.keepScreenOn"
        static let fontFamily = "wanxiang.read.fontFamily"
    }

    /// 万象书屋: 中文系统字体白名单 — iOS 内置可用的中文字体, 覆盖大部分用户偏好.
    public struct FontOption: Identifiable, Hashable {
        public let id = UUID()
        public let displayName: String
        public let familyName: String   // 空字符串 = 系统默认
    }
    public static let chineseFonts: [FontOption] = [
        FontOption(displayName: "系统默认",       familyName: ""),
        FontOption(displayName: "苹方",          familyName: "PingFang SC"),
        FontOption(displayName: "宋体",          familyName: "Songti SC"),
        FontOption(displayName: "黑体",          familyName: "Heiti SC"),
        FontOption(displayName: "楷体",          familyName: "Kaiti SC"),
        FontOption(displayName: "STSong",       familyName: "STSong"),
        FontOption(displayName: "STKaiti",      familyName: "STKaiti"),
        FontOption(displayName: "STFangsong",   familyName: "STFangsong"),
        FontOption(displayName: "STHeiti",      familyName: "STHeiti"),
        FontOption(displayName: "Hiragino Sans GB", familyName: "Hiragino Sans GB"),
    ]

    private init() {
        let d = UserDefaults.standard
        self.textSize = d.value(forKey: K.textSize) as? CGFloat ?? 18
        self.lineSpacing = d.value(forKey: K.lineSpacing) as? CGFloat ?? 1.5
        self.paragraphSpacing = d.value(forKey: K.paragraphSpacing) as? CGFloat ?? 12
        self.letterSpacing = d.value(forKey: K.letterSpacing) as? CGFloat ?? 0
        self.paddingTop = d.value(forKey: K.paddingTop) as? CGFloat ?? 18
        self.paddingBottom = d.value(forKey: K.paddingBottom) as? CGFloat ?? 12
        self.paddingHorizontal = d.value(forKey: K.paddingHorizontal) as? CGFloat ?? 18
        self.indentChars = d.value(forKey: K.indentChars) as? Int ?? 2
        self.pageAnim = PageAnim(rawValue: d.integer(forKey: K.pageAnim)) ?? .cover
        self.theme = ReaderThemeKind(rawValue: d.integer(forKey: K.theme)) ?? .default
        self.brightness = (d.value(forKey: K.brightness) as? Int) ?? -1
        self.autoBrightness = d.bool(forKey: K.autoBrightness)
        self.keepScreenOn = (d.value(forKey: K.keepScreenOn) as? Bool) ?? true
        self.fontFamily = d.string(forKey: K.fontFamily) ?? ""
    }

    /// 万象书屋: 给 PaginationEngine / SwiftUI Text 用的 UIFont.
    /// fontFamily 空 → 系统默认 (.preferredFont)
    public func uiFont(size: CGFloat? = nil) -> UIFont {
        let s = size ?? textSize
        if fontFamily.isEmpty {
            return UIFont.systemFont(ofSize: s)
        }
        // family 取一个具体 face
        if let descriptor = UIFontDescriptor(name: fontFamily, size: s) as UIFontDescriptor? {
            return UIFont(descriptor: descriptor, size: s)
        }
        return UIFont.systemFont(ofSize: s)
    }
}
