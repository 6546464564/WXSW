//
//  SelectorEngine.swift
//  万象书屋 iOS · 选择器引擎抽象
//
//  legado 书源规则前缀:
//   - `@css:`   → CSS 选择器 (jsoup 风格, SwiftSoup 实现)
//   - `@xpath:` → XPath 1.0 (libxml2 实现)
//   - `@json:`  → JSONPath ($.book.list[0].title 类似)
//   - `@js:`    → JavaScript (JavaScriptCore 实现)
//   - `@regex:` → 正则
//   - 无前缀且看起来像 CSS → 默认 CSS
//   - 无前缀且 JSON body → 默认 JSONPath
//
//  组合规则:
//   - `@css:.book@text##\\d+` → 先 CSS 选 .book 取 text, 再正则 \d+ 提取
//   - `||` 后接 net | js | regex 等修饰
//

import Foundation

/// 选择器引擎统一接口. 注意: 引擎是无状态的, 可以并发调用
public protocol SelectorEngine: Sendable {

    func selectList(rule: String, source: String, baseUrl: String?) throws -> [String]

    func selectString(rule: String, source: String, baseUrl: String?) throws -> String?
}

/// 选择器执行错误
public enum SelectorError: Error, LocalizedError {
    case parseFailed(String)
    case ruleInvalid(String)
    case engineUnsupported(String)

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let m): return "源解析失败: \(m)"
        case .ruleInvalid(let m): return "规则不合法: \(m)"
        case .engineUnsupported(let m): return "引擎不支持: \(m)"
        }
    }
}
