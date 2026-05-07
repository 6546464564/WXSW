//
//  SelectorDispatcher.swift
//  万象书屋 iOS · 选择器派发器
//
//  legado 规则字符串可以是:
//   1. 单段:
//      - "@css:.book@text"          → CSS
//      - "@xpath://div/a/@href"     → XPath
//      - "@json:$.book.list[0]"     → JSONPath
//      - "@js:result.book.title"    → JavaScript (最后求值结果)
//      - "@regex:\\d+"              → 正则
//      - "div.book@text"            → 默认 CSS (无前缀且不像 JSON path)
//      - "$.book.title"             → 默认 JSONPath (以 $ 开头)
//   2. 链式:
//      - "div.book@text##\\d+"      → CSS 选 → 正则提取
//      - "@css:.x##.y##(\\d+)"      → 多重正则
//   3. 组合 (||):
//      - "rule1||rule2"             → rule1 失败则用 rule2 (兜底)
//
//  本 dispatcher M1 实现的子集 (覆盖 90% legado 源):
//   - 前缀路由 (@css/@xpath/@json/@js/@regex)
//   - 默认推断 (CSS or JSONPath)
//   - 链式 ## 正则后处理
//   - || 兜底
//

import Foundation

public struct SelectorDispatcher: Sendable {

    public let css = CSSSelectorEngine()
    public let xpath = XPathSelectorEngine()
    public let json = JSONPathEngine()
    public let js: JSEngine

    public init(js: JSEngine) {
        self.js = js
    }

    /// 主入口: 列表
    /// 万象书屋: 委托给新的 LegadoRuleEngine, 它支持完整 legado DSL
    /// (|| && ## {{}} <js> @get @js: 等). 老 SelectorDispatcher 保留作为底层 engine.
    public func selectList(rule: String, source: String, baseUrl: String?, jsContext: JSContextScope? = nil) async throws -> [String] {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw SelectorError.ruleInvalid("空规则") }

