//
//  SearchLegadoOrderingTests.swift
//  验证 iOS 搜索结果排序与 Android SearchModel.mergeItems 分层一致 (完全匹配 > 包含 > 其余)
//

import XCTest
@testable import WanxiangBook

final class SearchLegadoOrderingTests: XCTestCase {

    /// 对齐 Android `SearchModel.mergeItems` 真实行为: tier 排序后, **同档保留输入顺序**.
    /// (Android 用 stable `sortByDescending { it.origins.size }` — 源数全相等时不动顺序.)
    /// 旧版本 iOS 还做 hasPrefix / 字典序 把 "青山之恋" 顶上来, 现已退化成与 Android 一致.
    func test_ordering_exactMatchBeforeContains() {
        let books = [
            makeSB(name: "住在青山", author: "某甲"),
            makeSB(name: "青山", author: "李四"),
            makeSB(name: "青山之恋", author: "王五"),
        ]
        let sorted = SearchLegadoOrdering.sort(books: books, key: "青山", precision: false)
        XCTAssertEqual(sorted.map(\.name), ["青山", "住在青山", "青山之恋"],
                       "tier=0 优先; tier=1 内 origins 都=1 时保留输入顺序 (与 Android stable sort 行为一致)")
    }

    func test_precision_dropsNonMatching() {
        let books = [
            makeSB(name: "无关", author: "张三"),
            makeSB(name: "青山", author: "李四"),
        ]
        let sorted = SearchLegadoOrdering.sort(books: books, key: "青山", precision: true)
        XCTAssertEqual(sorted.count, 1)
        XCTAssertEqual(sorted.first?.name, "青山")
    }

    func test_relevanceTier_authorExactMatch() {
        let b = makeSB(name: "某书", author: "青山")
        XCTAssertEqual(SearchLegadoOrdering.relevanceTier(book: b, key: "青山"), 0)
    }

    /// 对齐 Android: 同 relevance 档内 `origins.size` 大的在前
    func test_ordering_moreOriginsFirstWhenSameTier() {
        var one = makeSB(name: "青山之恋", author: "王五", url: "https://a/x")
        one.mergedSourceURLs = []
        var two = makeSB(name: "青山之恋", author: "王五", url: "https://b/x")
        two.mergedSourceURLs = ["https://c", "https://d"]
        two.mergedSourceNames = ["C", "D"]
        let books = [one, two]
        let sorted = SearchLegadoOrdering.sort(books: books, key: "青山", precision: false)
        XCTAssertEqual(sorted.first?.distinctOriginCount, 3)
        XCTAssertEqual(sorted.last?.distinctOriginCount, 1)
    }
}

private func makeSB(name: String, author: String, url: String = "https://ex.test") -> SearchBook {
    SearchBook(
        origin: url,
        originName: "测试源",
        name: name,
        author: author,
        bookUrl: "\(url)/b/\(name)-\(author)"
    )
}
