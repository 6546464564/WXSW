//
//  QidianBook.swift
//  万象书屋 iOS · 书城数据模型 (D-22 同 Android)
//
//  对应 Android: io.legado.app.ui.main.bookstore.QidianBook
//
//  数据来源: m.qidian.com 移动站 vite-plugin-ssr JSON
//  封面 URL 不在 JSON 内, 用 bookId 拼:
//    https://bookcover.yuewen.com/qdbimg/349573/<bookId>/180
//

import Foundation

/// 万象书屋·书城单本书目数据 (跟 Android `QidianBook.kt` 字段一一对齐)
struct QidianBook: Hashable, Identifiable {
    /// 书名 (起点字段 bName)
    let name: String
    /// 封面 URL — 拼 https://bookcover.yuewen.com/qdbimg/349573/<bookId>/180
    let coverUrl: String
    /// 作者 (起点字段 bAuth)
    let author: String
    /// 大分类 (起点字段 cat): 玄幻 / 都市 / 仙侠 / 言情 / 历史 / 科幻 / 悬疑 …
    let category: String
    /// 子分类 (起点字段 subCat): 修真文明 / 异术超能 / 东方玄幻 / 恋爱日常 …
    let subCategory: String
    /// 总字数 (起点字段 cnt): "569.44万字" 这种带单位字符串
    let wordCount: String
    /// 起点 bookId — 用于拼封面 URL / 跳详情页
    let bookId: String
    /// 该书在所属榜单内的真排名 (起点字段 rankNum, 1-based)
    let rank: Int
    /// 来自哪个榜单的中文名 ("月票榜" / "畅销榜" / …)
    let rankName: String
    /// 榜单维度数据 (起点字段 rankCnt): "12.04万月票" / "7.08万推荐" / "0月更字" — 部分榜单有
    let rankCount: String
    /// 简介 (起点字段 desc)
    let intro: String

    var id: String { bookId.isEmpty ? name : bookId }

    init(
        name: String,
        coverUrl: String,
        author: String = "",
        category: String = "",
        subCategory: String = "",
        wordCount: String = "",
        bookId: String = "",
        rank: Int = 0,
        rankName: String = "",
        rankCount: String = "",
        intro: String = ""
    ) {
        self.name = name
        self.coverUrl = coverUrl
        self.author = author
        self.category = category
        self.subCategory = subCategory
        self.wordCount = wordCount
        self.bookId = bookId
        self.rank = rank
        self.rankName = rankName
        self.rankCount = rankCount
        self.intro = intro
    }
}

/// 万象书屋·书城频道 (跟 Android `QidianRepository.Channel` 对齐)
///
/// D-22.1: 女频与男频 UI/数据结构一致; mirror.ranksFemale 空时 fallback ranks.
/// Publish 走 mirror.ranksPublish (catId=13100 实体书).
enum QidianChannel: String, CaseIterable, Identifiable {
    case male, female, publish
    var id: String { rawValue }

    var title: String {
        switch self {
        case .male: return "男生"
        case .female: return "女生"
        case .publish: return "出版"
        }
    }
}

/// 万象书屋: 9 + 4 种榜单类型. m.qidian.com SSR 一次返回所有榜单的 5 本, 我们按需消费.
enum QidianRankType: String, CaseIterable {
    case yuepiao        // fyRank   月票榜
    case hotReading     // hotRank  阅读榜
    case bestseller     // dsRank   畅销榜
    case recommend      // recRank  推荐榜
    case update         // updRank  更新榜
    case sign           // signRank 签约榜
    case newAuthor      // newpRank 新人榜
    case newBook        // newbRank 新书榜
    case fans           // newFans  书友榜
    // /finish/ 完结频道 4 个榜单
    case finishClassic  // classic  经典完本
    case finishMovie    // movie    影视化作品
    case finishBestSell // bestSell 完本畅销
    case finishDs       // ds       电视剧改编

    /// vite-ssr JSON 内的 key
    var ssrKey: String {
        switch self {
        case .yuepiao: return "fyRank"
        case .hotReading: return "hotRank"
        case .bestseller: return "dsRank"
        case .recommend: return "recRank"
        case .update: return "updRank"
        case .sign: return "signRank"
        case .newAuthor: return "newpRank"
        case .newBook: return "newbRank"
        case .fans: return "newFans"
        case .finishClassic: return "classic"
        case .finishMovie: return "movie"
        case .finishBestSell: return "bestSell"
        case .finishDs: return "ds"
        }
    }

    /// UI 展示中文榜单名
    var title: String {
        switch self {
        case .yuepiao: return "月票榜"
        case .hotReading: return "阅读榜"
        case .bestseller: return "畅销榜"
        case .recommend: return "推荐榜"
        case .update: return "更新榜"
        case .sign: return "签约榜"
        case .newAuthor: return "新人榜"
        case .newBook: return "新书榜"
        case .fans: return "书友榜"
        case .finishClassic: return "经典完本"
        case .finishMovie: return "影视化作品"
        case .finishBestSell: return "完本畅销"
        case .finishDs: return "电视剧改编"
        }
    }

    /// 是否属于 /finish/ 完结频道 4 榜
    var isFinishRank: Bool {
        switch self {
        case .finishClassic, .finishMovie, .finishBestSell, .finishDs: return true
        default: return false
        }
    }

    /// mirror finish JSON 内的 key
    var finishMirrorKey: String {
        switch self {
        case .finishClassic: return "classic"
        case .finishMovie: return "movie"
        case .finishBestSell: return "bestSell"
        case .finishDs: return "ds"
        default: return ssrKey
        }
    }

