//
//  ContentParser.swift
//  万象书屋 iOS · 章节正文解析
//
//  特性:
//   - 多页正文 (nextContentUrl) 自动拼接
//   - 净化替换 (sourceRegex / replaceRegex)
//   - 段落分割 (按双换行 / 单换行)
//   - 图片提取 (从正文 HTML 抽 <img src>)
//

import Foundation

/// 万象书屋: 改为 final class, 正文解析无 mutable state, 多并发安全.
public final class ContentParser: @unchecked Sendable {

    public let dispatcher: SelectorDispatcher
    public let fetcher: HTTPFetcher
    public static let maxContentPages = 20

    public init(dispatcher: SelectorDispatcher, fetcher: HTTPFetcher = .shared) {
        self.dispatcher = dispatcher
        self.fetcher = fetcher
    }

    /// 万象书屋: 正文解析入口
    /// - parameter book: 调用方传入的当前书 (用来做 `@get:{book.bookUrl}` 模板).
    ///   不传时, 仅靠 chapter.chapterUrl 作为最弱兜底, 无 book 上下文; 一些源
    ///   `<js>java.ajax(book.bookUrl)</js>` 之类需要 book 的规则会拿到空值.
    public func fetchContent(of chapter: BookChapter,
                             in source: BookSource,
                             book: BookInfo? = nil) async throws -> ChapterContent {
        guard let rule = source.ruleContent, let contentSelector = rule.content, !contentSelector.isEmpty else {
            throw BookSourceEngineError.missingRule("ruleContent.content")
        }
        guard let firstUrl = chapter.chapterUrl, !firstUrl.isEmpty else {
            throw BookSourceEngineError.missingRule("chapter.chapterUrl 为空且无替代")
        }

        var allContent = ""
        var allImages: [String] = []
        // 万象书屋: legado nextContentUrl 支持「单 URL / URL 数组 / JS 一次返多页」
        // 用队列 + seen-set 兼容 3 种, 队列尾被新 nextContentUrl 不断 append
        var queue: [String] = [firstUrl]
        var visited = Set<String>()
        var pageCount = 0

        // 万象书屋: 正文页 JS / 模板上下文 (修复点同 BookInfoParser).
        //   - book.* 来自调用方 (上层有 BookInfo 时务必透传)
        //   - chapter.* 让规则里能拿到 chapter.url / chapter.title (legado 全局变量)
        //   - bookSource: source 对象, 让 @js: 里 source.bookSourceUrl 可用
        let scopeBook: [String: Any] = book.map { TocParser.bookFieldsForScope($0) } ?? [:]
        let scopeChapter: [String: Any] = Self.chapterFieldsForScope(chapter)

        while !queue.isEmpty, pageCount < Self.maxContentPages {
            let currentUrl = queue.removeFirst()
            if visited.contains(currentUrl) { continue }
            visited.insert(currentUrl)
            pageCount += 1
            // 万象书屋: legado concurrentRate 限速 — 跟 Android 行为对齐.
            //   - 同一书快速翻页 (用户连点下一章 / nextContentUrl 多页) 时,
            //     每页之间至少间隔 concurrentRate 配置的时长.
            //   - 没这个钩子, iOS 会瞬间打 N 次同站请求触发反爬封 IP,
            //     用户体感是"读到一半突然全章节空白".
            await SourceRateLimiter.shared.acquire(source: source)
            let resp = try await fetcher.fetch(
                urlString: currentUrl,
                headers: source.parseHeaders(),
                sourceKey: source.bookSourceUrl,
                // 万象书屋 (M2.8 perf): retries: 1, 让上层 (BookDownloader / ReaderEngine)
                // 控 retry 节奏. 之前 HTTPFetcher 默认 retries: 3, BookDownloader 外层
                // 又 maxAttempts: 3, 双层 retry 叠加: 单章最坏 25s × 3 × 3 = 225s 卡死 worker.
                // Android 是 BookHelp 一次拉, 失败 push 回队列, 不阻塞 worker — 等价 retries: 1.
                retries: 1,
                // 万象书屋 (M2.6 fix): 章节正文页 (一章 5-30k 字 + 反爬延迟) 用 25s 超时,
                // 不能跟 search 共用 8s — 复现 case 是"永夜·小说之家", 8s × 3 retry 全超时
                // = 用户报"阅读不了"; 30s 测试时同源 24k 字正文能完整拉到.
                requestTimeoutSec: 25
            )
            let html = resp.bodyText
            let baseUrl = resp.finalURL?.absoluteString ?? currentUrl
            let scope = JSContextScope()
            scope.baseUrl = baseUrl
            scope.src = html
            scope.bookSource = source
            scope.book = scopeBook
            scope.chapter = scopeChapter

            // 1. 抽正文 (规则可能返回多段, join 起来)
            let rawList = try await dispatcher.selectList(
                rule: contentSelector, source: html, baseUrl: baseUrl, jsContext: scope
            )
            var pageText = rawList.joined(separator: "\n")
            if pageText.isEmpty {
                if let single = try? await dispatcher.selectString(
                    rule: contentSelector, source: html, baseUrl: baseUrl, jsContext: scope
                ) {
                    pageText = single
                }
            }

            // 2. 净化替换 (走 SafeRegex 做 ReDoS 保护 + LRU 编译缓存)
            if let pattern = rule.replaceRegex, !pattern.isEmpty {
                pageText = await applyReplaceRegex(pageText, pattern: pattern)
            }

            // 3. 提取图片 (含 src 后 ,{...} headers 选项)
            allImages.append(contentsOf: extractImages(from: pageText, baseUrl: baseUrl))

            // 4. HTML → 段落文本
            pageText = htmlToPlainText(pageText)

            allContent += (allContent.isEmpty ? "" : "\n") + pageText

            // 5. 多页翻页 — 优先 selectList (兼容 JS 返数组), 否则 selectString
            if let nextRule = rule.nextContentUrl, !nextRule.isEmpty {
                let nextList = (try? await dispatcher.selectList(
                    rule: nextRule, source: html, baseUrl: baseUrl, jsContext: scope
                )) ?? []
                let candidates: [String]
                if nextList.count > 1 {
                    candidates = nextList
                } else if let single = try? await dispatcher.selectString(
                    rule: nextRule, source: html, baseUrl: baseUrl, jsContext: scope), !single.isEmpty {
                    candidates = [single]
                } else {
                    candidates = []
                }
                for raw in candidates {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    // legado 约定: JS 返回 `""` / `null` / `[]` 时停止
                    if trimmed.isEmpty || trimmed == "null" || trimmed == "[]" { continue }
                    guard let abs = URL(string: trimmed, relativeTo: URL(string: baseUrl))?.absoluteString,
                          !visited.contains(abs) else { continue }
                    queue.append(abs)
                }
            }
        }

        return ChapterContent(
            chapterIndex: chapter.chapterIndex,
            title: chapter.title,
            content: allContent,
            images: allImages
        )
    }

