//
//  BookEntities.swift
//  万象书屋 iOS · 书源引擎对外的数据形态
//
//  对应 Android: io.legado.app.data.entities.{Book, BookChapter, SearchBook}
//  这里只挑书源引擎需要的字段, 阅读器/书架/书城用的是上层的 Book SQLite 模型 (Database/DB.swift)
//

import Foundation

/// 搜索结果中的一条书 (从源解析出来, 还没入书架)
public struct SearchBook: Codable, Hashable, Sendable {
    public var origin: String
    public var originName: String
    public var name: String
    public var author: String
    public var bookUrl: String
    public var coverUrl: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var wordCount: String?

    public init(
        origin: String,
        originName: String,
        name: String,
        author: String,
        bookUrl: String,
        coverUrl: String? = nil,
        intro: String? = nil,
        kind: String? = nil,
        lastChapter: String? = nil,
        updateTime: String? = nil,
        wordCount: String? = nil
    ) {
        self.origin = origin
        self.originName = originName
        self.name = name
        self.author = author
        self.bookUrl = bookUrl
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.lastChapter = lastChapter
        self.updateTime = updateTime
        self.wordCount = wordCount
    }

    /// 万象书屋: 去重 key (book name + author 归一化)
    /// 一些源会返回重复条目, 只在空白/书名号/冒号/作者前缀上有差异,
    /// 简单 trim 会导致同一本书重复刷屏。这里做强归一化。
    public var dedupeKey: String {
        let n = Self.normalizeKey(name)
        let a = Self.normalizeKey(author)
        return "\(n)::\(a)"
    }

    /// 更激进的标题 key: 搜索列表 UI 用来防止同源重复条刷屏。
    /// 只按书名归一化, 作者空/错位时也能合并。
    public var titleDedupeKey: String {
        String(Self.normalizeKey(name).prefix(14))
    }

    /// 万象书屋 (D-25 fix): SwiftUI ForEach 的稳定 id.
    /// bookUrl 在某些源 (如 QQ浏览器柳树) 解析时会因 query 拼接问题全部为同一个,
    /// 直接用 id: \.bookUrl 会让 19 本不同的书在 List 上 render 成同一条 cell 的复制,
    /// 用户体感"搜出来全是同一本". 这里用 (origin + name + author + bookUrl) 拼一个稳定 id.
    public var listRowId: String {
        "\(origin)|\(name)|\(author)|\(bookUrl)"
    }

    private static func normalizeKey(_ raw: String) -> String {
        var s = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .lowercased()
        for prefix in ["作者:", "作者：", "作 者:", "作 者：", "author:", "by "] {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
            }
        }
        let keep = CharacterSet.alphanumerics
        return s.unicodeScalars
            // 只保留字母/数字/汉字等 alphanumeric, 丢掉所有标点、空白、零宽字符、emoji 修饰等不可见差异
            .filter { keep.contains($0) }
            .map(String.init)
            .joined()
    }
}

/// 书的详细信息 (从详情页解析出来)
public struct BookInfo: Codable, Hashable, Sendable {
    public var bookUrl: String
    public var name: String
    public var author: String
    public var intro: String?
    public var kind: String?
    public var coverUrl: String?
    public var tocUrl: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var wordCount: String?

    public init(bookUrl: String, name: String, author: String,
                intro: String? = nil, kind: String? = nil, coverUrl: String? = nil,
                tocUrl: String? = nil, lastChapter: String? = nil,
                updateTime: String? = nil, wordCount: String? = nil) {
        self.bookUrl = bookUrl; self.name = name; self.author = author
        self.intro = intro; self.kind = kind; self.coverUrl = coverUrl
        self.tocUrl = tocUrl; self.lastChapter = lastChapter
        self.updateTime = updateTime; self.wordCount = wordCount
    }
}

/// 章节 (轻量, 不含 content)
public struct BookChapter: Codable, Hashable, Sendable {
    public var chapterIndex: Int
    public var chapterUrl: String?
    public var title: String
    public var isVolume: Bool = false
    public var isVip: Bool = false
    public var isPay: Bool = false
    public var updateTime: String? = nil
    public var tag: String? = nil
    public var startFragment: String? = nil
    public var endFragment: String? = nil

    public init(chapterIndex: Int, chapterUrl: String?, title: String,
                isVolume: Bool = false, isVip: Bool = false, isPay: Bool = false,
                updateTime: String? = nil, tag: String? = nil,
                startFragment: String? = nil, endFragment: String? = nil) {
        self.chapterIndex = chapterIndex; self.chapterUrl = chapterUrl
        self.title = title; self.isVolume = isVolume; self.isVip = isVip
        self.isPay = isPay; self.updateTime = updateTime; self.tag = tag
        self.startFragment = startFragment; self.endFragment = endFragment
    }
}

/// 章节正文 (含 content)
public struct ChapterContent: Codable, Hashable, Sendable {
    public var chapterIndex: Int
    public var title: String
    public var content: String
    public var images: [String] = []
    public var nextContentUrl: String? = nil

    public init(chapterIndex: Int, title: String, content: String,
                images: [String] = [], nextContentUrl: String? = nil) {
        self.chapterIndex = chapterIndex; self.title = title
        self.content = content; self.images = images; self.nextContentUrl = nextContentUrl
    }
}

/// 万象书屋: 引擎执行错误
public enum BookSourceEngineError: Error, LocalizedError {
    case missingRule(String)
    case missingSearchUrl
    case missingTocUrl
    case missingContent
    case selectorFailed(String)
    case jsExecutionFailed(String)
    case httpFailed(String)
    case encodingDetectionFailed
    case ruleEmpty(String)

    public var errorDescription: String? {
        switch self {
        case .missingRule(let r): return "书源缺规则: \(r)"
        case .missingSearchUrl: return "书源没配 searchUrl"
        case .missingTocUrl: return "书源没配 tocUrl 且 bookUrl 不可作目录"
        case .missingContent: return "正文为空"
        case .selectorFailed(let m): return "选择器执行失败: \(m)"
        case .jsExecutionFailed(let m): return "JS 执行失败: \(m)"
        case .httpFailed(let m): return "HTTP 失败: \(m)"
        case .encodingDetectionFailed: return "编码探测失败"
        case .ruleEmpty(let r): return "规则空: \(r)"
        }
    }
}
