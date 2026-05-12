//
//  BookSource.swift
//  万象书屋 iOS · 书源实体 (跟 Android 1:1)
//
//  对应 Android: app/src/main/java/io/legado/app/data/entities/BookSource.kt
//
//  设计原则:
//   - 字段名 1:1 跟 Kotlin (用 Swift CodingKeys 映射 snake_case 不要)
//   - 字段类型: 全部 var, 全部可选 (跟 legado 书源 JSON 实际形态一致)
//   - 不实现 Android 那一坨 group splitting / equality utility (那些是 UI 用,引擎不需要)
//

import Foundation

/// 书源类型
public enum BookSourceType: Int, Codable, Sendable {
    case text = 0       // 文本 (默认)
    case audio = 1      // 音频
    case image = 2      // 图片 (漫画)
    case file = 3       // 文件 (类似知轩藏书)
}

/// 书源 (legado 兼容)
public struct BookSource: Codable, Hashable, Sendable {

    // MARK: - 基础信息
    public var bookSourceUrl: String = ""
    public var bookSourceName: String = ""
    public var bookSourceGroup: String? = nil
    public var bookSourceType: Int = 0
    public var bookUrlPattern: String? = nil
    public var customOrder: Int = 0
    public var enabled: Bool = true
    public var enabledExplore: Bool = true
    public var enabledCookieJar: Bool? = true

    // MARK: - 网络与脚本
    public var jsLib: String? = nil
    public var concurrentRate: String? = nil
    public var header: String? = nil
    public var loginUrl: String? = nil
    public var loginUi: String? = nil
    public var loginCheckJs: String? = nil
    public var coverDecodeJs: String? = nil

    // MARK: - 注释和元数据
    public var bookSourceComment: String? = nil
    public var variableComment: String? = nil
    public var lastUpdateTime: Int64 = 0
    public var respondTime: Int64 = 180000
    public var weight: Int = 0

    // MARK: - 5 大规则
    public var exploreUrl: String? = nil
    public var exploreScreen: String? = nil
    public var ruleExplore: ExploreRule? = nil
    public var searchUrl: String? = nil
    public var ruleSearch: SearchRule? = nil
    public var ruleBookInfo: BookInfoRule? = nil
    public var ruleToc: TocRule? = nil
    public var ruleContent: ContentRule? = nil
    public var ruleReview: ReviewRule? = nil

    // MARK: - 计算属性

    /// 同 Android `getKey()` — 主键
    public var key: String { bookSourceUrl }

    /// 同 Android `getTag()` — 显示标签
    public var tag: String { bookSourceName }

    /// 万象书屋: 解析 concurrentRate "5/1000" → (count, periodMs)
    /// "0/0" 或 nil 表示无限制
    public func parseConcurrentRate() -> (count: Int, periodMs: Int)? {
        guard let r = concurrentRate, !r.isEmpty else { return nil }
        let parts = r.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return (parts[0], parts[1])
    }

