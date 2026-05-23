import XCTest
@testable import WanxiangBook

final class ReaderEngineTests: XCTestCase {

    // MARK: - 章节边界检查

    @MainActor
    func test_goToChapter_clampsToValidRange() async {
        let book = ShelfBook.stub(name: "测试书", durChapterIndex: 0)
        let engine = ReaderEngine(book: book)
        await engine.setChaptersForTesting([
            BookChapter.stub(index: 0, title: "第1章"),
            BookChapter.stub(index: 1, title: "第2章"),
            BookChapter.stub(index: 2, title: "第3章"),
        ])

        await engine.goToChapter(-1)
        XCTAssertEqual(engine.currentChapterIndex, 0, "负数索引应被拒绝")

        await engine.goToChapter(999)
        XCTAssertEqual(engine.currentChapterIndex, 0, "超出范围应被拒绝")
    }

    @MainActor
    func test_nextChapter_incrementsIndex() async {
        let book = ShelfBook.stub(name: "测试书", durChapterIndex: 0)
        let engine = ReaderEngine(book: book)
        await engine.setChaptersForTesting([
            BookChapter.stub(index: 0, title: "第1章"),
            BookChapter.stub(index: 1, title: "第2章"),
        ])

        await engine.goToChapter(0)
        await engine.nextChapter()
        XCTAssertEqual(engine.currentChapterIndex, 1)
    }

    @MainActor
    func test_previousChapter_decrementsIndex() async {
        let book = ShelfBook.stub(name: "测试书", durChapterIndex: 1)
        let engine = ReaderEngine(book: book)
        await engine.setChaptersForTesting([
            BookChapter.stub(index: 0, title: "第1章"),
            BookChapter.stub(index: 1, title: "第2章"),
        ])

        await engine.goToChapter(1)
        await engine.previousChapter()
        XCTAssertEqual(engine.currentChapterIndex, 0)
    }

    // MARK: - 内容缓存

    @MainActor
    func test_contentCache_returnsNilForUnloaded() {
        let book = ShelfBook.stub(name: "测试书")
        let engine = ReaderEngine(book: book)
        XCTAssertNil(engine.content(for: 0))
        XCTAssertNil(engine.content(for: -1))
        XCTAssertNil(engine.content(for: 999))
    }

    // MARK: - 空目录防护

    @MainActor
    func test_goToChapter_withEmptyChapters_doesNotCrash() async {
        let book = ShelfBook.stub(name: "空书")
        let engine = ReaderEngine(book: book)
        await engine.goToChapter(0)
        XCTAssertEqual(engine.currentChapterIndex, 0)
    }
}
