//
//  ChapterRepository.swift
//  万象书屋 iOS · 章节列表 + 章节正文 SQLite 缓存 (M2.5.1.5)
//
//  对应 Android: io.legado.app.data.dao.{BookChapterDao, RawChapterContentDao}
//
//  设计:
//   - 章节列表 (book_chapters 表): 拿过一次目录就缓存, 进阅读器秒开
//   - 章节正文: 复用 book_chapters.content 字段 (lazy 写入)
//   - 全部 actor 串行化, 走 DB.execQuery
//

import Foundation
import SQLite3

public actor ChapterRepository {

    public static let shared = ChapterRepository()

    private init() {}

    // MARK: - Toc (章节列表)

    public func saveToc(bookUrl: String, chapters: [BookChapter]) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            // 先清旧的, 再批量插 (transaction 保原子)
            sqlite3_exec(handle, "BEGIN TRANSACTION", nil, nil, nil)
            do {
                var del: OpaquePointer?
                sqlite3_prepare_v2(handle, "DELETE FROM book_chapters WHERE book_url = ?", -1, &del, nil)
                sqlite3_bind_text(del, 1, bookUrl, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(del)
                sqlite3_finalize(del)

                var ins: OpaquePointer?
                let sql = """
                INSERT INTO book_chapters(
                  book_url, chapter_index, chapter_url, title,
                  content, tag, start_fragment, end_fragment,
                  is_volume, is_paid, updated_at
                ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
                """
                sqlite3_prepare_v2(handle, sql, -1, &ins, nil)
                let now = Int64(Date().timeIntervalSince1970 * 1000)
                for c in chapters {
                    sqlite3_reset(ins)
                    sqlite3_bind_text(ins, 1, bookUrl, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(ins, 2, Int32(c.chapterIndex))
                    sqlite3_bind_optstr(ins, 3, c.chapterUrl)
                    sqlite3_bind_text(ins, 4, c.title, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_optstr(ins, 5, c.tag)
                    sqlite3_bind_optstr(ins, 6, c.startFragment)
                    sqlite3_bind_optstr(ins, 7, c.endFragment)
                    sqlite3_bind_int(ins, 8, c.isVolume ? 1 : 0)
                    sqlite3_bind_int(ins, 9, c.isPay ? 1 : 0)
                    sqlite3_bind_int64(ins, 10, now)
                    _ = sqlite3_step(ins)
                }
                sqlite3_finalize(ins)
                sqlite3_exec(handle, "COMMIT", nil, nil, nil)
            } catch {
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                throw error
            }
        }

        // 顺手更新书的 totalChapterNum
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "UPDATE books SET totalChapterNum = ?, updated_at = ? WHERE book_url = ?", -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(chapters.count))
            sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970 * 1000))
            sqlite3_bind_text(stmt, 3, bookUrl, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    public func loadToc(bookUrl: String) async throws -> [BookChapter] {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT chapter_index, chapter_url, title, tag, start_fragment, end_fragment, is_volume, is_paid
            FROM book_chapters WHERE book_url = ? ORDER BY chapter_index ASC
            """
            sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            var out: [BookChapter] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idx = Int(sqlite3_column_int(stmt, 0))
                let url = colString(stmt, 1)
                let title = colString(stmt, 2) ?? ""
                let chapter = BookChapter(
                    chapterIndex: idx,
                    chapterUrl: url,
                    title: title,
                    isVolume: sqlite3_column_int(stmt, 6) != 0,
                    isVip: false,
                    isPay: sqlite3_column_int(stmt, 7) != 0,
                    tag: colString(stmt, 3),
                    startFragment: colString(stmt, 4),
                    endFragment: colString(stmt, 5)
                )
                out.append(chapter)
            }
            return out
        }
    }

    public func tocCount(bookUrl: String) async throws -> Int {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM book_chapters WHERE book_url = ?", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    // MARK: - Content (章节正文)

    public func saveContent(bookUrl: String, chapterIndex: Int, content: String) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, """
                UPDATE book_chapters SET content = ?, updated_at = ?
                WHERE book_url = ? AND chapter_index = ?
            """, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, content, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970 * 1000))
            sqlite3_bind_text(stmt, 3, bookUrl, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(chapterIndex))
            _ = sqlite3_step(stmt)
        }
    }

    public func loadContent(bookUrl: String, chapterIndex: Int) async throws -> String? {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "SELECT content FROM book_chapters WHERE book_url = ? AND chapter_index = ?", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(chapterIndex))
            if sqlite3_step(stmt) == SQLITE_ROW {
                return colString(stmt, 0)
            }
            return nil
        }
    }

    /// 万象书屋 (M2.8 perf): 一次拿"已下载好正文"的章节 index 集合, 替代下载启动前
    /// "for chapter in chapters { await loadContent }" 的 N 次串行查盘.
    /// 500 章串行查 ≈ 数秒, 一次 SELECT WHERE LENGTH(content)>0 < 50ms.
    public func cachedContentIndexes(bookUrl: String) async throws -> Set<Int> {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, """
                SELECT chapter_index FROM book_chapters
                WHERE book_url = ? AND content IS NOT NULL AND LENGTH(content) > 0
            """, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            var result = Set<Int>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.insert(Int(sqlite3_column_int(stmt, 0)))
            }
            return result
        }
    }

    public func clearContent(bookUrl: String) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "UPDATE book_chapters SET content = NULL WHERE book_url = ?", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    /// 万象书屋: 换源时彻底清掉旧 toc + 内容
    public func clearAllForBook(bookUrl: String) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "DELETE FROM book_chapters WHERE book_url = ?", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    private nonisolated func colString(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cstr)
    }
}
