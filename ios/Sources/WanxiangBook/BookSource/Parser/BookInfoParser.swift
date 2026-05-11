//
//  BookInfoParser.swift
//  万象书屋 iOS · 详情页解析
//

import Foundation

/// 万象书屋: 改为 final class, 详情解析无 mutable state, 多并发安全.
public final class BookInfoParser: @unchecked Sendable {

    public let dispatcher: SelectorDispatcher
    public let fetcher: HTTPFetcher

    public init(dispatcher: SelectorDispatcher, fetcher: HTTPFetcher = .shared) {
        self.dispatcher = dispatcher
        self.fetcher = fetcher
    }

    public func fetchInfo(of book: SearchBook, in source: BookSource) async throws -> BookInfo {
        let resp = try await fetcher.fetch(
            urlString: book.bookUrl,
            headers: source.parseHeaders(),
            sourceKey: source.bookSourceUrl,
            // 万象书屋 (M2.6 fix): 详情页 25s 超时, 跟 ContentParser 一致 (info/toc/content 三件套统一)
            requestTimeoutSec: 25
        )
        var html = resp.bodyText
        let baseUrl = resp.finalURL?.absoluteString ?? book.bookUrl

        let rule = source.ruleBookInfo ?? BookInfoRule()

        // 万象书屋: 详情页解析的 JS / 模板上下文.
        //   - book.* 字段: 来自搜索结果 (用户最关心的源数据), 这是规则里
        //     `@get:{book.bookUrl}` `{{book.author}}` 能拿到值的关键.
        //   - bookSource: 源对象, 让 @js: 里的 source.bookSourceUrl / source.header 可用
        //   - 这一步是 iOS 解析能力对齐 Android 的核心修复:
        //     之前 dispatcher 调用没传 jsContext, 规则里的 book/source 全空,
        //     所以用了 `@get:{book.xxx}` 的源 (~半数) 在详情/目录环节直接断裂.
        let scope = JSContextScope()
        scope.baseUrl = baseUrl
        scope.src = html
        scope.bookSource = source
        scope.book = Self.bookFieldsForScope(book)

        // 万象书屋: legado bookInfoInit 预处理 (yckceo「6.书源之详情→预处理规则(bookInfoInit)」)
        //   - 只能是 AllInOne 正则 (`:` 开头) 或 JS
        //   - JS 返回 JSON 对象, 后续 name/author 等规则就直接是键名 (a/b/...)
        //   - 正则 capture 后 $1/$2... 在后续规则里可用
        // 简化做法: 跑出来后把结果 JSON 序列化成新 html 字符串, 让后续 JsonPath 规则取键
        if let initRule = rule.`init`, !initRule.isEmpty {
            let preprocessed = await runBookInfoInit(initRule, html: html, baseUrl: baseUrl, source: source)
            if let p = preprocessed, !p.isEmpty {
                html = p
                scope.src = html
            }
        }

        async let nameTask = optString(rule.name, html: html, baseUrl: baseUrl, scope: scope)
        async let authorTask = optString(rule.author, html: html, baseUrl: baseUrl, scope: scope)
        async let introTask = optString(rule.intro, html: html, baseUrl: baseUrl, scope: scope)
        async let kindTask = optString(rule.kind, html: html, baseUrl: baseUrl, scope: scope)
        async let lastTask = optString(rule.lastChapter, html: html, baseUrl: baseUrl, scope: scope)
        async let updTask = optString(rule.updateTime, html: html, baseUrl: baseUrl, scope: scope)
        async let coverTask = optString(rule.coverUrl, html: html, baseUrl: baseUrl, scope: scope)
        async let tocTask = optString(rule.tocUrl, html: html, baseUrl: baseUrl, scope: scope)
        async let wcTask = optString(rule.wordCount, html: html, baseUrl: baseUrl, scope: scope)

        let name = (await nameTask)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? book.name

        let rawToc = await tocTask
        let resolvedToc = sanitizeTocUrl(
            absolutize(rawToc, baseUrl: baseUrl),
            fallbackBookUrl: book.bookUrl
        )

        return BookInfo(
            bookUrl: book.bookUrl,
            name: name,
            author: (await authorTask)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? book.author,
            intro: await introTask,
            kind: await kindTask,
            coverUrl: absolutize(await coverTask, baseUrl: baseUrl) ?? book.coverUrl,
            tocUrl: resolvedToc,
            lastChapter: await lastTask,
            updateTime: await updTask,
            wordCount: await wcTask
        )
    }

    private func optString(_ rule: String?, html: String, baseUrl: String?, scope: JSContextScope? = nil) async -> String? {
        guard let rule, !rule.isEmpty else { return nil }
        return try? await dispatcher.selectString(rule: rule, source: html, baseUrl: baseUrl, jsContext: scope)
    }

