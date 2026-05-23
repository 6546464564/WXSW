import XCTest
@testable import WanxiangBook

final class PerformanceTests: XCTestCase {

    // MARK: - 分页性能

    func test_paginationPerformance_shortChapter() {
        let content = String(repeating: "测试分页性能的文本内容。每段大约二十个字。\n", count: 50)
        measure {
            _ = PaginationEngine.paginate(
                content: content,
                chapterIndex: 0,
                chapterTitle: "短章节",
                totalChapters: 100,
                viewport: CGSize(width: 375, height: 667),
                config: .testDefault
            )
        }
    }

    func test_paginationPerformance_longChapter() {
        let content = String(repeating: "这是一段较长的测试文本，模拟一个正常章节的内容。每个段落大约有四五十个字符，用于测试分页引擎在处理大量文本时的性能表现。\n\n", count: 200)
        measure {
            _ = PaginationEngine.paginate(
                content: content,
                chapterIndex: 50,
                chapterTitle: "长章节性能测试",
                totalChapters: 1000,
                viewport: CGSize(width: 375, height: 812),
                config: .testDefault
            )
        }
    }

    // MARK: - 搜索去重性能

    func test_searchDedupePerformance() {
        var books: [SearchBook] = []
        for i in 0..<500 {
            books.append(SearchBook.stub(
                name: "小说\(i % 50)",
                author: "作者\(i % 20)",
                origin: "https://source\(i).com"
            ))
        }
        measure {
            var seen = Set<String>()
            var result: [SearchBook] = []
            for book in books {
                let key = book.dedupeKey
                if seen.insert(key).inserted {
                    result.append(book)
                }
            }
            XCTAssertGreaterThan(result.count, 0)
        }
    }

    // MARK: - 图片缓存性能

    func test_imageURLParsingPerformance() {
        let urls = (0..<100).map {
            "https://img\($0).example.com/cover/\($0).jpg,{\"headers\":{\"Referer\":\"https://source\($0).com/\"}}"
        }
        measure {
            for url in urls {
                _ = BookCover.makeImageRequestPublic(from: url)
            }
        }
    }

    // MARK: - 内存基准

    func test_memoryBaseline_readerEngineInit() {
        measure(metrics: [XCTMemoryMetric()]) {
            autoreleasepool {
                let book = ShelfBook.stub(name: "内存测试书")
                let engine = ReaderEngine(book: book)
                _ = engine.currentChapterIndex
            }
        }
    }

    // MARK: - 启动时间基准

    func test_appState_bootstrapTime() {
        measure(metrics: [XCTClockMetric()]) {
            let exp = expectation(description: "bootstrap")
            Task { @MainActor in
                let state = AppState()
                await state.bootstrap()
                exp.fulfill()
            }
            wait(for: [exp], timeout: 30)
        }
    }
}
