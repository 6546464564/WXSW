//
//  LegadoRuleEngine.swift
//  万象书屋 iOS · legado 完整规则引擎
//
//  对应 Android: io.legado.app.model.analyzeRule.AnalyzeRule + RuleAnalyzer
//
//  对一段 ruleStr 的完整流程:
//   1. RuleParser.split: 按 `&&` `||` `%%` 切成 [SourceRule],
//      但 [...] (...) 内部出现的 && / || 不参与切 (平衡组保护)
//   2. 每个 SourceRule 推断 Mode:
//      - 显式前缀: @CSS: / @XPath: / @Json: / @js: / @http: / @@
//      - JSON content / `$.` / `$[`     → Json
//      - `/` 开头                       → XPath
//      - 默认                           → CSS (jsoup)
//      - 含 `<js>...</js>` 内嵌         → 触发 Mode.Regex (字符串模板)
//      - 含 `{{...}}` `@get:key`        → 触发 Mode.Regex
//   3. makeUpRule: 把 {{...}} / @get / $1-$9 占位符按当前 result 解出来填回 rule
//   4. 主体 select: 在 result 上跑 selector → 新 result
//   5. ##regex##replace[##]: 截取 / 替换 (3 ## = first only)
//   6. 把当前 result 喂给下一个 SourceRule (链式 reduce)
//
//  分流操作符:
//   - `&&` 串联 (next 在 prev 结果上继续)
//   - `||` 短路 (prev 拿到非空就停)
//   - `%%` 交错合并 (Celeter 文档: 多列表按 index 拉链 — 先各列表第1项, 再各列表第2项…)
//   - 列表前缀 `-` 倒置整段结果 (yckceo「获取列表的最前面加上负号」)

import Foundation

// MARK: - Mode

public enum LegadoMode: String, Sendable {
    case css       // 默认 jsoup
    case xpath
    case json
    case js
    case regex
    case raw       // 纯文本, 直接返回 rule 内容
}

// MARK: - SourceRule

/// 一段已切分好的子规则
public struct LegadoSourceRule: Sendable {
    public var mode: LegadoMode
    public var rule: String
    public var replaceRegex: String = ""
    public var replacement: String = ""
    public var replaceFirst: Bool = false
    public var isAllInOneRegex: Bool = false
    /// 内嵌 {{...}} / @get:xxx / $0..$9 占位符 (只在 Mode.Regex 下生效)
    public var hasPlaceholder: Bool = false
}

// MARK: - 上下文

public struct LegadoContext: Sendable {
    public var baseUrl: String?
    public var source: String         // 当前源的 raw response (供 @js: 用)
    public var key: String? = nil     // 搜索关键词
    public var page: Int = 1
    public var book: [String: String] = [:]   // book 字段 (book.name 等)
    /// 万象书屋: 当前 BookSource (注 source/cookie/host/jsLib)
    public var bookSource: BookSource? = nil

    public init(baseUrl: String? = nil, source: String = "", key: String? = nil, page: Int = 1,
                bookSource: BookSource? = nil) {
        self.baseUrl = baseUrl
        self.source = source
        self.key = key
        self.page = page
        self.bookSource = bookSource
    }
}

// MARK: - 引擎

