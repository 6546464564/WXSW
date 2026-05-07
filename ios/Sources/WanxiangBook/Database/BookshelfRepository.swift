//
//  BookshelfRepository.swift
//  万象书屋 iOS · 书架 CRUD (M2.2.10)
//
//  对应 Android: io.legado.app.data.dao.BookDao
//
//  目标:
//   - 跟 Database/DB.swift 的 books 表对齐
//   - 提供 6 种排序所需的 query
//   - 写入时做防御 (重复 url upsert)
//

import Foundation
import SQLite3

/// 书架里的一本书 (DB 行级表示)
public struct ShelfBook: Identifiable, Hashable, Sendable {
    public var id: String { bookUrl }

    public var bookUrl: String          // 主键 = 详情页 URL
    public var name: String
    public var author: String
    public var origin: String           // 源 URL
    public var originName: String
    public var coverUrl: String?
    public var intro: String?
    public var kind: String?
    public var tocUrl: String?
    public var totalChapterNum: Int = 0
    public var durChapterIndex: Int = 0      // 当前阅读到第几章
    public var durChapterTitle: String?      // 当前章节名
    public var durChapterPos: Int = 0        // 章节内字符 offset
    public var durChapterTime: Int64 = 0     // 上次阅读时间戳 ms
    public var lastCheckTime: Int64 = 0      // 最后检查更新时间
    public var latestChapterTitle: String?   // 全书最新章
    public var latestChapterTime: Int64 = 0
    public var orderIdx: Int = 0             // 手动排序
    public var groupId: Int = 0              // 分组 ID
    public var canUpdate: Bool = true
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        bookUrl: String, name: String, author: String,
        origin: String, originName: String,
        coverUrl: String? = nil, intro: String? = nil, kind: String? = nil,
        tocUrl: String? = nil
    ) {
        self.bookUrl = bookUrl
        self.name = name
        self.author = author
        self.origin = origin
        self.originName = originName
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.tocUrl = tocUrl
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        self.createdAt = now
        self.updatedAt = now
        self.durChapterTime = now
    }

    /// 阅读进度 0...1, 给进度条角标用
    public var progress: Double {
        guard totalChapterNum > 0 else { return 0 }
        return min(1.0, Double(durChapterIndex + 1) / Double(totalChapterNum))
    }

    /// 进度文字 ("12/200" 或 "未读" 或 "已读完")
    public var progressText: String {
        guard totalChapterNum > 0 else { return "未读" }
        if durChapterIndex + 1 >= totalChapterNum { return "已读完" }
        if durChapterIndex == 0 && durChapterPos == 0 { return "未读" }
        return "\(durChapterIndex + 1)/\(totalChapterNum)"
    }
}

/// 排序方式 (跟 Android `arrays.xml` `book_sort` 对齐)
public enum ShelfSort: Int, CaseIterable, Sendable {
    case latestRead = 0    // 最近阅读 (默认)
    case latestUpdate = 1  // 更新时间
    case name = 2          // 书名 (拼音)
    case manual = 3        // 手动 (orderIdx)
    case mixed = 4         // 综合 (最近阅读 + 有更新 优先)
    case author = 5        // 作者

    public var displayName: String {
        switch self {
        case .latestRead: return "最近阅读"
        case .latestUpdate: return "更新时间"
        case .name: return "书名"
        case .manual: return "手动"
        case .mixed: return "综合"
        case .author: return "作者"
        }
    }
}

