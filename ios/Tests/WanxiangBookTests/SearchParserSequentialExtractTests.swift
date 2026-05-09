//
//  SearchParserSequentialExtractTests.swift
//  万象书屋 iOS · D-25 解决"搜索结果 19 本书全显示成同一本"
//
//  用户报告: 在书城点「玄鉴仙族」 → 搜索结果 19 条全是同一本书 (实际 QQ浏览器柳树
//  返回的 19 本不同的书). Root cause:
//   - extractBook 之前用 async let 并发解析所有字段, bookUrl 模板里
//     {{book.kind}} 在 kind 还没 publish 时被求值 → 拼出全相同的 URL
//   - SwiftUI ForEach(id: \.bookUrl) 把 19 个 SearchBook 当同一个 row 渲染
//
//  修复: SearchParser.extractBook 改成顺序解析并 publish 到 scope.book;
//        SearchView ForEach 改用 listRowId (origin+name+author+bookUrl).
//

import XCTest
@testable import WanxiangBook

final class SearchParserSequentialExtractTests: XCTestCase {

    /// SearchBook.listRowId 必须能区分 "bookUrl 全相同但 name/author 不同" 的退化场景.
    /// 这条测在 SearchParser 修好之后变得不那么必需 (bookUrl 各不相同), 但留作守护:
    /// 如果未来有源又把 bookUrl 拼空了, listRowId 至少不会让 UI 退化成全是同一条.
    func test_listRowId_isStable_whenBookUrlAccidentallyEqual() {
        let a = SearchBook(
            origin: "https://qq.example",
            originName: "QQ浏览器柳树",
            name: "玄鉴仙族",
            author: "季越人",
            bookUrl: "https://novel.html5.qq.com/qbread/api/novel/bookInfo?resourceId="
        )
        let b = SearchBook(
            origin: "https://qq.example",
            originName: "QQ浏览器柳树",
            name: "天荒玄鉴",
            author: "精灵夜火",
            bookUrl: "https://novel.html5.qq.com/qbread/api/novel/bookInfo?resourceId="
        )
        XCTAssertNotEqual(a.listRowId, b.listRowId,
                         "listRowId 必须能区分两本不同的书, 即使 bookUrl 因解析 bug 全相同")
    }

    /// 同一本书 (跨源, 同 name+author 但 origin 和 bookUrl 不同) 给 listRowId 不同
    /// — 保留 SearchView 的 dedupe 责任 (按 dedupeKey), listRowId 只负责
    ///   "已 dedupe 后的不同 row 必须有不同 id".
    func test_listRowId_distinguishesSameBookFromDifferentSources() {
        let qq = SearchBook(
            origin: "https://qq.example",
            originName: "QQ浏览器柳树",
            name: "玄鉴仙族",
            author: "季越人",
            bookUrl: "https://qq.example/book/123"
        )
        let suduguShould = SearchBook(
            origin: "https://www.sudugu.org",
            originName: "速读谷",
            name: "玄鉴仙族",
            author: "季越人",
            bookUrl: "https://www.sudugu.org/53/"
        )
        XCTAssertEqual(qq.dedupeKey, suduguShould.dedupeKey,
                      "跨源同名同作者: dedupeKey 应该一样 (会被 ViewModel 合一条)")
        XCTAssertNotEqual(qq.listRowId, suduguShould.listRowId,
                         "如果 dedupe 漏了, listRowId 至少保证 UI 上 ForEach 不冲突")
    }
}
