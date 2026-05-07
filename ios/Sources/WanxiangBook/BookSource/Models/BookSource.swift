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
    public func parseHeaders() -> [String: String] {
        guard let h = header,
              let data = h.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict.compactMapValues { String(describing: $0) }
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
