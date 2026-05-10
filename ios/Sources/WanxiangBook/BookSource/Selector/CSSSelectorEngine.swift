//
//  CSSSelectorEngine.swift
//  万象书屋 iOS · CSS 选择器引擎 (基于 SwiftSoup)
//
//  跟 Android jsoup 行为对齐:
//   - 标准 CSS3 选择器 ✓
//   - jsoup 扩展: `:contains(text)`, `:matches(regex)`, `:has(selector)`, `:eq(n)`, `:gt(n)`, `:lt(n)`
//   - 属性提取: `selector@attr`, `selector@text`, `selector@html`, `selector@ownText`
//   - 多重: `selector1@attr1@attr2` (链式提取)
//   - Legado 列表索引 (对齐 AnalyzeByJSoup.ElementsSingle):
//       · 尾部 `[]` : `[i]`, `[a,b]`, `[start:end:step]`, `[!…]` 排除
//       · 阅读老写法: `sel.i.j`, `sel!i`, `tag.-1:5:2` 等 (`:` 多段索引)
//

import Foundation
import SwiftSoup

// MARK: - Legado index parse (mirror AnalyzeByJSoup.findIndexSet)

private enum LegadoBracketPiece {
    case single(Int)
    case range(start: Int?, end: Int?, step: Int)
}

private struct LegadoIndexParse {
    /// Kotlin AnalyzeByJSoup.ElementsSingle.split 默认 '.', 仅在解析失败 (即整段不像索引) 时才覆盖为 ' '
    var split: Character = "."
    var beforeRule: String = ""
    var indexDefault: [Int] = []
    var indexesBracket: [LegadoBracketPiece] = []
    /// 是否解析到了索引信息 (用来决定要不要 apply 筛选)
    var hasIndex: Bool { !indexDefault.isEmpty || !indexesBracket.isEmpty }
}

public struct CSSSelectorEngine: SelectorEngine {

    public init() {}

    public func selectList(rule: String, source: String, baseUrl: String?) throws -> [String] {
        let doc: Document
        do {
            doc = try SwiftSoup.parse(source, baseUrl ?? "")
        } catch {
            throw SelectorError.parseFailed("SwiftSoup parse: \(error)")
        }

        let (selector, extractors) = parseRule(rule)
        let idx = legadoFindIndexSet(selector)
        let cssRoot = idx.beforeRule
        let (mergedSelector, finalExtractors) = mergeSubSelectors(selector: cssRoot, extractors: extractors)

        let allElements: [Element]
        if mergedSelector.isEmpty || mergedSelector == "children" {
            allElements = doc.body()?.children().array() ?? []
        } else {
            allElements = (try? doc.select(mergedSelector).array()) ?? []
        }
        let elements = applyLegadoIndexFilter(parsed: idx, elements: allElements)

        var out: [String] = []
        out.reserveCapacity(elements.count)
        for el in elements {
            // 没有 extractor → 默认输出元素 outerHTML (后续选择器可继续在子树查)
            if finalExtractors.isEmpty {
                if let h = try? el.outerHtml() { out.append(h) }
                continue
            }
            if let v = applyExtractors(finalExtractors, to: el, baseUrl: baseUrl) {
                out.append(v)
            }
        }
        return out
    }

    public func selectString(rule: String, source: String, baseUrl: String?) throws -> String? {
        let doc: Document
        do {
            doc = try SwiftSoup.parse(source, baseUrl ?? "")
        } catch {
            throw SelectorError.parseFailed("SwiftSoup parse: \(error)")
        }

        let (selector, extractors) = parseRule(rule)
        let idx = legadoFindIndexSet(selector)
        let cssRoot = idx.beforeRule
        let (mergedSelector, finalExtractors) = mergeSubSelectors(selector: cssRoot, extractors: extractors)
        let allElements: [Element]
        if mergedSelector.isEmpty || mergedSelector == "children" {
            allElements = doc.body()?.children().array() ?? []
        } else {
            allElements = (try? doc.select(mergedSelector).array()) ?? []
        }
        let narrowed = applyLegadoIndexFilter(parsed: idx, elements: allElements)
        guard !narrowed.isEmpty else { return nil }
        if finalExtractors.isEmpty {
            return try? narrowed.first?.text()
        }
        // 万象书屋 (P0 fix): legado `a@title` 等属性提取
        for el in narrowed {
            if let v = applyExtractors(finalExtractors, to: el, baseUrl: baseUrl), !v.isEmpty {
                return v
            }
        }
        return nil
    }

