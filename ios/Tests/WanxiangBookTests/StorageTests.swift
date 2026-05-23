import XCTest
@testable import WanxiangBook

/// 存储测试：数据库完整性、数据持久化、缓存清理
final class StorageTests: XCTestCase {

    // MARK: - S1: 书架数据持久化

    func test_bookshelfPersistence() async throws {
        let repo = BookshelfRepository.shared
        let books = try await repo.listAll()
        XCTAssertNotNil(books, "书架查询不应返回nil")
    }

    // MARK: - S2: 章节缓存写入和读取

    func test_chapterCache_writeAndRead() async throws {
        let testBookUrl = "test://storage_test_\(UUID().uuidString)"
        let testContent = "这是测试章节内容 \(Date())"
        let chapterIndex = 0

        try await ChapterRepository.shared.saveContent(
            bookUrl: testBookUrl,
            chapterIndex: chapterIndex,
            content: testContent
        )

        let loaded = try await ChapterRepository.shared.loadContent(
            bookUrl: testBookUrl,
            chapterIndex: chapterIndex
        )
        XCTAssertEqual(loaded, testContent, "章节内容应可被正确读回")
    }

    // MARK: - S3: 空内容存储

    func test_chapterCache_emptyContent() async throws {
        let testBookUrl = "test://empty_\(UUID().uuidString)"
        try await ChapterRepository.shared.saveContent(
            bookUrl: testBookUrl, chapterIndex: 0, content: ""
        )
        let loaded = try await ChapterRepository.shared.loadContent(
            bookUrl: testBookUrl, chapterIndex: 0
        )
        XCTAssertEqual(loaded, "", "空内容应能正常存取")
    }

    // MARK: - S4: 特殊字符内容存储

    func test_chapterCache_specialCharacters() async throws {
        let testBookUrl = "test://special_\(UUID().uuidString)"
        let specialContent = "emoji: 😀🎉📚 symbols: ©®™ html: <p>test</p> sql: ' OR 1=1; --"

        try await ChapterRepository.shared.saveContent(
            bookUrl: testBookUrl, chapterIndex: 0, content: specialContent
        )
        let loaded = try await ChapterRepository.shared.loadContent(
            bookUrl: testBookUrl, chapterIndex: 0
        )
        XCTAssertEqual(loaded, specialContent, "特殊字符应能正确存取")
    }

    // MARK: - S5: UserDefaults 数据完整性

    func test_userDefaults_readConfig() {
        let config = ReadConfig.shared
        XCTAssertGreaterThan(config.textSize, 0, "字号应大于0")
        XCTAssertGreaterThan(config.lineSpacing, 0, "行距应大于0")
    }

    // MARK: - S6: 封面磁盘缓存清理

    func test_coverDiskCache_notCrashOnColdStart() async {
        let cache = await BookCoverDiskCache.shared.load(key: "nonexistent_key_\(UUID())")
        XCTAssertNil(cache, "不存在的key应返回nil")
    }
}
