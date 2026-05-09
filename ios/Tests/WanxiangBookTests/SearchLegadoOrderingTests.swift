//
//  SearchLegadoOrderingTests.swift
//  验证 iOS 搜索结果排序与 Android SearchModel.mergeItems 分层一致 (完全匹配 > 包含 > 其余)
//

import XCTest
@testable import WanxiangBook

final class SearchLegadoOrderingTests: XCTestCase {

    func test_ordering_exactMatchBeforeContains() {
        let books = [
            makeSB(name: "住在青山", author: "某甲"),
            makeSB(name: "青山", author: "李四"),
            makeSB(name: "青山之恋", author: "王五"),
        ]
        let sorted = SearchLegadoOrdering.sort(books: books, key: "青山", precision: false)
        XCTAssertEqual(sorted.map(\.name), ["青山", "青山之恋", "住在青山"])
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
}

private func makeSB(name: String, author: String) -> SearchBook {
    SearchBook(
        origin: "https://ex.test",
        originName: "测试源",
        name: name,
        author: author,
        bookUrl: "https://ex.test/b/\(name)-\(author)"
    )
}
