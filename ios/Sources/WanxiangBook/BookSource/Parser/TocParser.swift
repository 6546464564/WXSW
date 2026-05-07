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

public actor TocParser {

    public let dispatcher: SelectorDispatcher
    public let fetcher: HTTPFetcher
    public static let maxTocPages = 50

    public init(dispatcher: SelectorDispatcher, fetcher: HTTPFetcher = .shared) {
        self.dispatcher = dispatcher
        self.fetcher = fetcher
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

        while !queue.isEmpty, pageCount < Self.maxTocPages {
            let currentUrl = queue.removeFirst()
            if visitedPages.contains(currentUrl) { continue }
            visitedPages.insert(currentUrl)
            pageCount += 1
            let resp = try await fetcher.fetch(
                urlString: currentUrl,
                headers: source.parseHeaders(),
                sourceKey: source.bookSourceUrl
            )
            let html = resp.bodyText
            let baseUrl = resp.finalURL?.absoluteString ?? currentUrl

            let nodes = try await dispatcher.selectList(
                rule: listSelector, source: html, baseUrl: baseUrl
            )

            for node in nodes {
                // 万象书屋 (P0 fix): legado chapterName = "text" / "@text" 都是"取节点 text"
                // chapterUrl = "href" / "@href" 都是"取节点 href"
                // 不能直接当 css selector 跑, 必须走属性提取
                let nameRule = normalizeSimpleAttr(rule.chapterName ?? "text")
                let urlRule = normalizeSimpleAttr(rule.chapterUrl ?? "href")
                let title = (try? await dispatcher.selectString(
                    rule: nameRule, source: node, baseUrl: baseUrl
                ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let url = (try? await dispatcher.selectString(
                    rule: urlRule, source: node, baseUrl: baseUrl
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

                let isVolume = await readBoolFlag(rule.isVolume, html: node, baseUrl: baseUrl)
                let vipFromRule = await readBoolFlag(rule.isVip, html: node, baseUrl: baseUrl)
                let payFromRule = await readBoolFlag(rule.isPay, html: node, baseUrl: baseUrl)
                let isVip = urlSuffixVip || vipFromRule
                let isPay = urlSuffixPay || payFromRule
                let upd = (try? await dispatcher.selectString(
                    rule: rule.updateTime ?? "",
                    source: node,
                    baseUrl: baseUrl
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
                    // legado 约定: JS 返 `""` / `null` / `[]` 时停止
                    if trimmed.isEmpty || trimmed == "null" || trimmed == "[]" { continue }
                    let abs = absolutize(trimmed, baseUrl: baseUrl) ?? trimmed
                    if !visitedPages.contains(abs) { queue.append(abs) }
                }
            }
        }

        return chapters
    }

    private func readBoolFlag(_ rule: String?, html: String, baseUrl: String?) async -> Bool {
        guard let rule, !rule.isEmpty else { return false }
        let v = try? await dispatcher.selectString(rule: rule, source: html, baseUrl: baseUrl)
        guard let v, !v.isEmpty else { return false }
        return ["1", "true", "yes"].contains(v.lowercased())
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
        return rule
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
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        guard let base = baseUrl, let baseURL = URL(string: base) else { return url }
        return URL(string: url, relativeTo: baseURL)?.absoluteString ?? url
    }
}