public actor LegadoRuleEngine {

    public static let shared = LegadoRuleEngine()

    private let css = CSSSelectorEngine()
    private let xpath = XPathSelectorEngine()
    private let jsonp = JSONPathEngine()
    private let js = JSEngine()

    /// 万象书屋: legado `@put:{key:rule}` 的 KV 存储, 同一个 source 跨 search/toc/content 共享
    /// 维度: sourceKey (= bookSourceUrl 或 "default") → { putKey → value }
    /// 调用时机:
    ///   - search 阶段对每个候选 book 跑规则时, @put:{bid:".//*[@bid]"} 把 bid 写入
    ///   - 后续 bookInfo / toc / content 阶段, @get:{bid} 或 @get:bid 取出
    /// 跟 Android `AnalyzeRule.putMap`+`source.variable` 等价
    private var putStore: [String: [String: String]] = [:]

    public init() {}

    /// 暴露给外部: 手动注入 / 清空 (调试或换源时用)
    public func resetPutStore(sourceKey: String? = nil) {
        if let k = sourceKey {
            putStore[k] = nil
        } else {
            putStore.removeAll()
        }
    }

    public func putValue(_ value: String, forKey key: String, source: String) {
        var bag = putStore[source] ?? [:]
        bag[key] = value
        putStore[source] = bag
    }

    public func getValue(forKey key: String, source: String) -> String? {
        putStore[source]?[key]
    }

    /// 取 source bag, 内部用
    private func putBag(for ctx: LegadoContext) -> [String: String] {
        let key = ctx.bookSource?.bookSourceUrl ?? "default"
        return putStore[key] ?? [:]
    }
    private func setPut(_ k: String, _ v: String, ctx: LegadoContext) {
        let key = ctx.bookSource?.bookSourceUrl ?? "default"
        var bag = putStore[key] ?? [:]
        bag[k] = v
        putStore[key] = bag
    }

    // MARK: - 公共 API

    /// 取列表 (返多条结果)
    /// 万象书屋: 顶层 `||` = fallback (前面有结果就停), `&&` = 串联 (后面在前面结果上继续)
    public func selectList(rule: String, source: String, baseUrl: String? = nil,
                           ctx: LegadoContext? = nil) async -> [String] {
        let context = ctx ?? LegadoContext(baseUrl: baseUrl, source: source)
        return await evalToList(ruleStr: rule, on: source, ctx: context)
    }

    /// 取单值
    public func selectString(rule: String, source: String, baseUrl: String? = nil,
                             ctx: LegadoContext? = nil) async -> String? {
        let context = ctx ?? LegadoContext(baseUrl: baseUrl, source: source)
        let list = await evalToList(ruleStr: rule, on: source, ctx: context)
        return list.first?.isEmpty == true ? nil : list.first
    }

    // MARK: - 两层切: 先 || (fallback) 再 && (串联)

    /// bug #13 fix: 限制递归深度防恶意/极端书源栈溢出
    private static let maxRecursionDepth = 16

    private func evalToList(ruleStr: String, on input: Any, ctx: LegadoContext, depth: Int = 0) async -> [String] {
        if depth > Self.maxRecursionDepth {
            print("[LegadoRuleEngine] WARNING: rule recursion depth exceeded (\(depth)), rule: \(String(ruleStr.prefix(80)))")
            return []
        }
        // 万象书屋: legado 复合语法 — `<js>...code...</js>\nselector`
        // "先跑 JS,把它返回值当作新 source,然后用后面 selector 在新 source 上选"
        if let (jsCode, restRule) = stripLeadingJSBlock(ruleStr), !restRule.isEmpty {
            // 万象书屋 (P0): 反爬模式特化 — JS 含 startBrowserAwait 表示需要真浏览器跑反爬
            // 同步调 native 拿不到结果 (JSCore 不支持 Promise), 直接绕过 JS 调 BrowserBridge
            let lowerJs = jsCode.lowercased()
            if lowerJs.contains("startbrowserawait") || lowerJs.contains("startbrowser") {
                let kw = extractAwaitKeyword(from: jsCode) ?? "html"
                let url = extractAwaitURL(from: jsCode) ?? (ctx.baseUrl ?? "")
                let bridge = await BrowserBridgeRegistry.shared.get()
                if ProcessInfo.processInfo.environment["WX_DEBUG_BRIDGE"] != nil {
                    print("[BrowserBridge] 反爬: url=\(url) keyword=\(kw)")
                }
                if !url.isEmpty,
                   let newHtml = await bridge.loadAndWait(url: url, expectedKeyword: kw, timeout: 30) {
                    var newCtx = ctx
                    newCtx.source = newHtml
                    return await evalToList(ruleStr: restRule, on: newHtml, ctx: newCtx, depth: depth + 1)
                }
                return await evalToList(ruleStr: restRule, on: input, ctx: ctx, depth: depth + 1)
            }

            // 普通 JS 块: 直接跑 JS, 把返回值当新 source
            let scope = JSContextScope()
            scope.baseUrl = ctx.baseUrl
            scope.src = ctx.source
            scope.result = stringify(input)
            scope.key = ctx.key
            scope.page = ctx.page
            scope.bookSource = ctx.bookSource
            let newSource: String
            do {
                let v = try await js.evaluate(script: jsCode, source: ctx.source,
                                               baseUrl: ctx.baseUrl, scope: scope)
                newSource = stringifyOptional(v)
            } catch {
                newSource = stringify(input)
            }
            var newCtx = ctx
            newCtx.source = newSource
            return await evalToList(ruleStr: restRule, on: newSource, ctx: newCtx, depth: depth + 1)
        }

        let orBranches = LegadoRuleParser.splitTop(ruleStr, separators: ["||"])
        for branch in orBranches {
            let merged = await evalZipOrAnd(String(branch), on: input, ctx: ctx)
            if !merged.isEmpty && !(merged.count == 1 && merged[0].isEmpty) {
                return merged
            }
        }
        return []
    }

    /// `%%` 拉链 + `&&` 串联 + 可选前缀 `-` 列表倒置
    /// 对齐 yckceo.com 书源说明 & Android AnalyzeByJSoup `%%` 分支
    private func evalZipOrAnd(_ ruleStr: String, on input: Any, ctx: LegadoContext) async -> [String] {
        var rs = ruleStr.trimmingCharacters(in: .whitespacesAndNewlines)
        var invertList = false
        if rs.hasPrefix("-") {
            invertList = true
            rs = String(rs.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let zipSegs = LegadoRuleParser.splitTop(rs, separators: ["%%"])
        let out: [String]
        if zipSegs.count == 1 {
            out = await evalAnd(String(zipSegs[0]), on: input, ctx: ctx)
        } else {
            var lists: [[String]] = []
            for seg in zipSegs {
                lists.append(await evalAnd(String(seg), on: input, ctx: ctx))
            }
            out = Self.zipLegadoLists(lists)
        }
        return invertList ? Array(out.reversed()) : out
    }

    /// Android: `for (i in results[0].indices) { for (temp in results) { if (i < temp.size) add temp[i] } }`
    private nonisolated static func zipLegadoLists(_ lists: [[String]]) -> [String] {
        guard let first = lists.first, !first.isEmpty else { return [] }
        var result: [String] = []
        let rowCount = first.count
        for i in 0..<rowCount {
            for list in lists where i < list.count {
                result.append(list[i])
            }
        }
        return result
    }

    private func extractAwaitURL(from js: String) -> String? {
        // 1. 字符串字面量
        if let r = js.range(of: #"startBrowserAwait\s*\(\s*['""]([^'"")\s]+)['""]"#, options: .regularExpression) {
            let m = String(js[r])
            if let inner = m.range(of: #"['""]([^'""]+)['""]"#, options: .regularExpression) {
                let s = String(m[inner]).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                return s
            }
        }
        return nil
    }

    private func extractAwaitKeyword(from js: String) -> String? {
        // startBrowserAwait(url, 'keyword')
        if let r = js.range(of: #"startBrowserAwait\s*\([^,]+,\s*['""]([^'"")]+)['""]"#, options: .regularExpression) {
            let m = String(js[r])
            // 第二个引号串
            let pattern = try? NSRegularExpression(pattern: #"['""]([^'""]+)['""]"#)
            if let pattern {
                let nsstr = m as NSString
                let matches = pattern.matches(in: m, range: NSRange(0..<nsstr.length))
                if matches.count >= 2 {
                    return nsstr.substring(with: matches[1].range(at: 1))
                }
            }
        }
        return nil
    }

    /// 检测 ruleStr 是否以 `<js>...</js>` 开头. 返回 (jsCode, 后续 rule).
    /// 若前面纯 JS 块,后面还有内容,就是 legado 的"JS 替换 source 模式".
    private func stripLeadingJSBlock(_ ruleStr: String) -> (String, String)? {
        let trimmed = ruleStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<js>") else { return nil }
        guard let closeRange = trimmed.range(of: "</js>") else { return nil }
        let jsCode = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<closeRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = String(trimmed[closeRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (jsCode, rest)
    }

    /// 处理 `&&` 串联: 每段在前一段的 result 上继续 select
    private func evalAnd(_ ruleStr: String, on input: Any, ctx: LegadoContext) async -> [String] {
        let andSegs = LegadoRuleParser.splitTop(ruleStr, separators: ["&&"])
        if andSegs.count == 1 {
            let sr = LegadoRuleParser.parseSingle(String(andSegs[0]))
            let r = await applyRule(sr, on: input, ctx: ctx, listMode: true)
            return toStringList(r)
        }
        // 多段串联: 逐段在 result 上 reduce
        var current: [String] = [stringify(input)]
        for seg in andSegs {
            let sr = LegadoRuleParser.parseSingle(String(seg))
            var nextResults: [String] = []
            for src in current {
                let r = await applyRule(sr, on: src, ctx: ctx, listMode: true)
                let list = toStringList(r)
                nextResults.append(contentsOf: list)
            }
            current = nextResults
            if current.isEmpty { break }
        }
        return current
    }

    /// 渲染 URL 模板 (含 {{key}} {{page}} <js>...</js> 跨 result 占位符)
    public func renderURL(template: String, baseUrl: String? = nil,
                          key: String? = nil, page: Int = 1,
                          source: String = "") async -> String {
        let ctx = LegadoContext(baseUrl: baseUrl, source: source, key: key, page: page)
        return await expandTemplate(template, on: source, ctx: ctx)
    }

    // MARK: - 核心 apply

    private func applyRule(_ rule: LegadoSourceRule, on input: Any, ctx: LegadoContext, listMode: Bool) async -> Any {
        // 1. 替换 {{...}} / @get / $1-$9 占位符 (makeUpRule)
        let resolvedRule = await expandTemplate(rule.rule, on: input, ctx: ctx)
        let mode = rule.mode

        // 2. 把 input 转成 string (selector 都吃 string)
        let srcStr: String = stringify(input)

        // 3. 主体 select
        var midResult: [String]
        switch mode {
        case .raw:
            midResult = [resolvedRule]
        case .js:
            // @js: 真跑, 注入 result/source/baseUrl/key
            let r = await runJS(resolvedRule, result: input, ctx: ctx)
            midResult = toStringList(r)
        case .css:
            if listMode {
                midResult = (try? css.selectList(rule: resolvedRule, source: srcStr, baseUrl: ctx.baseUrl)) ?? []
            } else {
                midResult = [(try? css.selectString(rule: resolvedRule, source: srcStr, baseUrl: ctx.baseUrl)) ?? ""].filter { !$0.isEmpty }
            }
            // 万象书屋: source 看起来是 JSON 时, 默认 CSS 跑空就 fallback 到 JsonPath
            // (legado bookList JS 返回数组后, 元素是 JSON 串, ruleSearch.name="n" 等是隐式 JsonPath 键)
            // 还有 legado 缩写: `[*]` 等价 `$[*]`, `[0]` 等价 `$[0]`
            if midResult.isEmpty, looksLikeJSON(srcStr), !resolvedRule.hasPrefix("@") {
                let jpathRule: String
                if resolvedRule.hasPrefix("$") {
                    jpathRule = resolvedRule
                } else if resolvedRule.hasPrefix("[") {
                    jpathRule = "$" + resolvedRule
                } else {
                    jpathRule = "$." + resolvedRule
                }
                if listMode {
                    midResult = (try? jsonp.selectList(rule: jpathRule, source: srcStr, baseUrl: ctx.baseUrl)) ?? []
                } else {
                    midResult = [(try? jsonp.selectString(rule: jpathRule, source: srcStr, baseUrl: ctx.baseUrl)) ?? ""].filter { !$0.isEmpty }
                }
            }
        case .xpath:
            if listMode {
                midResult = (try? xpath.selectList(rule: resolvedRule, source: srcStr, baseUrl: ctx.baseUrl)) ?? []
            } else {
                midResult = [(try? xpath.selectString(rule: resolvedRule, source: srcStr, baseUrl: ctx.baseUrl)) ?? ""].filter { !$0.isEmpty }
            }
        case .json:
            if listMode {
                midResult = (try? jsonp.selectList(rule: resolvedRule, source: srcStr, baseUrl: ctx.baseUrl)) ?? []
            } else {
                midResult = [(try? jsonp.selectString(rule: resolvedRule, source: srcStr, baseUrl: ctx.baseUrl)) ?? ""].filter { !$0.isEmpty }
            }
        case .regex:
            // 两种 regex:
            // 1) AllInOne 列表正则 (`:pattern` 已在 parser 里去掉冒号): 在当前 source 上 findAll,
            //    每个 match 产出一个 JSON 对象 {"$0":full,"$1":group1...}, 后续字段规则 `$1`/`$2`
            //    会通过 JSON fallback 取值。
            // 2) 普通模板 regex: 没匹配到时保持旧行为, 把 expanded rule 当字符串返回。
            if rule.isAllInOneRegex {
                let matches = regexAllInOne(pattern: resolvedRule, source: srcStr)
                midResult = matches
            } else {
                // Mode.Regex 只是占位符化的字符串, expandTemplate 后 resolvedRule 就是结果
                midResult = [resolvedRule]
            }
        }

        // 4. ##regex##replace[##]
        // 万象书屋: 走 SafeRegex 做 ReDoS 保护 (LRU 缓存 + 长输入 timeout)
        if !rule.replaceRegex.isEmpty {
            var newResult: [String] = []
            newResult.reserveCapacity(midResult.count)
            for v in midResult {
                newResult.append(await applyReplaceSafe(value: v, rule: rule))
            }
            midResult = newResult
        }

        // 5. listMode=false 只取第一条
        if !listMode { return midResult.first ?? "" }
        return midResult
    }

    // MARK: - JS 真跑

    private func runJS(_ script: String, result: Any, ctx: LegadoContext) async -> Any? {
        let scope = JSContextScope()
        scope.baseUrl = ctx.baseUrl
        scope.src = ctx.source
        scope.result = stringify(result)
        scope.key = ctx.key
        scope.page = ctx.page
        scope.bookSource = ctx.bookSource
        // 万象书屋 (M2.8 fix bug): legado @js: 块经常引用 book.name / book.author / book.kind
        // (蓝海搜书 ruleBookInfo.tocUrl 换源 JS 等). 之前 ctx.book 没桥接 ⇒ JS 报
        // "null is not an object (evaluating 'book.name')" 整段 fail.
        if !ctx.book.isEmpty {
            scope.book = ctx.book
        }
        do {
            let v = try await js.evaluate(script: script, source: ctx.source,
                                           baseUrl: ctx.baseUrl, scope: scope)
            return v
        } catch {
            if ProcessInfo.processInfo.environment["WX_DEBUG_RULE"] != nil {
                let errStr = String(describing: error).replacingOccurrences(of: "\n", with: " ")
                print("[runJS.fail] \(script.prefix(60)) | err=\(errStr)")
                if ProcessInfo.processInfo.environment["WX_DEBUG_RULE_VERBOSE"] != nil {
                    print("[runJS.fail.full] (\(script.count) chars):\n\(script)\n---END---")
                }
            }
            return nil
        }
    }

    // MARK: - 模板展开 ({{}} / @get / <js>)

    /// 展开 rule 字符串里所有的 placeholder. 支持:
    /// - `{{$.field}}`         → 在 input (JSON) 上跑 JSONPath
    /// - `{{//div/text()}}`    → XPath
    /// - `{{div.title@text}}`  → CSS (默认)
    /// - `{{js code}}`         → 跑 JS
    /// - `<js>js code</js>`    → 跑 JS (legado URL 里常用)
    /// - `@get:key`            → 取上下文 book[key]
    /// - `{{key}}` `{{page}}`  → URL 模板搜索词/页
    private func expandTemplate(_ template: String, on input: Any, ctx: LegadoContext) async -> String {
        var s = template

        // 0. 万象书屋: legado URL 模板 `<X,Y>` 操作符 (Celeter 文档明示)
        //    page == 1 时取 X (常为空), page > 1 时取 Y
        //    例: `<,{{page}}>` → 第 1 页变空串, 后续页变 "2", "3"...
        s = expandPagePicker(s, page: ctx.page)

        // 1. 简单变量
        if let key = ctx.key {
            let enc = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            s = s.replacingOccurrences(of: "{{key}}", with: enc)
            s = s.replacingOccurrences(of: "{{searchKey}}", with: enc)
        }
        s = s.replacingOccurrences(of: "{{page}}", with: String(ctx.page))
        for (k, v) in ctx.book {
            s = s.replacingOccurrences(of: "{{book.\(k)}}", with: v)
            s = s.replacingOccurrences(of: "{{$.book.\(k)}}", with: v)
        }

        // 2. <js>...</js>  内联 JS  (legado 大量出现在 searchUrl / bookUrl 里)
        s = await replaceInlineJS(s, on: input, ctx: ctx)

        // 3. {{...}}  内嵌规则 / JS
        s = await replaceMustache(s, on: input, ctx: ctx)

        // 4. @get:key  (优先 ctx.book, 没有再查 putStore)
        if s.contains("@get:") {
            let regex = try? NSRegularExpression(pattern: #"@get:\{?(\w+)\}?"#)
            if let regex = regex {
                let nsstr = s as NSString
                let matches = regex.matches(in: s, range: NSRange(0..<nsstr.length)).reversed()
                let bag = putBag(for: ctx)
                for m in matches {
                    let key = nsstr.substring(with: m.range(at: 1))
                    let v = ctx.book[key] ?? bag[key] ?? ""
                    s = (s as NSString).replacingCharacters(in: m.range, with: v)
                }
            }
        }

        // 5. @put:{key:rule} — 万象书屋: 解析 rule, 在当前 source 上跑出值, 写入 putStore[sourceUrl][key]
        //    legado: search 用 @put 存 ID, bookInfo/toc 用 @get 取
        //    对齐 Android `AnalyzeRule.putRule` (写入 source.variable + putMap)
        if s.contains("@put:") {
            // 支持嵌套大括号的 rule 值: `@put:{bid: ".//*[@data-bid]/@data-bid"}`
            // 简单办法: 找 `@put:{...}` 的最外配对 `}`
            s = await applyPutDirectives(s, on: input, ctx: ctx)
        }
        return s
    }

    /// 万象书屋: legado `<X,Y>` 模板 — 第 1 页取 X (常为空), 第 2 页起取 Y
    /// 例: `https://x.com/list<,?p={{page}}>` → page1: "https://x.com/list"  page2: "https://x.com/list?p=2"
    /// 限制: X / Y 内不能含 `<` / `>` / `,` 字面量 (跟 Android 一致, 简单非贪婪扫描)
    nonisolated private func expandPagePicker(_ s: String, page: Int) -> String {
        guard s.contains("<"), s.contains(">"), s.contains(",") else { return s }
        guard let regex = try? NSRegularExpression(pattern: #"<([^<>,]*),([^<>]*)>"#) else { return s }
        let nsstr = s as NSString
        let matches = regex.matches(in: s, range: NSRange(0..<nsstr.length)).reversed()
        var out = s
        for m in matches {
            let x = nsstr.substring(with: m.range(at: 1))
            let y = nsstr.substring(with: m.range(at: 2))
            let pick = page <= 1 ? x : y
            out = (out as NSString).replacingCharacters(in: m.range, with: pick)
        }
        return out
    }

    /// 万象书屋: 提取所有 `@put:{...}`, 对每段 KV `key:rule`:
    ///   1. 在当前 input/source 上 evaluate rule (复用 selectString)
    ///   2. 写入 putStore (sourceUrl 维度)
    ///   3. 把整段 `@put:{...}` 从模板移除 (legado 行为: @put 不在 URL/规则里留痕)
    private func applyPutDirectives(_ s: String, on input: Any, ctx: LegadoContext) async -> String {
        var out = s
        while let openRange = out.range(of: "@put:{") {
            // 找配对的 }, 支持嵌套 (rule 里可能含 [{ }])
            var depth = 1
            var idx = openRange.upperBound
            var closeIdx: String.Index? = nil
            while idx < out.endIndex {
                let c = out[idx]
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { closeIdx = idx; break }
                }
                idx = out.index(after: idx)
            }
            guard let close = closeIdx else { break }  // 不闭合放弃
            let inner = String(out[openRange.upperBound..<close])
            // inner 形如 `bid: ".//*[@data-bid]"` 或 `bid:.//*[@data-bid]` 或多个 `a:r1, b:r2`
            for pair in splitPutPairs(inner) {
                guard let colon = pair.firstIndex(of: ":") else { continue }
                let key = String(pair[..<colon]).trimmingCharacters(in: .whitespaces)
                var ruleStr = String(pair[pair.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                // 去掉外层引号 (legado @put 的 rule 通常加引号但不强制)
                if (ruleStr.hasPrefix("\"") && ruleStr.hasSuffix("\"")) ||
                   (ruleStr.hasPrefix("'") && ruleStr.hasSuffix("'")) {
                    ruleStr = String(ruleStr.dropFirst().dropLast())
                }
                guard !key.isEmpty, !ruleStr.isEmpty else { continue }
                let v = (await selectString(rule: ruleStr, source: stringify(input),
                                             baseUrl: ctx.baseUrl, ctx: ctx)) ?? ""
                setPut(key, v, ctx: ctx)
            }
            // 删掉整段 `@put:{...}`
            let fullRange = openRange.lowerBound..<out.index(after: close)
            out.replaceSubrange(fullRange, with: "")
        }
        return out
    }

    /// 拆 `a:r1, b:r2` 顶层逗号 (rule 里可能含 `[a,b]` 之类)
    nonisolated private func splitPutPairs(_ s: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var inStr: Character? = nil
        var start = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if let qc = inStr {
                if c == qc { inStr = nil }
            } else {
                switch c {
                case "'", "\"": inStr = c
                case "{", "[", "(": depth += 1
                case "}", "]", ")": depth -= 1
                case "," where depth == 0:
                    out.append(String(s[start..<i]))
                    start = s.index(after: i)
                default: break
                }
            }
            i = s.index(after: i)
        }
        if start < s.endIndex { out.append(String(s[start...])) }
        return out
    }

    private func replaceInlineJS(_ s: String, on input: Any, ctx: LegadoContext) async -> String {
        guard s.contains("<js>") else { return s }
        var result = s
        while let openRange = result.range(of: "<js>"),
              let closeRange = result.range(of: "</js>", range: openRange.upperBound..<result.endIndex) {
            let script = String(result[openRange.upperBound..<closeRange.lowerBound])
            let v = await runJS(script, result: input, ctx: ctx)
            let str = stringifyOptional(v)
            result.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: str)
        }
        return result
    }

    private func replaceMustache(_ s: String, on input: Any, ctx: LegadoContext) async -> String {
        // 万象书屋 (M2.8 fix bug): legado 同时支持两种占位符语法:
        //   - `{{$.field}}` 双括号 (主流)
        //   - `{$.field}` 单括号 (旧/简化, 爱奇艺漫画 chapterUrl 用)
        // 之前只识别双括号 ⇒ 单括号源 chapter URL 拼不出来.
        // 先把单括号 `{$.x}` 展开为标准 JSONPath 替换, 再走双括号通用逻辑.
        var working = s
        if working.contains("{$") {
            if let singleRegex = try? NSRegularExpression(pattern: #"\{(\$\.[^}]+)\}"#) {
                while true {
                    let ns = working as NSString
                    let ms = singleRegex.matches(in: working, range: NSRange(0..<ns.length))
                    guard let m = ms.first else { break }
                    let path = ns.substring(with: m.range(at: 1))
                    let v = (try? jsonp.selectString(rule: path, source: stringify(input), baseUrl: ctx.baseUrl)) ?? ""
                    working = (working as NSString).replacingCharacters(in: m.range, with: v)
                }
            }
        }
        guard working.contains("{{") else { return working }
        let s = working
        let regex = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#)
        guard let regex else { return s }
        var result = s
        while true {
            let nsstr = result as NSString
            let matches = regex.matches(in: result, range: NSRange(0..<nsstr.length))
            guard let m = matches.first else { break }
            let inner = nsstr.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let value: String
            if inner.hasPrefix("$.") || inner.hasPrefix("$[") {
                value = (try? jsonp.selectString(rule: inner, source: stringify(input), baseUrl: ctx.baseUrl)) ?? ""
            } else if inner.hasPrefix("//") {
                value = (try? xpath.selectString(rule: inner, source: stringify(input), baseUrl: ctx.baseUrl)) ?? ""
            } else if inner.hasPrefix("@") || inner.hasPrefix(".") || inner.hasPrefix("#") {
                value = (try? css.selectString(rule: inner, source: stringify(input), baseUrl: ctx.baseUrl)) ?? ""
            } else if inner.hasPrefix("result.") {
                // 万象书屋 (M2.8 fix bug): legado 模板 `{{result.x.y}}` 是字段路径简写, 在
                // input (JSON 字符串) 上走 JSONPath 取. 之前直接当 JS 跑, scope.result 是
                // string 时 `result.x` = undefined ⇒ 拿不到值. (番茄等源因为 init 调
                // JSON.parse(result), result 必须是 string, 没法预先 parse 注入 object.)
                let path = String(inner.dropFirst("result.".count))
                value = (try? jsonp.selectString(rule: "$." + path, source: stringify(input), baseUrl: ctx.baseUrl)) ?? ""
            } else if inner.contains("cache.getFromMemory") || inner.contains("cache.get") {
                // 万象书屋: `{{cache.getFromMemory('key')}}` 直接调 KV store 取值, 不绕 JS
                let v = await runJS(inner, result: input, ctx: ctx)
                value = stringifyOptional(v)
            } else {
                // 默认当 JS 表达式跑
                let v = await runJS(inner, result: input, ctx: ctx)
                value = stringifyOptional(v)
            }
            result = (result as NSString).replacingCharacters(in: m.range, with: value)
        }
        return result
    }

    // MARK: - ## regex 链处理

    /// 万象书屋 D-16 (PARSE-1/2): 走 SafeRegex 做 ReDoS 保护 + LRU 缓存. 跟 Android
    /// `AnalyzeRule.replaceRegex` 行为对齐: 短输入快速路径 / 长输入 2s timeout / 编译缓存.
    private func applyReplaceSafe(value: String, rule: LegadoSourceRule) async -> String {
        await SafeRegex.shared.replace(
            in: value,
            pattern: rule.replaceRegex,
            replacement: rule.replacement,
            replaceFirst: rule.replaceFirst
        )
    }

    // 万象书屋 D-16: 旧同步 applyReplace 已迁到 SafeRegex.shared.replace (走 LRU + timeout).
    // 上层 applyRule 改用 applyReplaceSafe (async) 调用 — 章节正文长文本不再裸跑 NSRegularExpression.

    // MARK: - util

    /// 对齐 Android `String.isJson()`：首尾同时为 `{}` / `[]` 才算 JSON 样貌，
    /// 避免半截 `{` 误触发 CSS→JSONPath fallback。
    nonisolated private func looksLikeJSON(_ s: String) -> Bool {
        let str = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("{"), str.hasSuffix("}") { return true }
        if str.hasPrefix("["), str.hasSuffix("]") { return true }
        return false
    }

    /// AllInOne regex: findAll, each match -> JSON string with `$0..$n`.
    nonisolated private func regexAllInOne(pattern: String, source: String) -> [String] {
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let nsstr = source as NSString
        let matches = regex.matches(in: source, range: NSRange(0..<nsstr.length))
        return matches.compactMap { m in
            var dict: [String: String] = [:]
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                if r.location != NSNotFound {
                    dict["$\(i)"] = nsstr.substring(with: r)
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        }
    }

    private func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let arr = v as? [String] { return arr.first ?? "" }
        if let arr = v as? [Any] {
            return stringifyOptional(arr.first)
        }
        // 万象书屋 (M2.8 fix bug): JSONSerialization 在 dict 顶层即使 isValidJSONObject==true,
        // 内部 value 含 NSBlock / NSValue / 自定义 NSObject 时仍会抛 NSInvalidArgumentException
        // 整进程崩. 做法: stringify 前递归 deep-check 所有元素都是 JSON-safe type, 否则走
        // String(describing:) 兜底.
        if (v is [String: Any]) || (v is [Any]),
           Self.isDeepJSONSafe(v),
           let data = try? JSONSerialization.data(withJSONObject: v),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: v)
    }

    /// 万象书屋: 递归检查 v 里所有元素都是 JSON-serializable type (String/NSNumber/Bool/NSNull
    /// 或它们的 array/dict). 防 NSInvalidArgumentException.
    private static func isDeepJSONSafe(_ v: Any) -> Bool {
        if v is String || v is NSNumber || v is Bool || v is Int || v is Double || v is NSNull { return true }
        if let arr = v as? [Any] { return arr.allSatisfy { isDeepJSONSafe($0) } }
        if let dict = v as? [String: Any] { return dict.values.allSatisfy { isDeepJSONSafe($0) } }
        return false
    }

    private func stringifyOptional(_ v: Any?) -> String {
        guard let v else { return "" }
        // 万象书屋: Swift 把 Optional<Int> 的 String(describing:) 拼成 "Optional(4)", 必须主动剥
        let mirror = Mirror(reflecting: v)
        if mirror.displayStyle == .optional {
            if let firstChild = mirror.children.first {
                return stringifyOptional(firstChild.value)
            }
            return ""
        }
        return stringify(v)
    }

    private func toStringList(_ v: Any) -> [String] {
        // 万象书屋: 主动 unwrap 嵌套 Optional (String(describing:) 不会剥)
        let unwrapped = unwrapAny(v)
        if let s = unwrapped as? String { return s.isEmpty ? [] : [s] }
        if let arr = unwrapped as? [String] { return arr }
        if let arr = unwrapped as? [Any] { return arr.map { stringifyOptional($0) } }
        if let n = unwrapped as? NSNumber { return [n.stringValue] }
        return [stringify(unwrapped)]
    }

    private func unwrapAny(_ v: Any) -> Any {
        let m = Mirror(reflecting: v)
        if m.displayStyle == .optional {
            if let first = m.children.first { return unwrapAny(first.value) }
            return ""
        }
        return v
    }

    private func isEmpty(_ v: Any) -> Bool {
        if let s = v as? String { return s.isEmpty }
        if let a = v as? [Any] { return a.isEmpty }
        return false
    }
}
