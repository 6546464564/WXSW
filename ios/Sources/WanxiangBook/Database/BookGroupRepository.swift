//
//  BookGroupRepository.swift
//  万象书屋 iOS · 书架分组
//
//  对应 Android: io.legado.app.data.entities.BookGroup + dao
//
//  4 个内置分组 + 用户自定义:
//   - id=-1 = 全部 (special)
//   - id= 0 = 未分组 (默认)
//   - id>0  = 用户自定义 ("玄幻"/"完结"/"待读" 等)
//

import Foundation
import SQLite3

public struct BookGroup: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var orderIdx: Int
    public var bookCount: Int = 0   // 计算字段, list 时填充

    public static let allId: Int64 = -1
    public static let ungroupedId: Int64 = 0

    public static var all: BookGroup { .init(id: allId, name: "全部", orderIdx: -100) }
    public static var ungrouped: BookGroup { .init(id: ungroupedId, name: "未分组", orderIdx: -1) }
}

public actor BookGroupRepository {
    public static let shared = BookGroupRepository()
    private init() {}

    /// 启动 / 主迁移
    public func ensureSchema() async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            sqlite3_exec(handle, """
                CREATE TABLE IF NOT EXISTS book_groups (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    order_idx INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL
                );
                """, nil, nil, nil)
        }
    }

    public func listAll() async throws -> [BookGroup] {
        try await ensureSchema()
        var groups: [BookGroup] = [.all, .ungrouped]
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "SELECT id, name, order_idx FROM book_groups ORDER BY order_idx, id", -1, &stmt, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let orderIdx = Int(sqlite3_column_int(stmt, 2))
                groups.append(BookGroup(id: id, name: name, orderIdx: orderIdx))
            }
        }
        // 填 bookCount
        let counts = try await loadCounts()
        groups = groups.map { g in
            var x = g
            if g.id == BookGroup.allId {
                x.bookCount = counts.values.reduce(0, +)
            } else {
                x.bookCount = counts[g.id] ?? 0
            }
            return x
        }
        return groups
    }

    private func loadCounts() async throws -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "SELECT group_id, COUNT(*) FROM books GROUP BY group_id", -1, &stmt, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let gid = sqlite3_column_int64(stmt, 0)
                let cnt = Int(sqlite3_column_int(stmt, 1))
                out[gid] = cnt
            }
        }
        return out
    }

    @discardableResult
    public func create(name: String) async throws -> Int64 {
        try await ensureSchema()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NSError(domain: "Group", code: 1) }
        var id: Int64 = 0
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, """
                INSERT INTO book_groups (name, order_idx, created_at) VALUES (?, ?, ?)
                """, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, 0)
            sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970 * 1000))
            sqlite3_step(stmt)
            id = sqlite3_last_insert_rowid(handle)
        }
        return id
    }

    public func rename(id: Int64, newName: String) async throws {
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "UPDATE book_groups SET name=? WHERE id=?", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, newName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, id)
            sqlite3_step(stmt)
        }
    }

    public func delete(id: Int64) async throws {
        try await DB.shared.execQuery { handle in
            // 1. 删 group
            var s1: OpaquePointer?
            sqlite3_prepare_v2(handle, "DELETE FROM book_groups WHERE id=?", -1, &s1, nil)
            sqlite3_bind_int64(s1, 1, id)
            sqlite3_step(s1)
            sqlite3_finalize(s1)
            // 2. 这个 group 下的书移回"未分组" (group_id=0)
            var s2: OpaquePointer?
            sqlite3_prepare_v2(handle, "UPDATE books SET group_id=0 WHERE group_id=?", -1, &s2, nil)
            sqlite3_bind_int64(s2, 1, id)
            sqlite3_step(s2)
            sqlite3_finalize(s2)
        }
    }

    /// 移动书到 group (id=0 即"未分组")
    public func moveBook(bookUrl: String, toGroupId: Int64) async throws {
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "UPDATE books SET group_id=?, updated_at=? WHERE book_url=?", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, toGroupId)
            sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970 * 1000))
            sqlite3_bind_text(stmt, 3, bookUrl, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }
}
