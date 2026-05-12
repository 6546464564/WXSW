//
//  TocParser.swift
//  万象书屋 iOS · 目录解析
//
//  特性:
//   - 支持 nextTocUrl 多页目录翻页 (限制最多 50 页防死循环)
//   - 章节去重 (按 url + title)
//   - 按 chapterIndex 0-based 重新编号
//

import Foundation

/// 万象书屋: 改为 final class, 目录解析无 mutable state, 多并发安全.
public final class TocParser: @unchecked Sendable {

    public let dispatcher: SelectorDispatcher
    public let fetcher: HTTPFetcher
    public let jsEngine: JSEngine
    public static let maxTocPages = 50

    public init(dispatcher: SelectorDispatcher, fetcher: HTTPFetcher = .shared, jsEngine: JSEngine? = nil) {
        self.dispatcher = dispatcher
        self.fetcher = fetcher
        self.jsEngine = jsEngine ?? dispatcher.js
    }

    public func fetchToc(of info: BookInfo, in source: BookSource) async throws -> [BookChapter] {
        guard let rule = source.ruleToc, let listSelector = rule.chapterList, !listSelector.isEmpty else {
            throw BookSourceEngineError.missingRule("ruleToc.chapterList")
        }

        var chapters: [BookChapter] = []
        var seenKeys = Set<String>()
        // 万象书屋: legado nextTocUrl 文档支持「单 URL / URL 数组 / JS 一次返多页」
        // 跟 ContentParser 一致用 queue + visited
        var queue: [String] = [info.tocUrl ?? info.bookUrl]
        var visitedPages = Set<String>()
        var pageCount = 0

        // 万象书屋: 目录解析 JS / 模板上下文 (修复点同 BookInfoParser).
        //   - book.* 来自详情页结果, 让 chapterList JS / chapterName / chapterUrl 规则
        //     里的 `@get:{book.bookUrl}` `source.bookSourceUrl` 等可用
        //   - 一些目录 JS 用 `<js>if(result.includes('Cloudflare')) ... ajax(baseUrl)</js>`
        //     模板里 baseUrl/source 都靠这个 scope.
        let scopeBook = Self.bookFieldsForScope(info)

        while !queue.isEmpty, pageCount < Self.maxTocPages {
            let currentUrl = queue.removeFirst()
            if visitedPages.contains(currentUrl) { continue }
            visitedPages.insert(currentUrl)
            pageCount += 1
            // 万象书屋: 目录多页 (nextTocUrl 抓数十页) 也走 concurrentRate 限速,
            // 跟 Search/Content 一致避免封 IP.
            await SourceRateLimiter.shared.acquire(source: source)
            // 万象书屋 (2026-05-12): 改走 URLTemplate.legadoFetch — 对齐 Android AnalyzeUrl.
            //   tocUrl / nextTocUrl 里的 `,{method:'POST',body:'...'}` `,{webView:true}` 现在生效.
            let (html, baseUrl) = try await URLTemplate.legadoFetch(
                urlString: currentUrl,
                in: source,
                jsEngine: jsEngine,
                fetcher: fetcher,
                retries: 1,
                // 万象书屋 (M2.6 fix): 目录页 (大书可能 1-2MB HTML) 25s 超时, 跟 ContentParser 一致
                requestTimeoutSec: 25
            )
            let pageScope = JSContextScope()
            pageScope.baseUrl = baseUrl
            pageScope.src = html
            pageScope.bookSource = source
            pageScope.book = scopeBook

            let nodes = try await dispatcher.selectList(
                rule: listSelector, source: html, baseUrl: baseUrl, jsContext: pageScope
            )

            for node in nodes {
                // 万象书屋 (P0 fix): legado chapterName = "text" / "@text" 都是"取节点 text"
                // chapterUrl = "href" / "@href" 都是"取节点 href"
                // 不能直接当 css selector 跑, 必须走属性提取
                let nodeScope = JSContextScope()
                nodeScope.baseUrl = baseUrl
                nodeScope.src = node
                nodeScope.bookSource = source
                nodeScope.book = scopeBook

                // 万象书屋 (M2.8 fix bug): node 是 JSON object 时 (chapterList JS 返回 dict 数组,
                // e.g. 爱下电子书), chapterName="title" / chapterUrl="url" 是 JSON 字段名.
                // 不能 normalizeSimpleAttr 转成 `body > *@title` 走 CSS 取属性.
                // 改成用 nodeIsJsonObject 探测, JSON node 直接走 JSONPath `$.title`.
                // JSON 节点上的 `@js: result.xxx` 由 LegadoRuleEngine.runJS 内 `coerceJsResultValue` 解析.
                let nodeIsJson = isJsonObjectString(node)
                let rawName = rule.chapterName ?? "text"
                let rawUrl = rule.chapterUrl ?? "href"
                let nameRule = nodeIsJson ? jsonPathify(rawName) : normalizeSimpleAttr(rawName)
                let urlRule = nodeIsJson ? jsonPathify(rawUrl) : normalizeSimpleAttr(rawUrl)
                let title = (try? await dispatcher.selectString(
                    rule: nameRule, source: node, baseUrl: baseUrl, jsContext: nodeScope
                ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let url = (try? await dispatcher.selectString(
                    rule: urlRule, source: node, baseUrl: baseUrl, jsContext: nodeScope
                )) ?? ""

                if title.isEmpty { continue }
                let abs = absolutize(url, baseUrl: baseUrl) ?? url
                // 万象书屋: legado URL 后缀约定 (yckceo 文档「章节信息(ChapterInfo)」)
                //   /chapter/x.html#vip  → VIP 标志
                //   /chapter/x.html#pay  → 付费章
                //   /chapter/x.html#dur=120  → 音频时长 (秒)
                //   /chapter/x.html#title=备用标题
                //   /chapter/x.html,{"webView":true}  → 章节单独请求选项 (HTTPFetcher 处理)
                let (cleanUrl, urlSuffixVip, urlSuffixPay) = peelChapterUrlSuffix(abs)
                let key = "\(title)::\(cleanUrl)"
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)

                // 万象书屋 (M2.8 fix bug 续): updateTime / isVolume / isVip / isPay 也按
                // node 是不是 JSON 选 jsonPathify (爱下 toc 用 "n" 字段做 updateTime).
                let normUpd = nodeIsJson ? jsonPathify(rule.updateTime ?? "") : (rule.updateTime ?? "")
                let isVolume = await readBoolFlag(maybeJsonPathify(rule.isVolume, json: nodeIsJson), html: node, baseUrl: baseUrl, scope: nodeScope)
                let vipFromRule = await readBoolFlag(maybeJsonPathify(rule.isVip, json: nodeIsJson), html: node, baseUrl: baseUrl, scope: nodeScope)
                let payFromRule = await readBoolFlag(maybeJsonPathify(rule.isPay, json: nodeIsJson), html: node, baseUrl: baseUrl, scope: nodeScope)
                let isVip = urlSuffixVip || vipFromRule
                let isPay = urlSuffixPay || payFromRule
                let upd = (try? await dispatcher.selectString(
                    rule: normUpd,
                    source: node,
                    baseUrl: baseUrl,
                    jsContext: nodeScope
                ))

                chapters.append(BookChapter(
                    chapterIndex: chapters.count,
                    chapterUrl: cleanUrl.isEmpty ? nil : cleanUrl,
                    title: title,
                    isVolume: isVolume,
                    isVip: isVip,
                    isPay: isPay,
                    updateTime: upd
                ))
            }

            // 多页翻页 — 优先 selectList (兼容 JS 返数组), 否则退化 selectString
            if let nextRule = rule.nextTocUrl, !nextRule.isEmpty {
                let nextList = (try? await dispatcher.selectList(
                    rule: nextRule, source: html, baseUrl: baseUrl, jsContext: pageScope
                )) ?? []
                let candidates: [String]
                if nextList.count > 1 {
                    candidates = nextList
                } else if let single = try? await dispatcher.selectString(
                    rule: nextRule, source: html, baseUrl: baseUrl, jsContext: pageScope), !single.isEmpty {
                    candidates = [single]
                } else {
                    candidates = []
                }
                for raw in candidates {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    // legado 约定: JS 返 `""` / `null` / `[]` 时停止
                    if trimmed.isEmpty || trimmed == "null" || trimmed == "[]" { continue }
                    // 万象书屋 (M2.8 fix bug): absolutize 返 nil 表示这不是合法 URL
                    // (JSON 段/HTML 段). 不要 `?? trimmed` 把垃圾当 URL fetch.
                    guard let abs = absolutize(trimmed, baseUrl: baseUrl) else { continue }
                    if !visitedPages.contains(abs) { queue.append(abs) }
                }
            }
        }

        return chapters
    }

    private func readBoolFlag(_ rule: String?, html: String, baseUrl: String?, scope: JSContextScope? = nil) async -> Bool {
        guard let rule, !rule.isEmpty else { return false }
        let v = try? await dispatcher.selectString(rule: rule, source: html, baseUrl: baseUrl, jsContext: scope)
        guard let v, !v.isEmpty else { return false }
        return ["1", "true", "yes"].contains(v.lowercased())
    }

    /// 万象书屋: 把 BookInfo 字段拍平成 [String:Any] 给 JSContextScope.book 用.
    /// 详情结果是目录链路里 `@get:{book.author}` `{{book.kind}}` 等模板的来源.
    nonisolated static func bookFieldsForScope(_ info: BookInfo) -> [String: Any] {
        var dict: [String: Any] = [
            "name": info.name,
            "author": info.author,
            "bookUrl": info.bookUrl,
        ]
        if let v = info.coverUrl { dict["coverUrl"] = v }
        if let v = info.intro { dict["intro"] = v }
        if let v = info.kind { dict["kind"] = v }
        if let v = info.tocUrl { dict["tocUrl"] = v }
        if let v = info.lastChapter { dict["lastChapter"] = v }
        if let v = info.updateTime { dict["updateTime"] = v }
        if let v = info.wordCount { dict["wordCount"] = v }
        return dict
    }

    /// 万象书屋: legado 单属性关键字处理
    /// chapterName="text" / chapterUrl="href" 等是"对节点本身提取属性"
    /// SwiftSoup 解 partial HTML 时把 snippet 包进 `<html><body>`, 所以用 "body 内首个有内容的元素" 提取
    private nonisolated func normalizeSimpleAttr(_ rule: String) -> String {
        let attrs: Set<String> = ["text", "owntext", "html", "innerhtml", "outerhtml",
                                  "href", "src", "alt", "title", "value", "content"]
        let lower = rule.lowercased()
        if attrs.contains(lower) {
            // body > * 取 body 第一个子元素 (即 node 本身), 然后 @attr 提取属性
            return "body > *@\(lower)"
        }
        // 万象书屋 (M2.8 fix bug): 含 ## 链式正则的 rule, 拆出 base 部分单独 normalize.
        // 猕猴桃漫画 chapterUrl = `href##(\d+)$##/api/comic/image/$1?page=1###`,
        // base "href" 必须 normalize 成 `body > *@href` 才能在 <a> 节点上取到属性.
        if rule.contains("##") {
            let parts = rule.components(separatedBy: "##")
            if let first = parts.first, attrs.contains(first.lowercased()) {
                let normalized = "body > *@\(first.lowercased())"
                let rest = parts.dropFirst().joined(separator: "##")
                return normalized + "##" + rest
            }
        }
        return rule
    }

    /// 万象书屋 (M2.8 fix bug): node 是 JSON dict 字符串时, 把**简单字段名** "title" / "url"
    /// 转成 JSONPath `$.title` / `$.url`. 但要排除以下不该加 $. 前缀的情况:
    ///   - 已经带前缀 ($./@/// 等)
    ///   - 是完整 URL (含 :// , 番茄等源 chapterUrl 是 URL 模板)
    ///   - 含 mustache 模板 {{ (要 expandTemplate 自己展开)
    ///   - 含 @get / @put 指令
    ///   - 含 ## 链式正则
    ///   - 含 || && 复合规则
    private nonisolated func jsonPathify(_ rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return trimmed }
        if trimmed.hasPrefix("$") || trimmed.hasPrefix("@") || trimmed.hasPrefix("//") {
            return trimmed
        }
        if trimmed.contains("://") || trimmed.contains("{{") ||
           trimmed.contains("@get") || trimmed.contains("@put") ||
           trimmed.contains("##") || trimmed.contains("||") || trimmed.contains("&&") {
            return trimmed
        }
        return "$." + trimmed
    }

