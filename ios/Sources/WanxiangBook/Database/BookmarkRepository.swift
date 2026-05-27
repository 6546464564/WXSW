//
//  BookmarkRepository.swift
//  万象书屋 iOS · 书签 (M2.9.1) + 阅读时长 (M2.9.4)
//

import Foundation
import SQLite3

public struct BookmarkEntity: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var bookUrl: String
    public var bookName: String
    public var chapterIndex: Int
    public var chapterTitle: String?
    public var chapterPos: Int
    public var content: String?
    public var note: String?
    public var createdAt: Int64

    public init(id: Int64 = 0, bookUrl: String, bookName: String,
                chapterIndex: Int, chapterTitle: String? = nil, chapterPos: Int = 0,
                content: String? = nil, note: String? = nil) {
        self.id = id; self.bookUrl = bookUrl; self.bookName = bookName
        self.chapterIndex = chapterIndex; self.chapterTitle = chapterTitle
        self.chapterPos = chapterPos; self.content = content; self.note = note
        self.createdAt = Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public actor BookmarkRepository {
    public static let shared = BookmarkRepository()
    private init() {}

    public func add(_ b: BookmarkEntity) async throws -> Int64 {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, """
                INSERT INTO bookmarks(book_url, book_name, chapter_index, chapter_title, chapter_pos, content, note, created_at)
                VALUES (?,?,?,?,?,?,?,?)
            """, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, b.bookUrl, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, b.bookName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(b.chapterIndex))
            sqlite3_bind_optstr(stmt, 4, b.chapterTitle)
            sqlite3_bind_int(stmt, 5, Int32(b.chapterPos))
            sqlite3_bind_optstr(stmt, 6, b.content)
            sqlite3_bind_optstr(stmt, 7, b.note)
            sqlite3_bind_int64(stmt, 8, b.createdAt)
            _ = sqlite3_step(stmt)
            return sqlite3_last_insert_rowid(handle)
        }
    }

    public func listAll() async throws -> [BookmarkEntity] {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "SELECT id, book_url, book_name, chapter_index, chapter_title, chapter_pos, content, note, created_at FROM bookmarks ORDER BY created_at DESC", -1, &stmt, nil)
            var out: [BookmarkEntity] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var b = BookmarkEntity(
                    bookUrl: colString(stmt, 1) ?? "",
                    bookName: colString(stmt, 2) ?? "",
                    chapterIndex: Int(sqlite3_column_int(stmt, 3)),
                    chapterTitle: colString(stmt, 4),
                    chapterPos: Int(sqlite3_column_int(stmt, 5)),
                    content: colString(stmt, 6),
                    note: colString(stmt, 7)
                )
                b.id = sqlite3_column_int64(stmt, 0)
                b.createdAt = sqlite3_column_int64(stmt, 8)
                out.append(b)
            }
            return out
        }
    }

    public func listForBook(_ bookUrl: String) async throws -> [BookmarkEntity] {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "SELECT id, book_url, book_name, chapter_index, chapter_title, chapter_pos, content, note, created_at FROM bookmarks WHERE book_url = ? ORDER BY chapter_index ASC, chapter_pos ASC", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            var out: [BookmarkEntity] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var b = BookmarkEntity(
                    bookUrl: colString(stmt, 1) ?? "",
                    bookName: colString(stmt, 2) ?? "",
                    chapterIndex: Int(sqlite3_column_int(stmt, 3)),
                    chapterTitle: colString(stmt, 4),
                    chapterPos: Int(sqlite3_column_int(stmt, 5)),
                    content: colString(stmt, 6),
                    note: colString(stmt, 7)
                )
                b.id = sqlite3_column_int64(stmt, 0)
                b.createdAt = sqlite3_column_int64(stmt, 8)
                out.append(b)
            }
            return out
        }
    }

    public func delete(id: Int64) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "DELETE FROM bookmarks WHERE id=?", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, id)
            _ = sqlite3_step(stmt)
        }
    }
}

private func colString(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
    guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: cstr)
}
