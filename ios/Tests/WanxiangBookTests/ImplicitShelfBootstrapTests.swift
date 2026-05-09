//
//  ImplicitShelfBootstrapTests.swift
//  万象书屋 iOS · D-25 隐式加架 + 阅读进度持久化 验证
//
//  用户语义 (来自用户原话): "把ios里面书城的书籍都添加到书籍并阅读, 从中发现问题"
//  对应的真实路径: 书城 → 详情 → 直接点"开始阅读" → 阅读后退出
//
//  修复前的 BUG:
//   1. ReaderEngine.bootstrap 不 ensure 书在 books 表
//   2. BookshelfRepository.updateProgress 是纯 UPDATE → row 不存在静默丢
//   → 结果: 用户读完一本, 退出阅读器, 书架还是空的; 进度白丢, 下次进还是第 1 章
//
//  修复后:
//   1. ReaderEngine.bootstrap 第一行: BookshelfRepository.shared.add(book)
//      (idempotent: ON CONFLICT DO UPDATE 保留进度)
//   2. ReaderEngine.bootstrap 拿到 toc 后: updateTotalChapters 写回章节数
//   3. goToChapter 调 updateProgress: row 现在一定存在 → 进度持久化
//

import XCTest
@testable import WanxiangBook

@MainActor
final class ImplicitShelfBootstrapTests: XCTestCase {

    /// 用户场景: 从书城点开 → 详情 → 开始阅读, **完全没点过"加书架"**.
    /// 期望: 退出阅读器后, 这本书出现在书架, 且 totalChapterNum > 0.
    func test_reader_addsBookToShelf_evenWithoutExplicitAddTap() async throws {
        // Arrange: 完全干净的状态 — 这本 bookUrl 不在书架
        let bookUrl = "wxsw://test/d25/implicit-add/\(UUID().uuidString)"
        try? await BookshelfRepository.shared.remove(bookUrl: bookUrl)
        let preCount = await isInShelf(bookUrl: bookUrl)
        XCTAssertFalse(preCount, "前置: 这本书不应该在书架")

        // Act: 模拟"详情 → 开始阅读" — 直接进 ReaderEngine.bootstrap
        let shelfBook = ShelfBook(
            bookUrl: bookUrl,
            name: "D-25 隐式加架测试书",
            author: "测试作者",
            origin: "https://example.test/source",
            originName: "测试源",
            coverUrl: nil, intro: nil, kind: nil,
            tocUrl: bookUrl
        )
        let engine = ReaderEngine(book: shelfBook, source: nil)

        // bootstrap 会调 BookshelfRepository.shared.add(book) — 不需要等真拉 toc
        // (没源时会在拿 toc 那步 fail, 但 add 已经先调了)
        await engine.bootstrap()

        // Assert: 书已经在书架
        let inShelf = await isInShelf(bookUrl: bookUrl)
        XCTAssertTrue(inShelf, "ReaderEngine.bootstrap 必须自动把书写入 books 表")

        // 清理
        try? await BookshelfRepository.shared.remove(bookUrl: bookUrl)
    }

    /// 用户场景: 加架后回去再读, 不能覆盖之前的阅读进度
    /// (隐式 add 必须 idempotent, 不能把 durChapterIndex 重置回 0)
    func test_implicitAdd_doesNotResetReadingProgress() async throws {
        let bookUrl = "wxsw://test/d25/preserve-progress/\(UUID().uuidString)"
        defer {
            Task { try? await BookshelfRepository.shared.remove(bookUrl: bookUrl) }
        }

        // 1. 用户先正常加架 + 读到第 5 章
        let original = ShelfBook(
            bookUrl: bookUrl, name: "保留进度测试书", author: "作者",
            origin: "https://example.test/source", originName: "源", tocUrl: bookUrl
        )
        try await BookshelfRepository.shared.add(original)
        try await BookshelfRepository.shared.updateProgress(
            bookUrl: bookUrl, chapterIndex: 5, chapterTitle: "第六章", chapterPos: 0
        )

        // 2. 假装下次启动 ReaderEngine, 触发隐式 add
        let engine = ReaderEngine(book: original, source: nil)
        await engine.bootstrap()  // 内部会 add(book), 应该走 ON CONFLICT DO UPDATE 但不动进度

        // 3. 验证进度还在
        let after = try await BookshelfRepository.shared.get(bookUrl: bookUrl)
        XCTAssertNotNil(after)
        XCTAssertEqual(after?.durChapterIndex, 5,
                      "ReaderEngine.bootstrap 隐式 add 不能覆盖既有的阅读进度")
        XCTAssertEqual(after?.durChapterTitle, "第六章")
    }

