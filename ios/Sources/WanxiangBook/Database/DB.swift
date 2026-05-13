//
//  DB.swift
//  万象书屋 iOS · SQLite actor 封装
//
//  设计原则 (跟 ios/AGENTS.md 早期版一致):
//   - 不引 GRDB / SQLite.swift, 直接 system sqlite3
//   - actor 串行化, 杜绝多线程数据竞争
//   - schema 跟 Android Room 19 张表 1:1 (列名/类型一致),
//     方便后端结构与跨端逻辑对齐
//   - WAL 模式 + busy_timeout, 跟后端 better-sqlite3 配置同款
//
//  M0-I4 阶段:
//   - 只建 books / book_chapters / book_sources / search_keywords / read_progress 5 张核心表
//   - 其余表在 M2 各阶段按需扩展
//

import Foundation
import SQLite3   // 系统库, Apple silicon 原生包含

/// 万象书屋: SQLite 错误的 LocalizedError 包装
enum DBError: Error, LocalizedError {
    case openFailed(Int32, String)
    case prepareFailed(Int32, String)
    case stepFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let c, let m): return "DB open \(c): \(m)"
        case .prepareFailed(let c, let m): return "DB prepare \(c): \(m)"
        case .stepFailed(let c, let m): return "DB step \(c): \(m)"
        }
    }
}

