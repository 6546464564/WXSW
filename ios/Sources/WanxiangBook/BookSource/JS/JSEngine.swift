//
//  JSEngine.swift
//  万象书屋 iOS · JavaScript 执行引擎 (基于 JavaScriptCore)
//
//  对应 Android: org.mozilla.javascript.Rhino + io.legado.app.help.JsExtensions
//
//  关键差异点跟 Android Rhino 的兼容垫片:
//   - java.put(key, value) / java.get(key)         ← 共享变量
//   - java.log(msg)                                ← 日志
//   - java.ajax(url) / java.ajaxAll([urls])        ← 同步 HTTP (这是 iOS 难点!)
//   - java.cache(key, default)                     ← KV 持久 (用 UserDefaults)
//   - java.timeFormat(timestamp, fmt)
//   - java.t2s / java.s2t                          ← 简繁转换 (M2.5.4 接)
//   - java.encodeURI / decodeURI / urlEncode
//   - java.base64Encode / base64Decode
//   - java.md5Encode / sha1Encode / sha256Encode
//   - java.aesEncode / aesDecode (M1 不实现, 真用到再写)
//   - java.toString
//   - 隐式变量: result, baseUrl, src, book, chapter, page (按上下文注入)
//
//  iOS 难点: java.ajax 在 Android Rhino 是同步阻塞的, JavaScriptCore 沙盒不能在 JS 内部
//  发同步 HTTP. 解法:
//    - 把 JS 评估放在 actor, JS 调 native 时 yield 给 actor 执行 async, 然后 resolve 回去
//    - 或者: pre-fetch (提前算出该 ajax 的结果, 存进 java context, JS 里调时直接读)
//  M1 用方案 B (pre-fetch + cache hit), 复杂场景再加 callback bridge.
//

import Foundation
import JavaScriptCore

/// JS 执行作用域 (隐式变量 + 共享 KV)
public final class JSContextScope: @unchecked Sendable {
    public var result: Any? = nil
    public var baseUrl: String? = nil
    public var src: String? = nil
    public var key: String? = nil   // 万象书屋: 搜索关键词 (legado @js: 里能用)
    public var page: Int = 1        // 万象书屋: 翻页 (legado JS 里 page 全局可读)
    public var book: [String: Any]? = nil
    public var chapter: [String: Any]? = nil
    public var sharedKV: [String: Any] = [:]
    public var prefetchedAjax: [String: String] = [:]
    /// 万象书屋: 当前书源 (注入 source / host / cookie 全局 + jsLib)
    public var bookSource: BookSource? = nil

    public init() {}
}

