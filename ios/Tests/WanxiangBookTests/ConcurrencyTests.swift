import XCTest
@testable import WanxiangBook

/// 并发测试：多线程安全、竞态条件检测
final class ConcurrencyTests: XCTestCase {

    // MARK: - C1: ReaderEngine 并发访问不崩溃

    @MainActor
    func test_readerEngine_concurrentAccess() async {
        let book = ShelfBook.stub(name: "并发测试书")
        let engine = ReaderEngine(book: book)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { @MainActor in
                    _ = engine.content(for: i)
                }
            }
        }
    }

    // MARK: - C2: BookSourceRegistry 并发查询

    func test_sourceRegistry_concurrentFind() async {
        let registry = await BookSourceRegistry.shared
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    _ = await registry.find(origin: "https://fake\(i).com")
                }
            }
        }
    }

    // MARK: - C3: 图片缓存并发写入

    func test_imageCacheConcurrentWrite() {
        let cache = BookCoverImageCache.shared
        let group = DispatchGroup()

        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                let img = UIImage(systemName: "book.fill")!
                cache.set(img, for: "concurrent_test_\(i)")
                _ = cache.image(for: "concurrent_test_\(i)")
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 10)
        XCTAssertEqual(result, .success, "并发图片缓存操作应在10秒内完成")
    }

    // MARK: - C4: 章节缓存并发读写

    func test_chapterRepository_concurrentOps() async throws {
        let baseUrl = "test://concurrent_\(UUID().uuidString)"
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try await ChapterRepository.shared.saveContent(
                        bookUrl: baseUrl, chapterIndex: i, content: "内容\(i)"
                    )
                }
            }
            try await group.waitForAll()
        }

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let content = try? await ChapterRepository.shared.loadContent(
                        bookUrl: baseUrl, chapterIndex: i
                    )
                    XCTAssertNotNil(content, "并发写入的章节\(i)应能读回")
                }
            }
        }
    }

    // MARK: - C5: 分页引擎并发调用

    func test_pagination_concurrentCalls() {
        let content = String(repeating: "并发分页测试文本内容。", count: 100)
        let group = DispatchGroup()

        for i in 0..<10 {
            group.enter()
            DispatchQueue.global().async {
                let pages = PaginationEngine.paginate(
                    content: content,
                    chapterIndex: i,
                    chapterTitle: "章节\(i)",
                    totalChapters: 100,
                    viewport: CGSize(width: 375, height: 667),
                    config: .testDefault
                )
                XCTAssertGreaterThan(pages.count, 0, "并发分页应返回结果")
                group.leave()
            }
        }

        let result = group.wait(timeout: .now() + 30)
        XCTAssertEqual(result, .success, "并发分页应在30秒内完成")
    }
}