    // MARK: - 净化与转换

    /// legado replaceRegex 格式: "regex##replacement##regex2##replacement2"
    ///
    /// 跟 Android `AnalyzeRule.replaceRegex` (D-16 PARSE-1/2) 行为对齐:
    ///   - 用 SafeRegex 做 LRU 缓存 + 长输入 timeout (避免 ReDoS 烂书源 hang 阅读流程)
    ///   - 短输入 (< 1000 字) 走快速路径无 timeout 开销
    private func applyReplaceRegex(_ text: String, pattern: String) async -> String {
        let pairs = pattern.components(separatedBy: "##")
        var result = text
        var i = 0
        while i < pairs.count {
            let regex = pairs[i]
            let replacement = (i + 1 < pairs.count) ? pairs[i + 1] : ""
            i += 2
            guard !regex.isEmpty else { continue }
            result = await SafeRegex.shared.replace(
                in: result, pattern: regex, replacement: replacement
            )
        }
        return result
    }

    /// 万象书屋: 把 BookChapter 字段拍平成 [String:Any] 给 JSContextScope.chapter 用.
    /// legado 正文规则里 chapter.title / chapter.url 是常用上下文.
    nonisolated static func chapterFieldsForScope(_ chapter: BookChapter) -> [String: Any] {
        var dict: [String: Any] = [
            "title": chapter.title,
            "index": chapter.chapterIndex,
            "isVip": chapter.isVip,
            "isPay": chapter.isPay,
        ]
        if let v = chapter.chapterUrl { dict["url"] = v }
        if let v = chapter.updateTime { dict["updateTime"] = v }
        return dict
    }

    private func extractImages(from html: String, baseUrl: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<img[^>]+src=['"]([^'"]+)['"]"#, options: [.caseInsensitive]) else {
            return []
        }
        let nsstr = html as NSString
        return regex.matches(in: html, range: NSRange(0..<nsstr.length)).compactMap { m in
            guard m.numberOfRanges > 1 else { return nil }
            var raw = nsstr.substring(with: m.range(at: 1))
            // 万象书屋: legado 约定 — 图片 src 后可附 ,{"headers":{...}} 自定义请求头
            // 例: `https://x.com/img.jpg,{"headers":{"Referer":"x"}}`
            // 我们只输出 URL 部分 (option 留给图片下载层独立解析, ImageHTTP 已经会 split)
            if let optsRange = raw.range(of: ",{") {
                raw = String(raw[..<optsRange.lowerBound])
            }
            if raw.hasPrefix("http") { return raw }
            return URL(string: raw, relativeTo: URL(string: baseUrl))?.absoluteString
        }
    }

    /// 万象书屋: 简化 HTML → 段落 (跟 legado 行为对齐):
    ///   - <br>、<br/> 转 \n
    ///   - <p> 段间转 \n\n
    ///   - 其它 HTML tag 全剥
    ///   - HTML entity 还原 (&nbsp;/&amp;/&lt;/&gt;/&quot;)
    private func htmlToPlainText(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"</?p[^>]*>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        // 万象书屋 (M2.8 Gap 3): 在剥所有 tag 前先把 <img src="X"> 抽出来当占位段落.
        // 标记用 INVISIBLE SEPARATOR (U+2063) 包起来, 这是 0 宽度不可见 unicode —
        // 即使被字符级分页 (PaginationEngine 用 CTFramesetter) 切到中间, 用户看到的也是
        // 残留 url 文字, 不是奇怪的可见控制符 (之前用 ␎ U+240E 是 Symbols-for-Control 显示
        // 为可见 "SO" 字符, 切断时用户看到乱码).
        s = s.replacingOccurrences(
            of: #"<img[^>]+src=['"]([^'"]+)['"][^>]*>"#,
            with: "\n\u{2063}WX_IMG{$1}\u{2063}\n",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;", with: "'")
        // 折叠 3+ 换行 → 2
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        // 行首/尾空白
        s = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