/// JS 引擎 (actor 串行化避免 JSContext 多线程并发问题)
public actor JSEngine {

    private let ctx: JSContext

    public init() {
        // JavaScriptCore JSContext 不是 thread-safe, 全 actor 串行化
        let ctx = JSContext()!
        ctx.exceptionHandler = { _, e in
            if let e {
                print("[JSEngine] uncaught: \(e.toString() ?? "?")")
            }
        }
        self.ctx = ctx
        injectStdLib()
        // 万象书屋: legado 源 JS 内部经常调 org.jsoup.Jsoup.parse(...).select(...)
        // (Android Rhino 暴露 Java 类). iOS 必须 wrap SwiftSoup 提供同接口
        JsoupShim.install(in: ctx)
    }

    /// 评估 JS, 返回最后一个表达式的值
    /// - Parameters:
    ///   - script: JS 源码
    ///   - source: 给到 JS 的 src 隐式变量 (HTML / JSON 字符串)
    ///   - baseUrl: 给到 JS 的 baseUrl 隐式变量
    ///   - scope: 共享上下文 (跨多次 evaluate 的 result / java.put)
    public func evaluate(script: String, source: String? = nil, baseUrl: String? = nil, scope: JSContextScope? = nil) throws -> Any? {
        // 注入 / 重置隐式变量
        let s = scope ?? JSContextScope()
        s.src = source ?? s.src
        s.baseUrl = baseUrl ?? s.baseUrl
        injectScopeVars(s)

        // 万象书屋: legado JS 经常是 statement-style (含 let/var/const + if/for + 末尾裸表达式).
        // 老 prepareScript 用启发式加 return, 对 if/else 块后跟表达式的情况判断不准.
        // 新策略: 把整段当 string 注入, IIFE 里 eval — eval 自动返回最后求值的 expression 值,
        // 跟 Android Rhino + legado 行为一致. (direct eval 在 IIFE 内是 sloppy mode, let/const 隔离)
        let prepared = prepareScriptForEval(script)
        if ProcessInfo.processInfo.environment["WX_DEBUG_JS"] != nil {
            print("[JS.prepared]\n\(prepared)\n[/JS.prepared]")
        }
        // 用 base64 注入避免任何 \ ` ${} 的 escape 灾难
        let b64 = Data(prepared.utf8).base64EncodedString()
        let wrapped = """
        (function() {
            try {
                var __wx_src = atob("\(b64)");
                // direct eval — let/const 局限在内, 自动返回最后 expression 值
                return eval(__wx_src);
            } catch (e) {
                if (typeof e === 'object' && e && e.message) return '__WX_JS_ERR__:' + e.message;
                return '__WX_JS_ERR__:' + String(e);
            }
        })()
        """
        guard let v = ctx.evaluateScript(wrapped) else {
            throw BookSourceEngineError.jsExecutionFailed("ctx returned nil")
        }
        if let exc = ctx.exception {
            ctx.exception = nil
            throw BookSourceEngineError.jsExecutionFailed(exc.toString() ?? "?")
        }
        if let s = v.toString(), s.hasPrefix("__WX_JS_ERR__:") {
            throw BookSourceEngineError.jsExecutionFailed(String(s.dropFirst("__WX_JS_ERR__:".count)))
        }
        let result = jsValueToSwift(v, scope: s)
        if ProcessInfo.processInfo.environment["WX_DEBUG_JS"] != nil {
            let preview = String(describing: result ?? "nil").prefix(120)
            print("[JS.eval] result=\(preview)")
        }
        return result
    }

    /// 万象书屋: 给 eval 路径用 — 极少处理, 只去 trim, 因为 eval 会自动返回最后值.
    /// 注意 `atob` 在 JavaScriptCore 默认存在.
    private nonisolated func prepareScriptForEval(_ script: String) -> String {
        var trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        // 老式 legado JS 末尾偶尔有"裸 return"(显式 return ...) — eval 不允许 outer return,
        // 把它去掉变成表达式让 eval 返回.
        if trimmed.hasPrefix("return ") {
            trimmed = String(trimmed.dropFirst("return ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 万象书屋: legado JS 在 Android 跑的是 Rhino, Rhino 对 `let`/`const` 重复声明很宽松;
        // JavaScriptCore 严格 ES2015 会抛 "Cannot declare a let variable twice".
        // 实战中观察到一批源 (笔趣类、第一版主类) 在 if/else 多分支里都写 `let bu = ...` 导致冲突.
        // 简单办法: 把顶层 `let ` / `const ` 都改成 `var ` (function scope, 允许重复).
        // 这会丢掉 block scope 语义, 但 legado 源 JS 一般不依赖 let 在循环里的闭包捕获.
        return demoteLetConstToVar(trimmed)
    }

    /// 把脚本里所有不在字符串/正则/注释里的 `let`/`const` 关键字改成 `var`.
    /// 边界条件用 word boundary, 避免误改 `letXX` / `constants` 等标识符.
    nonisolated private func demoteLetConstToVar(_ s: String) -> String {
        guard s.range(of: #"\b(let|const)\b"#, options: .regularExpression) != nil else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        var inSingle = false   // ' string
        var inDouble = false   // " string
        var inTpl = false      // ` string (template literal)
        var inLine = false     // // ...
        var inBlock = false    // /* ... */
        var inRegex = false    // /.../
        var prevSig: Character = "\n"   // 上一个非空白字符 (判断 / 是 regex 还是除法)
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            // 注释
            if inLine {
                out.append(c); if c == "\n" { inLine = false }
                i = next; continue
            }
            if inBlock {
                out.append(c)
                if c == "*", next < s.endIndex, s[next] == "/" {
                    out.append("/"); i = s.index(after: next); inBlock = false; continue
                }
                i = next; continue
            }
            // 字符串
            if inSingle {
                out.append(c); if c == "\\", next < s.endIndex { out.append(s[next]); i = s.index(after: next); continue }
                if c == "'" { inSingle = false }
                i = next; continue
            }
            if inDouble {
                out.append(c); if c == "\\", next < s.endIndex { out.append(s[next]); i = s.index(after: next); continue }
                if c == "\"" { inDouble = false }
                i = next; continue
            }
            if inTpl {
                out.append(c); if c == "\\", next < s.endIndex { out.append(s[next]); i = s.index(after: next); continue }
                if c == "`" { inTpl = false }
                i = next; continue
            }
            if inRegex {
                out.append(c); if c == "\\", next < s.endIndex { out.append(s[next]); i = s.index(after: next); continue }
                if c == "/" { inRegex = false }
                i = next; continue
            }

            // 进入字符串/注释/regex 的判定
            if c == "/" {
                if next < s.endIndex && s[next] == "/" {
                    out.append("/"); out.append("/"); inLine = true; i = s.index(after: next); continue
                }
                if next < s.endIndex && s[next] == "*" {
                    out.append("/"); out.append("*"); inBlock = true; i = s.index(after: next); continue
                }
                // 区分除法 vs regex 字面量: 上一非空白若是表达式结尾 (字母/数字/)/]) 则当除法
                let isExprPrev = prevSig.isLetter || prevSig.isNumber || prevSig == ")" || prevSig == "]"
                if !isExprPrev {
                    out.append(c); inRegex = true; i = next; prevSig = c; continue
                }
            }
            if c == "'" { out.append(c); inSingle = true; i = next; prevSig = c; continue }
            if c == "\"" { out.append(c); inDouble = true; i = next; prevSig = c; continue }
            if c == "`" { out.append(c); inTpl = true; i = next; prevSig = c; continue }

            // word boundary: 检查 `let` / `const` 关键字 (前一字符不能是标识符字符)
            let isPrevIdent = prevSig.isLetter || prevSig.isNumber || prevSig == "_" || prevSig == "$"
            if !isPrevIdent {
                if c == "l", let endLet = s.index(i, offsetBy: 3, limitedBy: s.endIndex), s[i..<endLet] == "let",
                   endLet < s.endIndex, !(s[endLet].isLetter || s[endLet].isNumber || s[endLet] == "_" || s[endLet] == "$") {
                    out.append("var")
                    i = endLet
                    prevSig = "t"
                    continue
                }
                if c == "c", let endConst = s.index(i, offsetBy: 5, limitedBy: s.endIndex), s[i..<endConst] == "const",
                   endConst < s.endIndex, !(s[endConst].isLetter || s[endConst].isNumber || s[endConst] == "_" || s[endConst] == "$") {
                    out.append("var")
                    i = endConst
                    prevSig = "t"
                    continue
                }
            }

            out.append(c)
            if !c.isWhitespace { prevSig = c }
            i = next
        }
        return out
    }

    /// 万象书屋: 给最后一个表达式语句加 return (legado JS 经常这样写) — 已废弃, 留作老代码兼容
    /// bug fix v3: 按"顶层 ;" 切语句 (跳过 string / regex / `${}` / 平衡组), 而非按 `\n`.
    /// 这样 multi-line 表达式 (如 JSON.stringify({\n  ...\n})) 不会被错误判成控制流块.
    private nonisolated func prepareScript(_ script: String) -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let stmts = splitTopLevelStatements(trimmed)
        guard !stmts.isEmpty else { return trimmed }

        // 找最后一个非空语句
        var lastIdx = stmts.count - 1
        while lastIdx >= 0,
              stmts[lastIdx].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lastIdx -= 1
        }
        guard lastIdx >= 0 else { return trimmed }
        let lastStmt = stmts[lastIdx].trimmingCharacters(in: .whitespacesAndNewlines)

        // 已经显式 return / 控制流 / 声明 — 不动
        if lastStmt.hasPrefix("return ") || lastStmt == "return" || lastStmt.hasPrefix("return\t") || lastStmt.hasPrefix("return;") {
            return trimmed
        }
        // 用 \b 风格判断, 防 letX (变量名) 误命中 let
        let declKw = ["var ", "let ", "const ", "function ", "throw ", "if ", "if(",
                      "for ", "for(", "while ", "while(", "switch ", "switch(",
                      "try ", "try{", "do ", "do{", "//", "/*"]
        if declKw.contains(where: { lastStmt.hasPrefix($0) }) {
            return trimmed
        }
        // 到这里, lastStmt 是个表达式, 加 return
        var newStmts = stmts
        newStmts[lastIdx] = "return " + lastStmt
        return newStmts.joined(separator: ";")
    }

    /// 万象书屋: 按"顶层 ;" 切. 字符串/反引号/正则/平衡组内的 ; 不算.
    private nonisolated func splitTopLevelStatements(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var depthParen = 0     // ( ) 平衡
        var depthBracket = 0   // [ ]
        var depthBrace = 0     // { }
        var inStr: Character? = nil
        var prev: Character = " "
        var inLineComment = false
        var inBlockComment = false

        for c in s {
            // 行注释
            if inLineComment {
                cur.append(c)
                if c == "\n" { inLineComment = false }
                prev = c
                continue
            }
            if inBlockComment {
                cur.append(c)
                if prev == "*" && c == "/" { inBlockComment = false }
                prev = c
                continue
            }
            if let q = inStr {
                cur.append(c)
                if c == q && prev != "\\" { inStr = nil }
                prev = c
                continue
            }
            // 检测注释开始
            if prev == "/" && c == "/" { inLineComment = true; cur.append(c); prev = c; continue }
            if prev == "/" && c == "*" { inBlockComment = true; cur.append(c); prev = c; continue }

            switch c {
            case "'", "\"", "`":
                inStr = c
                cur.append(c)
            case "(": depthParen += 1; cur.append(c)
            case ")": depthParen -= 1; cur.append(c)
            case "[": depthBracket += 1; cur.append(c)
            case "]": depthBracket -= 1; cur.append(c)
            case "{": depthBrace += 1; cur.append(c)
            case "}": depthBrace -= 1; cur.append(c)
            case ";":
                if depthParen == 0 && depthBracket == 0 && depthBrace == 0 {
                    out.append(cur)
                    cur = ""
                } else {
                    cur.append(c)
                }
            default:
                cur.append(c)
            }
            prev = c
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(cur)
        }
        return out
    }

    // MARK: - 注入隐式变量

    private func injectScopeVars(_ scope: JSContextScope) {
        // 万象书屋 (M2.8 fix bug): result 注入跟 Android Rhino 行为对齐 — 始终是 raw value,
        // **不**预先 JSON.parse. 之前自动 parse 让番茄等源的 init JS `JSON.parse(result)`
        // 直接 TypeError ("Unexpected identifier object" — 因为 JSON.parse 给到 object 而非 string).
        // 模板里 `{{result.x}}` 的 dot access 在 LegadoRuleEngine.replaceMustache 里特化处理,
        // 不依赖 result 已被 parse.
        let resultRaw: Any = scope.result ?? NSNull()
        ctx.setObject(resultRaw, forKeyedSubscript: "result" as NSString)
        ctx.setObject(scope.baseUrl ?? "", forKeyedSubscript: "baseUrl" as NSString)
        ctx.setObject(scope.src ?? "", forKeyedSubscript: "src" as NSString)
        ctx.setObject(scope.book ?? NSNull(), forKeyedSubscript: "book" as NSString)
        ctx.setObject(scope.chapter ?? NSNull(), forKeyedSubscript: "chapter" as NSString)
        ctx.setObject(scope.key ?? "", forKeyedSubscript: "key" as NSString)
        ctx.setObject(scope.key ?? "", forKeyedSubscript: "searchKey" as NSString)
        ctx.setObject(scope.page, forKeyedSubscript: "page" as NSString)

        // 万象书屋: legado 给每段 JS 评估都注入 source / cookie / host 全局
        // 缺这些会让大量 "高级" 源 (动态 host / 用户 token / cookie 鉴权) 直接挂
        injectSourceContext(scope.bookSource)
        // 万象书屋 (M2.8 perf): cache.* global 不在每次 evaluate 重注 — 它是 process-singleton
        // KV store, 进程内 API 不变. 移到 injectStdLib (init 一次性) 里, 减少每章节 ~5-10ms 开销.
    }

    /// 万象书屋: 注入 legado JS 的 `cache.*` 全局 KV store API.
    /// API 跟 Android `io.legado.app.help.CacheManager` 对齐:
    ///   - cache.putMemory(key, value)         内存存 (无过期, 进程内有效)
    ///   - cache.getFromMemory(key)            内存取
    ///   - cache.put(key, value, [saveTime])   持久存 (UserDefaults)
    ///   - cache.get(key)                      持久取
    ///   - cache.delete(key)                   删
    private func injectCacheGlobal() {
        let cache = JSValue(newObjectIn: ctx)!
        let putMem: @convention(block) (String, Any?) -> Void = { key, value in
            JSEngineCache.shared.putMemory(key: key, value: value)
        }
        let getMem: @convention(block) (String) -> Any? = { key in
            JSEngineCache.shared.getMemory(key: key) ?? NSNull()
        }
        let put: @convention(block) (String, Any?, Any?) -> Void = { key, value, _ in
            // saveTime 第三参 (秒), iOS 简化为永久 — UserDefaults 没原生 expire
            if let s = value as? String {
                UserDefaults.standard.set(s, forKey: "wx.jsCache." + key)
            } else if let v = value {
                UserDefaults.standard.set(String(describing: v), forKey: "wx.jsCache." + key)
            }
        }
        let get: @convention(block) (String) -> String = { key in
            UserDefaults.standard.string(forKey: "wx.jsCache." + key) ?? ""
        }
        let del: @convention(block) (String) -> Void = { key in
            UserDefaults.standard.removeObject(forKey: "wx.jsCache." + key)
        }
        cache.setObject(putMem, forKeyedSubscript: "putMemory" as NSString)
        cache.setObject(getMem, forKeyedSubscript: "getFromMemory" as NSString)
        cache.setObject(put, forKeyedSubscript: "put" as NSString)
        cache.setObject(get, forKeyedSubscript: "get" as NSString)
        cache.setObject(del, forKeyedSubscript: "delete" as NSString)
        ctx.setObject(cache, forKeyedSubscript: "cache" as NSString)
    }

    /// 注入 legado 的 `source` `cookie` `host` `book` 全局, 并 eval `jsLib`
    /// 万象书屋: 每次 evaluate 都重新注入 (源可能不一样)
    private func injectSourceContext(_ source: BookSource?) {
        guard let source = source else {
            // 无源时给 stub, 避免 JS 直接 ReferenceError
            ctx.setObject(NSNull(), forKeyedSubscript: "source" as NSString)
            ctx.setObject(NSNull(), forKeyedSubscript: "cookie" as NSString)
            ctx.setObject([] as [String], forKeyedSubscript: "host" as NSString)
            return
        }

        let sourceUrl = source.bookSourceUrl
        let snapshot = SourceVariableSnapshot(sourceUrl: sourceUrl)

        // 1. source 全局对象
        let sourceObj = JSValue(newObjectIn: ctx)!

        // 万象书屋: 用 box 让闭包能修改 snapshot.variable; 后面 evaluate 完写回 store
        // 简化: 直接读 UserDefaults, 写也直接写 UserDefaults (一次评估调用次数有限)
        let getKey: @convention(block) () -> String = { sourceUrl }
        let getName: @convention(block) () -> String = { source.bookSourceName }
        let getOrigin: @convention(block) () -> String = { sourceUrl }
        let getTag: @convention(block) () -> String = { source.bookSourceName }

        let getVariable: @convention(block) () -> String = {
            UserDefaults.standard.string(forKey: "wx.sourceVariable." + sourceUrl) ?? ""
        }
        let setVariable: @convention(block) (Any?) -> Void = { val in
            if let v = val as? String {
                UserDefaults.standard.set(v, forKey: "wx.sourceVariable." + sourceUrl)
            } else if val == nil {
                UserDefaults.standard.removeObject(forKey: "wx.sourceVariable." + sourceUrl)
            } else {
                // legado 偶尔传 object, 序列化
                // 万象书屋 (M2.8 fix bug): 必须 isValidJSONObject 守卫. 不然 fragment 类型
                // (Number/String 顶层) 直接 NSException crash 整个 App.
                if let v = val,
                   JSONSerialization.isValidJSONObject(v),
                   let data = try? JSONSerialization.data(withJSONObject: v),
                   let s = String(data: data, encoding: .utf8) {
                    UserDefaults.standard.set(s, forKey: "wx.sourceVariable." + sourceUrl)
                }
            }
        }
        let getLoginInfo: @convention(block) () -> String = {
            let snap = SourceVariableSnapshot(sourceUrl: sourceUrl)
            // snap.loginInfo 是 [String: String], 总是合法的 JSON 顶层. 这里加守卫是防御.
            if JSONSerialization.isValidJSONObject(snap.loginInfo),
               let data = try? JSONSerialization.data(withJSONObject: snap.loginInfo),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{}"
        }
        let getLoginInfoMap: @convention(block) () -> [String: String] = {
            SourceVariableSnapshot(sourceUrl: sourceUrl).loginInfo
        }
        let getLoginHeader: @convention(block) () -> String = { "" }
        let getLoginHeaderMap: @convention(block) () -> [String: String] = { [:] }

        sourceObj.setObject(getKey, forKeyedSubscript: "getKey" as NSString)
        sourceObj.setObject(getName, forKeyedSubscript: "getName" as NSString)
        sourceObj.setObject(getOrigin, forKeyedSubscript: "getOrigin" as NSString)
        sourceObj.setObject(getTag, forKeyedSubscript: "getTag" as NSString)
        sourceObj.setObject(getVariable, forKeyedSubscript: "getVariable" as NSString)
        sourceObj.setObject(setVariable, forKeyedSubscript: "setVariable" as NSString)
        sourceObj.setObject(getLoginInfo, forKeyedSubscript: "getLoginInfo" as NSString)
        sourceObj.setObject(getLoginInfoMap, forKeyedSubscript: "getLoginInfoMap" as NSString)
        sourceObj.setObject(getLoginHeader, forKeyedSubscript: "getLoginHeader" as NSString)
        sourceObj.setObject(getLoginHeaderMap, forKeyedSubscript: "getLoginHeaderMap" as NSString)
        ctx.setObject(sourceObj, forKeyedSubscript: "source" as NSString)

        // 2. cookie 全局
        let cookieObj = JSValue(newObjectIn: ctx)!
        let getCookie: @convention(block) (String) -> String = { url in
            CookieJarStore.getCookie(url: url)
        }
        let getCookieKey: @convention(block) (String, String) -> String = { url, key in
            CookieJarStore.getCookieValue(url: url, key: key)
        }
        let setCookie: @convention(block) (String, String?) -> Void = { url, val in
            CookieJarStore.setCookie(url: url, cookie: val)
        }
        let removeCookie: @convention(block) (String) -> Void = { url in
            CookieJarStore.removeCookie(url: url)
        }
        cookieObj.setObject(getCookie, forKeyedSubscript: "getCookie" as NSString)
        cookieObj.setObject(getCookieKey, forKeyedSubscript: "getCookieKey" as NSString)
        cookieObj.setObject(setCookie, forKeyedSubscript: "setCookie" as NSString)
        cookieObj.setObject(removeCookie, forKeyedSubscript: "removeCookie" as NSString)
        cookieObj.setObject(removeCookie, forKeyedSubscript: "clearCookie" as NSString)
        ctx.setObject(cookieObj, forKeyedSubscript: "cookie" as NSString)

        // 3. host 数组 (legado 源用 host[0] 取主域)
        if let parsed = URL(string: sourceUrl), let scheme = parsed.scheme, let host = parsed.host {
            let hostUrl = "\(scheme)://\(host)"
            ctx.setObject([hostUrl, sourceUrl], forKeyedSubscript: "host" as NSString)
        } else {
            ctx.setObject([sourceUrl], forKeyedSubscript: "host" as NSString)
        }

        // 4. 万象书屋: legado 全局 helper - getArguments(varStr, key)
        // 解析 source.getVariable() 返回的 JSON, 取某 key 的值
        let getArgumentsScript = """
        if (typeof getArguments !== 'function') {
          var getArguments = function(str, key) {
            if (!str || str === "") return "";
            try { var o = JSON.parse(str); return o[key] != null ? String(o[key]) : ""; }
            catch (e) { return ""; }
          };
        }
        // legado 源 jsLib 经常自定义这两个 fallback
        if (typeof getServerHost !== 'function') {
          var getServerHost = function() {
            var s = source && source.getVariable ? source.getVariable() : "";
            return getArguments(s, 'server') || getArguments(s, 'host') || (host && host[0]) || "";
          };
        }
        if (typeof getSecretKey !== 'function') {
          var getSecretKey = function() {
            var s = source && source.getVariable ? source.getVariable() : "";
            return getArguments(s, 'secret') || getArguments(s, 'key') || "";
          };
        }
        """
        ctx.evaluateScript(demoteLetConstToVar(getArgumentsScript))

        // 5. 加载源的 jsLib (如果有)
        if let jsLib = source.jsLib, !jsLib.isEmpty {
            // jsLib 可能是: 纯 JS 代码 / URL / {name: url} 的 JSON map
            evalJsLib(jsLib)
        }
    }

    /// 万象书屋: 解析 jsLib 字段并 eval 进当前 ctx
    /// jsLib 可能形态:
    ///   1. 纯 JS 代码 ("function foo(){...}")
    ///   2. 单 URL ("https://example.com/lib.js")
    ///   3. JSON map ({"hub":"https://x/a.js", "util":"https://x/b.js"})
    private func evalJsLib(_ jsLib: String) {
        let trimmed = jsLib.trimmingCharacters(in: .whitespacesAndNewlines)
        // 单 URL
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if let cached = JsLibCache.get(url: trimmed) {
                ctx.evaluateScript(demoteLetConstToVar(cached))
            } else {
                // M2: 同步下载 (URLSession dataTask + condition var). 对每源首次评估稍慢, 后续走 cache.
                if let js = JsLibCache.fetchSync(url: trimmed) {
                    ctx.evaluateScript(demoteLetConstToVar(js))
                }
            }
            return
        }
        // JSON map
        if trimmed.hasPrefix("{") {
            if let data = trimmed.data(using: .utf8),
               let map = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                for (_, url) in map {
                    if url.hasPrefix("http") {
                        if let cached = JsLibCache.get(url: url) {
                            ctx.evaluateScript(demoteLetConstToVar(cached))
                        } else if let js = JsLibCache.fetchSync(url: url) {
                            ctx.evaluateScript(demoteLetConstToVar(js))
                        }
                    } else {
                        // 直接是 JS 代码
                        ctx.evaluateScript(demoteLetConstToVar(url))
                    }
                }
                return
            }
        }
        // 纯 JS 代码
        ctx.evaluateScript(demoteLetConstToVar(trimmed))
    }

    /// 万象书屋: 试 JSON parse, 失败返原值
    private func parseResultIfJson(_ v: Any?) -> Any {
        guard let v else { return NSNull() }
        if let s = v as? String, !s.isEmpty {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                if let data = trimmed.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) {
                    return parsed
                }
            }
            return s
        }
        return v
    }

    // MARK: - 注入 java.* 兼容垫片

    private func injectStdLib() {
        // 万象书屋: JavaScriptCore 默认没有 browser globals atob/btoa, 补一下 (legado JS 经常用)
        let atob: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s) else { return "" }
            return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) ?? ""
        }
        ctx.setObject(atob, forKeyedSubscript: "atob" as NSString)
        let btoa: @convention(block) (String) -> String = { s in
            return Data(s.utf8).base64EncodedString()
        }
        ctx.setObject(btoa, forKeyedSubscript: "btoa" as NSString)

        let java = JSValue(newObjectIn: ctx)!

        // java.put / get / cache (KV)
        // 万象书屋: legado Android `java.put(k,v)` 返回 v 本身 (Rhino 行为), 这样可以
        // 链式写 `key;java.put("key",key)` 让 mustache 取到 key 值同时存 K-V.
        // 之前 Void 返回导致 `{{key;java.put("key",key)}}` 求值得 nil → URL 缺关键词.
        let put: @convention(block) (String, JSValue) -> JSValue = { [weak self] key, val in
            self?.ctx.setObject(val, forKeyedSubscript: ("__wx_kv_\(key)") as NSString)
            return val
        }
        let get: @convention(block) (String) -> Any? = { [weak self] key in
            self?.ctx.objectForKeyedSubscript(("__wx_kv_\(key)") as NSString)
        }
        java.setObject(put, forKeyedSubscript: "put" as NSString)
        java.setObject(get, forKeyedSubscript: "get" as NSString)
        java.setObject(put, forKeyedSubscript: "cache" as NSString)   // 简化: cache=put

        // java.log
        let log: @convention(block) (String) -> Void = { msg in
            print("[JS.log] \(msg)")
        }
        java.setObject(log, forKeyedSubscript: "log" as NSString)

        // java.ajax(url) — 用 condition variable 同步 fetch (跟 Android Rhino 同步 ajax 行为对齐)
        // 万象书屋: 这是 iOS JavaScriptCore 没法绕的坑, 只能阻塞当前 actor 等 URLSession 完成
        let ajax: @convention(block) (String) -> String = { url in
            return SyncHTTP.get(url: url, headers: [:])?.body ?? ""
        }
        java.setObject(ajax, forKeyedSubscript: "ajax" as NSString)

        // 万象书屋: java.get(url, headers) → Response 对象 (有 .body() .header(name) .code() .headers())
        // 必须返回带"方法"的对象, 因为 legado 源 JS 用 `resp.header("location")` 而非 `resp.headers["location"]`.
        // 用 native closure capture self.ctx 给返回的 JSValue 对象动态附加方法.
        let weakCtx = ctx   // capture
        let getHttp: @convention(block) (String, Any?) -> JSValue = { [weakCtx] url, headersAny in
            let headers = (headersAny as? [String: Any])?.compactMapValues { String(describing: $0) } ?? [:]
            let r = SyncHTTP.get(url: url, headers: headers)
                ?? SyncHTTPResponse(body: "", statusCode: 0, headers: [:])
            return Self.makeResponseValue(r, in: weakCtx)
        }
        java.setObject(getHttp, forKeyedSubscript: "get" as NSString)
        java.setObject(getHttp, forKeyedSubscript: "head" as NSString)
        java.setObject(getHttp, forKeyedSubscript: "connect" as NSString)

        // java.post(url, body, headers) → Response
        let postHttp: @convention(block) (String, Any?, Any?) -> JSValue = { [weakCtx] url, bodyAny, headersAny in
            let body = (bodyAny as? String) ?? ""
            let headers = (headersAny as? [String: Any])?.compactMapValues { String(describing: $0) } ?? [:]
            let r = SyncHTTP.post(url: url, body: body, headers: headers)
                ?? SyncHTTPResponse(body: "", statusCode: 0, headers: [:])
            return Self.makeResponseValue(r, in: weakCtx)
        }
        java.setObject(postHttp, forKeyedSubscript: "post" as NSString)

        // 万象书屋: java.toast / longToast (legado 在 Android 弹 Toast, iOS 这里 noop + log)
        let toast: @convention(block) (Any?) -> Void = { msg in
            if let m = msg { print("[js.toast] \(m)") }
        }
        java.setObject(toast, forKeyedSubscript: "toast" as NSString)
        java.setObject(toast, forKeyedSubscript: "longToast" as NSString)

        // 万象书屋: legado 还有这些纯 noop / 兼容方法
        let webView: @convention(block) (Any?, Any?, Any?) -> String = { _, _, _ in "" }
        java.setObject(webView, forKeyedSubscript: "webView" as NSString)
        java.setObject(webView, forKeyedSubscript: "webViewGetSource" as NSString)
        java.setObject(webView, forKeyedSubscript: "webViewGetOverrideUrl" as NSString)
        java.setObject({ (_: String, _: String) in } as @convention(block) (String, String) -> Void,
                       forKeyedSubscript: "startBrowser" as NSString)
        // 万象书屋: java.startBrowserAwait(url, keyword) — 反爬关键
        //   - legado 源经常这么写: `if (result.includes('Cloudflare')) {
        //       result = java.startBrowserAwait(baseUrl, '关键词').body();
        //     }`
        //   - 之前是 stub 返空对象, 顶点小说/黄易天地等用 CF 防护的源 result=""
        //     → 后续 selector 全跑空 → 0 搜索结果. 这是 iOS 跟 Android 解析能力
        //     差距最直接的一刀.
        //   - 现在桥到 BrowserBridgeRegistry → WKWebViewBridge, 真起 WKWebView
        //     跑 JS, 等 outerHTML 含 keyword 后回填. 30s 超时让 JS 链能 fallback.
        //   - 同步阻塞: JSEngine 是 actor, 这里 sema.wait() 卡当前 JS 求值线程,
        //     跟 SyncHTTP 同模式. 不在 main thread 上跑就 OK.
        let startBrowserAwait: @convention(block) (Any?, Any?) -> [String: Any] = { urlAny, keywordAny in
            let url = (urlAny as? String) ?? ""
            let keyword = keywordAny as? String   // 可空, BrowserBridge 会兜底返 outerHTML
            guard !url.isEmpty else {
                return ["body": "", "code": 0, "headers": [:] as [String: String]]
            }
            // 跳出 actor: Task 在合作池跑 await, sema 同步等结果回灌
            let sema = DispatchSemaphore(value: 0)
            // 万象书屋: 用 wrapper class 让 closure 可写 (Swift block 默认按值捕获)
            let box = _BrowserResultBox()
            Task.detached {
                let bridge = await BrowserBridgeRegistry.shared.get()
                let html = await bridge.loadAndWait(
                    url: url, expectedKeyword: keyword, timeout: 30
                )
                box.body = html ?? ""
                sema.signal()
            }
            // 35s 兜底: 给 BrowserBridge 30s + 缓冲, 自身 timeout 还是要的防 actor 卡死.
            _ = sema.wait(timeout: .now() + 35)
            return [
                "body": box.body,
                "code": box.body.isEmpty ? 0 : 200,
                "headers": [:] as [String: String]
            ]
        }
        java.setObject(startBrowserAwait, forKeyedSubscript: "startBrowserAwait" as NSString)
        let randomUUID: @convention(block) () -> String = {
            UUID().uuidString
        }
        java.setObject(randomUUID, forKeyedSubscript: "randomUUID" as NSString)

        // 编码 / 解码 / 哈希
        let encodeURI: @convention(block) (String) -> String = { s in
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        let decodeURI: @convention(block) (String) -> String = { s in
            s.removingPercentEncoding ?? s
        }
        java.setObject(encodeURI, forKeyedSubscript: "encodeURI" as NSString)
        java.setObject(decodeURI, forKeyedSubscript: "decodeURI" as NSString)
        java.setObject(encodeURI, forKeyedSubscript: "urlEncode" as NSString)

        let base64Encode: @convention(block) (String) -> String = { s in
            s.data(using: .utf8)?.base64EncodedString() ?? ""
        }
        let base64Decode: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        java.setObject(base64Encode, forKeyedSubscript: "base64Encode" as NSString)
        java.setObject(base64Decode, forKeyedSubscript: "base64Decode" as NSString)

        let md5Encode: @convention(block) (String) -> String = { s in
            md5Hex(s)
        }
        java.setObject(md5Encode, forKeyedSubscript: "md5Encode" as NSString)

        let sha1Encode: @convention(block) (String) -> String = { s in
            sha1Hex(s)
        }
        java.setObject(sha1Encode, forKeyedSubscript: "sha1Encode" as NSString)

        // 万象书屋: legado JS 还有 sha256Encode (一些登录签名 JS 用), Android 已有.
        // 之前 iOS 没挂到 java 上, 源 JS 调到这里就是 undefined → 抛错 → 整段 JS 失败.
        let sha256Encode: @convention(block) (String) -> String = { s in
            sha256Hex(s)
        }
        java.setObject(sha256Encode, forKeyedSubscript: "sha256Encode" as NSString)

        let toString: @convention(block) (Any?) -> String = { v in
            v.map { String(describing: $0) } ?? ""
        }
        java.setObject(toString, forKeyedSubscript: "toString" as NSString)

        // 时间格式化
        let timeFormat: @convention(block) (Double, String) -> String = { ts, fmt in
            let date = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
            let f = DateFormatter()
            f.dateFormat = fmt
            return f.string(from: date)
        }
        java.setObject(timeFormat, forKeyedSubscript: "timeFormat" as NSString)

        // 简繁转换 (M2.5.4 接真实数据集; M1 直接返原文)
        let identity: @convention(block) (String) -> String = { $0 }
        java.setObject(identity, forKeyedSubscript: "t2s" as NSString)
        java.setObject(identity, forKeyedSubscript: "s2t" as NSString)

        // 万象书屋 (M2.8 P0): 补齐 Android JsExtensions 高频但 iOS 没实现的 java.* 方法.
        // 之前 iOS 缺这些方法 → 调用方 JS 直接 ReferenceError → 整段 evaluate 失败.

        // == HTML 实体反转义 (大量源 content rule 末尾用) ==
        // Android: htmlFormat(str) → 反转义 &amp; → & / &nbsp; → space / &quot; → " 等
        let htmlFormat: @convention(block) (String) -> String = { s in
            var out = s
            let entities: [(String, String)] = [
                ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                ("&quot;", "\""), ("&#039;", "'"), ("&apos;", "'"),
                ("&nbsp;", " "), ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
                ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
                ("&hellip;", "…"), ("&mdash;", "—"), ("&ndash;", "–"),
                ("&copy;", "©"), ("&reg;", "®"), ("&trade;", "™"),
            ]
            for (k, v) in entities { out = out.replacingOccurrences(of: k, with: v) }
            // 数字实体 &#1234; → unicode
            if out.contains("&#") {
                let pattern = #"&#(\d+);"#
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let nsstr = out as NSString
                    let matches = regex.matches(in: out, range: NSRange(0..<nsstr.length)).reversed()
                    for m in matches {
                        let numStr = nsstr.substring(with: m.range(at: 1))
                        if let n = UInt32(numStr), let scalar = Unicode.Scalar(n) {
                            out = (out as NSString).replacingCharacters(in: m.range, with: String(scalar))
                        }
                    }
                }
            }
            return out
        }
        java.setObject(htmlFormat, forKeyedSubscript: "htmlFormat" as NSString)

        // == 字符编码转换 (加密源 / 字符级处理) ==
        // strToBytes(str, charset?) → ByteArray (JS 当 number[] 用)
        let strToBytes: @convention(block) (String, Any?) -> [UInt8] = { s, charsetAny in
            let charset = (charsetAny as? String)?.lowercased() ?? "utf-8"
            let enc: String.Encoding = {
                switch charset {
                case "gbk", "gb2312":
                    let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                case "big5":
                    let cf = CFStringEncoding(CFStringEncodings.big5.rawValue)
                    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                case "utf-16le": return .utf16LittleEndian
                case "utf-16be": return .utf16BigEndian
                case "iso-8859-1", "latin1": return .isoLatin1
                default: return .utf8
                }
            }()
            return Array(s.data(using: enc) ?? Data())
        }
        java.setObject(strToBytes, forKeyedSubscript: "strToBytes" as NSString)

        // bytesToStr(bytes, charset?) → String
        let bytesToStr: @convention(block) (Any, Any?) -> String = { bytesAny, charsetAny in
            let charset = (charsetAny as? String)?.lowercased() ?? "utf-8"
            let data: Data
            if let arr = bytesAny as? [Any] {
                let bytes: [UInt8] = arr.compactMap {
                    if let n = $0 as? NSNumber { return UInt8(truncatingIfNeeded: n.intValue) }
                    return nil
                }
                data = Data(bytes)
            } else if let d = bytesAny as? Data {
                data = d
            } else {
                return ""
            }
            let enc: String.Encoding = {
                switch charset {
                case "gbk", "gb2312":
                    let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                case "big5":
                    let cf = CFStringEncoding(CFStringEncodings.big5.rawValue)
                    return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                default: return .utf8
                }
            }()
            return String(data: data, encoding: enc) ?? ""
        }
        java.setObject(bytesToStr, forKeyedSubscript: "bytesToStr" as NSString)

        // == Hex 编解码 (加密源用很多) ==
        // hexEncodeToString(utf8: String) → "48656c6c6f"
        let hexEncodeToString: @convention(block) (String) -> String = { s in
            return s.utf8.map { String(format: "%02x", $0) }.joined()
        }
        java.setObject(hexEncodeToString, forKeyedSubscript: "hexEncodeToString" as NSString)

        // hexDecodeToString("48656c6c6f") → "Hello"
        let hexDecodeToString: @convention(block) (String) -> String = { hex in
            let cleaned = hex.replacingOccurrences(of: " ", with: "")
            guard cleaned.count % 2 == 0 else { return "" }
            var bytes: [UInt8] = []
            var idx = cleaned.startIndex
            while idx < cleaned.endIndex {
                let next = cleaned.index(idx, offsetBy: 2)
                if let b = UInt8(cleaned[idx..<next], radix: 16) {
                    bytes.append(b)
                }
                idx = next
            }
            return String(data: Data(bytes), encoding: .utf8) ?? ""
        }
        java.setObject(hexDecodeToString, forKeyedSubscript: "hexDecodeToString" as NSString)

        // hexDecodeToByteArray("48656c") → [UInt8] (JS 当 number[] 用)
        let hexDecodeToByteArray: @convention(block) (String) -> [UInt8] = { hex in
            let cleaned = hex.replacingOccurrences(of: " ", with: "")
            guard cleaned.count % 2 == 0 else { return [] }
            var bytes: [UInt8] = []
            var idx = cleaned.startIndex
            while idx < cleaned.endIndex {
                let next = cleaned.index(idx, offsetBy: 2)
                if let b = UInt8(cleaned[idx..<next], radix: 16) {
                    bytes.append(b)
                }
                idx = next
            }
            return bytes
        }
        java.setObject(hexDecodeToByteArray, forKeyedSubscript: "hexDecodeToByteArray" as NSString)

        // base64DecodeToByteArray
        let base64DecodeToByteArray: @convention(block) (String) -> [UInt8] = { s in
            guard let d = Data(base64Encoded: s) else { return [] }
            return Array(d)
        }
        java.setObject(base64DecodeToByteArray, forKeyedSubscript: "base64DecodeToByteArray" as NSString)

        // == 时间格式化 (UTC 偏移版) ==
        // timeFormatUTC(timestamp, format, sh: 时区小时偏移)
        let timeFormatUTC: @convention(block) (Double, String, Int) -> String = { ts, fmt, sh in
            let date = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
            let f = DateFormatter()
            f.dateFormat = fmt
            f.timeZone = TimeZone(secondsFromGMT: sh * 3600)
            return f.string(from: date)
        }
        java.setObject(timeFormatUTC, forKeyedSubscript: "timeFormatUTC" as NSString)

        // == 章节序号标准化 (一些源章节排序用) ==
        // toNumChapter("第一千零九十七章 大璺在身") → 数字字符串便于排序
        // 简化实现: 提取连续数字 (Android 实际处理"第一" "第二十" 等中文数字, 这里先提阿拉伯数字)
        let toNumChapter: @convention(block) (String?) -> String = { s in
            guard let s = s else { return "" }
            // 先 try 数字
            let pattern = #"\d+"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let nsstr = s as NSString
                if let m = regex.firstMatch(in: s, range: NSRange(0..<nsstr.length)) {
                    return nsstr.substring(with: m.range)
                }
            }
            // 中文数字粗映射 (一二三四五六七八九十百千万)
            let cnDigits: [Character: Int] = [
                "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "百": 100, "千": 1000, "万": 10000
            ]
            var result = 0
            var current = 0
            for ch in s {
                if let v = cnDigits[ch] {
                    if v >= 10 {
                        if current == 0 { current = 1 }
                        current *= v
                        if v >= 100 {
                            result += current
                            current = 0
                        }
                    } else {
                        current = current * 10 + v
                    }
                } else if current > 0 || result > 0 {
                    break
                }
            }
            result += current
            return result > 0 ? String(result) : s
        }
        java.setObject(toNumChapter, forKeyedSubscript: "toNumChapter" as NSString)

        // == ajaxAll(urls) — 多 URL 并发抓 ==
        // 一些源用 `java.ajaxAll(["url1","url2"])` 批量抓页面合并解析
        let ajaxAll: @convention(block) (Any?) -> [String] = { urlsAny in
            guard let urls = urlsAny as? [String] else { return [] }
            // 串行实现 (JSCore actor 内部调, async/await 跨 boundary 用 sync wait)
            // 比 Android 真并发慢, 但功能正确; 个别源命中量级很小
            return urls.map { url in
                SyncHTTP.get(url: url, headers: [:])?.body ?? ""
            }
        }
        java.setObject(ajaxAll, forKeyedSubscript: "ajaxAll" as NSString)

        // == getWebViewUA() — 反爬源用 ==
        let getWebViewUA: @convention(block) () -> String = {
            // 万象书屋: 跟 BookCoverDiskCache / SyncHTTP / WKWebViewBridge 用同款 Safari UA
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }
        java.setObject(getWebViewUA, forKeyedSubscript: "getWebViewUA" as NSString)

        // == importScript(path: String) — 引入外部 JS ==
        // Android 支持 path = http(s) URL 或本地路径. iOS 简化: 仅支持 http(s) URL, 走 JsLibCache.
        let importScript: @convention(block) (String) -> String = { path in
            guard path.hasPrefix("http://") || path.hasPrefix("https://") else {
                return ""  // 本地路径 iOS 不支持
            }
            return JsLibCache.fetchSync(url: path) ?? ""
        }
        java.setObject(importScript, forKeyedSubscript: "importScript" as NSString)

        // == queryTTF / replaceFont — 字体反爬 (番茄/晋江系) ==
        // queryTTF(url|base64, useCache?) → QueryTTF 对象, 有 .getNameByCode(unicode) /
        //   .getCodeByName(name) / .inLimit(code) 等方法
        // replaceFont(text, fromTTF, toTTF) → 字符级替换文本 (TTF glyph 反向映射)
        //
        // 万象书屋: 完整 TTF 解析 = Android QueryTTF.java 1055 行 Java (Header / Directory /
        //   HeadLayout / NameLayout / MaxpLayout / CmapRecord / GlyphTableBySimple /
        //   GlyphTableComponent), Swift 重写 ~1000 行 + 真实场景需要 glyph outline 像素
        //   比较才能跨字体匹配同一汉字 (Android 用 PixelMap 算法). 实现量极大且反爬规则
        //   一直变, ROI 太低.
        //
        // 当前 stub 策略 — 让 JS 调用链不抛错:
        //   - queryTTF / queryBase64TTF 返带方法的 JSValue object
        //   - getNameByCode / getCodeByName 返 null (而非 undefined)
        //     源 JS 拿 null 走 fallback 路径 (一些源会判 `if (glyph === null) return c`)
        //   - inLimit 返 false (字符不在 TTF 范围 → 不替换)
        //   - replaceFont 返原 text 不替换
        //
        // 后续若用户报"某源乱码", 再做完整 TTF 解析.
        let queryTTF: @convention(block) (Any?, Any?) -> JSValue = { [weakCtx] _, _ in
            let obj = JSValue(newObjectIn: weakCtx)!
            // 跟 Android QueryTTF 接口对齐 — 返 null 或 false 让 JS 走 fallback
            let getNameByCode: @convention(block) (Any?) -> Any? = { _ in NSNull() }
            let getCodeByName: @convention(block) (Any?) -> Any? = { _ in NSNull() }
            let inLimit: @convention(block) (Any?) -> Bool = { _ in false }
            let getGlyfByCode: @convention(block) (Any?) -> Any? = { _ in NSNull() }
            obj.setObject(getNameByCode, forKeyedSubscript: "getNameByCode" as NSString)
            obj.setObject(getCodeByName, forKeyedSubscript: "getCodeByName" as NSString)
            obj.setObject(inLimit, forKeyedSubscript: "inLimit" as NSString)
            obj.setObject(getGlyfByCode, forKeyedSubscript: "getGlyfByCode" as NSString)
            // 字段: 一些源直接读 .ttfRange / .fileBytes
            obj.setObject([] as [Int], forKeyedSubscript: "ttfRange" as NSString)
            obj.setObject([] as [Int], forKeyedSubscript: "fileBytes" as NSString)
            return obj
        }
        java.setObject(queryTTF, forKeyedSubscript: "queryTTF" as NSString)
        java.setObject(queryTTF, forKeyedSubscript: "queryBase64TTF" as NSString)
        let replaceFont: @convention(block) (String, Any?, Any?) -> String = { text, _, _ in
            return text
        }
        java.setObject(replaceFont, forKeyedSubscript: "replaceFont" as NSString)

        ctx.setObject(java, forKeyedSubscript: "java" as NSString)

        // 万象书屋 (M2.8 fix bug): java.getElements / java.getElement / java.getString —
        // legado AnalyzeRule 暴露给 JS 的"在当前 src 上跑 selector"快捷方法.
        // 蓝海搜书等多源在 chapterList @js: 里调 `java.getElements("class.X")`,
        // iOS 之前没注入这俩方法 ⇒ ReferenceError ⇒ "Unexpected end of script" 整段 JS 失败.
        //
        // 实现策略: JS 端用现成的 globalThis.Jsoup (JsoupShim) 跑, 加 legado keyword 翻译.
        // 不重新桥接 native bridge (复用已有 wrap/__wx_jsoup_select 链路).
        ctx.evaluateScript("""
        (function() {
            function legadoSelector(rule) {
                if (typeof rule !== 'string') return rule;
                if (rule.indexOf('class.') === 0) {
                    var inner = rule.substring(6);
                    if (inner.indexOf(' ') >= 0) {
                        return inner.split(/\\s+/).filter(Boolean).map(function(c) { return '.' + c; }).join('');
                    }
                    return '.' + inner;
                }
                if (rule.indexOf('id.') === 0) return '#' + rule.substring(3);
                if (rule.indexOf('tag.') === 0) return rule.substring(4);
                return rule;
            }
            // java.getElements(rule) → ElementJS[]
            // 跟 Android `java.getElements` 行为对齐: 在当前 src 上跑 selector, 返元素数组.
            java.getElements = function(rule) {
                var html = (typeof src !== 'undefined' && src) ? String(src) : '';
                if (!html) return [];
                var doc = (typeof Jsoup !== 'undefined') ? Jsoup.parse(html) : null;
                if (!doc) return [];
                var sel = legadoSelector(rule);
                var els = doc.select(sel);
                if (!els) return [];
                var out = [];
                var n = els.size();
                for (var i = 0; i < n; i++) {
                    var el = els.get(i);
                    if (el) out.push(el);
                }
                return out;
            };
            // java.getElement(rule) → first ElementJS or null
            java.getElement = function(rule) {
                var arr = java.getElements(rule);
                return arr.length > 0 ? arr[0] : null;
            };
            // java.getString(rule) → element.text() (跟 Android AnalyzeRule.getString 对齐)
            java.getString = function(rule) {
                var el = java.getElement(rule);
                return el ? el.text() : '';
            };
        })();
        """)

        // 万象书屋 (M2.8 perf): cache.* 进程级 KV store, init 时注一次, 评估时不重注.
        // 之前在 injectScopeVars 每次 evaluate 重注 7 个 closure 增加 ~5-10ms 开销.
        injectCacheGlobal()

        // 万象书屋 (M2.8 fix bug): Rhino-style String.prototype polyfill — Android Legado 用的
        // Mozilla Rhino 把 Java String API 暴露给 JS, 大量源 author 写 `text.replaceAll(regex, x)`
        // 期望 first arg 是 regex pattern (Java String.replaceAll). JS ES2021 的 replaceAll
        // first arg 是 plain string (除非传 RegExp 必须带 /g flag). 这两个语义直接打架,
        // 禁忌书屋/可乐小说网/篱笆好文学等多个源的 content rule 用 Java 风格全废.
        //
        // Polyfill: 检测 first arg 是 string 且含 regex meta 字符 (`[]()*+?{}|^$\` 或 `(?i)`),
        // 当 RegExp 跑; 否则保持 ES2021 plain-string 行为不破坏标准用法.
        ctx.evaluateScript("""
        (function() {
            var _origReplaceAll = String.prototype.replaceAll;
            String.prototype.replaceAll = function(searchValue, replaceValue) {
                if (typeof searchValue === 'string') {
                    // 含 regex meta 或 (?i) 等 inline flag, 当 regex 跑 (Rhino 兼容)
                    if (/[\\\\\\[\\]()*+?{}|^$]/.test(searchValue) || searchValue.indexOf('(?') === 0) {
                        try {
                            var pattern = searchValue;
                            var flags = 'g';
                            // Java (?i) inline flag → JS 'i' flag
                            var m = pattern.match(/^\\(\\?([a-z]+)\\)(.*)/);
                            if (m) {
                                if (m[1].indexOf('i') >= 0) flags += 'i';
                                if (m[1].indexOf('s') >= 0) flags += 's';
                                if (m[1].indexOf('m') >= 0) flags += 'm';
                                pattern = m[2];
                            }
                            return this.replace(new RegExp(pattern, flags), replaceValue);
                        } catch (e) {
                            // regex 编译失败 fallback ES 标准行为
                        }
                    }
                }
                return _origReplaceAll.call(this, searchValue, replaceValue);
            };
            // 万象书屋: Java String.equals → JS ===
            String.prototype.equals = function(s) { return String(this) === String(s); };
            String.prototype.equalsIgnoreCase = function(s) {
                return String(this).toLowerCase() === String(s).toLowerCase();
            };
            // 万象书屋: Java String.contains → JS includes
            if (!String.prototype.contains) {
                String.prototype.contains = function(s) { return this.indexOf(s) >= 0; };
            }
            // 万象书屋: Java String.length() 是 method, JS .length 是 property
            // (无法 polyfill — JS engine 不允许给 string property 加 method 同名 length)
        })();
        """)
    }

    /// 万象书屋: 把 SyncHTTPResponse 包成 JS 对象, 暴露 .header(name) / .body() / .code() / .headers() 方法
    /// 这是 legado Connection.Response 的最小可用 shim
    private nonisolated static func makeResponseValue(_ r: SyncHTTPResponse, in ctx: JSContext) -> JSValue {
        let obj = JSValue(newObjectIn: ctx)!
        obj.setObject(r.body, forKeyedSubscript: "_body" as NSString)
        obj.setObject(r.statusCode, forKeyedSubscript: "_code" as NSString)
        obj.setObject(r.headers, forKeyedSubscript: "_headers" as NSString)
        // 字段风格 (一些源也这样用)
        obj.setObject(r.body, forKeyedSubscript: "body" as NSString)
        obj.setObject(r.statusCode, forKeyedSubscript: "code" as NSString)
        obj.setObject(r.headers, forKeyedSubscript: "headers" as NSString)
        // 方法风格 (legado 主流): .header("Location") / .body() / .code()
        let headers = r.headers
        let header: @convention(block) (String) -> String = { name in
            // case-insensitive
            return headers[name.lowercased()]
                ?? headers[name]
                ?? ""
        }
        obj.setObject(header, forKeyedSubscript: "header" as NSString)
        let bodyFn: @convention(block) () -> String = { r.body }
        obj.setObject(bodyFn, forKeyedSubscript: "body" as NSString)   // overrides field if called as method
        let codeFn: @convention(block) () -> Int = { r.statusCode }
        obj.setObject(codeFn, forKeyedSubscript: "code" as NSString)
        let headersFn: @convention(block) () -> [String: String] = { headers }
        obj.setObject(headersFn, forKeyedSubscript: "headers" as NSString)
        return obj
    }

    // MARK: - JSValue → Swift Any

    private nonisolated func jsValueToSwift(_ v: JSValue, scope: JSContextScope) -> Any? {
        if v.isNull || v.isUndefined { return nil }
        if v.isString { return v.toString() }
        if v.isBoolean { return v.toBool() }
        if v.isNumber { return v.toNumber() }
        if v.isArray {
            // 万象书屋 (M2.8 fix bug): 之前直接 `as? [Any]` 拿到的是 NSArray 元素 (NSDictionary 等),
            // 后续 stringify 里 JSONSerialization.data(withJSONObject:) 处理 NSDictionary 时
            // 偶发取不到 dict 内容 (爱下电子书 toc rule 返回 [{title, url, ...}, ...] 之后
            // selectString("title") 拿不到值 ⇒ toc 0 chapter). 显式深度递归转换.
            let raw = v.toArray() ?? []
            return raw.map { Self.deepBridgeToSwift($0) }
        }
        if v.isObject {
            let raw = v.toDictionary() ?? [:]
            return Self.deepBridgeDict(raw)
        }
        return v.toString()
    }

    /// 万象书屋: NSObject (NSArray / NSDictionary / NSNumber / NSString) 深度桥接成
    /// 纯 Swift 类型. 让 `as? [String: Any]` / `JSONSerialization` 都能稳吃.
    private nonisolated static func deepBridgeToSwift(_ x: Any) -> Any {
        if let nsd = x as? [AnyHashable: Any] {
            return deepBridgeDict(nsd)
        }
        if let nsa = x as? [Any] {
            return nsa.map { deepBridgeToSwift($0) }
        }
        if let n = x as? NSNumber { return n }
        if let s = x as? String { return s }
        // 万象书屋 (M2.8 fix bug): JSValue.toDictionary 会把对象上的 method (function) 桥成
        // ObjC block (NSMallocBlock / NSStackBlock / NSGlobalBlock). 这种东西塞进 dict 后,
        // JSONSerialization 会抛 NSInvalidArgumentException 整个进程崩.
        // 做法: 检测 block-like ObjC class 名, 替成 NSNull.
        let typeName = String(describing: type(of: x))
        if typeName.contains("Block") {
            return NSNull()
        }
        return x
    }

    private nonisolated static func deepBridgeDict(_ d: [AnyHashable: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(d.count)
        for (k, v) in d {
            let key = (k as? String) ?? String(describing: k)
            out[key] = deepBridgeToSwift(v)
        }
        return out
    }
}

