import XCTest
@testable import WanxiangBook

final class UpgradeCompatTests: XCTestCase {

    // MARK: - BookChapterMigration: 换源章节映射

    private func makeChapter(title: String) -> BookChapter {
        BookChapter(bookUrl: "test", title: title, chapterUrl: "")
    }

    func test_mappedDurChapterIndex_emptyNewChapters_returnsOldIndex() {
        let result = BookChapterMigration.mappedDurChapterIndex(
            oldDurChapterIndex: 5,
            oldDurChapterTitle: "第五章 天地初开",
            newChapters: [],
            oldChapterListSize: 100
        )
        XCTAssertEqual(result, 5)
    }

    func test_mappedDurChapterIndex_zeroOldIndex_returnsZero() {
        let chapters = (0..<50).map { makeChapter(title: "第\($0+1)章") }
        let result = BookChapterMigration.mappedDurChapterIndex(
            oldDurChapterIndex: 0,
            oldDurChapterTitle: nil,
            newChapters: chapters,
            oldChapterListSize: 50
        )
        XCTAssertEqual(result, 0)
    }

    func test_mappedDurChapterIndex_exactTitleMatch() {
        let chapters = [
            makeChapter(title: "第一章 楔子"),
            makeChapter(title: "第二章 天命之人"),
            makeChapter(title: "第三章 初入江湖"),
            makeChapter(title: "第四章 剑道初成"),
            makeChapter(title: "第五章 风起云涌"),
        ]
        let result = BookChapterMigration.mappedDurChapterIndex(
            oldDurChapterIndex: 2,
            oldDurChapterTitle: "第三章 初入江湖",
            newChapters: chapters,
            oldChapterListSize: 5
        )
        XCTAssertEqual(result, 2)
    }

    func test_mappedDurChapterIndex_chapterNumFallback() {
        let chapters = [
            makeChapter(title: "章节一 起始"),
            makeChapter(title: "第2章 新的开始"),
            makeChapter(title: "第3章 异世界"),
            makeChapter(title: "第4章 觉醒"),
            makeChapter(title: "第5章 出发"),
        ]
        let result = BookChapterMigration.mappedDurChapterIndex(
            oldDurChapterIndex: 3,
            oldDurChapterTitle: "第四章 完全不同的标题",
            newChapters: chapters,
            oldChapterListSize: 5
        )
        XCTAssertEqual(result, 3, "应通过章节编号 4 匹配到 index 3")
    }

    func test_mappedDurChapterIndex_newChaptersShorterThanOldIndex() {
        let chapters = [
            makeChapter(title: "第1章"),
            makeChapter(title: "第2章"),
            makeChapter(title: "第3章"),
        ]
        let result = BookChapterMigration.mappedDurChapterIndex(
            oldDurChapterIndex: 100,
            oldDurChapterTitle: "第100章 大结局",
            newChapters: chapters,
            oldChapterListSize: 200
        )
        XCTAssertTrue(result >= 0 && result < chapters.count,
                       "结果 \(result) 应在 [0, \(chapters.count)) 范围内")
    }

    func test_mappedDurChapterIndex_chineseNumericChapterTitle() {
        let chapters = (1...20).map { makeChapter(title: "第\(chineseNum($0))章 内容\($0)") }
        let result = BookChapterMigration.mappedDurChapterIndex(
            oldDurChapterIndex: 9,
            oldDurChapterTitle: "第十章 旧版标题",
            newChapters: chapters,
            oldChapterListSize: 20
        )
        XCTAssertEqual(result, 9, "中文数字'十'应映射到 index 9 (第十章)")
    }

    private func chineseNum(_ n: Int) -> String {
        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        if n <= 10 { return digits[n] }
        if n < 20 { return "十\(digits[n - 10])" }
        return "二十"
    }
}