    /// 万象书屋: 解析 header JSON 字符串 → [String: String]
    /// 支持 legado 源里的两种写法: 标准 JSON (`{"k":"v"}`) 和单引号 (`{'k':'v'}`).
    /// Android Gson 默认严格, 但 legado 自己的 GSON 配置 setLenient + 一些源真的写单引号
    /// (猫眼看书等需要 client-device/version 自定义 header 才能拿数据), 所以 iOS 也要兼容.
    public func parseHeaders() -> [String: String] {
        guard let h = header, !h.isEmpty else { return [:] }
        // 1. 先严格 JSON 试
        if let data = h.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict.compactMapValues { String(describing: $0) }
        }
        // 2. lenient: 简单把不在双引号内的单引号换成双引号再试
        // 万象书屋 (M2.8 fix bug): 猫眼看书等大量加密源 header 写单引号 ⇒ 严格 JSON 解析失败
        // ⇒ 没带 client-device/version/Authorization ⇒ API 返 4004 device 不能为空 ⇒ toc 0.
        let normalized = lenientJSONNormalize(h)
        if let data = normalized.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict.compactMapValues { String(describing: $0) }
        }
        return [:]
    }

    /// 万象书屋: 简单 lenient JSON 标准化 — 把字符串外的单引号换成双引号.
    /// 不做完整 JS lexer, 只处理 legado 源里典型的单引号 KV 写法.
    private func lenientJSONNormalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inDouble = false
        var prev: Character = " "
        for c in s {
            if !inDouble && c == "'" {
                out.append("\"")
            } else if c == "\"" && prev != "\\" {
                inDouble.toggle()
                out.append(c)
            } else {
                out.append(c)
            }
            prev = c
        }
        return out
    }

    // MARK: - 防御性 Decoding (legado 书源 JSON 字段缺失/类型不一致时不崩)
    // legado 书源历史上有 enabled 写成 0/1 (Int) 或 true/false (Bool), 都要兼容
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)

        bookSourceUrl = c.tryDecode("bookSourceUrl") ?? ""
        bookSourceName = c.tryDecode("bookSourceName") ?? ""
        bookSourceGroup = c.tryDecode("bookSourceGroup")
        bookSourceType = c.tryDecodeFlexibleInt("bookSourceType") ?? 0
        bookUrlPattern = c.tryDecode("bookUrlPattern")
        customOrder = c.tryDecodeFlexibleInt("customOrder") ?? 0
        enabled = c.tryDecodeFlexibleBool("enabled") ?? true
        enabledExplore = c.tryDecodeFlexibleBool("enabledExplore") ?? true
        enabledCookieJar = c.tryDecodeFlexibleBool("enabledCookieJar")

        jsLib = c.tryDecode("jsLib")
        concurrentRate = c.tryDecode("concurrentRate")
        header = c.tryDecode("header")
        loginUrl = c.tryDecode("loginUrl")
        loginUi = c.tryDecode("loginUi")
        loginCheckJs = c.tryDecode("loginCheckJs")
        coverDecodeJs = c.tryDecode("coverDecodeJs")

        bookSourceComment = c.tryDecode("bookSourceComment")
        variableComment = c.tryDecode("variableComment")
        lastUpdateTime = c.tryDecodeFlexibleInt64("lastUpdateTime") ?? 0
        respondTime = c.tryDecodeFlexibleInt64("respondTime") ?? 180000
        weight = c.tryDecodeFlexibleInt("weight") ?? 0

        exploreUrl = c.tryDecode("exploreUrl")
        exploreScreen = c.tryDecode("exploreScreen")
        ruleExplore = try? c.decodeIfPresent(ExploreRule.self, forKey: AnyCodingKey("ruleExplore"))
        searchUrl = c.tryDecode("searchUrl")
        ruleSearch = try? c.decodeIfPresent(SearchRule.self, forKey: AnyCodingKey("ruleSearch"))
        ruleBookInfo = try? c.decodeIfPresent(BookInfoRule.self, forKey: AnyCodingKey("ruleBookInfo"))
        ruleToc = try? c.decodeIfPresent(TocRule.self, forKey: AnyCodingKey("ruleToc"))
        ruleContent = try? c.decodeIfPresent(ContentRule.self, forKey: AnyCodingKey("ruleContent"))
        ruleReview = try? c.decodeIfPresent(ReviewRule.self, forKey: AnyCodingKey("ruleReview"))
    }

    public init(
        bookSourceUrl: String,
        bookSourceName: String,
        searchUrl: String? = nil,
        ruleSearch: SearchRule? = nil,
        ruleBookInfo: BookInfoRule? = nil,
        ruleToc: TocRule? = nil,
        ruleContent: ContentRule? = nil
    ) {
        self.bookSourceUrl = bookSourceUrl
        self.bookSourceName = bookSourceName
        self.searchUrl = searchUrl
        self.ruleSearch = ruleSearch
        self.ruleBookInfo = ruleBookInfo
        self.ruleToc = ruleToc
        self.ruleContent = ruleContent
    }
}

// MARK: - 5 大规则结构

public struct SearchRule: Codable, Hashable, Sendable {
    public var checkKeyWord: String? = nil
    public var bookList: String? = nil
    public var name: String? = nil
    public var author: String? = nil
    public var intro: String? = nil
    public var kind: String? = nil
    public var lastChapter: String? = nil
    public var updateTime: String? = nil
    public var bookUrl: String? = nil
    public var coverUrl: String? = nil
    public var wordCount: String? = nil
    public init() {}
}

public struct ExploreRule: Codable, Hashable, Sendable {
    public var bookList: String? = nil
    public var name: String? = nil
    public var author: String? = nil
    public var intro: String? = nil
    public var kind: String? = nil
    public var lastChapter: String? = nil
    public var updateTime: String? = nil
    public var bookUrl: String? = nil
    public var coverUrl: String? = nil
    public var wordCount: String? = nil
    public init() {}
}

public struct BookInfoRule: Codable, Hashable, Sendable {
    public var `init`: String? = nil
    public var name: String? = nil
    public var author: String? = nil
    public var intro: String? = nil
    public var kind: String? = nil
    public var lastChapter: String? = nil
    public var updateTime: String? = nil
    public var coverUrl: String? = nil
    public var tocUrl: String? = nil
    public var wordCount: String? = nil
    public var canReName: String? = nil
    public var downloadUrls: String? = nil

    public init() {}

    enum CodingKeys: String, CodingKey {
        case `init` = "init"
        case name, author, intro, kind, lastChapter, updateTime
        case coverUrl, tocUrl, wordCount, canReName, downloadUrls
    }
}