// 万象书屋: 跨线程结果回传辅助 (java.startBrowserAwait 用)
//   - DispatchSemaphore + sync wait 模式下, closure 内闭包不允许直接写 var
//   - 用 final class wrap 一个 mutable field 让 Task 跨线程回填
final class _BrowserResultBox: @unchecked Sendable {
    var body: String = ""
}

/// 万象书屋: legado JS `cache.putMemory()` / `getFromMemory()` 的进程内 KV 存储.
/// 跨多次 JSEngine.evaluate (多源并发) 共享 — 番茄等源用它跨 search→info→toc 阶段传 articleid.
/// 跟 Android `io.legado.app.help.CacheManager` 内存 cache 对齐.
public final class JSEngineCache: @unchecked Sendable {
    public static let shared = JSEngineCache()
    private let lock = NSLock()
    private var memory: [String: Any] = [:]

    public func putMemory(key: String, value: Any?) {
        lock.lock(); defer { lock.unlock() }
        if let v = value { memory[key] = v }
        else { memory.removeValue(forKey: key) }
    }

    public func getMemory(key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return memory[key]
    }
}

// MARK: - 哈希工具 (CommonCrypto)

import CommonCrypto

func md5Hex(_ s: String) -> String {
    let data = Data(s.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}

func sha1Hex(_ s: String) -> String {
    let data = Data(s.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(_ s: String) -> String {
    let data = Data(s.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
    return digest.map { String(format: "%02x", $0) }.joined()
}
