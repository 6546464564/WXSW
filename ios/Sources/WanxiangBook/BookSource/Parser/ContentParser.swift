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

public actor ContentParser {

    public let dispatcher: SelectorDispatcher
    public let fetcher: HTTPFetcher
    public static let maxContentPages = 20

    public init(dispatcher: SelectorDispatcher, fetcher: HTTPFetcher = .shared) {
        self.dispatcher = dispatcher
        self.fetcher = fetcher
    }

    public func fetchContent(of chapter: BookChapter, in source: BookSource) async throws -> ChapterContent {
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

        while !queue.isEmpty, pageCount < Self.maxContentPages {
            let currentUrl = queue.removeFirst()
            if visited.contains(currentUrl) { continue }
            visited.insert(currentUrl)
            pageCount += 1
            let resp = try await fetcher.fetch(
                urlString: currentUrl,
                headers: source.parseHeaders(),
                sourceKey: source.bookSourceUrl
            )
            let html = resp.bodyText
            let baseUrl = resp.finalURL?.absoluteString ?? currentUrl

            // 1. 抽正文 (规则可能返回多段, join 起来)
            let rawList = try await dispatcher.selectList(
                rule: contentSelector, source: html, baseUrl: baseUrl
            )
            var pageText = rawList.joined(separator: "\n")
            if pageText.isEmpty {
                if let single = try? await dispatcher.selectString(
                    rule: contentSelector, source: html, baseUrl: baseUrl
                ) {
                    pageText = single
                }
            }

            // 2. 净化替换
            if let pattern = rule.replaceRegex, !pattern.isEmpty {
                pageText = applyReplaceRegex(pageText, pattern: pattern)
            }

            // 3. 提取图片 (含 src 后 ,{...} headers 选项)
            allImages.append(contentsOf: extractImages(from: pageText, baseUrl: baseUrl))

            // 4. HTML → 段落文本
            pageText = htmlToPlainText(pageText)

            allContent += (allContent.isEmpty ? "" : "\n") + pageText

            // 5. 多页翻页 — 优先 selectList (兼容 JS 返数组), 否则 selectString
            if let nextRule = rule.nextContentUrl, !nextRule.isEmpty {
                let nextList = (try? await dispatcher.selectList(
                    rule: nextRule, source: html, baseUrl: baseUrl
                )) ?? []
                let candidates: [String]
                if nextList.count > 1 {
                    candidates = nextList
                } else if let single = try? await dispatcher.selectString(
                    rule: nextRule, source: html, baseUrl: baseUrl), !single.isEmpty {
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
    private func applyReplaceRegex(_ text: String, pattern: String) -> String {
        let pairs = pattern.components(separatedBy: "##")
        var result = text
        var i = 0
        while i < pairs.count {
            let regex = pairs[i]
            let replacement = (i + 1 < pairs.count) ? pairs[i + 1] : ""
            i += 2
            guard !regex.isEmpty,
                  let r = try? NSRegularExpression(pattern: regex, options: []) else { continue }
            let nsstr = result as NSString
            result = r.stringByReplacingMatches(
                in: result,
                range: NSRange(0..<nsstr.length),
                withTemplate: replacement
            )
        }
        return result
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
