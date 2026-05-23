import XCTest
@testable import WanxiangBook

final class PaginationEngineTests: XCTestCase {

    func test_paginate_emptyContent_returnsEmptyPages() {
        let pages = PaginationEngine.paginate(
            content: "",
            chapterIndex: 0,
            chapterTitle: "空章节",
            totalChapters: 10,
            viewport: CGSize(width: 375, height: 667),
            config: .testDefault
        )
        XCTAssertTrue(pages.isEmpty || pages.count == 1, "空内容应返回0或1页")
    }

    func test_paginate_shortContent_returnsSinglePage() {
        let pages = PaginationEngine.paginate(
            content: "这是一段很短的正文。",
            chapterIndex: 0,
            chapterTitle: "短章节",
            totalChapters: 10,
            viewport: CGSize(width: 375, height: 667),
            config: .testDefault
        )
        XCTAssertEqual(pages.count, 1, "短内容应分为1页")
        XCTAssertTrue(pages.first?.isFirstPage ?? false)
        XCTAssertTrue(pages.first?.isLastPage ?? false)
    }

    func test_paginate_longContent_returnsMultiplePages() {
        let longText = String(repeating: "这是一段很长的正文内容，用于测试分页逻辑。", count: 200)
        let pages = PaginationEngine.paginate(
            content: longText,
            chapterIndex: 5,
            chapterTitle: "长章节",
            totalChapters: 100,
            viewport: CGSize(width: 375, height: 667),
            config: .testDefault
        )
        XCTAssertGreaterThan(pages.count, 1, "长内容应分为多页")
        XCTAssertTrue(pages.first?.isFirstPage ?? false)
        XCTAssertTrue(pages.last?.isLastPage ?? false)
    }

    func test_paginate_differentViewportSizes() {
        let content = String(repeating: "测试文本用于验证不同屏幕尺寸。", count: 100)
        let smallPages = PaginationEngine.paginate(
            content: content,
            chapterIndex: 0,
            chapterTitle: "测试",
            totalChapters: 1,
            viewport: CGSize(width: 320, height: 480),
            config: .testDefault
        )
        let largPages = PaginationEngine.paginate(
            content: content,
            chapterIndex: 0,
            chapterTitle: "测试",
            totalChapters: 1,
            viewport: CGSize(width: 430, height: 932),
            config: .testDefault
        )
        XCTAssertGreaterThanOrEqual(smallPages.count, largPages.count,
            "小屏应分出更多页 (或相等)")
    }
}