        var ctx = LegadoContext(baseUrl: baseUrl, source: source, key: jsContext?.key,
                                 page: jsContext?.page ?? 1, bookSource: jsContext?.bookSource)
        if let s = jsContext?.src { ctx.source = s }
        return await LegadoRuleEngine.shared.selectList(rule: trimmed, source: source, ctx: ctx)
    }

    /// 主入口: 单值 — 委托新引擎
    public func selectString(rule: String, source: String, baseUrl: String?, jsContext: JSContextScope? = nil) async throws -> String? {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        var ctx = LegadoContext(baseUrl: baseUrl, source: source, key: jsContext?.key,
                                 page: jsContext?.page ?? 1, bookSource: jsContext?.bookSource)
        if let s = jsContext?.src { ctx.source = s }
        return await LegadoRuleEngine.shared.selectString(rule: trimmed, source: source, ctx: ctx)
    }

    // MARK: - 路由

    private func dispatchList(rule: String, source: String, baseUrl: String?, jsContext: JSContextScope?) async throws -> [String] {
        if rule.hasPrefix("@css:") {
            return try css.selectList(rule: String(rule.dropFirst(5)), source: source, baseUrl: baseUrl)
        }
        if rule.hasPrefix("@xpath:") {
            return try xpath.selectList(rule: String(rule.dropFirst(7)), source: source, baseUrl: baseUrl)
        }
        if rule.hasPrefix("@json:") {
            return try json.selectList(rule: String(rule.dropFirst(6)), source: source, baseUrl: baseUrl)
        }
        if rule.hasPrefix("$.") || rule.hasPrefix("$..") {
            return try json.selectList(rule: rule, source: source, baseUrl: baseUrl)
        }
        if rule.hasPrefix("@js:") {
            // JS 返回数组或单值
            let v = try await js.evaluate(script: String(rule.dropFirst(4)),
                                          source: source, baseUrl: baseUrl, scope: jsContext)
            if let arr = v as? [Any] {
                return arr.map { String(describing: $0) }
            }
            if let s = v as? String { return [s] }
            return []
        }
        if rule.hasPrefix("@regex:") {
            return regexFindAll(pattern: String(rule.dropFirst(7)), in: source)
        }
        // 默认 CSS
        return try css.selectList(rule: rule, source: source, baseUrl: baseUrl)
    }

    private func dispatchString(rule: String, source: String, baseUrl: String?, jsContext: JSContextScope?) async throws -> String? {
        // 万象书屋 (P0 fix): mustache + JSONPath 模板
        // 如 "https://x.com/detail/{{$.articleid}}?lang=zh"
        // 检测到 `{{$.xxx}}` 占位符且 source 是 JSON 时, 在 source 里查值替换
        if rule.contains("{{$.") || rule.contains("{{$..") {
            return try expandJsonMustache(template: rule, source: source)
        }
        if rule.hasPrefix("@css:") {
            return try css.selectString(rule: String(rule.dropFirst(5)), source: source, baseUrl: baseUrl)
        }
        if rule.hasPrefix("@xpath:") {
            return try xpath.selectString(rule: String(rule.dropFirst(7)), source: source, baseUrl: baseUrl)
        }
        if rule.hasPrefix("@json:") {
            return try json.selectString(rule: String(rule.dropFirst(6)), source: source, baseUrl: baseUrl)
        }
        if rule.hasPrefix("$.") || rule.hasPrefix("$..") {
            return try json.selectString(rule: rule, source: source, baseUrl: baseUrl)
        }
        if rule.hasPrefix("@js:") {
            let v = try await js.evaluate(script: String(rule.dropFirst(4)),
                                          source: source, baseUrl: baseUrl, scope: jsContext)
            return v.map { String(describing: $0) }
        }
        if rule.hasPrefix("@regex:") {
            return regexFindFirst(pattern: String(rule.dropFirst(7)), in: source)
        }
        return try css.selectString(rule: rule, source: source, baseUrl: baseUrl)
    }

    // MARK: - 链式 ## 正则

    /// "rule##regex1##regex2"  →  ("rule", ["regex1", "regex2"])
    private func splitRegexChain(_ rule: String) -> (head: String, regexes: [String]) {
        let parts = rule.components(separatedBy: "##")
        guard parts.count > 1 else { return (rule, []) }
        return (parts[0], Array(parts.dropFirst()))
    }

    private func applyRegexChain(_ regexes: [String], to inputs: [String]) -> [String] {
        if regexes.isEmpty { return inputs }
        var current = inputs
        for r in regexes {
            current = current.compactMap { regexFindFirst(pattern: r, in: $0) }
        }
        return current
    }

    /// 万象书屋: 把 "https://x.com/detail/{{$.articleid}}/{{$.lang}}" 中的 mustache JSONPath
    /// 用 source (JSON 字符串) 解出来填回去.
    private func expandJsonMustache(template: String, source: String) throws -> String {
        // 用正则抓所有 {{...}} 占位符
        let pattern = #"\{\{([^}]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }
        let nsstr = template as NSString
        let matches = regex.matches(in: template, range: NSRange(0..<nsstr.length))
        var result = template
        for m in matches.reversed() {
            let inner = nsstr.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            var value: String? = nil
            if inner.hasPrefix("$.") || inner.hasPrefix("$..") {
                value = try? json.selectString(rule: inner, source: source, baseUrl: nil)
            }
            if let v = value {
                result = (result as NSString).replacingCharacters(in: m.range, with: v)
            }
        }
        return result
    }

    private func regexFindFirst(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let nsstr = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(0..<nsstr.length)) else { return nil }
        // 优先返第一个 capture group, 没 group 则返整体
        if m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound {
            return nsstr.substring(with: m.range(at: 1))
        }
        return nsstr.substring(with: m.range)
    }

    private func regexFindAll(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsstr = text as NSString
        return regex.matches(in: text, range: NSRange(0..<nsstr.length)).compactMap { m in
            if m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound {
                return nsstr.substring(with: m.range(at: 1))
            }
            return nsstr.substring(with: m.range)
        }
    }
}
