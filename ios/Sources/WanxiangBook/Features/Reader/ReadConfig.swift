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
import CoreText

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

    /// 万象书屋: 中文阅读字体候选（去重 + 中文显示名）.
    public struct FontOption: Identifiable, Hashable {
        public var id: String { familyName }
        public let displayName: String
        public let familyName: String   // 空字符串 = 系统默认
    }

    private static let chineseFontCandidates: [FontOption] = [
        FontOption(displayName: "系统默认", familyName: ""),
        FontOption(displayName: "黑体", familyName: "NotoSansSC-Regular"),
        FontOption(displayName: "宋体", familyName: "NotoSerifSC-Regular"),
        FontOption(displayName: "楷体", familyName: "LXGWWenKai-Regular"),
    ]

    private static let bundledFontResources: [(name: String, ext: String)] = [
        ("NotoSansSC-Regular", "otf"),
        ("NotoSerifSC-Regular", "otf"),
        ("LXGWWenKai-Regular", "ttf"),
    ]

    private static var bundledFontsRegistered = false

    /// 显式注册内置字体（UIAppFonts 之外再保障一次）.
    private static func ensureBundledFontsRegistered() {
        guard !bundledFontsRegistered else { return }
        bundledFontsRegistered = true
        for res in bundledFontResources {
            guard let url = Bundle.main.url(forResource: res.name, withExtension: res.ext) else {
                #if DEBUG
                NSLog("[WX-Font] bundled font missing: %@.%@", res.name, res.ext)
                #endif
                continue
            }
            var err: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
        }
    }

    /// 旧版 / 已移除字体 → 当前 canonical 值.
    private static let fontFamilyAliases: [String: String] = [
        "PingFang SC": "",
        "Heiti SC": "NotoSansSC-Regular",
        "STHeiti": "NotoSansSC-Regular",
        "Hiragino Sans GB": "NotoSansSC-Regular",
        "Hiragino Sans": "NotoSansSC-Regular",
        "Songti SC": "NotoSerifSC-Regular",
        "STSong": "NotoSerifSC-Regular",
        "Kaiti SC": "LXGWWenKai-Regular",
        "STKaiti": "LXGWWenKai-Regular",
        "STFangsong": "NotoSerifSC-Regular",
        "Yuanti SC": "NotoSansSC-Regular",
        "__system_serif__": "NotoSerifSC-Regular",
        "__system_rounded__": "NotoSansSC-Regular",
        "Hiragino Mincho ProN": "NotoSerifSC-Regular",
        "Hiragino Maru Gothic ProN": "NotoSansSC-Regular",
    ]

    /// 当前设备可用且不重复的阅读字体.
    public static var availableChineseFonts: [FontOption] {
        ensureBundledFontsRegistered()
        var seenPostScript = Set<String>()
        var result: [FontOption] = []
        for opt in chineseFontCandidates {
            guard isFontAvailable(opt.familyName) else { continue }
            let ps = resolveUIFont(family: opt.familyName, size: 12).fontName
            guard seenPostScript.insert(ps).inserted else { continue }
            result.append(opt)
        }
        return result
    }

    /// 启动时打印设备字体诊断（Debug 构建）.
    public static func logFontDiagnostics() {
        #if DEBUG
        for opt in chineseFontCandidates {
            let ok = isFontAvailable(opt.familyName)
            let font = resolveUIFont(family: opt.familyName, size: 12)
            let inList = availableChineseFonts.contains { $0.familyName == opt.familyName }
            NSLog("[WX-Font] %@ family=%@ ok=%@ listed=%@ resolved=%@",
                  opt.displayName, opt.familyName, ok ? "YES" : "NO", inList ? "YES" : "NO", font.fontName)
        }
        #endif
    }

    private static func isFontAvailable(_ family: String) -> Bool {
        if family.isEmpty { return true }
        ensureBundledFontsRegistered()
        return UIFont(name: family, size: 12) != nil
    }

    /// 按字体族名解析 UIFont（iOS 需通过 fontNames(forFamilyName:) 取具体 face）.
    nonisolated public static func resolveUIFont(family: String, size: CGFloat, bold: Bool = false) -> UIFont {
        if family.isEmpty {
            return bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        }
        let base: UIFont?
        if let named = UIFont(name: family, size: size) {
            base = named
        } else if let face = UIFont.fontNames(forFamilyName: family).first,
                  let font = UIFont(name: face, size: size) {
            base = font
        } else {
            base = nil
        }
        guard let base else {
            return bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        }
        if !bold { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
        return UIFont(descriptor: desc, size: size)
    }

    private static func normalizeFontFamily(_ raw: String) -> String {
        let aliased = fontFamilyAliases[raw] ?? raw
        guard !aliased.isEmpty else { return "" }
        return isFontAvailable(aliased) ? aliased : ""
    }

    private init() {
        let d = UserDefaults.standard
        self.textSize = d.value(forKey: K.textSize) as? CGFloat ?? 20
        // 迁移: 对齐安卓默认 lineSpacingExtra=12/10=1.2, 旧默认 1.6 调整为 1.2
        if let stored = d.value(forKey: K.lineSpacing) as? CGFloat, stored >= 1.6 {
            d.set(Float(1.2), forKey: K.lineSpacing)
        }
        self.lineSpacing = d.value(forKey: K.lineSpacing) as? CGFloat ?? 1.2
        // 迁移: 对齐参考视觉效果, 默认 6pt (约 0.25×lineHeight); 旧值 ≥8 调整为 6pt
        if let stored = d.value(forKey: K.paragraphSpacing) as? CGFloat, stored >= 8 {
            d.set(CGFloat(6), forKey: K.paragraphSpacing)
        }
        self.paragraphSpacing = d.value(forKey: K.paragraphSpacing) as? CGFloat ?? 6
        self.letterSpacing = d.value(forKey: K.letterSpacing) as? CGFloat ?? 0
        // 万象书屋 (排版): 默认上下边距加宽, 章节标题更有"打开一本书"的呼吸感, 页脚也不贴边
        self.paddingTop = d.value(forKey: K.paddingTop) as? CGFloat ?? 24
        self.paddingBottom = d.value(forKey: K.paddingBottom) as? CGFloat ?? 18
        self.paddingHorizontal = d.value(forKey: K.paddingHorizontal) as? CGFloat ?? 20
        self.indentChars = d.value(forKey: K.indentChars) as? Int ?? 2
        self.pageAnim = PageAnim(rawValue: d.integer(forKey: K.pageAnim)) ?? .cover
        self.theme = ReaderThemeKind(rawValue: d.integer(forKey: K.theme)) ?? .default
        self.brightness = (d.value(forKey: K.brightness) as? Int) ?? -1
        self.autoBrightness = d.bool(forKey: K.autoBrightness)
        self.keepScreenOn = (d.value(forKey: K.keepScreenOn) as? Bool) ?? true
        let rawFontFamily = d.string(forKey: K.fontFamily) ?? ""
        self.fontFamily = Self.normalizeFontFamily(rawFontFamily)
        if self.fontFamily != rawFontFamily {
            d.set(self.fontFamily, forKey: K.fontFamily)
        }
    }

    /// 万象书屋: 给 PaginationEngine / SwiftUI Text 用的 UIFont.
    /// fontFamily 空 → 系统默认 (.preferredFont)
    public func uiFont(size: CGFloat? = nil) -> UIFont {
        Self.resolveUIFont(family: fontFamily, size: size ?? textSize)
    }
}
