//
//  SourceScoreStore.swift
//  万象书屋 iOS · 换源候选评分持久化
//
//  对应 Android: io.legado.app.data.entities.SearchBook.bookScore (-1 / 0 / 1)
//  + ChangeBookSourceAdapter 里 👍 / 👎 影响候选排序.
//
//  存储在 UserDefaults, 跨 sheet 重开 / App 重启都有效.
//  Key 用 origin+bookUrl, 同一本书在同一个源始终保持评分.
//

import Foundation
import SwiftUI

@MainActor
final class SourceScoreStore: ObservableObject {

    static let shared = SourceScoreStore()

    private static let storageKey = "wx.changesource.score.v1"

    /// (origin + "::" + bookUrl) -> score (-1 / 0 / 1)
    @Published private var cache: [String: Int]

    private init() {
        cache = (UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: Int]) ?? [:]
    }

    private static func id(origin: String, bookUrl: String) -> String { "\(origin)::\(bookUrl)" }

    func score(for book: SearchBook) -> Int {
        cache[Self.id(origin: book.origin, bookUrl: book.bookUrl)] ?? 0
    }

    /// 设置评分; 0 表示清除 (从存储里删掉, 不浪费空间).
    func set(score: Int, for book: SearchBook) {
        let k = Self.id(origin: book.origin, bookUrl: book.bookUrl)
        if score == 0 { cache.removeValue(forKey: k) } else { cache[k] = score }
        UserDefaults.standard.set(cache, forKey: Self.storageKey)
    }
}
