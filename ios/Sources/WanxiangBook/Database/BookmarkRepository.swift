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

public struct ReadRecordRow: Identifiable, Hashable, Sendable {
    public var id: String { "\(bookUrl)::\(day)" }
    public let bookUrl: String
    public let day: String         // YYYY-MM-DD
    public let seconds: Int
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

// MARK: - Read Record

public actor ReadRecordRepository {
    public static let shared = ReadRecordRepository()
    private init() {}

    /// 加几秒 (阅读器每分钟调一次, 加 60 秒之类)
    public func addSeconds(bookUrl: String, seconds: Int) async throws {
        guard seconds > 0 else { return }
        try await DB.shared.openIfNeeded()
        let day = todayKey()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, """
                INSERT INTO read_progress(book_url, day, seconds) VALUES (?, ?, ?)
                ON CONFLICT(book_url, day) DO UPDATE SET seconds = seconds + excluded.seconds
            """, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, day, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(seconds))
            _ = sqlite3_step(stmt)
        }
    }

    /// 总时长 (秒)
    public func totalSeconds() async throws -> Int {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "SELECT IFNULL(SUM(seconds), 0) FROM read_progress", -1, &stmt, nil)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    /// 按天聚合 (近 30 天)
    public func dailyLast30() async throws -> [ReadRecordRow] {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, """
                SELECT book_url, day, SUM(seconds) FROM read_progress
                WHERE day >= date('now', '-30 days')
                GROUP BY book_url, day
                ORDER BY day DESC
            """, -1, &stmt, nil)
            var out: [ReadRecordRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let url = colString(stmt, 0) ?? ""
                let d = colString(stmt, 1) ?? ""
                let s = Int(sqlite3_column_int(stmt, 2))
                out.append(ReadRecordRow(bookUrl: url, day: d, seconds: s))
            }
            return out
        }
    }

    private func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: Date())
    }
}

private func colString(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
    guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: cstr)
}
