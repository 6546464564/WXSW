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

/// 万象书屋: 改为 final class 让多源 search 真并发跑.
/// 之前 `actor` 把所有源的 search 串行化, 32 源耗时 30-90s; 改后 5-15s 跟 Android 持平.
/// 内部无 mutable state (3 个属性都是 let), 多线程安全; JS 求值仍走 JSEngine actor 串行,
/// HTTP/HTML 解析变并发.
public final class SearchParser: @unchecked Sendable {

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

        // 万象书屋: 限速钩子 — 单源 concurrentRate 控制并发节流
        //   - legado JSON: "concurrentRate": "200" / "1000,2"  (毫秒/次 或 ms/N)
        //   - 跟 Android ConcurrentRateLimiter.withLimit 对齐
        //   - 没限速 iOS 多源并发搜索时一秒打 30+ 次同一站点, 触发反爬封 IP
        await SourceRateLimiter.shared.acquire(source: source)

        // 万象书屋: 显式 `,{webView:true}` 优先 WK 渲染, 不走 URLSession.
        //   - 对应 legado UrlOption.webView. 这个标志位的本意是
        //     "这个 URL 必须在浏览器里跑过 JS 才能拿到 DOM" (SPA + Cloudflare 必经).
        //   - 之前 iOS 解出来但没消费, 0 命中才走启发式回退. 显式声明的源因此
        //     第一次都失败一次, 浪费一次握手 + 触发反爬计数.
        //   - 仅 GET 走 WK; POST 表单类的 webView:true 比较罕见, 不做改造.
        var bodyText: String
        var finalBaseUrl: String
        if rendered.useWebView, rendered.method.uppercased() == "GET" {
            let bridge = await BrowserBridgeRegistry.shared.get()
            if let html = await bridge.loadAndWait(
                url: rendered.url, expectedKeyword: key, timeout: 25
            ), !html.isEmpty {
                bodyText = html
                finalBaseUrl = rendered.url
            } else {
                // WK 失败回退到 URLSession (一些源 webView:true 是冗余声明)
                let resp = try await fetcher.fetch(
                    urlString: rendered.url,
                    method: rendered.method,
                    body: rendered.body,
                    headers: source.parseHeaders().merging(rendered.headers, uniquingKeysWith: { _, b in b }),
                    sourceKey: source.bookSourceUrl,
                    retries: rendered.retry ?? 1   // 万象书屋 (M2.4 perf): search 不 retry, 单源失败立即让位多源并发
                )
                bodyText = resp.bodyText
                finalBaseUrl = resp.finalURL?.absoluteString ?? rendered.url
            }
        } else {
            // 万象书屋 (M2.8 fix): GET 拿到 4xx 时, 不抛错, 让下面 0-hit 启发式 fallback
            // 用 BrowserBridge 重新拉. 顶点小说 / 随梦小说网等 Cloudflare 反爬源直接 400,
            // 之前 throw 跳出 → 反爬源永远 search_fail. 现在 catch 错误后给空 bodyText 走
            // webview fallback. (POST 不能这么做, 因为 webview 重放 GET URL 不带 body.)
            do {
                let resp = try await fetcher.fetch(
                    urlString: rendered.url,
                    method: rendered.method,
                    body: rendered.body,
                    headers: source.parseHeaders().merging(rendered.headers, uniquingKeysWith: { _, b in b }),
                    sourceKey: source.bookSourceUrl,
                    retries: rendered.retry ?? 1
                )
                bodyText = resp.bodyText
                finalBaseUrl = resp.finalURL?.absoluteString ?? rendered.url
            } catch {
                // GET 拿 4xx/5xx — 留给后面 webview fallback 重新拉. POST 直接 rethrow.
                if rendered.method.uppercased() == "GET" {
                    bodyText = ""
                    finalBaseUrl = rendered.url
                } else {
                    throw error
                }
            }
        }

        // 2. 选书列表
        let scope = JSContextScope()
        scope.baseUrl = finalBaseUrl
        scope.src = bodyText
        scope.key = key
        scope.page = page
        scope.bookSource = source

        var nodes = try await dispatcher.selectList(
            rule: listSelector,
            source: bodyText,
            baseUrl: scope.baseUrl,
            jsContext: scope
        )

