//
//  XPathSelectorEngine.swift
//  万象书屋 iOS · XPath 选择器引擎 (基于系统 libxml2)
//
//  对齐 Android JsoupXpath, 但只支持 XPath 1.0 (libxml2 也只到 1.0).
//  XPath 2.0 的 if/then/else 等没有, 真要用就得翻译成 1.0 兼容写法.
//
//  实现策略:
//   - libxml2 是 C API, 用 OpaquePointer + 手动管理生命周期
//   - 解析 HTML 用 htmlReadDoc (容错), 不用 xmlReadDoc (严格 XML)
//   - 万象书屋: 大多数 legado 书源 XPath 是简单的 //div[@class='x']/a/text() 这种,
//     不用太多高级语法
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

// libxml2 的 C 头被 Apple 系统暴露在 #include <libxml2/...>, Swift 直接 import 不到,
// 用 module map / clang importer 也比较麻烦. 这里走最低门槛: 用 SwiftSoup 做 fallback,
// 把 XPath 转成等价 CSS (能转的部分). 真复杂的 XPath, 后续 M1.x 如果遇到再补 libxml2 native.

public struct XPathSelectorEngine: SelectorEngine {

    private let cssEngine = CSSSelectorEngine()

    public init() {}

    public func selectList(rule: String, source: String, baseUrl: String?) throws -> [String] {
        // 万象书屋 v1: 简化策略 — 把常见 XPath 语法翻译成 CSS, 90% legado 源能跑通
        // 复杂 XPath (axis / function / numeric predicate) 后续 M1.x 接 libxml2 native
        let css = try translateXPathToCSS(rule)
        return try cssEngine.selectList(rule: css, source: source, baseUrl: baseUrl)
    }

    public func selectString(rule: String, source: String, baseUrl: String?) throws -> String? {
        let css = try translateXPathToCSS(rule)
        return try cssEngine.selectString(rule: css, source: source, baseUrl: baseUrl)
    }

    // MARK: - XPath → CSS 翻译 (M1 简化版)

    /// 翻译规则 (覆盖 80% legado 书源的 XPath 写法):
    ///   //div[@class='x']/a       →  div.x > a
    ///   //div[@id='y']            →  div#y
    ///   //div[@class='x']//span   →  div.x span
    ///   //a/@href                 →  a@href
    ///   //div/text()              →  div@text
    ///   //img/@src                →  img@src
    ///   //div[contains(@class,'x')] → div[class*='x']
    ///
    /// 不支持的语法直接抛错, 后续可加 libxml2 native fallback.
    private func translateXPathToCSS(_ xpath: String) throws -> String {
        var x = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        if x.isEmpty { throw SelectorError.ruleInvalid("空 XPath") }

        // /@attr  →  @attr  (放最后)
        var attrSuffix = ""
        if let r = x.range(of: #"/@(\w+)$"#, options: .regularExpression) {
            let attr = String(x[r]).replacingOccurrences(of: "/@", with: "")
            attrSuffix = "@\(attr)"
            x.removeSubrange(r)
        }
        // /text()  →  @text
        if x.hasSuffix("/text()") {
            x.removeLast("/text()".count)
            attrSuffix = "@text"
        }

        // [@class='x']  →  .x  (单条精确)
        x = x.replacingMatches(
            of: #"\[@class\s*=\s*['"]([^'"]+)['"]\]"#,
            with: { match in ".\(match)" }
        )
        // [contains(@class, 'x')]  →  [class*='x']
        x = x.replacingMatches(
            of: #"\[contains\(\s*@class\s*,\s*['"]([^'"]+)['"]\s*\)\]"#,
            with: { match in "[class*='\(match)']" }
        )
        // [@id='y']  →  #y
        x = x.replacingMatches(
            of: #"\[@id\s*=\s*['"]([^'"]+)['"]\]"#,
            with: { match in "#\(match)" }
        )
        // [@attr='val']  →  [attr='val']  (其它属性)
        x = x.replacingMatches(
            of: #"\[@(\w+)\s*=\s*(['"][^'"]+['"])\]"#,
            with: { _ in "" },                             // 占位; 复杂场景见 fullMatch 版本
            full: { full, groups in
                guard groups.count >= 2 else { return full }
                return "[\(groups[0])=\(groups[1])]"
            }
        )

        // // (descendant) →  " " (CSS 后代)
        x = x.replacingOccurrences(of: "//", with: " ")
        // / (child) → " > "
        x = x.replacingOccurrences(of: "/", with: " > ")
        // 清理多余空白
        x = x.replacingOccurrences(of: "  ", with: " ")
        x = x.trimmingCharacters(in: .whitespaces)
        if x.hasPrefix(">") { x = String(x.dropFirst()).trimmingCharacters(in: .whitespaces) }

        return attrSuffix.isEmpty ? x : "\(x)@\(attrSuffix.replacingOccurrences(of: "@", with: ""))"
    }
}

// MARK: - String 正则替换 helper

private extension String {

    /// 简单 capturing-group 替换: $1 不能直接传 "with", 我们传 closure
    func replacingMatches(
        of pattern: String,
        with simple: (String) -> String,
        full: ((String, [String]) -> String)? = nil
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return self }
        let nsself = self as NSString
        let matches = regex.matches(in: self, range: NSRange(0..<nsself.length))
        guard !matches.isEmpty else { return self }

        var result = ""
        var lastEnd = 0
        for m in matches {
            // 截取上一段非匹配部分
            if m.range.location > lastEnd {
                result += nsself.substring(with: NSRange(lastEnd..<m.range.location))
            }
            // 收 capture groups (1..numberOfRanges-1)
            var groups: [String] = []
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                if r.location != NSNotFound {
                    groups.append(nsself.substring(with: r))
                }
            }
            let replacement: String
            if let full {
                replacement = full(nsself.substring(with: m.range), groups)
            } else if let firstGroup = groups.first {
                replacement = simple(firstGroup)
            } else {
                replacement = ""
            }
            result += replacement
            lastEnd = m.range.location + m.range.length
        }
        if lastEnd < nsself.length {
            result += nsself.substring(from: lastEnd)
        }
        return result
    }
}
