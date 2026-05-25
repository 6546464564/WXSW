import XCTest
@testable import WanxiangBook

final class BookshelfModelTests: XCTestCase {

    private func book(
        total: Int = 0,
        index: Int = 0,
        pos: Int = 0
    ) -> ShelfBook {
        var b = ShelfBook(
            bookUrl: "https://example.com/book/1",
            name: "测试书",
            author: "作者",
            origin: "https://source.test",
            originName: "测试源"
        )
        b.totalChapterNum = total
        b.durChapterIndex = index
        b.durChapterPos = pos
        return b
    }

    func test_unreadChapterNum_midProgress() {
        let b = book(total: 100, index: 48)
        XCTAssertEqual(b.unreadChapterNum, 51)
        XCTAssertEqual(b.progressText, "49/100")
    }

    func test_unreadChapterNum_finished() {
        let b = book(total: 50, index: 49)
        XCTAssertEqual(b.unreadChapterNum, 0)
        XCTAssertEqual(b.progressText, "已读完")
    }

    func test_unreadChapterNum_noTotal() {
        let b = book(total: 0, index: 0)
        XCTAssertEqual(b.unreadChapterNum, 0)
        XCTAssertEqual(b.progressText, "未读")
    }

    func test_unreadChapterNum_unreadAtStart() {
        let b = book(total: 200, index: 0, pos: 0)
        XCTAssertEqual(b.unreadChapterNum, 199)
        XCTAssertEqual(b.progressText, "未读")
    }

    func test_progress_clampedToOne() {
        let b = book(total: 10, index: 9)
        XCTAssertEqual(b.progress, 1.0, accuracy: 0.001)
    }
}