        // 万象书屋: 0 hit 时尝试 WKWebView — (1) SPA 壳 (2) GET + 403/Cloudflare 挑战页
        // (3) 万象书屋 M2.8 新增: bodyText 空 (上面 catch 4xx 留空) 也触发 webview 兜底.
        // 对齐 legado AnalyzeUrl.useWebView / BackstageWebView. POST 表单搜索无法简单用 GET URL 重放, 跳过.
        // 注: useWebView=true 已在上面优先 WK, 这里走的是隐式启发式回退.
        if nodes.isEmpty, !rendered.useWebView {
            let isSPA = bodyText.contains("data-n-head-ssr")
                     || bodyText.contains("__NUXT__")
                     || bodyText.contains("__NEXT_DATA__")
                     || bodyText.contains(#"id="__nuxt""#)
            let cfWall = bodyText.localizedCaseInsensitiveContains("just a moment")
                || bodyText.contains("__cf_chl")
                || bodyText.contains("cf-browser-verification")
                || bodyText.localizedCaseInsensitiveContains("attention required")
            // 万象书屋 (M2.8 fix): bodyText 空 (4xx HTTP fail) 也算反爬, 走 webview
            let httpFail = bodyText.isEmpty
            let allowWebRetry = isSPA
                || (rendered.method.uppercased() == "GET" && (cfWall || httpFail))
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

    /// 从单个书节点抽字段.
    ///
    /// 万象书屋 (D-25 fix · P0): **必须串行解析, 不能 async let 并发**.
    ///   - 部分源 (例: QQ浏览器柳树) 在 ruleSearch.bookUrl 用 `{{book.kind}}` 模板,
    ///     bookUrl 必须在 kind 解析后再解析, 否则 {{book.kind}} 求值为空 →
    ///     bookUrl 全部退化成相同的 query, 19 本书在 UI 上变成同一本.
    ///   - Android Legado (`SearchData.analyzeSearchBook`) 也是顺序解析并把
    ///     每个字段回写到 `book` map, 让后续模板能引用. 这里对齐它的语义.
    private func extractBook(rule: SearchRule, nodeHtml: String, baseUrl: String?, source: BookSource) async throws -> SearchBook? {
        let scope = JSContextScope()
        scope.baseUrl = baseUrl
        scope.src = nodeHtml
        scope.bookSource = source
        scope.book = [:]

        // 顺序: name → author → kind → lastChapter → intro → coverUrl → updateTime → wordCount → bookUrl
        // 每解析完一个就 publish 进 scope.book, 让后续字段的模板能引用.
        let name = (await optString(rule.name, html: nodeHtml, baseUrl: baseUrl, scope: scope))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        scope.book?["name"] = name

        let author = (await optString(rule.author, html: nodeHtml, baseUrl: baseUrl, scope: scope)) ?? ""
        scope.book?["author"] = author

        let kind = await optString(rule.kind, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        scope.book?["kind"] = kind ?? ""

        let lastChapter = await optString(rule.lastChapter, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        scope.book?["lastChapter"] = lastChapter ?? ""

        let rawIntro = await optString(rule.intro, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        scope.book?["intro"] = rawIntro ?? ""

        let cover = await optString(rule.coverUrl, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        scope.book?["coverUrl"] = cover ?? ""

        let updateTime = await optString(rule.updateTime, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        scope.book?["updateTime"] = updateTime ?? ""

        let wordCount = await optString(rule.wordCount, html: nodeHtml, baseUrl: baseUrl, scope: scope)
        scope.book?["wordCount"] = wordCount ?? ""

        // bookUrl 必须最后解析, 才能用到上面所有 {{book.xxx}} 模板.
        let bookUrl = (await optString(rule.bookUrl, html: nodeHtml, baseUrl: baseUrl, scope: scope))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, !bookUrl.isEmpty else { return nil }

        let cleanIntro = sanitizeIntro(rawIntro, author: author, name: name)
        return SearchBook(
            origin: source.bookSourceUrl,
            originName: source.bookSourceName,
            name: name,
            author: author,
            bookUrl: absolutize(bookUrl, baseUrl: baseUrl),
            coverUrl: absolutize(cover, baseUrl: baseUrl),
            intro: cleanIntro,
            kind: kind,
            lastChapter: lastChapter,
            updateTime: updateTime,
            wordCount: wordCount
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
