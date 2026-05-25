import XCTest
@testable import WanxiangBook

final class BookshelfTocUpdaterTests: XCTestCase {

    func test_emptyBooksReturnsZero() async {
        let result = await BookshelfTocUpdater.update(books: [])
        XCTAssertEqual(result.ok, 0)
        XCTAssertEqual(result.failed, 0)
    }
}