    /// 万象书屋: 把 SearchBook 字段拍平成 [String:Any] 给 JSContextScope.book 用.
    /// 跟 Android `RuleData.put`/`Book.toMap` 对齐: 只放规则里常用的字段名,
    /// 都用 String 值, JS 里 book.author 直接拿到字符串.
    nonisolated static func bookFieldsForScope(_ book: SearchBook) -> [String: Any] {
        var dict: [String: Any] = [
            "name": book.name,
            "author": book.author,
            "bookUrl": book.bookUrl,
            "origin": book.origin,
            "originName": book.originName,
        ]
        if let v = book.coverUrl { dict["coverUrl"] = v }
        if let v = book.intro { dict["intro"] = v }
        if let v = book.kind { dict["kind"] = v }
        if let v = book.lastChapter { dict["lastChapter"] = v }
        if let v = book.updateTime { dict["updateTime"] = v }
        if let v = book.wordCount { dict["wordCount"] = v }
        return dict
    }

    /// 万象书屋: 处理详情页预处理规则 bookInfoInit
    /// - 以 `:` 开头  → AllInOne 正则模式: 提取 capture groups, 拼成 JSON 数组返回
    /// - 含 `<js>...</js>` 或以 `@js:` 开头  → 跑 JS, 期望返回 object/string, 序列化成 JSON 返回
    /// - 其他情况  → 当成普通规则 (CSS/XPath/JsonPath) 跑, 返回单值字符串
    private func runBookInfoInit(_ rule: String, html: String, baseUrl: String, source: BookSource) async -> String? {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        // AllInOne 正则
        if trimmed.hasPrefix(":") {
            let pattern = String(trimmed.dropFirst())
            guard !pattern.isEmpty,
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
                return nil
            }
            let nsstr = html as NSString
            guard let m = regex.firstMatch(in: html, range: NSRange(0..<nsstr.length)) else { return nil }
            // 把每个 capture group 拼成 {"$1": "...", "$2": "..."} 让后续 JsonPath 规则能取
            var dict: [String: String] = [:]
            for i in 1..<m.numberOfRanges {
                let r = m.range(at: i)
                if r.location != NSNotFound {
                    dict["$\(i)"] = nsstr.substring(with: r)
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return nil
        }
        // JS / 其他
        let v = try? await dispatcher.selectString(rule: trimmed, source: html, baseUrl: baseUrl)
        return v
    }

    nonisolated func absolutize(_ url: String?, baseUrl: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        guard let base = baseUrl, let baseURL = URL(string: base) else { return url }
        return URL(string: url, relativeTo: baseURL)?.absoluteString ?? url
    }

    /// 万象书屋: 一批源的 ruleBookInfo.tocUrl 写得很泛 (如 `.item a@href`),
    /// 在详情页会误抽到站点首页 / 搜索页等非目录 URL。Android 侧通常后续规则还能容忍,
    /// iOS 直接拿这个 URL 抓目录就会 toc=0。这里做保守兜底:
    /// - 空 URL → bookUrl
    /// - 抽到同域根路径 `/` → bookUrl
    /// - 抽到明显搜索/首页路径 → bookUrl
    nonisolated private func sanitizeTocUrl(_ toc: String?, fallbackBookUrl: String) -> String {
        guard let toc, !toc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallbackBookUrl
        }
        let trimmed = toc.trimmingCharacters(in: .whitespacesAndNewlines)
        // 万象书屋 (M2.8 fix bug): 七星阁等源 ruleBookInfo.tocUrl 写法太泛, 抽出来的是
        // HTML 段落而不是 URL (e.g. "<header> <div...>"). 这种内容 URL(string:) 不会返
        // nil — Foundation URL 接受很多奇怪字符串. 必须显式过滤: 包含 < > 或换行 → 不是 URL.
        if trimmed.contains("<") || trimmed.contains(">") ||
           trimmed.contains("\n") || trimmed.contains(" ") {
            return fallbackBookUrl
        }
        // 万象书屋 (M2.8 fix bug): 言情小说吧等源 tocUrl JS 返回 ajax response 整对象
        // (`{"headers":...}`), HTTPFetcher 拿这字符串当 URL ⇒ "非法 URL: {...}". 过滤
        // JSON 段(以 `{`/`[` 开头)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return fallbackBookUrl
        }
        // 万象书屋: tocUrl 不是 http/https 也不行 (相对路径 absolutize 后应该已经带 scheme)
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            return fallbackBookUrl
        }
        guard let u = URL(string: trimmed) else { return fallbackBookUrl }
        let path = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if path.isEmpty { return fallbackBookUrl }
        let badPathFragments = ["search", "s.php", "index", "home"]
        if badPathFragments.contains(where: { path == $0 || path.hasPrefix($0 + ".") }) {
            return fallbackBookUrl
        }
        return trimmed
    }
}