    private nonisolated func maybeJsonPathify(_ rule: String?, json: Bool) -> String? {
        guard let rule, !rule.isEmpty else { return rule }
        return json ? jsonPathify(rule) : rule
    }

    /// 万象书屋 (M2.8 fix bug): 判 source 是不是单个 JSON object (开头 {).
    /// 用来探测 chapterList JS 返回 dict 数组之后, 每个 node 是 JSON 字段表而不是 HTML.
    private nonisolated func isJsonObjectString(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") && t.hasSuffix("}")
    }

    /// 万象书屋: 剥 legado 章节 URL 末尾的 `#vip` / `#pay` / `#dur=` 等元信息后缀,
    /// 返回 (clean, isVip, isPay)
    /// 注意: `,{...}` 选项后缀保留 — HTTPFetcher 会按 legado URL 选项 DSL 解
    nonisolated private func peelChapterUrlSuffix(_ url: String) -> (clean: String, isVip: Bool, isPay: Bool) {
        guard !url.isEmpty else { return ("", false, false) }
        // 找最右 `#` (跳过 `,{...}` 块内部, 但实际上 legado 把 # 放选项块前)
        var optionsTail = ""
        var head = url
        if let r = url.range(of: ",{") {
            optionsTail = String(url[r.lowerBound...])
            head = String(url[..<r.lowerBound])
        }
        var isVip = false
        var isPay = false
        if let hashRange = head.range(of: "#", options: .backwards) {
            let tag = String(head[hashRange.upperBound...]).lowercased()
            if !tag.isEmpty {
                let firstSeg = tag.split(separator: "&").first.map(String.init) ?? tag
                if firstSeg == "vip" { isVip = true }
                if firstSeg == "pay" { isPay = true }
                // 仅当尾段是已识别的元信息标志才剥; 否则可能是真正的 fragment, 保留
                let known: Set<String> = ["vip", "pay"]
                let isMetaTag = known.contains(firstSeg) || firstSeg.hasPrefix("dur=") || firstSeg.hasPrefix("title=")
                if isMetaTag {
                    head = String(head[..<hashRange.lowerBound])
                }
            }
        }
        return (head + optionsTail, isVip, isPay)
    }

    nonisolated func absolutize(_ url: String?, baseUrl: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        // 万象书屋 (M2.8 fix bug): 跟 BookInfoParser.absolutize 同步, 拦 JSON / HTML 段.
        // 言情小说吧等源 nextTocUrl JS 返 ajax response object 当下一页 URL,
        // 走到 fetcher 抛 "非法 URL: {...}".
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ||
           trimmed.hasPrefix("<") || trimmed.contains("\n") {
            return nil
        }
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        guard let base = baseUrl, let baseURL = URL(string: base) else { return url }
        return URL(string: url, relativeTo: baseURL)?.absoluteString ?? url
    }
}