actor DB {
    static let shared = DB()

    /// 万象书屋: handle 设为 internal 让 BookshelfRepository / 其它 Repository 能在 actor 隔离下访问
    var handle: OpaquePointer?
    private var migrationApplied = false

    /// 数据库文件路径. iOS 写在 Application Support 下 (备份不被 iCloud 同步, 内容稳定)
    static var dbPath: URL {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            let fallback = FileManager.default.temporaryDirectory
            return fallback.appendingPathComponent("wanxiang.sqlite")
        }
        return dir.appendingPathComponent("wanxiang.sqlite")
    }

    private init() {}

    /// 打开 db (幂等). 必须在第一次查询前 await
    func openIfNeeded() async throws {
        if handle != nil { return }
        let path = Self.dbPath.path
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &h, flags, nil)
        guard status == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(h)
            throw DBError.openFailed(status, msg)
        }
        // 万象书屋: WAL 模式让读不阻塞写, 跟后端配置一致
        sqlite3_exec(h, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(h, "PRAGMA busy_timeout=5000;", nil, nil, nil)
        sqlite3_exec(h, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(h, "PRAGMA foreign_keys=ON;", nil, nil, nil)
        self.handle = h
        try migrate()
    }

    /// M0 阶段最小 schema. M2 各阶段往里加表.
    private func migrate() throws {
        guard let h = handle, !migrationApplied else { return }

        // 万象书屋: 5 张核心表对应 Android Room
        //   - books             →  io.legado.app.data.entities.Book
        //   - book_chapters     →  io.legado.app.data.entities.BookChapter
        //   - book_sources      →  io.legado.app.data.entities.BookSource (远端拉的本地 cache)
        //   - search_keywords   →  io.legado.app.data.entities.SearchKeyword
        //   - read_progress     →  ReadRecord 简化版
        let sql = """
        CREATE TABLE IF NOT EXISTS books (
            book_url        TEXT PRIMARY KEY,
            tocUrl          TEXT,
            origin          TEXT,
            originName      TEXT,
            name            TEXT NOT NULL,
            author          TEXT,
            kind            TEXT,
            customTag       TEXT,
            coverUrl        TEXT,
            customCoverUrl  TEXT,
            intro           TEXT,
            customIntro     TEXT,
            charset         TEXT,
            type            INTEGER NOT NULL DEFAULT 0,
            group_id        INTEGER NOT NULL DEFAULT 0,
            latestChapterTitle TEXT,
            latestChapterTime  INTEGER NOT NULL DEFAULT 0,
            lastCheckTime   INTEGER NOT NULL DEFAULT 0,
            totalChapterNum INTEGER NOT NULL DEFAULT 0,
            durChapterTitle TEXT,
            durChapterIndex INTEGER NOT NULL DEFAULT 0,
            durChapterPos   INTEGER NOT NULL DEFAULT 0,
            durChapterTime  INTEGER NOT NULL DEFAULT 0,
            wordCount       TEXT,
            canUpdate       INTEGER NOT NULL DEFAULT 1,
            order_idx       INTEGER NOT NULL DEFAULT 0,
            created_at      INTEGER NOT NULL,
            updated_at      INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_books_updated ON books(updated_at);
        CREATE INDEX IF NOT EXISTS idx_books_order ON books(order_idx);

        CREATE TABLE IF NOT EXISTS book_chapters (
            book_url        TEXT NOT NULL,
            chapter_index   INTEGER NOT NULL,
            chapter_url     TEXT,
            title           TEXT,
            content         TEXT,
            tag             TEXT,
            start_fragment  TEXT,
            end_fragment    TEXT,
            is_volume       INTEGER NOT NULL DEFAULT 0,
            is_paid         INTEGER NOT NULL DEFAULT 0,
            updated_at      INTEGER NOT NULL,
            PRIMARY KEY (book_url, chapter_index)
        );

        CREATE TABLE IF NOT EXISTS book_sources (
            source_url      TEXT PRIMARY KEY,
            source_name     TEXT NOT NULL,
            source_group    TEXT,
            json_blob       TEXT NOT NULL,
            enabled         INTEGER NOT NULL DEFAULT 1,
            updated_at      INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS search_keywords (
            keyword         TEXT PRIMARY KEY,
            usage_count     INTEGER NOT NULL DEFAULT 1,
            last_used_at    INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS read_progress (
            book_url        TEXT NOT NULL,
            day             TEXT NOT NULL,    -- YYYY-MM-DD
            seconds         INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (book_url, day)
        );

        -- M2.7.1 替换规则
        CREATE TABLE IF NOT EXISTS replace_rules (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT NOT NULL,
            group_name      TEXT,                           -- 分组名 (CSV)
            pattern         TEXT NOT NULL,                  -- 正则模式
            replacement     TEXT NOT NULL DEFAULT '',
            is_regex        INTEGER NOT NULL DEFAULT 1,     -- 0 = 普通替换, 1 = 正则
            scope           TEXT NOT NULL DEFAULT '',       -- 限定书源或书 URL (CSV)
            enabled         INTEGER NOT NULL DEFAULT 1,
            order_idx       INTEGER NOT NULL DEFAULT 0,
            updated_at      INTEGER NOT NULL
        );

        -- M2.7.4 词典规则
        CREATE TABLE IF NOT EXISTS dict_rules (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT NOT NULL,
            url_template    TEXT NOT NULL,                  -- "https://hanyu.baidu.com/zici/s?wd={{key}}"
            rule            TEXT,                           -- 选择器 (CSS / XPath / JS)
            enabled         INTEGER NOT NULL DEFAULT 1,
            order_idx       INTEGER NOT NULL DEFAULT 0,
            updated_at      INTEGER NOT NULL
        );

        -- M2.7.6 TXT 目录规则
        CREATE TABLE IF NOT EXISTS txt_toc_rules (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            name            TEXT NOT NULL,
            pattern         TEXT NOT NULL,                  -- 章节标题正则
            example         TEXT,                           -- 示例文本
            enabled         INTEGER NOT NULL DEFAULT 1,
            order_idx       INTEGER NOT NULL DEFAULT 0,
            updated_at      INTEGER NOT NULL
        );

        -- M2.9.1 书签
        CREATE TABLE IF NOT EXISTS bookmarks (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            book_url        TEXT NOT NULL,
            book_name       TEXT NOT NULL,
            chapter_index   INTEGER NOT NULL,
            chapter_title   TEXT,
            chapter_pos     INTEGER NOT NULL DEFAULT 0,
            content         TEXT,                           -- 选中的原文片段
            note            TEXT,                           -- 用户笔记
            created_at      INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_bookmarks_book ON bookmarks(book_url, chapter_index);
        """

        var err: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(h, sql, nil, nil, &err)
        if status != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw DBError.prepareFailed(status, msg)
        }
        migrationApplied = true
    }

    /// 健康检查: SELECT 1 看 db 是否能用
    func healthCheck() async throws -> Bool {
        try await openIfNeeded()
        guard let h = handle else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let status = sqlite3_prepare_v2(h, "SELECT 1", -1, &stmt, nil)
        guard status == SQLITE_OK else { return false }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 万象书屋: 注销账号时清空全部表 (PIPL 必须)
    func wipeAll() async throws {
        try await openIfNeeded()
        guard let h = handle else { return }
        let tables = ["books", "book_chapters", "book_sources",
                      "search_keywords", "read_progress"]
        for t in tables {
            sqlite3_exec(h, "DELETE FROM \(t);", nil, nil, nil)
        }
        sqlite3_exec(h, "VACUUM;", nil, nil, nil)
    }

    deinit {
        if let h = handle { sqlite3_close_v2(h) }
    }

    // MARK: - book_sources CRUD (M2.4 BookSourceRegistry 用)

    /// 全量替换 book_sources (启动后从 /api/sources 拉了之后调一次)
    public func replaceAllBookSources(_ list: [BookSource]) async throws {
        try await openIfNeeded()
        guard let h = handle else { return }
        sqlite3_exec(h, "BEGIN TRANSACTION;", nil, nil, nil)
        sqlite3_exec(h, "DELETE FROM book_sources;", nil, nil, nil)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for src in list {
            // 万象书屋: 用 BookSource 自身 JSON encode 存 blob, 重启时整体 decode 回来
            guard let data = try? JSONEncoder().encode(src),
                  let json = String(data: data, encoding: .utf8) else { continue }
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(h, """
                INSERT OR REPLACE INTO book_sources
                (source_url, source_name, source_group, json_blob, enabled, updated_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, src.bookSourceUrl, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, src.bookSourceName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, src.bookSourceGroup ?? "", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, json, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, src.enabled ? 1 : 0)
            sqlite3_bind_int64(stmt, 6, now)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        sqlite3_exec(h, "COMMIT;", nil, nil, nil)
    }

    /// 万象书屋: 合并写入书源 (INSERT OR REPLACE, 不清库). 用于用户本地导入 legado JSON.
    public func mergeBookSources(_ list: [BookSource]) async throws {
        try await openIfNeeded()
        guard let h = handle else { return }
        sqlite3_exec(h, "BEGIN TRANSACTION;", nil, nil, nil)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for src in list {
            guard let data = try? JSONEncoder().encode(src),
                  let json = String(data: data, encoding: .utf8) else { continue }
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(h, """
                INSERT OR REPLACE INTO book_sources
                (source_url, source_name, source_group, json_blob, enabled, updated_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, src.bookSourceUrl, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, src.bookSourceName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, src.bookSourceGroup ?? "", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, json, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, src.enabled ? 1 : 0)
            sqlite3_bind_int64(stmt, 6, now)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        sqlite3_exec(h, "COMMIT;", nil, nil, nil)
    }

    /// 启动 fast-path: 直接读 SQLite 还原所有 BookSource
    public func loadAllBookSources() async throws -> [BookSource] {
        try await openIfNeeded()
        guard let h = handle else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(h, "SELECT json_blob FROM book_sources;", -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        var out: [BookSource] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(stmt, 0) {
                let json = String(cString: cstr)
                if let data = json.data(using: .utf8),
                   let bs = try? JSONDecoder().decode(BookSource.self, from: data) {
                    out.append(bs)
                }
            }
        }
        return out
    }
}

// 万象书屋: SQLITE_TRANSIENT 已在 BookshelfRepository.swift 定义为 internal, 此文件复用
