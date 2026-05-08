//
//  L10n.swift
//  万象书屋 iOS · 多语言访问器
//
//  对应 Android: R.string.* + Resources.getString
//
//  设计:
//   - 走标准 Bundle.main.localizedString(forKey:value:table:) — 跟 NSLocalizedString 等价
//   - 提供两个 API:
//       L10n.t("key")           直接取
//       L10n.t("key", "p1", 2)   带参数 (printf style %@/%d/%lld)
//   - 当前阶段保留所有 SwiftUI 硬编码中文字符串 (上架前可以分批迁过来),
//     这个文件先打基础, 让新代码直接走 L10n.t.
//

import Foundation

public enum L10n {

    /// 取本地化字符串. key 不存在时返回 key 本身 (而非 "??") 方便排查.
    public static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// 带参数版本; 自动 String(format:) — 支持 %@ %d %lld %f.
    public static func t(_ key: String, _ args: CVarArg...) -> String {
        let template = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        return String(format: template, locale: Locale.current, arguments: args)
    }
}