    /// 对齐 Android `AnalyzeByJSoup.ElementsSingle.findIndexSet(rule)`
    private func legadoFindIndexSet(_ rule: String) -> LegadoIndexParse {
        var p = LegadoIndexParse()
        let rus = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rus.isEmpty else { return p }

        let chars = Array(rus)
        var curMinus = false
        var l = ""
        var curList: [Int?] = []

        let head = (chars.last == "]")

        if head {
            // Kotlin: var len = length; len-- 跳过 ']'; while (len-- >= 0) { rl = rus[len] }
            // 等价: len 先指向 ']', 每轮先 len -= 1 再读 chars[len]
            var len = chars.count - 1
            while len > 0 {
                len -= 1
                var rl = chars[len]
                if rl == " " { continue }
                if rl >= "0", rl <= "9" {
                    l = String(rl) + l
                    continue
                }
                if rl == "-" {
                    curMinus = true
                    continue
                }

                let curInt: Int? = {
                    if l.isEmpty { return nil }
                    guard let v = Int(l) else { return nil }
                    return curMinus ? -v : v
                }()

                if rl == ":" {
                    curList.append(curInt)
                    l = ""
                    curMinus = false
                    continue
                }

                if curList.isEmpty {
                    if curInt == nil { break }
                    p.indexesBracket.append(.single(curInt!))
                } else {
                    let endX = curList.last!
                    let stepHole: Int? = curList.count == 2 ? curList[0] : nil
                    let stepVal = stepHole ?? 1
                    p.indexesBracket.append(.range(start: curInt, end: endX, step: stepVal))
                    curList.removeAll(keepingCapacity: true)
                }

                if rl == "!" {
                    p.split = "!"
                    repeat {
                        len -= 1
                        if len < 0 { break }
                        rl = chars[len]
                    } while rl == " "
                }

                if rl == "[" {
                    p.beforeRule = String(chars[0..<len])
                    return p
                }

                if rl != "," { break }

                l = ""
                curMinus = false
            }
        } else {
            // Kotlin: len = length; while (len-- >= 0)
            var len = chars.count
            while len > 0 {
                len -= 1
                let rl = chars[len]
                if rl == " " { continue }
                if rl >= "0", rl <= "9" {
                    l = String(rl) + l
                    continue
                }
                if rl == "-" {
                    curMinus = true
                    continue
                }

                if rl == "!" || rl == "." || rl == ":" {
                    guard !l.isEmpty, let v = Int(l) else { break }
                    let num = curMinus ? -v : v
                    p.indexDefault.append(num)
                    if rl != ":" {
                        p.split = rl
                        p.beforeRule = String(chars[0..<len])
                        return p
                    }
                    l = ""
                    curMinus = false
                    continue
                }
                break
            }
        }

        // 走到这里说明从未在 head/old 模式里 return → 整段不是索引, 还原 default
        p.split = " "
        p.beforeRule = rus
        p.indexDefault.removeAll()
        p.indexesBracket.removeAll()
        return p
    }

