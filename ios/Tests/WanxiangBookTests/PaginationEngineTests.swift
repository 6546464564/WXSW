import XCTest
@testable import WanxiangBook

final class PaginationEngineTests: XCTestCase {

    private let canvasSize = CGSize(width: 335, height: 700)
    private let config = ReadConfigSnapshot(
        textSize: 18, lineSpacing: 1.2, paragraphSpacing: 6,
        letterSpacing: 0, indentChars: 2, fontFamily: ""
    )

    func testLongChapterCoversAllCharacters() {
        let paragraph = "　　这是用于测试长章分页的段落内容，需要确保每一页都能正确填充，不会出现后面页码丢失或正文截断的问题。"
        let body = (1...800).map { "第\($0)段" + String(paragraph.dropFirst(2)) }.joined(separator: "\n")
        let pages = PaginationEngine.paginate(
            text: body, chapterIndex: 0, chapterTitle: "长章测试",
            canvasSize: canvasSize, config: config
        )
        XCTAssertGreaterThan(pages.count, 50, "长章应分出足够页数")
        let attr = PaginationEngine.buildChapterAttrString(
            text: body, chapterTitle: "长章测试", config: config)
        let covered = pages.reduce(0) { $0 + $1.charLength }
        XCTAssertEqual(covered, attr.length, "所有字符都应被分页覆盖，后半段不能丢失")
        XCTAssertEqual((pages.last?.charOffset ?? 0) + (pages.last?.charLength ?? 0), attr.length)
    }

    func testAdjacentChapterCapKeepsCurrentChapterIntact() {
        let short = String(repeating: "短章内容。", count: 20)
        let pages = PaginationEngine.paginate(
            text: short, chapterIndex: 5, chapterTitle: "第五章",
            canvasSize: canvasSize, config: config
        )
        XCTAssertFalse(pages.isEmpty)
        XCTAssertEqual(pages.first?.chapterIndex, 5)
        XCTAssertEqual(pages.last?.totalPages, pages.count)
    }
}
