//
//  URLTemplate.swift
//  万象书屋 iOS · legado URL 模板渲染
//
//  legado searchUrl / exploreUrl 是个 mini DSL:
//
//   1. 简单模板:
//      "https://x.com/search?q={{key}}"           ← {{key}} = 搜索关键字
//      "https://x.com/list?p={{page}}"            ← {{page}} = 页码
//
//   2. JSON 选项:
//      "https://x.com/api,{method:'POST',body:'q={{key}}',headers:{'X-Token':'a'}}"
//
//   3. JS 计算:
//      "https://x.com/search?q=<js>encodeURIComponent(key)</js>"
//      "@js: ... 返回 URL 或 {url, method, body, headers}"
//
//   4. exploreUrl 多个: 用 "name::url" + 换行分隔
//      "热门::https://x.com/hot\n\n完结::https://x.com/done"
//

import Foundation

public struct URLTemplate {

    /// 渲染结果
    public struct Rendered: Sendable {
        public var url: String
        public var method: String = "GET"
        public var body: Data? = nil
        public var headers: [String: String] = [:]
        public var charset: String? = nil
        public var retry: Int? = nil
        /// 万象书屋: legado `,{webView:true}` 选项 — caller 应该走 WKWebView 渲染再取 HTML
        public var useWebView: Bool = false
    }

