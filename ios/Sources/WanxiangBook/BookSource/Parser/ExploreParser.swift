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
import JavaScriptCore

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
    public func parseExploreKinds(of source: BookSource) async -> [Kind] {
        guard let raw = source.exploreUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }

        // @js: 前缀 — 执行 JS 得到 JSON 数组 [{title,url,style?},...]
        if raw.hasPrefix("@js:") {
            let jsCode = String(raw.dropFirst(4))
            guard let engine = jsEngine else { return [] }
            let scope = JSContextScope()
            scope.bookSource = source
            scope.baseUrl = source.bookSourceUrl
            scope.page = 1
            do {
                let v = try await engine.evaluate(script: jsCode, source: nil,
                                                   baseUrl: source.bookSourceUrl, scope: scope)
                return parseKindsFromJSResult(v)
            } catch {
                print("[ExploreParser] @js exploreUrl error: \(error)")
                return []
            }
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

    private func parseKindsFromJSResult(_ v: Any?) -> [Kind] {
        var jsonStr: String?
        if let s = v as? String { jsonStr = s }
        else if let jsVal = v as? JavaScriptCore.JSValue, jsVal.isString { jsonStr = jsVal.toString() }
        else if let arr = v as? [Any] { return parseKindsArray(arr) }

        guard let jsonStr, let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return parseKindsArray(arr)
    }

    private func parseKindsArray(_ arr: [Any]) -> [Kind] {
        arr.compactMap { item -> Kind? in
            guard let dict = item as? [String: Any],
                  let title = dict["title"] as? String else { return nil }
            let url = dict["url"] as? String ?? ""
            return Kind(title: title, url: url)
        }
    }

    /// 拉某频道的书列表
    public func fetchExplore(of source: BookSource, kind: Kind, page: Int = 1) async throws -> [SearchBook] {
        // ruleExplore 为空时 fallback 到 ruleSearch (legado 常见模式)
        let listSelector: String
        let ruleName: String?
        let ruleAuthor: String?
        let ruleBookUrl: String?
        let ruleCoverUrl: String?
        let ruleIntro: String?
        let ruleKind: String?
        let ruleLastChapter: String?
        let ruleUpdateTime: String?
        let ruleWordCount: String?

        if let er = source.ruleExplore, let bl = er.bookList, !bl.isEmpty {
            listSelector = bl
            ruleName = er.name; ruleAuthor = er.author; ruleBookUrl = er.bookUrl
            ruleCoverUrl = er.coverUrl; ruleIntro = er.intro; ruleKind = er.kind
            ruleLastChapter = er.lastChapter; ruleUpdateTime = er.updateTime; ruleWordCount = er.wordCount
        } else if let sr = source.ruleSearch, let bl = sr.bookList, !bl.isEmpty {
            listSelector = bl
            ruleName = sr.name; ruleAuthor = sr.author; ruleBookUrl = sr.bookUrl
            ruleCoverUrl = sr.coverUrl; ruleIntro = sr.intro; ruleKind = sr.kind
            ruleLastChapter = sr.lastChapter; ruleUpdateTime = sr.updateTime; ruleWordCount = sr.wordCount
        } else {
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
            headers: (await source.resolvedHeaders(js: jsEngine ?? dispatcher.js))
                .merging(rendered.headers, uniquingKeysWith: { _, b in b }),
            sourceKey: source.bookSourceUrl,
            retries: rendered.retry ?? 3
        )
        let html = resp.bodyText
        let baseUrl = resp.finalURL?.absoluteString ?? rendered.url

        let nodes = try await dispatcher.selectList(rule: listSelector, source: html, baseUrl: baseUrl)

        let scope = JSContextScope()
        scope.baseUrl = baseUrl
        scope.src = html
        scope.bookSource = source
        scope.page = page

        var out: [SearchBook] = []
        for node in nodes {
            scope.src = node
            let name = (try? await dispatcher.selectString(rule: ruleName ?? "", source: node, baseUrl: baseUrl, jsContext: scope))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bookUrl = (try? await dispatcher.selectString(rule: ruleBookUrl ?? "@href", source: node, baseUrl: baseUrl, jsContext: scope)) ?? ""
            if name.isEmpty || bookUrl.isEmpty { continue }
            let abs = absolutize(bookUrl, baseUrl: baseUrl) ?? bookUrl

            out.append(SearchBook(
                origin: source.bookSourceUrl,
                originName: source.bookSourceName,
                name: name,
                author: (try? await dispatcher.selectString(rule: ruleAuthor ?? "", source: node, baseUrl: baseUrl, jsContext: scope)) ?? "",
                bookUrl: abs,
                coverUrl: absolutize(try? await dispatcher.selectString(rule: ruleCoverUrl ?? "", source: node, baseUrl: baseUrl, jsContext: scope), baseUrl: baseUrl),
                intro: try? await dispatcher.selectString(rule: ruleIntro ?? "", source: node, baseUrl: baseUrl, jsContext: scope),
                kind: try? await dispatcher.selectString(rule: ruleKind ?? "", source: node, baseUrl: baseUrl, jsContext: scope),
                lastChapter: try? await dispatcher.selectString(rule: ruleLastChapter ?? "", source: node, baseUrl: baseUrl, jsContext: scope),
                updateTime: try? await dispatcher.selectString(rule: ruleUpdateTime ?? "", source: node, baseUrl: baseUrl, jsContext: scope),
                wordCount: try? await dispatcher.selectString(rule: ruleWordCount ?? "", source: node, baseUrl: baseUrl, jsContext: scope)
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
