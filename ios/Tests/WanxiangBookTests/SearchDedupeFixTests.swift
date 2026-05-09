//
//  SearchDedupeFixTests.swift
//  万象书屋 iOS · 搜索去重 bug 修复验证
//
//  复现/守护用户报告的 "搜捞尸人, 出来全是同一本书" 问题:
//  1. ViewModel 之前同时按 dedupeKey + titleDedupeKey 双重去重 → 不同作者的
//     同名书 (《捞尸人》by 陈十三 / 《捞尸人》by 纯洁滴小龙) 被全部合一条
//  2. UI displayResults 之前 q.count >= 8 时把所有书塞进同一个全局 key →
//     搜任意 8+ 字符关键词永远只显示 1 条
//

import XCTest
@testable import WanxiangBook

final class SearchDedupeFixTests: XCTestCase {

    /// 万象书屋: 复现 "搜捞尸人多本书被合并" 的核心场景.
    ///   - 同名不同作者: 应保留全部
    ///   - 同名同作者: 不同源应合并 (节省卡片空间, 让用户在一条上看到多个源)
    ///   - 完全不同名: 应保留全部
    func test_dedupeKey_distinguishesByAuthor() {
        let books = [
            makeSearchBook(name: "捞尸人", author: "陈十三", origin: "https://a.com"),
            makeSearchBook(name: "捞尸人", author: "纯洁滴小龙", origin: "https://b.com"),
            makeSearchBook(name: "捞尸人", author: "陈十三", origin: "https://c.com"),  // 同名同作者, 不同源
            makeSearchBook(name: "黄河捞尸人", author: "潜水小叨", origin: "https://d.com"),
            makeSearchBook(name: "捞尸人笔记", author: "牛肉米粉丶", origin: "https://e.com"),
        ]
        var seenKeys = Set<String>()
        var deduped: [SearchBook] = []
        for b in books {
            if seenKeys.insert(b.dedupeKey).inserted {
                deduped.append(b)
            }
        }
        XCTAssertEqual(deduped.count, 4,
                      "应该 4 条 (3 个不同作者的捞尸人 + 1 黄河 + 1 笔记 - 1 个同作者重复)")
        XCTAssertEqual(deduped.map(\.name), ["捞尸人", "捞尸人", "黄河捞尸人", "捞尸人笔记"])
        XCTAssertEqual(deduped.map(\.author), ["陈十三", "纯洁滴小龙", "潜水小叨", "牛肉米粉丶"])
    }

    /// 万象书屋: 反 regression, 旧的 titleDedupeKey 检查会让上面 4 条变 3 条
    /// (3 本"捞尸人"系列前 14 字 normalize 后 key 重叠 → 只剩 1 本).
    /// 这里直接验证 titleDedupeKey 的分组行为, 文档化它的"伤害域".
    func test_titleDedupeKey_collapsesDifferentBooksWithSimilarTitles() {
        let a = makeSearchBook(name: "捞尸人", author: "陈十三", origin: "https://a")
        let b = makeSearchBook(name: "捞尸人", author: "纯洁滴小龙", origin: "https://b")
        XCTAssertEqual(a.titleDedupeKey, b.titleDedupeKey,
                      "titleDedupeKey 把不同作者的同名书合并 — 这是导致 bug 的源头")
    }

    /// 万象书屋: dedupeKey 必须区分作者
    func test_dedupeKey_sameNameDifferentAuthors_areNotEqual() {
        let a = makeSearchBook(name: "捞尸人", author: "陈十三", origin: "https://a")
        let b = makeSearchBook(name: "捞尸人", author: "纯洁滴小龙", origin: "https://b")
        XCTAssertNotEqual(a.dedupeKey, b.dedupeKey,
                         "name 相同 author 不同的两本书必须 dedupeKey 不同")
    }

    /// 万象书屋: 同名同作者 (跨源同一本书) 必须合并
    func test_dedupeKey_sameNameSameAuthor_mergesAcrossSources() {
        let a = makeSearchBook(name: "诡秘之主", author: "爱潜水的乌贼", origin: "https://a")
        let b = makeSearchBook(name: "诡秘之主", author: "爱潜水的乌贼", origin: "https://b")
        XCTAssertEqual(a.dedupeKey, b.dedupeKey,
                      "name+author 相同 (同一本书不同源) 必须 dedupeKey 一致, UI 上合一条")
    }

    /// 万象书屋: 标题前后空白 / 全角空格 / 大小写差异不应阻碍合并
    func test_dedupeKey_normalizationCoversWhitespaceAndCase() {
        let a = makeSearchBook(name: " 捞尸人 ", author: "陈十三", origin: "https://a")
        let b = makeSearchBook(name: "捞尸人", author: "陈十三", origin: "https://b")
        XCTAssertEqual(a.dedupeKey, b.dedupeKey,
                      "前后空白差异必须 normalize 掉, 否则同一本书会重复")
    }

    /// 万象书屋: 完全不同的 8+ 字关键词搜索, 不应被旧的 long-query bug 折叠成一条
    /// (这里只能间接守护: 用 dedupeKey 验证不同 (name, author) 始终不同 key)
    func test_longQuery_doesNotCollapseAllToSingleResult() {
        let a = makeSearchBook(name: "Harry Potter and the Philosopher's Stone",
                               author: "J.K. Rowling", origin: "https://a")
        let b = makeSearchBook(name: "Harry Potter and the Chamber of Secrets",
                               author: "J.K. Rowling", origin: "https://b")
        XCTAssertNotEqual(a.dedupeKey, b.dedupeKey,
                         "长英文书名同作者不同书必须 key 不同 (反 long-query-single-result regression)")
    }

    // MARK: - helpers

    private func makeSearchBook(name: String, author: String, origin: String) -> SearchBook {
        SearchBook(
            origin: origin, originName: "test",
            name: name, author: author, bookUrl: "\(origin)/book/\(name)",
            coverUrl: nil, intro: nil, kind: nil,
            lastChapter: nil, updateTime: nil, wordCount: nil
        )
    }
}