    /// 万象书屋: 异步版 render — 真正执行 `<js>...</js>` 块, 注入 source / cookie / host 全局.
    /// 旧 sync `render(...)` 保留作 fallback (无 source / 无 <js> 时), 内部委托给这个.
    public static func renderAsync(_ template: String,
                                   bookSource: BookSource? = nil,
                                   jsEngine: JSEngine? = nil,
                                   baseURL: String? = nil,
                                   key: String? = nil,
                                   page: Int = 1,
                                   vars: [String: String] = [:]) async -> Rendered {
        var raw = template.trimmingCharacters(in: .whitespaces)

        // 万象书屋: 3 种 JS 前缀 (legado 兼容)
        //   1. `<js>...</js>` 块 (URL 包整段)
        //   2. `@js:` 前缀 (整段都是 JS)
        //   3. `<js>...</js>` 后跟 ",{opts}" 之类 (混合)
        if raw.hasPrefix("<js>"), let end = raw.range(of: "</js>") {
            let jsCode = String(raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound])
            let restAfter = String(raw[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            raw = await runJsToString(jsCode, append: restAfter,
                                       bookSource: bookSource, jsEngine: jsEngine,
                                       baseURL: baseURL, key: key, page: page) ?? ""
        } else if raw.hasPrefix("@js:") {
            let jsCode = String(raw.dropFirst(4))
            raw = await runJsToString(jsCode, append: "",
                                       bookSource: bookSource, jsEngine: jsEngine,
                                       baseURL: baseURL, key: key, page: page) ?? ""
        }

        // 万象书屋: 提前展开非 simple 变量的 `{{ ... }}` JS 表达式 (整段 url + opts)
        // 例: `searchkey={{encodeURIComponent(key)}}` 在 body 里要先求值, 否则 substituteVars 只替换 `{{key}}` 不会动
        if raw.contains("{{"), let engine = jsEngine {
            raw = await expandMustacheJS(raw,
                                          bookSource: bookSource, jsEngine: engine,
                                          baseURL: baseURL, key: key, page: page)
        }

        return renderRaw(raw: raw, baseURL: baseURL ?? bookSource?.bookSourceUrl,
                         key: key, page: page, vars: vars)
    }

    /// 万象书屋: 通用 `{{ ... }}` JS 求值器, 跳过我们的 fast-path 字面量 `{{key}}` `{{page}}` `{{searchKey}}`.
    /// 其它表达式 (含 java.encodeURI/encodeURIComponent/(page-1)*N 等) 直接喂 JSEngine 跑.
    private static func expandMustacheJS(_ s: String,
                                          bookSource: BookSource?, jsEngine: JSEngine,
                                          baseURL: String?, key: String?, page: Int) async -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([^{}]+)\}\}"#) else { return s }
        let nsstr = s as NSString
        let matches = regex.matches(in: s, range: NSRange(0..<nsstr.length)).reversed()
        var out = s
        for m in matches {
            let inner = nsstr.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            // fast-path: substituteVars 后续会替换这些
            if inner == "key" || inner == "page" || inner == "searchKey" { continue }
            // 也跳过 `book.xxx`, 后续兜底处理
            if inner.hasPrefix("book.") { continue }
            let scope = JSContextScope()
            scope.bookSource = bookSource
            scope.baseUrl = baseURL ?? bookSource?.bookSourceUrl
            scope.key = key
            scope.page = page
            let v: Any? = (try? await jsEngine.evaluate(script: inner,
                                                         source: nil,
                                                         baseUrl: scope.baseUrl,
                                                         scope: scope))
            let str = stringifyJsResult(v ?? "")
            out = (out as NSString).replacingCharacters(in: m.range, with: str)
        }
        return out
    }

    /// 万象书屋: 跑 JS 并把结果转成 string. 返回 nil = 没 jsEngine.
    private static func runJsToString(_ jsCode: String, append: String,
                                       bookSource: BookSource?, jsEngine: JSEngine?,
                                       baseURL: String?, key: String?, page: Int) async -> String? {
        guard let engine = jsEngine else { return append }
        let scope = JSContextScope()
        scope.bookSource = bookSource
        scope.baseUrl = baseURL ?? bookSource?.bookSourceUrl
        scope.key = key
        scope.page = page
        let result: Any?
        do {
            result = try await engine.evaluate(script: jsCode, source: nil,
                                                baseUrl: scope.baseUrl, scope: scope)
        } catch {
            if ProcessInfo.processInfo.environment["WX_DEBUG_JS"] != nil {
                print("[URLTemplate] JS error: \(error)")
            }
            result = nil
        }
        var s = stringifyJsResult(result ?? "")
        if !append.isEmpty { s += append }
        return s
    }

    /// 旧 sync render — 内部不实际执行 <js>, 给老 caller 用. 推荐迁移到 renderAsync.
    public static func render(_ template: String,
                              baseURL: String? = nil,
                              key: String? = nil,
                              page: Int = 1,
                              vars: [String: String] = [:]) -> Rendered {
        // sync 版直接强行剥 <js>, 老行为 — 给没改造的 callsite 兜底
        var raw = template.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("<js>") {
            if let end = raw.range(of: "</js>") {
                raw = String(raw[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return renderRaw(raw: raw, baseURL: baseURL, key: key, page: page, vars: vars)
    }

    /// 万象书屋: 把 JS 返回值转 string (object 序列化, NSNumber.stringValue, 等)
    private static func stringifyJsResult(_ v: Any?) -> String {
        guard let v = v else { return "" }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if JSONSerialization.isValidJSONObject(v),
           let data = try? JSONSerialization.data(withJSONObject: v),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: v)
    }

    /// 内部: raw (已经剥 <js>) → Rendered, 兼容 sync 和 async 入口
    private static func renderRaw(raw r: String, baseURL: String?, key: String?,
                                   page: Int, vars: [String: String]) -> Rendered {
        var raw = r
        var optsJSON: String? = nil
        if let commaIdx = findOptsSplit(raw) {
            optsJSON = String(raw[raw.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
            raw = String(raw[..<commaIdx]).trimmingCharacters(in: .whitespaces)
        }
        var charset: String? = nil
        var optsParsed: [String: Any]? = nil
        if let optsJSON = optsJSON {
            let normalized = normalizeJSObjectLiteral(optsJSON)
            if let data = normalized.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                charset = dict["charset"] as? String
                optsParsed = dict
            }
        }
        var url = substituteVars(raw, key: key, page: page, vars: vars, charset: charset)
        url = absolutize(url: url, baseURL: baseURL)
        var rendered = Rendered(url: url)
        rendered.charset = charset
        if let dict = optsParsed {
            if let m = dict["method"] as? String { rendered.method = m.uppercased() }
            if let retry = dict["retry"] as? Int { rendered.retry = retry }
            else if let retryStr = dict["retry"] as? String, let retry = Int(retryStr) { rendered.retry = retry }
            if let webView = dict["webView"] {
                if let b = webView as? Bool { rendered.useWebView = b }
                else if let s = webView as? String { rendered.useWebView = !s.isEmpty && s.lowercased() != "false" && s != "0" }
                else { rendered.useWebView = true }
            }
            if let b = dict["body"] as? String {
                let bodyStr = substituteVars(b, key: key, page: page, vars: vars, charset: charset)
                if let cs = charset, let enc = stringEncoding(for: cs) {
                    rendered.body = bodyStr.data(using: enc) ?? bodyStr.data(using: .utf8)
                } else {
                    rendered.body = bodyStr.data(using: .utf8)
                }
            }
            if let h = dict["headers"] as? [String: String] { rendered.headers = h }
        }
        return rendered
    }

    /// 万象书屋: charset 字符串映射到 String.Encoding
    private static func stringEncoding(for charset: String) -> String.Encoding? {
        let lower = charset.lowercased().replacingOccurrences(of: "-", with: "")
        switch lower {
        case "utf8", "utf_8":            return .utf8
        case "gbk", "gb2312", "gb18030":
            let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        case "big5":
            let cf = CFStringEncoding(CFStringEncodings.big5.rawValue)
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        default: return nil
        }
    }

    /// 把相对 URL 跟 base 拼成绝对 URL
    private static func absolutize(url: String, baseURL: String?) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return trimmed }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        guard let base = baseURL,
              let baseUrl = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return trimmed
        }
        // 拿 scheme + host + port (丢弃 base 的 path/query)
        var comps = URLComponents()
        comps.scheme = baseUrl.scheme ?? "https"
        comps.host = baseUrl.host
        comps.port = baseUrl.port
        if trimmed.hasPrefix("//") {
            // protocol-relative URL: "//cdn.x.com/..."
            return "\(comps.scheme ?? "https"):\(trimmed)"
        }
        if trimmed.hasPrefix("/") {
            // absolute path
            return (comps.url?.absoluteString ?? "") + trimmed
        }
        // 相对 path 拼 base.path
        let basePath = baseUrl.path.hasSuffix("/") ? baseUrl.path : (baseUrl.path + "/")
        return (comps.url?.absoluteString ?? "") + basePath + trimmed
    }

    // MARK: - Helpers

    /// 在 template 中找"URL 与 opts JSON" 分隔的逗号 (JSON 内部的逗号要忽略)
    /// 例: "https://x.com/?a=1,{method:'POST'}"
    ///                       ^ 这个逗号
    private static func findOptsSplit(_ s: String) -> String.Index? {
        var depth = 0
        var inString: Character? = nil
        for idx in s.indices {
            let c = s[idx]
            if let qc = inString {
                if c == qc { inString = nil }
                continue
            }
            switch c {
            case "'", "\"": inString = c
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            case ",":
                if depth == 0 {
                    // 检查右边是否为 JSON 对象 (以 { 开头, 跳过空白)
                    var rhsStart = s.index(after: idx)
                    while rhsStart < s.endIndex, s[rhsStart].isWhitespace {
                        rhsStart = s.index(after: rhsStart)
                    }
                    if rhsStart < s.endIndex, s[rhsStart] == "{" {
                        return idx
                    }
                }
            default: break
            }
        }
        return nil
    }

    private static func substituteVars(_ s: String, key: String?, page: Int, vars: [String: String],
                                        charset: String? = nil) -> String {
        var result = s
        if let key {
            let encoded = percentEncode(key, charset: charset)
            result = result.replacingOccurrences(of: "{{key}}", with: encoded)
            result = result.replacingOccurrences(of: "{{searchKey}}", with: encoded)
        }
        result = result.replacingOccurrences(of: "{{page}}", with: String(page))
        for (k, v) in vars {
            let encoded = percentEncode(v, charset: charset)
            result = result.replacingOccurrences(of: "{{\(k)}}", with: encoded)
        }
        return result
    }

    /// 万象书屋: charset 感知的 percent-encoding
    /// - utf-8/默认: 标准 RFC3986 percent-encoding (Swift 自带)
    /// - GBK/GB2312/Big5: 先转字符集 bytes, 再每个非 ASCII unreserved byte 转 %XX
    /// - bug fix: 不能 `Character(UnicodeScalar(b))` 后判 isLetter — 0xC6 是 GBK 数据字节
    ///   被当成 latin-1 字母 `Æ` 误放, 导致 URL `%B6%B7ÆÆ²Ôñ%B7` 而非正确的 `%B6%B7%C6%C6%B2%D4%F1%B7`
    private static func percentEncode(_ s: String, charset: String?) -> String {
        if let cs = charset, let enc = stringEncoding(for: cs), enc != .utf8 {
            guard let data = s.data(using: enc) else {
                return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
            }
            var out = ""
            out.reserveCapacity(data.count * 3)
            for b in data {
                // RFC3986 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
                if (b >= 0x30 && b <= 0x39)            // 0-9
                    || (b >= 0x41 && b <= 0x5A)        // A-Z
                    || (b >= 0x61 && b <= 0x7A)        // a-z
                    || b == 0x2D                       // -
                    || b == 0x2E                       // .
                    || b == 0x5F                       // _
                    || b == 0x7E                       // ~
                {
                    out.append(Character(Unicode.Scalar(b)))
                } else {
                    out.append(String(format: "%%%02X", b))
                }
            }
            return out
        }
        return s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    /// 把 JS 对象字面量 (单引号 / 无引号 key) 转标准 JSON
    /// "{method:'POST',headers:{'X-A':'1'}}" → "{\"method\":\"POST\",\"headers\":{\"X-A\":\"1\"}}"
    private static func normalizeJSObjectLiteral(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespaces)
        // 单引号 → 双引号 (字符串内部双引号没法分辨, 先简化处理)
        out = out.replacingOccurrences(of: "'", with: "\"")
        // 无引号 key: {key: → {"key":
        // 用正则匹配 { 或 , 后面紧跟 word 字符 + :
        let regex = try? NSRegularExpression(pattern: #"([{,]\s*)([a-zA-Z_$][\w$]*)\s*:"#, options: [])
        if let regex {
            let nsstr = out as NSString
            let matches = regex.matches(in: out, range: NSRange(0..<nsstr.length)).reversed()
            for m in matches {
                let prefix = nsstr.substring(with: m.range(at: 1))
                let key = nsstr.substring(with: m.range(at: 2))
                out = (out as NSString).replacingCharacters(in: m.range, with: "\(prefix)\"\(key)\":")
            }
        }
        return out
    }
}