/// 书架仓库 (actor 串行化, 全部经 DB.shared)
public actor BookshelfRepository {

    public static let shared = BookshelfRepository()

    private init() {}

    // MARK: - Read

    public func listAll(sortedBy sort: ShelfSort = .latestRead, groupId: Int64? = nil) async throws -> [ShelfBook] {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            let orderBy: String = {
                switch sort {
                case .latestRead:   return "durChapterTime DESC"
                case .latestUpdate: return "latestChapterTime DESC"
                case .name:         return "name ASC"
                case .manual:       return "order_idx ASC, durChapterTime DESC"
                case .mixed:        return "durChapterTime DESC, latestChapterTime DESC"
                case .author:       return "author ASC"
                }
            }()
            // 万象书屋: groupId=nil 或 -1 → 全部, 其它按 group_id 过滤
            let whereClause: String
            if let gid = groupId, gid != BookGroup.allId {
                whereClause = " WHERE group_id = \(gid)"
            } else {
                whereClause = ""
            }
            let sql = "SELECT * FROM books\(whereClause) ORDER BY \(orderBy)"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed(sqlite3_errcode(handle), String(cString: sqlite3_errmsg(handle)))
            }
            var out: [ShelfBook] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let book = readRow(stmt) {
                    out.append(book)
                }
            }
            return out
        }
    }

    public func get(bookUrl: String) async throws -> ShelfBook? {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, "SELECT * FROM books WHERE book_url = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed(sqlite3_errcode(handle), String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW ? readRow(stmt) : nil
        }
    }

    public func contains(bookUrl: String) async throws -> Bool {
        try await get(bookUrl: bookUrl) != nil
    }

    public func count() async throws -> Int {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM books", -1, &stmt, nil) == SQLITE_OK else {
                return 0
            }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    // MARK: - Write

    /// 加书架 (主键 book_url 冲突时 UPDATE 元数据,但不覆盖阅读进度)
    public func add(_ book: ShelfBook) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            let sql = """
            INSERT INTO books(
              book_url, tocUrl, origin, originName, name, author, kind, coverUrl,
              intro, type, group_id, totalChapterNum, durChapterIndex, durChapterPos,
              durChapterTime, latestChapterTitle, latestChapterTime, lastCheckTime,
              canUpdate, order_idx, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?, ?, ?)
            ON CONFLICT(book_url) DO UPDATE SET
              name=excluded.name, author=excluded.author, coverUrl=excluded.coverUrl,
              intro=excluded.intro, kind=excluded.kind, tocUrl=excluded.tocUrl,
              originName=excluded.originName, updated_at=excluded.updated_at
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed(sqlite3_errcode(handle), String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt,  1, book.bookUrl, -1, SQLITE_TRANSIENT)
            sqlite3_bind_optstr(stmt, 2, book.tocUrl)
            sqlite3_bind_text(stmt,  3, book.origin, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt,  4, book.originName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt,  5, book.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt,  6, book.author, -1, SQLITE_TRANSIENT)
            sqlite3_bind_optstr(stmt, 7, book.kind)
            sqlite3_bind_optstr(stmt, 8, book.coverUrl)
            sqlite3_bind_optstr(stmt, 9, book.intro)
            sqlite3_bind_int(stmt,  10, Int32(book.groupId))
            sqlite3_bind_int(stmt,  11, Int32(book.totalChapterNum))
            sqlite3_bind_int(stmt,  12, Int32(book.durChapterIndex))
            sqlite3_bind_int(stmt,  13, Int32(book.durChapterPos))
            sqlite3_bind_int64(stmt, 14, book.durChapterTime)
            sqlite3_bind_optstr(stmt, 15, book.latestChapterTitle)
            sqlite3_bind_int64(stmt, 16, book.latestChapterTime)
            sqlite3_bind_int(stmt,  17, Int32(book.orderIdx))
            sqlite3_bind_int64(stmt, 18, book.createdAt)
            sqlite3_bind_int64(stmt, 19, book.updatedAt)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DBError.stepFailed(sqlite3_errcode(handle), String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// 删一本书
    public func remove(bookUrl: String) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(handle, "DELETE FROM books WHERE book_url = ?", -1, &stmt, nil) == SQLITE_OK else {
                throw DBError.prepareFailed(sqlite3_errcode(handle), String(cString: sqlite3_errmsg(handle)))
            }
            sqlite3_bind_text(stmt, 1, bookUrl, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
            // 同步删该书的章节缓存
            sqlite3_exec(handle, "DELETE FROM book_chapters WHERE book_url = '\(escape(bookUrl))'", nil, nil, nil)
        }
    }

    /// 置顶 (orderIdx 设为最小值 - 1)
    public func pin(bookUrl: String) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            // 拿当前最小 orderIdx
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(handle, "SELECT MIN(order_idx) FROM books", -1, &stmt, nil)
            var minIdx: Int32 = 0
            if sqlite3_step(stmt) == SQLITE_ROW { minIdx = sqlite3_column_int(stmt, 0) }
            sqlite3_finalize(stmt)

            stmt = nil
            sqlite3_prepare_v2(handle, "UPDATE books SET order_idx = ?, updated_at = ? WHERE book_url = ?", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, minIdx - 1)
            sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970 * 1000))
            sqlite3_bind_text(stmt, 3, bookUrl, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    /// 万象书屋: 换源时改 book_url 主键 + 同步刷其它字段
    /// 万象书屋 (bug 4 fix): DELETE + INSERT 必须在事务里, 否则中途崩溃会丢数据
    public func changeBookUrl(oldUrl: String, newBook: ShelfBook) async throws {
        try await DB.shared.openIfNeeded()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try await DB.shared.execQuery { handle in
            sqlite3_exec(handle, "BEGIN TRANSACTION", nil, nil, nil)
            // 1. 删旧
            var del: OpaquePointer?
            sqlite3_prepare_v2(handle, "DELETE FROM books WHERE book_url=?", -1, &del, nil)
            sqlite3_bind_text(del, 1, oldUrl, -1, SQLITE_TRANSIENT)
            sqlite3_step(del)
            sqlite3_finalize(del)
            // 2. 插新 (跟 add 用相同字段集, 22 字段)
            var ins: OpaquePointer?
            sqlite3_prepare_v2(handle, """
                INSERT INTO books(
                  book_url, tocUrl, origin, originName, name, author, kind, coverUrl,
                  intro, type, group_id, totalChapterNum, durChapterIndex, durChapterPos,
                  durChapterTime, latestChapterTitle, latestChapterTime, lastCheckTime,
                  canUpdate, order_idx, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?, ?, ?)
            """, -1, &ins, nil)
            sqlite3_bind_text (ins,  1, newBook.bookUrl, -1, SQLITE_TRANSIENT)
            sqlite3_bind_optstr(ins, 2, newBook.tocUrl)
            sqlite3_bind_text (ins,  3, newBook.origin, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text (ins,  4, newBook.originName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text (ins,  5, newBook.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text (ins,  6, newBook.author, -1, SQLITE_TRANSIENT)
            sqlite3_bind_optstr(ins, 7, newBook.kind)
            sqlite3_bind_optstr(ins, 8, newBook.coverUrl)
            sqlite3_bind_optstr(ins, 9, newBook.intro)
            sqlite3_bind_int  (ins, 10, Int32(newBook.groupId))
            sqlite3_bind_int  (ins, 11, Int32(newBook.totalChapterNum))
            sqlite3_bind_int  (ins, 12, Int32(newBook.durChapterIndex))
            sqlite3_bind_int  (ins, 13, Int32(newBook.durChapterPos))
            sqlite3_bind_int64(ins, 14, newBook.durChapterTime)
            sqlite3_bind_optstr(ins, 15, newBook.latestChapterTitle)
            sqlite3_bind_int64(ins, 16, newBook.latestChapterTime)
            sqlite3_bind_int  (ins, 17, Int32(newBook.orderIdx))
            sqlite3_bind_int64(ins, 18, now)
            sqlite3_bind_int64(ins, 19, now)
            sqlite3_step(ins)
            sqlite3_finalize(ins)
            sqlite3_exec(handle, "COMMIT", nil, nil, nil)
        }
    }

    /// 更新阅读进度 (从阅读器调; M2.5 用)
    public func updateProgress(bookUrl: String, chapterIndex: Int, chapterTitle: String?, chapterPos: Int) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, """
                UPDATE books SET durChapterIndex=?, durChapterTitle=?, durChapterPos=?, durChapterTime=?, updated_at=?
                WHERE book_url=?
            """, -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(chapterIndex))
            sqlite3_bind_optstr(stmt, 2, chapterTitle)
            sqlite3_bind_int(stmt, 3, Int32(chapterPos))
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            sqlite3_bind_int64(stmt, 4, now)
            sqlite3_bind_int64(stmt, 5, now)
            sqlite3_bind_text(stmt, 6, bookUrl, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: - Helpers

    private nonisolated func readRow(_ stmt: OpaquePointer?) -> ShelfBook? {
        guard let stmt = stmt else { return nil }
        // 列名顺序跟 books 表 schema 一致 (Database/DB.swift)
        // 0=book_url, 1=tocUrl, 2=origin, 3=originName, 4=name, 5=author, 6=kind, 7=customTag,
        // 8=coverUrl, 9=customCoverUrl, 10=intro, 11=customIntro, 12=charset, 13=type,
        // 14=group_id, 15=latestChapterTitle, 16=latestChapterTime, 17=lastCheckTime,
        // 18=totalChapterNum, 19=durChapterTitle, 20=durChapterIndex, 21=durChapterPos,
        // 22=durChapterTime, 23=wordCount, 24=canUpdate, 25=order_idx, 26=created_at, 27=updated_at
        guard let url = colString(stmt, 0), let name = colString(stmt, 4) else { return nil }
        var b = ShelfBook(
            bookUrl: url,
            name: name,
            author: colString(stmt, 5) ?? "",
            origin: colString(stmt, 2) ?? "",
            originName: colString(stmt, 3) ?? "",
            coverUrl: colString(stmt, 8),
            intro: colString(stmt, 10),
            kind: colString(stmt, 6),
            tocUrl: colString(stmt, 1)
        )
        b.groupId = Int(sqlite3_column_int(stmt, 14))
        b.latestChapterTitle = colString(stmt, 15)
        b.latestChapterTime = sqlite3_column_int64(stmt, 16)
        b.lastCheckTime = sqlite3_column_int64(stmt, 17)
        b.totalChapterNum = Int(sqlite3_column_int(stmt, 18))
        b.durChapterTitle = colString(stmt, 19)
        b.durChapterIndex = Int(sqlite3_column_int(stmt, 20))
        b.durChapterPos = Int(sqlite3_column_int(stmt, 21))
        b.durChapterTime = sqlite3_column_int64(stmt, 22)
        b.canUpdate = sqlite3_column_int(stmt, 24) != 0
        b.orderIdx = Int(sqlite3_column_int(stmt, 25))
        b.createdAt = sqlite3_column_int64(stmt, 26)
        b.updatedAt = sqlite3_column_int64(stmt, 27)
        return b
    }

    private nonisolated func colString(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cstr)
    }

    private nonisolated func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}

// MARK: - DB 访问扩展

extension DB {
    /// 万象书屋: 暴露给 Repository 的 actor-isolated handle 访问
    /// 用 closure 形式确保 handle 不外溢, 仍走 actor 串行化
    func execQuery<T: Sendable>(_ block: @Sendable (OpaquePointer) throws -> T) async throws -> T {
        try await openIfNeeded()
        guard let h = self.handle else {
            throw DBError.openFailed(0, "db handle is nil")
        }
        return try block(h)
    }
}

// MARK: - SQLite C 绑定常量 + 工具

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func sqlite3_bind_optstr(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
    if let v = value {
        sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
    } else {
        sqlite3_bind_null(stmt, idx)
    }
}