    /// /finish/<path> 单榜详情 path
    var finishDetailPath: String? {
        switch self {
        case .finishClassic: return "classic"
        case .finishMovie: return "movie"
        case .finishBestSell: return "bestSell"
        case .finishDs: return "ds"
        default: return nil
        }
    }
}

// MARK: - Search stub

extension QidianBook {
    /// 书城 → 详情页找源用的 SearchBook 占位 (bookUrl 空, 详情页 resolveSourceIfNeeded 补源).
    func toSearchStub() -> SearchBook {
        let tags = [category, subCategory].filter { !$0.isEmpty }
        var kindStr = tags.joined(separator: " · ")
        if !bookId.isEmpty {
            let marker = "qd:\(bookId)"
            kindStr = kindStr.isEmpty ? marker : "\(kindStr) · \(marker)"
        }
        return SearchBook(
            origin: "",
            originName: "起点书城",
            name: name,
            author: author,
            bookUrl: "",
            coverUrl: coverUrl.isEmpty ? nil : coverUrl,
            intro: intro.isEmpty ? nil : intro,
            kind: kindStr.isEmpty ? nil : kindStr,
            wordCount: wordCount.isEmpty ? nil : wordCount
        )
    }

    /// 从 kind 字段解析起点 bookId (格式 `qd:123456`).
    static func extractQidianId(from kind: String?) -> String? {
        guard let kind, !kind.isEmpty else { return nil }
        for part in kind.split(separator: "·").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.hasPrefix("qd:") {
                let id = String(part.dropFirst(3))
                if !id.isEmpty { return id }
            }
        }
        return nil
    }

    private static let qidianCoverTemplate = "https://bookcover.yuewen.com/qdbimg/349573/%@/300"

    /// 查找起点封面 URL: 先查 BookstoreMirror 缓存, 没有则直接搜 m.qidian.com.
    static func lookupQidianCover(name: String) async -> String? {
        guard !name.isEmpty else { return nil }

        let cached = await coverLookupCache.get(name)
        if cached.hit { return cached.url }

        // 1. 快速路径: BookstoreMirror 缓存查找
        if let payload = await BookstoreMirror.shared.fetch() {
            if let url = mirrorLookup(name: name, payload: payload) {
                await coverLookupCache.set(name, url: url)
                return url
            }
        }

        // 2. 慢路径: 搜索 m.qidian.com SSR
        let result = await searchQidianCover(name: name)
        await coverLookupCache.set(name, url: result)
        return result
    }

    private static let coverLookupCache = QidianCoverLookupCache()

    private static func mirrorLookup(name: String, payload: [String: Any]) -> String? {
        func searchInRanks(_ obj: [String: Any]) -> String? {
            for (_, value) in obj {
                guard let arr = value as? [[String: Any]] else { continue }
                if let url = findBid(name: name, in: arr) { return url }
            }
            return nil
        }
        for key in ["ranks", "ranksFemale", "ranksPublish"] {
            if let obj = payload[key] as? [String: Any],
               let url = searchInRanks(obj) { return url }
        }
        if let obj = payload["finish"] as? [String: Any],
           let url = searchInRanks(obj) { return url }
        for key in ["yuepiaoTop50", "yuepiaoTop50Female", "yuepiaoTop50Publish"] {
            if let arr = payload[key] as? [[String: Any]],
               let url = findBid(name: name, in: arr) { return url }
        }
        return nil
    }

    private static func findBid(name: String, in arr: [[String: Any]]) -> String? {
        for item in arr {
            let n = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard n == name else { continue }
            if let bid = item["bid"] as? String, !bid.isEmpty {
                return String(format: qidianCoverTemplate, bid)
            }
            if let bid = item["bid"] as? Int {
                return String(format: qidianCoverTemplate, "\(bid)")
            }
            if let cover = item["coverUrl"] as? String, !cover.isEmpty {
                return cover
            }
        }
        return nil
    }

    /// 搜索 m.qidian.com SSR 页面获取 bookId, 拼接封面 URL.
    private static func searchQidianCover(name: String) async -> String? {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://m.qidian.com/soushu/\(encoded)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else { return nil }

        // SSR: <script type="application/json">{"pageContext":{...}}</script>
        guard let range = html.range(of: "\"bid\":"),
              let numStart = html[range.upperBound...].firstIndex(where: { $0.isNumber }) else { return nil }
        var numEnd = numStart
        while numEnd < html.endIndex && html[numEnd].isNumber { numEnd = html.index(after: numEnd) }
        let bid = String(html[numStart..<numEnd])
        guard !bid.isEmpty else { return nil }
        return String(format: qidianCoverTemplate, bid)
    }
}

/// 起点封面 URL 查询缓存 (内存 + UserDefaults 持久化)
private actor QidianCoverLookupCache {
    private var store: [String: String]
    private var misses: Set<String> = []
    private static let udKey = "wx_qidianCoverCache"

    init() {
        store = UserDefaults.standard.dictionary(forKey: Self.udKey) as? [String: String] ?? [:]
    }

    func get(_ name: String) -> (hit: Bool, url: String?) {
        if let url = store[name] { return (true, url) }
        if misses.contains(name) { return (true, nil) }
        return (false, nil)
    }

    func set(_ name: String, url: String?) {
        if let url = url {
            store[name] = url
            misses.remove(name)
            if store.count > 500 {
                let drop = store.count - 400
                store = Dictionary(uniqueKeysWithValues: Array(store.dropFirst(drop)))
            }
            UserDefaults.standard.set(store, forKey: Self.udKey)
        } else {
            misses.insert(name)
        }
    }
}