public struct TocRule: Codable, Hashable, Sendable {
    public var preUpdateJs: String? = nil
    public var chapterList: String? = nil
    public var chapterName: String? = nil
    public var chapterUrl: String? = nil
    public var formatJs: String? = nil
    public var isVolume: String? = nil
    public var isVip: String? = nil
    public var isPay: String? = nil
    public var updateTime: String? = nil
    public var nextTocUrl: String? = nil
    public init() {}
}

public struct ContentRule: Codable, Hashable, Sendable {
    public var content: String? = nil
    public var title: String? = nil
    public var nextContentUrl: String? = nil
    public var webJs: String? = nil
    public var sourceRegex: String? = nil
    public var replaceRegex: String? = nil
    public var imageStyle: String? = nil
    public var imageDecode: String? = nil
    public var payAction: String? = nil
    public init() {}
}

public struct ReviewRule: Codable, Hashable, Sendable {
    public var reviewUrl: String? = nil
    public var avatarRule: String? = nil
    public var contentRule: String? = nil
    public var postTimeRule: String? = nil
    public var reviewQuoteUrl: String? = nil
    public var voteUpUrl: String? = nil
    public var voteDownUrl: String? = nil
    public var postReviewUrl: String? = nil
    public var postQuoteUrl: String? = nil
    public var deleteUrl: String? = nil
    public init() {}
}

// MARK: - 防御性解码工具

/// 万象书屋: legado 书源 JSON 历史 schema 不一致 (Int 写成 String, Bool 写成 0/1),
/// 用这个 helper 做容忍解码, 避免一个旧字段就让全源加载失败
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ s: String) { self.stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

extension KeyedDecodingContainer where K == AnyCodingKey {
    func tryDecode(_ key: String) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: AnyCodingKey(key)) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: AnyCodingKey(key)) { return String(i) }
        return nil
    }

    func tryDecodeFlexibleInt(_ key: String) -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: AnyCodingKey(key)) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: AnyCodingKey(key)) { return Int(s) }
        if let b = try? decodeIfPresent(Bool.self, forKey: AnyCodingKey(key)) { return b ? 1 : 0 }
        return nil
    }

    func tryDecodeFlexibleInt64(_ key: String) -> Int64? {
        if let i = try? decodeIfPresent(Int64.self, forKey: AnyCodingKey(key)) { return i }
        if let s = try? decodeIfPresent(String.self, forKey: AnyCodingKey(key)) { return Int64(s) }
        return nil
    }

    func tryDecodeFlexibleBool(_ key: String) -> Bool? {
        if let b = try? decodeIfPresent(Bool.self, forKey: AnyCodingKey(key)) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: AnyCodingKey(key)) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: AnyCodingKey(key))?.lowercased() {
            return ["true", "1", "yes"].contains(s)
        }
        return nil
    }
}

// MARK: - 请求头 (@js Header, 对齐 Android BaseSource.getHeaderMap)

extension BookSource {

    /// `header` 支持 `@js:` / `<js>...</js>` — Android `evalJS` 后把返回值解析成 JSON headers.
    /// 之前 iOS 只解析字面 JSON, `@js:` 失败 ⇒ 空 headers ⇒ QQ 企鹅 API “incorrect referrer”十几字节 ⇒ 目录 0 章.
    public func resolvedHeaders(js: JSEngine) async -> [String: String] {
        guard let h = header, !h.isEmpty else { return [:] }
        let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()

        func dictFromJsOutput(_ out: Any?) -> [String: String] {
            guard let out else { return [:] }
            let jsonStr: String
            if let s = out as? String {
                jsonStr = s
            } else if JSONSerialization.isValidJSONObject(out),
                      let data = try? JSONSerialization.data(withJSONObject: out, options: []),
                      let s = String(data: data, encoding: .utf8) {
                jsonStr = s
            } else {
                jsonStr = String(describing: out)
            }
            guard let data = jsonStr.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return dict.compactMapValues { String(describing: $0) }
        }

        if lower.hasPrefix("@js:") {
            let script = String(t.dropFirst(4))
            let scope = JSContextScope()
            scope.bookSource = self
            let out = try? await js.evaluate(script: script, source: "", baseUrl: bookSourceUrl, scope: scope)
            let parsed = dictFromJsOutput(out)
            return parsed.isEmpty ? parseHeaders() : parsed
        }
        if lower.hasPrefix("<js>"),
           let endRange = t.range(of: "</js>", options: .caseInsensitive) {
            let start = t.index(t.startIndex, offsetBy: 4)
            let script = String(t[start..<endRange.lowerBound])
            let scope = JSContextScope()
            scope.bookSource = self
            let out = try? await js.evaluate(script: script, source: "", baseUrl: bookSourceUrl, scope: scope)
            let parsed = dictFromJsOutput(out)
            return parsed.isEmpty ? parseHeaders() : parsed
        }
        return parseHeaders()
    }
}
