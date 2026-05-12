//
//  SearchVariantsCache.swift
//  万象书屋 iOS · 搜索结果跨源变体缓存
//
//  问题: 用户在搜索列表里点一本书 → BookDetailView 用 pickBestSource 挑了某个源.
//  如果该源的 TOC 拉不到 (rule 失效 / 反爬 / 死站), 用户体验是「点了开始阅读 → 目录为空」.
//  Android 之所以"默认源永远能读"是因为它选的就是 race-winner, 通常是稳定的主流源.
//
//  iOS 的 pickBestSource 评分挑选可能比 race-winner 更精, 但仍可能踩到 toc 失败的源.
//  解决方案: BookDetailView 在 toc 拉空时, 用同名同作者的「其它源变体」(每个变体有自己的
//  `bookUrl` 和 `source`) 依次试, 命中第一个能拉 toc 的就切过去, 用户感觉是"自动选了能用的源".
//
//  数据来源: SearchViewModel.search 边搜边把每个候选 SearchBook 存到 rowVariants;
//  落到这个 process-global cache (按 dedupeKey 索引), BookDetailView 读取做 fallback.
//
//  TTL: 进程内永久 (~MB 级别, 单次会话搜的总量), 重启进程清空.
//

import Foundation

/// 万象书屋: 跨"搜索 → 详情页"传递"同书的所有源变体".
///
/// Thread-safe via NSLock; 读多写多的场景, 内存里小哈希表.
public final class SearchVariantsCache: @unchecked Sendable {

    public static let shared = SearchVariantsCache()

    private let lock = NSLock()
    /// key = `SearchBook.dedupeKey` (normalized name + author); value = 所有源变体, 含各源自己
    /// 的 bookUrl / origin / 解析数据.
    private var variants: [String: [SearchBook]] = [:]

    private init() {}

    public func set(key: String, variants: [SearchBook]) {
        lock.lock(); defer { lock.unlock() }
        self.variants[key] = variants
    }

    /// 拿出 dedupeKey 对应的全部变体. 没有时返空数组.
    public func get(key: String) -> [SearchBook] {
        lock.lock(); defer { lock.unlock() }
        return variants[key] ?? []
    }

    /// 测试 / 内存敏感场景下用. 一般不需要主动清.
    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        variants.removeAll()
    }
}
