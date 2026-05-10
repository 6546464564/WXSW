//
//  ExploreParser.swift
//  万象书屋 iOS · 发现页 (书城频道) 解析
//
//  legado exploreUrl 是多频道列表:
//   "热门::https://x.com/hot
//
//   完结::https://x.com/done
//
//   分类::@js: ..."
//
//  每个 ":: " 后是 URL 模板 (跟 searchUrl 一样支持 {{page}})
//

import Foundation

/// 万象书屋: 改为 final class, 发现页解析无 mutable state, 多并发安全.
public final class ExploreParser: @unchecked Sendable {

    public let dispatcher: SelectorDispatcher
    public let fetcher: HTTPFetcher
    public let jsEngine: JSEngine?

    /// 一个频道
    public struct Kind: Hashable, Sendable {
        public let title: String
        public let url: String
        public init(title: String, url: String) { self.title = title; self.url = url }
    }

    public init(dispatcher: SelectorDispatcher, fetcher: HTTPFetcher = .shared, jsEngine: JSEngine? = nil) {
        self.dispatcher = dispatcher
        self.fetcher = fetcher
        self.jsEngine = jsEngine
    }

    /// 解析源的所有发现频道
    public nonisolated func parseExploreKinds(of source: BookSource) -> [Kind] {
        guard let raw = source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }
        // legado 用 \n\n 分隔频道
        return raw.components(separatedBy: CharacterSet(charactersIn: "\n\r"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line -> Kind? in
                guard let r = line.range(of: "::") else { return nil }
                let title = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                let url = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if title.isEmpty || url.isEmpty { return nil }
                return Kind(title: title, url: url)
            }
    }

    /// 拉某频道的书列表
    public func fetchExplore(of source: BookSource, kind: Kind, page: Int = 1) async throws -> [SearchBook] {
        guard let rule = source.ruleExplore, let listSelector = rule.bookList, !listSelector.isEmpty else {
            throw BookSourceEngineError.missingRule("ruleExplore.bookList")
        }
        let rendered = await URLTemplate.renderAsync(
            kind.url, bookSource: source, jsEngine: jsEngine,
            baseURL: source.bookSourceUrl, page: page
        )
        let resp = try await fetcher.fetch(
            urlString: rendered.url,
            method: rendered.method,
            body: rendered.body,
            headers: source.parseHeaders().merging(rendered.headers, uniquingKeysWith: { _, b in b }),
            sourceKey: source.bookSourceUrl,
            retries: rendered.retry ?? 3
        )
        let html = resp.bodyText
        let baseUrl = resp.finalURL?.absoluteString ?? rendered.url

        let nodes = try await dispatcher.selectList(rule: listSelector, source: html, baseUrl: baseUrl)

        var out: [SearchBook] = []
        for node in nodes {
            let name = (try? await dispatcher.selectString(rule: rule.name ?? "", source: node, baseUrl: baseUrl))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bookUrl = (try? await dispatcher.selectString(rule: rule.bookUrl ?? "@href", source: node, baseUrl: baseUrl)) ?? ""
            if name.isEmpty || bookUrl.isEmpty { continue }
            let abs = absolutize(bookUrl, baseUrl: baseUrl) ?? bookUrl

            out.append(SearchBook(
                origin: source.bookSourceUrl,
                originName: source.bookSourceName,
                name: name,
                author: (try? await dispatcher.selectString(rule: rule.author ?? "", source: node, baseUrl: baseUrl)) ?? "",
                bookUrl: abs,
                coverUrl: absolutize(try? await dispatcher.selectString(rule: rule.coverUrl ?? "", source: node, baseUrl: baseUrl), baseUrl: baseUrl),
                intro: try? await dispatcher.selectString(rule: rule.intro ?? "", source: node, baseUrl: baseUrl),
                kind: try? await dispatcher.selectString(rule: rule.kind ?? "", source: node, baseUrl: baseUrl),
                lastChapter: try? await dispatcher.selectString(rule: rule.lastChapter ?? "", source: node, baseUrl: baseUrl),
                updateTime: try? await dispatcher.selectString(rule: rule.updateTime ?? "", source: node, baseUrl: baseUrl),
                wordCount: try? await dispatcher.selectString(rule: rule.wordCount ?? "", source: node, baseUrl: baseUrl)
            ))
        }
        return out
    }

    nonisolated func absolutize(_ url: String?, baseUrl: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        guard let base = baseUrl, let baseURL = URL(string: base) else { return url }
        return URL(string: url, relativeTo: baseURL)?.absoluteString ?? url
    }
}
