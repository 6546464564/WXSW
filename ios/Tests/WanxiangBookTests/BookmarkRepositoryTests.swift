//
//  BookmarkRepositoryTests.swift
//  万象书屋 iOS · 书签存储 (M2.9.1) 单元测试
//
//  覆盖 BookmarkRepository (覆盖率报告曾 0%):
//    add / listAll / listForBook / delete
//  每次用唯一 bookUrl, 测试后清理, 避免污染共享测试库.

import XCTest
@testable import WanxiangBook

final class BookmarkRepositoryTests: XCTestCase {

    /// add → listForBook 能查到, 字段完整
    func test_addAndListForBook_roundTrip() async throws {
        let bookUrl = "wxsw://test/bookmark/add/\(UUID().uuidString)"
        defer { Task { try? await cleanup(bookUrl: bookUrl) } }

        let b = BookmarkEntity(
            bookUrl: bookUrl, bookName: "书签测试书",
            chapterIndex: 3, chapterTitle: "第四章", chapterPos: 42,
            content: "这是书签内容", note: "我的批注"
        )
        let id = try await BookmarkRepository.shared.add(b)
        XCTAssertGreaterThan(id, 0, "add 应返回自增 id")

        let list = try await BookmarkRepository.shared.listForBook(bookUrl)
        XCTAssertEqual(list.count, 1)
        let got = list[0]
        XCTAssertEqual(got.bookName, "书签测试书")
        XCTAssertEqual(got.chapterIndex, 3)
        XCTAssertEqual(got.chapterTitle, "第四章")
        XCTAssertEqual(got.chapterPos, 42)
        XCTAssertEqual(got.content, "这是书签内容")
        XCTAssertEqual(got.note, "我的批注")
        XCTAssertEqual(got.createdAt, b.createdAt)
    }

    /// 多本书签: listForBook 只返回指定书的, 且按章节/位置排序
    func test_listForBook_onlyThatBook_andSorted() async throws {
        let bookA = "wxsw://test/bookmark/sortA/\(UUID().uuidString)"
        let bookB = "wxsw://test/bookmark/sortB/\(UUID().uuidString)"
        defer {
            Task {
                try? await cleanup(bookUrl: bookA)
                try? await cleanup(bookUrl: bookB)
            }
        }

        // 书 A 两枚 (倒序插入, 验证 listForBook 按章节正序)
        let ch2 = BookmarkEntity(bookUrl: bookA, bookName: "A", chapterIndex: 2, chapterTitle: "第三章", chapterPos: 0)
        let ch1 = BookmarkEntity(bookUrl: bookA, bookName: "A", chapterIndex: 1, chapterTitle: "第二章", chapterPos: 0)
        try await BookmarkRepository.shared.add(ch2)
        try await BookmarkRepository.shared.add(ch1)
        // 书 B 一枚
        try await BookmarkRepository.shared.add(
            BookmarkEntity(bookUrl: bookB, bookName: "B", chapterIndex: 1, chapterTitle: "二章", chapterPos: 0)
        )

        let listA = try await BookmarkRepository.shared.listForBook(bookA)
        XCTAssertEqual(listA.count, 2)
        XCTAssertEqual(listA[0].chapterIndex, 1, "listForBook 应按 chapter_index ASC")
        XCTAssertEqual(listA[1].chapterIndex, 2)

        let listB = try await BookmarkRepository.shared.listForBook(bookB)
        XCTAssertEqual(listB.count, 1)
        XCTAssertEqual(listB[0].bookName, "B")
    }

    /// delete 后书签消失
    func test_delete_removesBookmark() async throws {
        let bookUrl = "wxsw://test/bookmark/delete/\(UUID().uuidString)"
        defer { Task { try? await cleanup(bookUrl: bookUrl) } }

        let id = try await BookmarkRepository.shared.add(
            BookmarkEntity(bookUrl: bookUrl, bookName: "待删书", chapterIndex: 0, chapterTitle: "第一章", chapterPos: 0)
        )
        let before = try await BookmarkRepository.shared.listForBook(bookUrl)
        XCTAssertEqual(before.count, 1)

        try await BookmarkRepository.shared.delete(id: id)
        let after = try await BookmarkRepository.shared.listForBook(bookUrl)
        XCTAssertEqual(after.count, 0, "删除后不应再查到")

        // 删不存在的 id 不抛错 (幂等)
        try await BookmarkRepository.shared.delete(id: 9_999_999)
    }

    /// 同一本书多个章节书签: listAll 能全部返回, 且按 created_at DESC
    func test_listAll_returnsAllBookmarks() async throws {
        let bookUrl = "wxsw://test/bookmark/all/\(UUID().uuidString)"
        defer { Task { try? await cleanup(bookUrl: bookUrl) } }

        for i in 0..<3 {
            _ = try await BookmarkRepository.shared.add(
                BookmarkEntity(bookUrl: bookUrl, bookName: "多书签", chapterIndex: i, chapterTitle: "第\(i + 1)章", chapterPos: 0)
            )
        }
        let all = try await BookmarkRepository.shared.listAll()
        let mine = all.filter { $0.bookUrl == bookUrl }
        XCTAssertEqual(mine.count, 3, "listAll 应包含全部书签")
        // listAll 按 created_at DESC 排序; 同毫秒插入时时间戳可能相等, 此时不强制顺序
        if mine[0].createdAt != mine[1].createdAt {
            XCTAssertGreaterThanOrEqual(mine[0].createdAt, mine[1].createdAt,
                                        "listAll 应按 created_at DESC")
        }
    }

    // MARK: - Helpers

    private func cleanup(bookUrl: String) async throws {
        let mine = try await BookmarkRepository.shared.listForBook(bookUrl)
        for b in mine {
            try await BookmarkRepository.shared.delete(id: b.id)
        }
    }
}