    /// 用户场景: 阅读到第 N 章, 退出后书架显示 X/N
    /// 关键: updateTotalChapters 要让书架进度条 (durChapterIndex / totalChapterNum) 真显数字
    func test_updateTotalChapters_writesBackForShelfProgressBar() async throws {
        let bookUrl = "wxsw://test/d25/total-chapters/\(UUID().uuidString)"
        defer {
            Task { try? await BookshelfRepository.shared.remove(bookUrl: bookUrl) }
        }

        let book = ShelfBook(
            bookUrl: bookUrl, name: "章节数测试书", author: "作者",
            origin: "https://example.test/source", originName: "源", tocUrl: bookUrl
        )
        try await BookshelfRepository.shared.add(book)

        // 模拟 ReaderEngine.bootstrap 拿到 toc 后回写
        try await BookshelfRepository.shared.updateTotalChapters(
            bookUrl: bookUrl, total: 1234, latestTitle: "第 1234 章 完结撒花"
        )

        let after = try await BookshelfRepository.shared.get(bookUrl: bookUrl)
        XCTAssertEqual(after?.totalChapterNum, 1234,
                      "totalChapterNum 必须被写回, 否则书架永远显示'未读'")
        XCTAssertEqual(after?.latestChapterTitle, "第 1234 章 完结撒花")

        // 验证 progressText 不再是"未读"
        var afterWithProgress = after!
        afterWithProgress.durChapterIndex = 100
        XCTAssertEqual(afterWithProgress.progressText, "101/1234")
    }

    /// 用户场景: row 不存在时 updateTotalChapters 必须 silently no-op (不能 throw)
    func test_updateTotalChapters_noRow_silentNoOp() async throws {
        let nonExistentUrl = "wxsw://test/d25/no-row/\(UUID().uuidString)"
        // 不应 throw
        try await BookshelfRepository.shared.updateTotalChapters(
            bookUrl: nonExistentUrl, total: 100, latestTitle: "x"
        )
        let still = try await BookshelfRepository.shared.get(bookUrl: nonExistentUrl)
        XCTAssertNil(still, "updateTotalChapters 不应该自己创建一行")
    }

    /// 用户场景: 详情页 ReadActionTitle 必须随进度变化
    /// "开始阅读" → 加架 + 拉到 toc 后 → "继续阅读 1/N"
    /// 这测的是 BookDetailViewModel 的状态而不是字面 UI 渲染.
    func test_bookDetailViewModel_reflectsShelfProgress() async throws {
        let bookUrl = "wxsw://test/d25/detail-vm/\(UUID().uuidString)"
        defer {
            Task { try? await BookshelfRepository.shared.remove(bookUrl: bookUrl) }
        }

        let vm = BookDetailViewModel()
        await vm.refreshShelfStatus(bookUrl: bookUrl)
        XCTAssertFalse(vm.isInShelf)
        XCTAssertEqual(vm.shelfDurChapterIndex, -1, "未在书架时为 -1")

        // 模拟书加进书架并读到第 3 章
        let book = ShelfBook(
            bookUrl: bookUrl, name: "VM 测试书", author: "作者",
            origin: "https://example.test/source", originName: "源", tocUrl: bookUrl
        )
        try await BookshelfRepository.shared.add(book)
        try await BookshelfRepository.shared.updateProgress(
            bookUrl: bookUrl, chapterIndex: 2, chapterTitle: "第三章", chapterPos: 0
        )

        await vm.refreshShelfStatus(bookUrl: bookUrl)
        XCTAssertTrue(vm.isInShelf)
        XCTAssertEqual(vm.shelfDurChapterIndex, 2, "应该反映书架里的实际进度")
    }

    // MARK: - Helpers

    private func isInShelf(bookUrl: String) async -> Bool {
        (try? await BookshelfRepository.shared.contains(bookUrl: bookUrl)) ?? false
    }
}
