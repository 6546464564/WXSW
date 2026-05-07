//
//  SearchParser.swift
//  万象书屋 iOS · 搜索结果解析
//
//  对应 Android: io.legado.app.model.webBook.BookList.analyzeBookList (search 部分)
//
//  流程:
//   1. 渲染 searchUrl + 替换 {{key}} → fetch HTTP
//   2. 用 ruleSearch.bookList 选出书列表节点 [String]
//   3. 对每个节点用其余字段选择器抽 name/author/coverUrl/...
//   4. 拼成 [SearchBook]
//

import Foundation

public actor SearchParser {

    public let dispatcher: SelectorDispatcher
    public let fetcher: HTTPFetcher
    public let jsEngine: JSEngine

    public init(dispatcher: SelectorDispatcher, fetcher: HTTPFetcher = .shared, jsEngine: JSEngine) {
        self.dispatcher = dispatcher
        self.fetcher = fetcher
        self.jsEngine = jsEngine
    }

    public func search(in source: BookSource, key: String, page: Int = 1) async throws -> [SearchBook] {
        guard let searchUrlTemplate = source.searchUrl, !searchUrlTemplate.isEmpty else {
            throw BookSourceEngineError.missingSearchUrl
        }
        guard let rule = source.ruleSearch, let listSelector = rule.bookList, !listSelector.isEmpty else {
            throw BookSourceEngineError.missingRule("ruleSearch.bookList")
        }

        // 1. 渲染 + fetch (async 版: 真执行 <js>...</js> + 注入 source/cookie/host)
        let rendered = await URLTemplate.renderAsync(
            searchUrlTemplate, bookSource: source, jsEngine: jsEngine,
            baseURL: source.bookSourceUrl, key: key, page: page
        )
        let resp = try await fetcher.fetch(
            urlString: rendered.url,
            method: rendered.method,
            body: rendered.body,
            headers: source.parseHeaders().merging(rendered.headers, uniquingKeysWith: { _, b in b }),
            sourceKey: source.bookSourceUrl,
            retries: rendered.retry ?? 3
        )

        // 2. 选书列表
        let scope = JSContextScope()
        scope.baseUrl = resp.finalURL?.absoluteString ?? rendered.url
        scope.src = resp.bodyText
        scope.key = key
        scope.page = page
        scope.bookSource = source

        var bodyText = resp.bodyText
        var nodes = try await dispatcher.selectList(
            rule: listSelector,
            source: bodyText,
            baseUrl: scope.baseUrl,
            jsContext: scope
        )

        // 万象书屋: 0 hit 时尝试 WKWebView — (1) SPA 壳 (2) GET + 403/Cloudflare 挑战页
        // 对齐 legado AnalyzeUrl.useWebView / BackstageWebView. POST 表单搜索无法简单用 GET URL 重放, 跳过.
        if nodes.isEmpty {
            let isSPA = bodyText.contains("data-n-head-ssr")
                     || bodyText.contains("__NUXT__")
                     || bodyText.contains("__NEXT_DATA__")
                     || bodyText.contains(#"id="__nuxt""#)
            let cfWall = bodyText.localizedCaseInsensitiveContains("just a moment")
                || bodyText.contains("__cf_chl")
                || bodyText.contains("cf-browser-verification")
                || bodyText.localizedCaseInsensitiveContains("attention required")
            let clientErr = (400..<500).contains(resp.statusCode)
            let allowWebRetry = isSPA
                || (rendered.method.uppercased() == "GET" && (cfWall || clientErr))
            if allowWebRetry {
                let bridge = await BrowserBridgeRegistry.shared.get()
                if let renderedHtml = await bridge.loadAndWait(
                    url: rendered.url, expectedKeyword: key, timeout: 25
                ), renderedHtml.count > min(500, bodyText.count) {
                    bodyText = renderedHtml
                    scope.src = renderedHtml
                    nodes = try await dispatcher.selectList(
                        rule: listSelector, source: bodyText,
                        baseUrl: scope.baseUrl, jsContext: scope
                    )
                }
            }
        }

        _ = bodyText  // suppress unused after SPA branch
        // 3. 对每个节点抽字段
        var results: [SearchBook] = []
        results.reserveCapacity(nodes.count)
        for node in nodes {
            let book = try await extractBook(rule: rule, nodeHtml: node, baseUrl: scope.baseUrl, source: source)
            if let book, !isNoiseSearchResult(book) {
                results.append(book)
            }
        }
        return results
    }

    /// 万象书屋: 过滤明显不是书籍的公告/登录提示/站点说明.
    /// 一些 JSON API (99书吧等) 会把公告混在搜索数组第一项, 旧逻辑会把公告展示成搜索结果。
    private nonisolated func isNoiseSearchResult(_ book: SearchBook) -> Bool {
        let text = "\(book.name) \(book.author) \(book.intro ?? "") \(book.bookUrl)".lowercased()
        let noiseKeywords = [
            "公告", "最新公告", "站点公告", "使用说明", "请登录", "未登录",
            "登录后使用", "注册", "客服", "telegram", "tg频道"
        ]
        if noiseKeywords.contains(where: { text.contains($0.lowercased()) }) {
            return true
        }
        // 很短的伪 URL / 站点关键字也丢掉
        if book.bookUrl.contains("shubas") || book.bookUrl.contains("notice") {
            return true
        }
        return false
    }

    /// 从单个书节点抽字段
    private func extractBook(rule: SearchRule, nodeHtml: String, baseUrl: String?, source: BookSource) async throws -> SearchBook? {
        // 万象书屋: 子字段抽取也要带 source/cookie/host JS context
        let scope = JSContextScope()
        scope.baseUrl = baseUrl
        scope.src = nodeHtml
        scope.bookSource = source

        async let nameTask = optString(rule.name, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        async let authorTask = optString(rule.author, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        async let bookUrlTask = optString(rule.bookUrl, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        async let coverTask = optString(rule.coverUrl, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        async let introTask = optString(rule.intro, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        async let kindTask = optString(rule.kind, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        async let lastTask = optString(rule.lastChapter, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        async let updTask = optString(rule.updateTime, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        async let wcTask = optString(rule.wordCount, html: nodeHtml, baseUrl: baseUrl, scope: scope)

        let name = (await nameTask)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bookUrl = (await bookUrlTask)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, !bookUrl.isEmpty else { return nil }

        let author = (await authorTask) ?? ""
        // 万象书屋: 部分源 intro 规则错位拿到 "作者:xxx" 这种, 自动 sanitize
        let rawIntro = await introTask
        let cleanIntro = sanitizeIntro(rawIntro, author: author, name: name)
        return SearchBook(
            origin: source.bookSourceUrl,
            originName: source.bookSourceName,
            name: name,
            author: author,
            bookUrl: absolutize(bookUrl, baseUrl: baseUrl),
            coverUrl: absolutize(await coverTask, baseUrl: baseUrl),
            intro: cleanIntro,
            kind: await kindTask,
            lastChapter: await lastTask,
            updateTime: await updTask,
            wordCount: await wcTask
        )
    }

    /// 万象书屋: intro 净化
    /// - 去掉重复的"作者:xxx"前缀(小说之家 等源规则错位)
    /// - 去掉"书名:xxx" / "作者:" 等无意义前缀
    /// - 多余空白合并
    private nonisolated func sanitizeIntro(_ raw: String?, author: String, name: String) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        // "作者: 天蚕土豆" / "作者：天蚕土豆"
        let prefixes = ["作者:", "作者:", "作者：", "Author:", "Author:"]
        for p in prefixes {
            if s.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if s == author || s.hasPrefix(author + " ") || s.hasPrefix(author) {
                    return nil   // 整段就是"作者: xxx", 没真 intro
                }
            }
        }
        // 去掉 "书名: xxx" 前缀
        for p in ["书名:", "书名:", "书名："] {
            if s.hasPrefix(p) {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if s == name { return nil }
            }
        }
        // 全是 author 重复
        if s == author || s == "作者:\(author)" || s == "作者：\(author)" {
            return nil
        }
        // 合并多余空白
        s = s.replacingOccurrences(of: "[\\s\u{3000}]+", with: " ", options: .regularExpression)
        return s.isEmpty ? nil : s
    }

    private func optString(_ rule: String?, html: String, baseUrl: String?, scope: JSContextScope? = nil) async -> String? {
        guard let rule, !rule.isEmpty else { return nil }
        return try? await dispatcher.selectString(rule: rule, source: html, baseUrl: baseUrl, jsContext: scope)
    }

    /// 万象书屋: 把相对 URL 拼成绝对 URL
    nonisolated func absolutize(_ url: String?, baseUrl: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        guard let base = baseUrl, let baseURL = URL(string: base) else { return url }
        return URL(string: url, relativeTo: baseURL)?.absoluteString ?? url
    }
}

// 重载 absolutize 接非可选输入
extension SearchParser {
    nonisolated func absolutize(_ url: String, baseUrl: String?) -> String {
        absolutize(url as String?, baseUrl: baseUrl) ?? url
    }
}