    /// 对齐 `getElementsSingle` 里 indexSet + split 筛选
    private func applyLegadoIndexFilter(parsed: LegadoIndexParse, elements: [Element]) -> [Element] {
        // Android: split=' ' 表示「当前段无索引」, 直接返回原列表
        guard parsed.split != " ", parsed.hasIndex else { return elements }
        let len = elements.count
        if len == 0 { return elements }

        var ordered: [Int] = []

        let useBracket = !parsed.indexesBracket.isEmpty
        let lastIx: Int = useBracket ? (parsed.indexesBracket.count - 1) : (parsed.indexDefault.count - 1)
        if lastIx < 0 { return elements }

        if useBracket {
            for ix in stride(from: lastIx, through: 0, by: -1) {
                switch parsed.indexesBracket[ix] {
                case .single(let it):
                    if it >= 0, it < len {
                        legadoAppendUnique(&ordered, it)
                    } else if it < 0, len >= -it {
                        legadoAppendUnique(&ordered, it + len)
                    }
                case .range(let startX, let endX, let stepX):
                    var start = startX ?? 0
                    if start < 0 { start += len }

                    var end = endX ?? (len - 1)
                    if end < 0 { end += len }

                    if (start < 0 && end < 0) || (start >= len && end >= len) {
                        continue
                    }

                    if start >= len { start = len - 1 }
                    else if start < 0 { start = 0 }

                    if end >= len { end = len - 1 }
                    else if end < 0 { end = 0 }

                    if start == end || stepX >= len {
                        legadoAppendUnique(&ordered, start)
                        continue
                    }

                    let step: Int = {
                        if stepX > 0 { return stepX }
                        if -stepX < len { return stepX + len }
                        return 1
                    }()

                    // Kotlin: `start..end step step` 与 `start downTo end step step`
                    // step 永远是正整数, 反向时是 i 减 step (而不是加)
                    let posStep = abs(step) == 0 ? 1 : abs(step)
                    if end > start {
                        var i = start
                        while i <= end {
                            legadoAppendUnique(&ordered, i)
                            i += posStep
                        }
                    } else {
                        var i = start
                        while i >= end {
                            legadoAppendUnique(&ordered, i)
                            i -= posStep
                        }
                    }
                }
            }
        } else {
            for ix in stride(from: lastIx, through: 0, by: -1) {
                let it = parsed.indexDefault[ix]
                if it >= 0, it < len {
                    legadoAppendUnique(&ordered, it)
                } else if it < 0, len >= -it {
                    legadoAppendUnique(&ordered, it + len)
                }
            }
        }

        if parsed.split == "!" {
            let drop = Set(ordered)
            return elements.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }

        return ordered.compactMap { ($0 >= 0 && $0 < len) ? elements[$0] : nil }
    }

    private func legadoAppendUnique(_ arr: inout [Int], _ v: Int) {
        if !arr.contains(v) { arr.append(v) }
    }

    /// 万象书屋 (P0 fix): 合并 legado 嵌套 + 索引语法 + tag.X 关键字
    /// "div@a@href" → ("div a", ["href"])      : a 是 subSelector, href 是属性
    /// "div@a"      → ("div a", [])            : a 是 subSelector, 无属性
    /// "div@text"   → ("div", ["text"])        : text 是属性
    /// "a.0@href"   → ("a:eq(0)", ["href"])    : .0 是索引, jsoup :eq(n)
    /// "a.0"        → ("a:eq(0)", [])
    /// "div@tag.li" → ("div li", [])           : tag.NAME 等价于子 NAME 元素
    /// "div@tag.a@href" → ("div a", ["href"])
    private func mergeSubSelectors(selector: String, extractors: [String]) -> (String, [String]) {
        // 万象书屋: 与 applyExtractors 内 attrKeywords 保持同步
        let attrKeywords: Set<String> = ["text", "textnodes", "owntext",
                                          "html", "innerhtml", "outerhtml", "all",
                                          "tag", "tagname", "href", "src", "data-src", "data-url",
                                          "data-original", "alt", "title", "value", "content"]
        // 万象书屋: 主 selector 翻译 legado class./id. 关键字
        var mergedSelector = applyIndexSugar(translateLegadoKeyword(selector))
        var remaining: [String] = extractors
        while let first = remaining.first {
            let lower = first.lowercased()
            // legado: 允许索引作为 @ 分段后每个部分的首规则,
            // `head@.1@text` / `head@[1]@text` / `head@children[1]@text`
            // 等价于在当前节点 children 上取索引。
            if lower == "children" || lower.hasPrefix("children[") || lower.hasPrefix("children.") || lower.hasPrefix("children!") || lower.hasPrefix("children:") {
                let rest = String(first.dropFirst("children".count))
                mergedSelector += " > " + childIndexSelector(rest)
                remaining.removeFirst()
                continue
            }
            if lower.hasPrefix("[") || lower.hasPrefix(".") || lower.hasPrefix("!") || lower.hasPrefix(":") {
                mergedSelector += " > " + childIndexSelector(first)
                remaining.removeFirst()
                continue
            }
            // legado tag.NAME (含 .cls), class.NAME, id.NAME 都翻译成 CSS 后接
            if lower.hasPrefix("tag.") {
                let sub = String(first.dropFirst(4))
                if !sub.isEmpty {
                    mergedSelector += " " + sub
                    remaining.removeFirst()
                    continue
                }
            }
            if lower.hasPrefix("class.") || lower.hasPrefix("id.") {
                mergedSelector += " " + translateLegadoKeyword(first)
                remaining.removeFirst()
                continue
            }
            if attrKeywords.contains(lower) { break }
            if lower.hasPrefix("data-") { break }
            mergedSelector += " " + applyIndexSugar(first)
            remaining.removeFirst()
        }
        return (mergedSelector, remaining)
    }

