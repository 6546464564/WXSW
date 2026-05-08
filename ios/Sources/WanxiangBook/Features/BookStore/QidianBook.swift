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
/// D-22.1: 起点 m 站对 ?gender=female 反爬挡 + fallback male, 客户端在 RankType 映射上做差异化.
/// Publish 走独立 endpoint /finish/ (m.qidian 真完结频道, 4 完结榜).
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
}
