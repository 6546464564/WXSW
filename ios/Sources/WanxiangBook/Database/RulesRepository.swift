//
//  RulesRepository.swift
//  万象书屋 iOS · 规则系统 (M2.7) Repositories
//
//  - ReplaceRule  替换规则
//  - DictRule     词典规则
//  - TxtTocRule   TXT 目录规则
//
//  对应 Android: io.legado.app.data.dao.{ReplaceRuleDao, DictRuleDao, TxtTocRuleDao}
//

import Foundation
import SQLite3

// MARK: - 模型

public struct ReplaceRuleEntity: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var groupName: String?
    public var pattern: String
    public var replacement: String
    public var isRegex: Bool
    public var scope: String          // 限定书源或书 URL CSV; 空 = 全局
    public var enabled: Bool
    public var orderIdx: Int
    public var updatedAt: Int64

    public init(id: Int64 = 0, name: String, pattern: String, replacement: String = "",
                isRegex: Bool = true, scope: String = "", enabled: Bool = true,
                groupName: String? = nil, orderIdx: Int = 0) {
        self.id = id; self.name = name; self.pattern = pattern; self.replacement = replacement
        self.isRegex = isRegex; self.scope = scope; self.enabled = enabled
        self.groupName = groupName; self.orderIdx = orderIdx
        self.updatedAt = Int64(Date().timeIntervalSince1970 * 1000)
    }
}

public struct DictRuleEntity: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var urlTemplate: String     // {{key}} 占位
    public var rule: String?           // 提取规则 (CSS / XPath / JS)
    public var enabled: Bool
    public var orderIdx: Int

    public init(id: Int64 = 0, name: String, urlTemplate: String,
                rule: String? = nil, enabled: Bool = true, orderIdx: Int = 0) {
        self.id = id; self.name = name; self.urlTemplate = urlTemplate
        self.rule = rule; self.enabled = enabled; self.orderIdx = orderIdx
    }
}

public struct TxtTocRuleEntity: Identifiable, Hashable, Sendable {
    public var id: Int64
    public var name: String
    public var pattern: String
    public var example: String?
    public var enabled: Bool
    public var orderIdx: Int

    public init(id: Int64 = 0, name: String, pattern: String,
                example: String? = nil, enabled: Bool = true, orderIdx: Int = 0) {
        self.id = id; self.name = name; self.pattern = pattern
        self.example = example; self.enabled = enabled; self.orderIdx = orderIdx
    }
}

// MARK: - Replace Repository