    /// 将 `@.1` / `@[1]` / `@children[1]` 这类“子元素索引段”转成 SwiftSoup 可理解的 selector.
    /// 简单选择用 jsoup `:eq(n)` 支持最常见的单 index; 复杂 `[!...]`/range 仍由完整 ElementsSingle 路径处理。
    private func childIndexSelector(_ suffix: String) -> String {
        let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "*" }
        if trimmed.hasPrefix(".") {
            return applyIndexSugar("*" + trimmed)
        }
        if trimmed.hasPrefix("["),
           trimmed.hasSuffix("]") {
            let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(inner) {
                return "*:eq(\(n))"
            }
        }
        return "*" + trimmed
    }

    /// 万象书屋: legado `class.X` / `id.X` / `tag.X` 关键字翻译成标准 CSS
    /// 例: `class.searchresult` → `.searchresult`, `id.main` → `#main`
    /// 万象书屋 (M2.8 fix bug): 支持 `class.foo bar` 多 class 写法 (空格分隔表
    /// "同时具备多个 class"), 翻译成 `.foo.bar`. 例: 肉文小说的
    /// `class.book chapterlist` ⇒ `.book.chapterlist`. 之前只剥 `class.` 前缀,
    /// 留下 `book chapterlist` 当 CSS 跑被解释成"book 内的 chapterlist 后代"导致空.
    private func translateLegadoKeyword(_ s: String) -> String {
        if s.hasPrefix("class.") {
            let inner = String(s.dropFirst(6))
            if inner.contains(" ") {
                let parts = inner.split(separator: " ").filter { !$0.isEmpty }
                return parts.map { "." + $0 }.joined()
            }
            return "." + inner
        }
        if s.hasPrefix("id.") {
            return "#" + String(s.dropFirst(3))
        }
        // 万象书屋 (M2.8 fix bug): 首段 selector 是 `tag.dd` / `tag.a` 等时, 转成
        // jsoup tag selector. 之前只在 extractors 链路里处理, 首段不处理 ⇒ jsoup 收到
        // `tag.dd` 当 class+tag 解析必定 0 命中. 肉文小说 chapterName="tag.dd@text" 复现.
        if s.hasPrefix("tag.") {
            return String(s.dropFirst(4))
        }
        return s
    }

    /// 把 "tag.N" 形式的尾部数字转 jsoup :eq(N)
    private func applyIndexSugar(_ s: String) -> String {
        // 匹配末尾 `.N`, 但要排除 `.foo` (class) 和 `.0.5` (浮点不该出现, 跳过)
        guard let regex = try? NSRegularExpression(pattern: #"\.(\d+)$"#) else { return s }
        let nsstr = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(0..<nsstr.length)) else { return s }
        let n = nsstr.substring(with: m.range(at: 1))
        let head = nsstr.substring(with: NSRange(location: 0, length: m.range.location))
        // 万象书屋: 如果 head 为空 (比如 ".0") 说明没 tag, 给 * 兜底
        let final = head.isEmpty ? "*" : head
        return final + ":eq(\(n))"
    }

    // MARK: - 规则解析

    /// "div.book@a@href" → ("div.book", ["a", "href"])
    /// "div.book"        → ("div.book", [])
    /// bug #15 fix: legado `@@` 是"强制 css selector"标记 (非分隔符), 别拆乱
    private func parseRule(_ rule: String) -> (selector: String, extractors: [String]) {
        // 把 `@@` 临时占位, 避免被 split 拆开
        let placeholder = "\u{1F}AT_AT\u{1F}"
        let escaped = rule.replacingOccurrences(of: "@@", with: placeholder)
        let parts = escaped.split(separator: "@", omittingEmptySubsequences: false)
        guard let first = parts.first else { return (rule, []) }
        let restore = { (s: String) -> String in
            s.replacingOccurrences(of: placeholder, with: "@@")
        }
        let extractors = parts.dropFirst()
            .map { restore(String($0)) }
            .filter { !$0.isEmpty }
        return (restore(String(first)), extractors)
    }

    /// 应用 ["a", "href"] 链:
    /// 1. 先在当前 el 内找 "a" 元素 (CSS 子选择器)
    /// 2. 然后取其 "href" 属性
    /// 特殊属性:
    ///   - text  / textNodes: el.text()
    ///   - html  / outerHtml: el.outerHtml()
    ///   - ownText: 仅自身文本 (不含子)
    ///   - href / src 等: el.attr(...)
    private func applyExtractors(_ extractors: [String], to element: Element, baseUrl: String?) -> String? {
        let attrKeywords: Set<String> = ["text", "textnodes", "owntext", "html", "innerhtml",
                                          "outerhtml", "all", "tagname", "href", "src",
                                          "data-src", "data-url", "data-original",
                                          "alt", "title", "value", "content"]
        var current: Element? = element
        for (i, ext) in extractors.enumerated() {
            guard let el = current else { return nil }
            let isLast = (i == extractors.count - 1)
            let lower = ext.lowercased()
            let isAttr = attrKeywords.contains(lower) || lower.hasPrefix("data-")
            // 万象书屋: 末尾若是属性关键字, 必须按属性取, 取不到就明确返 nil
            // (绝不 fallback 到 .text(), 否则 `a@title` 没 title 时会错给 text)
            if isLast, isAttr {
                return extractAttribute(ext, from: el, baseUrl: baseUrl)
            }
            if let next = try? el.select(ext).first() {
                current = next
            } else if !isLast {
                return nil
            }
        }
        return try? current?.text()
    }

    private func extractAttribute(_ name: String, from el: Element, baseUrl: String?) -> String? {
        switch name.lowercased() {
        case "text":
            return try? el.text()
        case "textnodes":
            // 万象书屋: 跟 Android Element.textNodes() 对齐 — 直接子文本节点 join "\n"
            // SwiftSoup: el.textNodes() 返回 [TextNode]
            let nodes = el.textNodes()
            let lines = nodes.compactMap { tn -> String? in
                let t = tn.text().trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        case "owntext":
            return try? el.ownText()
        case "html", "innerhtml":
            // 万象书屋: legado html extractor 会先 remove script/style
            do {
                let cloned = el.copy() as? Element
                _ = try? cloned?.select("script").remove()
                _ = try? cloned?.select("style").remove()
                return try cloned?.html() ?? el.html()
            } catch {
                return try? el.html()
            }
        case "outerhtml":
            return try? el.outerHtml()
        case "all":
            // 万象书屋: legado all 关键字 = 当前 element 的 outerHtml
            return try? el.outerHtml()
        case "tag", "tagname":
            return el.tagName()
        default:
            // 普通 HTML 属性: href / src / data-xxx 等
            // 万象书屋: href/src 用 absUrl 拼绝对 URL (需要 baseUrl)
            let lower = name.lowercased()
            if ["href", "src", "data-src", "data-url", "data-original"].contains(lower) {
                if let abs = try? el.absUrl(name), !abs.isEmpty { return abs }
            }
            return try? el.attr(name).isEmpty == false ? el.attr(name) : nil
        }
    }
}