public actor ReplaceRuleRepository {
    public static let shared = ReplaceRuleRepository()
    private init() {}

    public func listAll() async throws -> [ReplaceRuleEntity] {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, """
                SELECT id, name, group_name, pattern, replacement, is_regex, scope, enabled, order_idx, updated_at
                FROM replace_rules ORDER BY order_idx ASC, id ASC
            """, -1, &stmt, nil)
            var out: [ReplaceRuleEntity] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(ReplaceRuleEntity(
                    id: sqlite3_column_int64(stmt, 0),
                    name: colString(stmt, 1) ?? "",
                    pattern: colString(stmt, 3) ?? "",
                    replacement: colString(stmt, 4) ?? "",
                    isRegex: sqlite3_column_int(stmt, 5) != 0,
                    scope: colString(stmt, 6) ?? "",
                    enabled: sqlite3_column_int(stmt, 7) != 0,
                    groupName: colString(stmt, 2),
                    orderIdx: Int(sqlite3_column_int(stmt, 8))
                ))
            }
            return out
        }
    }

    public func upsert(_ r: ReplaceRuleEntity) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if r.id == 0 {
                sqlite3_prepare_v2(handle, """
                    INSERT INTO replace_rules(name, group_name, pattern, replacement, is_regex, scope, enabled, order_idx, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, -1, &stmt, nil)
                sqlite3_bind_text(stmt, 1, r.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_optstr(stmt, 2, r.groupName)
                sqlite3_bind_text(stmt, 3, r.pattern, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, r.replacement, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 5, r.isRegex ? 1 : 0)
                sqlite3_bind_text(stmt, 6, r.scope, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 7, r.enabled ? 1 : 0)
                sqlite3_bind_int(stmt, 8, Int32(r.orderIdx))
                sqlite3_bind_int64(stmt, 9, now)
            } else {
                sqlite3_prepare_v2(handle, """
                    UPDATE replace_rules SET name=?, group_name=?, pattern=?, replacement=?, is_regex=?, scope=?, enabled=?, order_idx=?, updated_at=?
                    WHERE id=?
                """, -1, &stmt, nil)
                sqlite3_bind_text(stmt, 1, r.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_optstr(stmt, 2, r.groupName)
                sqlite3_bind_text(stmt, 3, r.pattern, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, r.replacement, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 5, r.isRegex ? 1 : 0)
                sqlite3_bind_text(stmt, 6, r.scope, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 7, r.enabled ? 1 : 0)
                sqlite3_bind_int(stmt, 8, Int32(r.orderIdx))
                sqlite3_bind_int64(stmt, 9, now)
                sqlite3_bind_int64(stmt, 10, r.id)
            }
            _ = sqlite3_step(stmt)
        }
    }

    public func delete(id: Int64) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "DELETE FROM replace_rules WHERE id = ?", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, id)
            _ = sqlite3_step(stmt)
        }
    }
}

// MARK: - Dict Repository

public actor DictRuleRepository {
    public static let shared = DictRuleRepository()
    private init() {}

    public func listAll() async throws -> [DictRuleEntity] {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, """
                SELECT id, name, url_template, rule, enabled, order_idx
                FROM dict_rules ORDER BY order_idx ASC, id ASC
            """, -1, &stmt, nil)
            var out: [DictRuleEntity] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(DictRuleEntity(
                    id: sqlite3_column_int64(stmt, 0),
                    name: colString(stmt, 1) ?? "",
                    urlTemplate: colString(stmt, 2) ?? "",
                    rule: colString(stmt, 3),
                    enabled: sqlite3_column_int(stmt, 4) != 0,
                    orderIdx: Int(sqlite3_column_int(stmt, 5))
                ))
            }
            return out
        }
    }

    public func upsert(_ r: DictRuleEntity) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if r.id == 0 {
                sqlite3_prepare_v2(handle, "INSERT INTO dict_rules(name, url_template, rule, enabled, order_idx, updated_at) VALUES (?,?,?,?,?,?)", -1, &stmt, nil)
                sqlite3_bind_text(stmt, 1, r.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, r.urlTemplate, -1, SQLITE_TRANSIENT)
                sqlite3_bind_optstr(stmt, 3, r.rule)
                sqlite3_bind_int(stmt, 4, r.enabled ? 1 : 0)
                sqlite3_bind_int(stmt, 5, Int32(r.orderIdx))
                sqlite3_bind_int64(stmt, 6, now)
            } else {
                sqlite3_prepare_v2(handle, "UPDATE dict_rules SET name=?, url_template=?, rule=?, enabled=?, order_idx=?, updated_at=? WHERE id=?", -1, &stmt, nil)
                sqlite3_bind_text(stmt, 1, r.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, r.urlTemplate, -1, SQLITE_TRANSIENT)
                sqlite3_bind_optstr(stmt, 3, r.rule)
                sqlite3_bind_int(stmt, 4, r.enabled ? 1 : 0)
                sqlite3_bind_int(stmt, 5, Int32(r.orderIdx))
                sqlite3_bind_int64(stmt, 6, now)
                sqlite3_bind_int64(stmt, 7, r.id)
            }
            _ = sqlite3_step(stmt)
        }
    }

    public func delete(id: Int64) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "DELETE FROM dict_rules WHERE id=?", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, id)
            _ = sqlite3_step(stmt)
        }
    }

    /// 万象书屋: 默认内置 3 个词典 (汉典 / 有道 / 百度), 首启 seed 一次
    public func seedDefaultsIfNeeded() async throws {
        let existing = try await listAll()
        guard existing.isEmpty else { return }
        try await upsert(DictRuleEntity(name: "汉典", urlTemplate: "https://www.zdic.net/hans/{{key}}"))
        try await upsert(DictRuleEntity(name: "有道", urlTemplate: "https://dict.youdao.com/result?word={{key}}&lang=en"))
        try await upsert(DictRuleEntity(name: "百度汉语", urlTemplate: "https://hanyu.baidu.com/zici/s?wd={{key}}"))
    }
}

// MARK: - TxtToc Repository

public actor TxtTocRuleRepository {
    public static let shared = TxtTocRuleRepository()
    private init() {}

    public func listAll() async throws -> [TxtTocRuleEntity] {
        try await DB.shared.openIfNeeded()
        return try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "SELECT id, name, pattern, example, enabled, order_idx FROM txt_toc_rules ORDER BY order_idx ASC, id ASC", -1, &stmt, nil)
            var out: [TxtTocRuleEntity] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(TxtTocRuleEntity(
                    id: sqlite3_column_int64(stmt, 0),
                    name: colString(stmt, 1) ?? "",
                    pattern: colString(stmt, 2) ?? "",
                    example: colString(stmt, 3),
                    enabled: sqlite3_column_int(stmt, 4) != 0,
                    orderIdx: Int(sqlite3_column_int(stmt, 5))
                ))
            }
            return out
        }
    }

    public func upsert(_ r: TxtTocRuleEntity) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            if r.id == 0 {
                sqlite3_prepare_v2(handle, "INSERT INTO txt_toc_rules(name, pattern, example, enabled, order_idx, updated_at) VALUES (?,?,?,?,?,?)", -1, &stmt, nil)
                sqlite3_bind_text(stmt, 1, r.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, r.pattern, -1, SQLITE_TRANSIENT)
                sqlite3_bind_optstr(stmt, 3, r.example)
                sqlite3_bind_int(stmt, 4, r.enabled ? 1 : 0)
                sqlite3_bind_int(stmt, 5, Int32(r.orderIdx))
                sqlite3_bind_int64(stmt, 6, now)
            } else {
                sqlite3_prepare_v2(handle, "UPDATE txt_toc_rules SET name=?, pattern=?, example=?, enabled=?, order_idx=?, updated_at=? WHERE id=?", -1, &stmt, nil)
                sqlite3_bind_text(stmt, 1, r.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, r.pattern, -1, SQLITE_TRANSIENT)
                sqlite3_bind_optstr(stmt, 3, r.example)
                sqlite3_bind_int(stmt, 4, r.enabled ? 1 : 0)
                sqlite3_bind_int(stmt, 5, Int32(r.orderIdx))
                sqlite3_bind_int64(stmt, 6, now)
                sqlite3_bind_int64(stmt, 7, r.id)
            }
            _ = sqlite3_step(stmt)
        }
    }

    public func delete(id: Int64) async throws {
        try await DB.shared.openIfNeeded()
        try await DB.shared.execQuery { handle in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            sqlite3_prepare_v2(handle, "DELETE FROM txt_toc_rules WHERE id=?", -1, &stmt, nil)
            sqlite3_bind_int64(stmt, 1, id)
            _ = sqlite3_step(stmt)
        }
    }

    /// 万象书屋: 默认内置 4 套常见 TXT 章节模式
    public func seedDefaultsIfNeeded() async throws {
        let existing = try await listAll()
        guard existing.isEmpty else { return }
        try await upsert(TxtTocRuleEntity(name: "第x章", pattern: #"^\s*第[一二三四五六七八九十百千零〇0-9]+章"#))
        try await upsert(TxtTocRuleEntity(name: "Chapter X", pattern: #"^\s*Chapter\s+\d+"#))
        try await upsert(TxtTocRuleEntity(name: "卷x", pattern: #"^\s*第[一二三四五六七八九十0-9]+卷"#))
        try await upsert(TxtTocRuleEntity(name: "数字编号", pattern: #"^\s*\d+\.\s+"#))
    }
}

// MARK: - 净化引擎 (在 ReaderEngine 加载完正文后调)

public enum ReplacementEngine {
    /// 应用所有启用的规则到正文
    public static func apply(rules: [ReplaceRuleEntity], to text: String, sourceUrl: String?) -> String {
        var result = text
        for r in rules where r.enabled {
            if !r.scope.isEmpty {
                // scope 限定: 只在 sourceUrl 命中时应用
                let scopes = r.scope.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if !scopes.contains(where: { sourceUrl?.contains($0) ?? false }) { continue }
            }
            if r.isRegex {
                if let re = try? NSRegularExpression(pattern: r.pattern, options: []) {
                    let nsstr = result as NSString
                    result = re.stringByReplacingMatches(in: result, range: NSRange(0..<nsstr.length), withTemplate: r.replacement)
                }
            } else {
                result = result.replacingOccurrences(of: r.pattern, with: r.replacement)
            }
        }
        return result
    }
}

// MARK: - sql column helper (内部)

private func colString(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
    guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
    return String(cString: cstr)
}
