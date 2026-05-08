//
//  QidianRepository.swift
//  万象书屋 iOS · 书城数据源 (D-22 / D-23 同 Android)
//
//  对应 Android: io.legado.app.ui.main.bookstore.QidianRepository
//
//  数据源优先级:
//   1. 后端 mirror (/api/bookstore/mirror) — 后端定时抓的 cache, 1 跳到我们 server
//   2. 直抓 m.qidian.com/rank/ 或 /finish/ — 后端 503 / 网络故障时降级
//
//  9 个 /rank/ 榜单 (vite-ssr key → 中文 → 我们的 RankType):
//   fyRank   月票榜 (Yuepiao)
//   hotRank  阅读榜 (HotReading)
//   dsRank   畅销榜 (Bestseller)
//   recRank  推荐榜 (Recommend)
//   updRank  更新榜 (Update)
//   signRank 签约榜 (Sign)
//   newpRank 新人榜 (NewAuthor)
//   newbRank 新书榜 (NewBook)
//   newFans  书友榜 (Fans)
//
//  4 个 /finish/ 榜单:
//   classic / movie / bestSell / ds
//
//  Yuepiao 单榜分页 (D-22.3): /majax/rank/yuepiaolist 接口可拉 1000 名, 需先用
//  /rank/yuepiao 拿到 _csrfToken cookie 再带 token 请求 majax.
//
//  解析器优化清单 (跟 Android 完全对齐):
//   1. 全字段 trim (bAuth/cat/subCat/cnt/desc/rankCnt)
//   2. rankNum/bid 容错: Int / Int64 / NSNumber / String 兜底
//   3. csrf 用 HTTPCookieStorage 取 (跳过 Set-Cookie 合并坑)
//   4. SwiftSoup 解析 SSR script (跳过 id 属性顺序坑)
//   5. 重试 1 次 (与 Android okHttpClient retry=1 对齐)
//   6. HTTP 2xx 状态校验
//   7. 完整日志 (与 Android LogUtils.d 对齐)
//

import Foundation
import os
import SwiftSoup

enum QidianRepositoryError: Error, LocalizedError {
    case ssrScriptNotFound
    case pageDataMissing
    case emptyResponse
    case httpError(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .ssrScriptNotFound: return "vite-ssr script 不存在 (起点改了协议?)"
        case .pageDataMissing: return "pageData 缺失"
        case .emptyResponse: return "空响应"
        case .httpError(let code): return "HTTP \(code)"
        case .parseFailed(let msg): return msg
        }
    }
}

/// 万象书屋·书城 数据源 (singleton).
///
/// 跟 Android `QidianRepository.kt` 的所有 API + 容错行为 1:1 对齐.
actor QidianRepository {

    static let shared = QidianRepository()

    private let base = "https://m.qidian.com"
    private let userAgent =
        "Mozilla/5.0 (Linux; Android 12; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36"

    /// 阅文集团 CDN 封面模板; bookId 替换占位即得最终 URL
    private let coverTemplate = "https://bookcover.yuewen.com/qdbimg/349573/%@/180"

    /// 万象书屋 D-22.3: csrf token 内存缓存. 一次拿到后整个 App 进程都复用.
    private var cachedCsrfToken: String?

    /// 万象书屋: URLSession 默认开 cookieAcceptPolicy=onlyFromMainDocumentDomain,
    /// Set-Cookie 自动写到 HTTPCookieStorage.shared, 跳过 Set-Cookie header 合并坑.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: cfg)
    }()

    private let log = Logger(subsystem: "com.wanxiang.reader", category: "QidianRepository")

    // MARK: - Public

    /// 抓书城 9 榜单数据.
    /// - returns: 9 个 RankType → [QidianBook] (每榜 ~5 本); 找不到 SSR JSON 时抛异常.
    func fetchAllRanks() async throws -> [QidianRankType: [QidianBook]] {
        if let mirror = await BookstoreMirror.shared.fetch(),
           let ranksObj = mirror["ranks"] as? [String: Any], !ranksObj.isEmpty {
            log.debug("ranks from mirror version=\(String(describing: mirror["version"] ?? "?"))")
            return parseMirrorRanks(ranksObj)
        }
        log.debug("ranks fallback to direct fetch")
        let url = "\(base)/rank/?gender=male"
        let pageData = try await fetchPageWithSSR(url: url)
        return try parseRanksFromPageData(pageData)
    }

    /// 万象书屋 D-22.1: 抓 /finish/ 完结频道, 返回 4 完结榜.
    func fetchFinishRanks() async throws -> [QidianRankType: [QidianBook]] {
        if let mirror = await BookstoreMirror.shared.fetch(),
           let finishObj = mirror["finish"] as? [String: Any], !finishObj.isEmpty {
            log.debug("finish from mirror")
            return parseMirrorFinish(finishObj)
        }
        log.debug("finish fallback to direct fetch")
        let url = "\(base)/finish/"
        let pageData = try await fetchPageWithSSR(url: url)
        return try parseFinishFromPageData(pageData)
    }

    /// 万象书屋 D-22.3: 拉多页凑够 [target] 本; 失败的页跳过, 已拿到的不浪费.
    func fetchRankPages(type: QidianRankType, target: Int = 50) async -> [QidianBook] {
        // D-23: Yuepiao 优先 mirror.yuepiaoTop50 (50 本现成的)
        if type == .yuepiao,
           let mirror = await BookstoreMirror.shared.fetch(),
           let arr = mirror["yuepiaoTop50"] as? [[String: Any]], !arr.isEmpty {
            log.debug("yuepiao 50 from mirror size=\(arr.count)")
            return Array(arr.compactMap { mirrorBookToQidian($0, rankType: .yuepiao) }.prefix(target))
        }

        if type != .yuepiao {
            let all = (try? await fetchAllRanks()) ?? [:]
            return Array((all[type] ?? []).prefix(target))
        }

        log.debug("yuepiao 50 fallback to direct fetch (SSR + majax)")
        var out: [QidianBook] = []
        var seen = Set<String>()
        var page = 1
        while out.count < target && page <= 5 {
            let books: [QidianBook]
            do {
                books = page == 1
                    ? try await fetchRankSSR(type: type)
                    : try await fetchRankAjax(type: type, pageNum: page)
            } catch {
                log.debug("page=\(page) failed: \(error.localizedDescription)")
                break
            }
            log.debug("page=\(page) got=\(books.count) total=\(out.count + books.count)")
            if books.isEmpty { break }
            for b in books where seen.insert(b.bookId).inserted {
                out.append(b)
            }
            page += 1
        }
        return Array(out.prefix(target))
    }

    // MARK: - Mirror parsing

    /// 万象书屋: 测试用 — 同 module 单测可通过 actor 访问. 生产代码不应在外部调.
    internal func parseMirrorRanks(_ obj: [String: Any]) -> [QidianRankType: [QidianBook]] {
        let order: [QidianRankType] = [
            .yuepiao, .hotReading, .bestseller, .recommend,
            .update, .sign, .newAuthor, .newBook, .fans,
        ]
        var out: [QidianRankType: [QidianBook]] = [:]
        for rt in order {
            guard let arr = obj[rt.ssrKey] as? [[String: Any]] else { continue }
            out[rt] = arr.compactMap { mirrorBookToQidian($0, rankType: rt) }
        }
        return out
    }

    private func parseMirrorFinish(_ obj: [String: Any]) -> [QidianRankType: [QidianBook]] {
        let map: [(String, QidianRankType)] = [
            ("classic", .finishClassic),
            ("movie", .finishMovie),
            ("bestSell", .finishBestSell),
            ("ds", .finishDs),
        ]
        var out: [QidianRankType: [QidianBook]] = [:]
        for (key, rt) in map {
            guard let arr = obj[key] as? [[String: Any]] else { continue }
            out[rt] = arr.compactMap { mirrorBookToQidian($0, rankType: rt) }
        }
        return out
    }

    /// mirror schema (来自后端 jobs/qidianMirror.js parseBook):
    /// bid / name / author / cat / subCat / wordCount / rank / rankCount / intro / coverUrl
    private func mirrorBookToQidian(_ obj: [String: Any], rankType: QidianRankType) -> QidianBook? {
        let name = obj.trimmedString(forKey: "name")
        guard !name.isEmpty else { return nil }
        let bid = obj.stringNumber(forKey: "bid")
        let cover = obj.trimmedString(forKey: "coverUrl").nonEmpty
            ?? (bid.isEmpty ? "" : String(format: coverTemplate, bid))
        return QidianBook(
            name: name,
            coverUrl: cover,
            author: obj.trimmedString(forKey: "author"),
            category: obj.trimmedString(forKey: "cat"),
            subCategory: obj.trimmedString(forKey: "subCat"),
            wordCount: obj.trimmedString(forKey: "wordCount"),
            bookId: bid,
            rank: obj.intNumber(forKey: "rank") ?? 0,
            rankName: rankType.title,
            rankCount: obj.trimmedString(forKey: "rankCount"),
            intro: obj.trimmedString(forKey: "intro")
        )
    }

    // MARK: - Direct SSR fetch

    private func fetchPageWithSSR(url: String) async throws -> [String: Any] {
        log.debug("fetch \(url)")
        let html = try await fetchHtml(
            url: url,
            extraHeaders: [
                "Referer": "\(base)/",
                "Accept-Language": "zh-CN,zh;q=0.9",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9",
            ]
        )
        return try extractPageData(from: html)
    }

    /// 万象书屋: 用 SwiftSoup 抽 vite-plugin-ssr JSON, 不再用 regex (跳过属性顺序坑).
    /// 跟 Android `Jsoup.parse(html).selectFirst("script#vite-plugin-ssr_pageContext")` 行为一致.
    /// 测试用: internal — 给 QidianRepositoryTests 直接调.
    internal func extractPageData(from html: String) throws -> [String: Any] {
        guard !html.isEmpty else { throw QidianRepositoryError.emptyResponse }
        let doc: Document
        do {
            doc = try SwiftSoup.parse(html)
        } catch {
            throw QidianRepositoryError.parseFailed("HTML parse 失败: \(error.localizedDescription)")
        }
        guard let script = try? doc.select("script#vite-plugin-ssr_pageContext").first() else {
            throw QidianRepositoryError.ssrScriptNotFound
        }
        let raw = script.data()
        guard !raw.isEmpty else { throw QidianRepositoryError.ssrScriptNotFound }
        guard let data = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QidianRepositoryError.parseFailed("vite-ssr JSON 解析失败")
        }
        guard let ctx = root["pageContext"] as? [String: Any],
              let props = ctx["pageProps"] as? [String: Any],
              let pageData = props["pageData"] as? [String: Any] else {
            throw QidianRepositoryError.pageDataMissing
        }
        return pageData
    }

    /// 万象书屋: SSR 拉单榜第一页 (无需 csrf, 永远稳定)
    private func fetchRankSSR(type: QidianRankType) async throws -> [QidianBook] {
        guard let path = rankDetailPath(type: type) else {
            throw QidianRepositoryError.parseFailed("RankType \(type) 无单榜分页 path")
        }
        let url = "\(base)/rank/\(path)?gender=male"
        log.debug("fetch detail SSR \(url)")
        let pageData = try await fetchPageWithSSR(url: url)
        guard let records = pageData["records"] as? [[String: Any]] else { return [] }
        return records.compactMap { parseBook($0, rankType: type) }
    }

    /// D-22.3: ajax 拉第 N 页 (N>=2). 需要 _csrfToken.
    private func fetchRankAjax(type: QidianRankType, pageNum: Int) async throws -> [QidianBook] {
        guard let path = rankAjaxPath(type: type) else {
            throw QidianRepositoryError.parseFailed("RankType \(type) 无 majax path")
        }
        let csrf = try await ensureCsrfToken()
        let url = "\(base)/majax/rank/\(path)?_csrfToken=\(csrf)&gender=male&pageNum=\(pageNum)"
        log.debug("fetch detail ajax \(url)")
        let referer = "\(base)/rank/\(rankDetailPath(type: type) ?? "")?gender=male"
        let raw = try await fetchString(
            url: url,
            extraHeaders: [
                "Referer": referer,
                "Accept": "application/json, text/plain, */*",
                // 万象书屋 D-22.3: 起点 majax 服务端校验 cookie._csrfToken == query._csrfToken,
                // 仅 query 不行 (实测返 code=1 失败). cookie 也带上保证一致性.
                "Cookie": "_csrfToken=\(csrf)",
            ]
        )
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let code = obj.intNumber(forKey: "code") ?? -1
        if code != 0 {
            log.debug("majax err code=\(code) msg=\(String(describing: obj["msg"] ?? "?"))")
            return []
        }
        guard let dataObj = obj["data"] as? [String: Any],
              let records = dataObj["records"] as? [[String: Any]] else {
            return []
        }
        return records.compactMap { parseBook($0, rankType: type) }
    }

    /// 万象书屋 D-22.3: 拉 csrf token. 起点 m 站只在 /rank/yuepiao 等具体路径设 _csrfToken cookie.
    ///
    /// 改进点 (跟 Android 对齐):
    ///   * 用 HTTPCookieStorage.shared.cookies(for:) 拿 cookie, 不再用 value(forHTTPHeaderField:)
    ///     (后者多个 Set-Cookie 合并 + 日期里逗号 → 解析挂掉)
    ///   * URLSession.httpShouldSetCookies = true (默认), Set-Cookie 自动入存储
    private func ensureCsrfToken() async throws -> String {
        if let cached = cachedCsrfToken { return cached }
        let urlStr = "\(base)/rank/yuepiao?gender=male"
        guard let url = URL(string: urlStr) else {
            throw QidianRepositoryError.parseFailed("csrf base URL 非法: \(urlStr)")
        }
        _ = try await fetchString(url: urlStr, extraHeaders: ["Accept": "text/html"])

        // URLSession 把 Set-Cookie 自动塞进 HTTPCookieStorage.shared, 这里直接读取
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard let token = cookies.first(where: { $0.name == "_csrfToken" })?.value, !token.isEmpty else {
            throw QidianRepositoryError.parseFailed("响应未带 _csrfToken Set-Cookie (起点改了协议?)")
        }
        cachedCsrfToken = token
        log.debug("csrf token cached")
        return token
    }

    // MARK: - HTTP helpers (with retry + status check)

    /// 拉 HTML, 失败重试 1 次 (跟 Android okHttpClient retry=1 对齐)
    private func fetchHtml(url: String, extraHeaders: [String: String] = [:]) async throws -> String {
        try await fetchString(url: url, extraHeaders: extraHeaders)
    }

    private func fetchString(url: String, extraHeaders: [String: String] = [:]) async throws -> String {
        guard let parsed = URL(string: url) else {
            throw QidianRepositoryError.parseFailed("URL 非法: \(url)")
        }
        var lastError: Error = QidianRepositoryError.emptyResponse
        // retry = 1 → 最多 2 次尝试 (首次 + 1 次 retry)
        for attempt in 0..<2 {
            do {
                var req = URLRequest(url: parsed)
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                for (k, v) in extraHeaders {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw QidianRepositoryError.parseFailed("无 HTTPURLResponse")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw QidianRepositoryError.httpError(http.statusCode)
                }
                guard !data.isEmpty else {
                    throw QidianRepositoryError.emptyResponse
                }
                return String(data: data, encoding: .utf8) ?? ""
            } catch {
                lastError = error
                if attempt == 0 {
                    log.debug("attempt 1 failed (\(error.localizedDescription)), retry...")
                }
            }
        }
        throw lastError
    }

    /// RankType → /rank/<path>?pageNum=N 的 SSR path
    private func rankDetailPath(type: QidianRankType) -> String? {
        switch type {
        case .yuepiao: return "yuepiao"
        case .hotReading: return "hotsales"
        case .bestseller: return "ds"
        case .recommend: return "recom"
        case .update: return "update"
        case .sign: return "signnewbook"
        case .newAuthor: return "newauthor"
        case .newBook: return "newbook"
        case .fans: return "newFans"
        default: return nil
        }
    }

    /// RankType → /majax/rank/<path>List 的 ajax path (path 后缀加 "List", 实测)
    private func rankAjaxPath(type: QidianRankType) -> String? {
        switch type {
        case .yuepiao: return "yuepiaolist"
        case .hotReading: return "hotsalesList"
        case .bestseller: return "dsList"
        case .recommend: return "recomList"
        case .update: return "updateList"
        case .sign: return "signnewbookList"
        case .newAuthor: return "newauthorList"
        case .newBook: return "newbookList"
        case .fans: return "newFansList"
        default: return nil
        }
    }

    // MARK: - SSR pageData parsing

    /// 测试用: internal — 给 QidianRepositoryTests 直接调.
    internal func parseRanksFromPageData(_ pageData: [String: Any]) throws -> [QidianRankType: [QidianBook]] {
        let order: [QidianRankType] = [
            .yuepiao, .hotReading, .bestseller, .recommend,
            .update, .sign, .newAuthor, .newBook, .fans,
        ]
        var out: [QidianRankType: [QidianBook]] = [:]
        for rt in order {
            guard let arr = pageData[rt.ssrKey] as? [[String: Any]], !arr.isEmpty else {
                out[rt] = []
                continue
            }
            out[rt] = arr.compactMap { parseBook($0, rankType: rt) }
        }
        let total = out.values.map { $0.count }.reduce(0, +)
        log.debug("parsed ranks=\(out.keys.count) total=\(total)")
        if total == 0 {
            throw QidianRepositoryError.parseFailed("解析到 0 条数据 (m.qidian 字段名变更?)")
        }
        return out
    }

    private func parseFinishFromPageData(_ pageData: [String: Any]) throws -> [QidianRankType: [QidianBook]] {
        let order: [QidianRankType] = [.finishClassic, .finishMovie, .finishBestSell, .finishDs]
        var out: [QidianRankType: [QidianBook]] = [:]
        for rt in order {
            guard let arr = pageData[rt.ssrKey] as? [[String: Any]], !arr.isEmpty else {
                out[rt] = []
                continue
            }
            out[rt] = arr.enumerated().compactMap { idx, el in
                parseBook(el, rankType: rt, fallbackRank: idx + 1)
            }
        }
        let total = out.values.map { $0.count }.reduce(0, +)
        log.debug("parsed finish ranks=\(out.keys.count) total=\(total)")
        if total == 0 {
            throw QidianRepositoryError.parseFailed("解析到 0 条 finish 数据")
        }
        return out
    }

    /// 解析单本书. 起点字段名:
    ///   /rank/  系列: bName / bAuth / bid (string) / cat / subCat / cnt / desc / rankNum / rankCnt
    ///   /finish/ 系列: bName / bAuth / bid (number) / cat / cnt / desc / state — 无 subCat / rankNum / rankCnt
    ///
    /// 跟 Android `parseBook` 的容错完全对齐:
    ///   * 全字段 trim
    ///   * bid: String / Int / Int64 / NSNumber 全兼容
    ///   * rankNum: Int / NSNumber / 数值字符串 全兼容
    private func parseBook(
        _ obj: [String: Any],
        rankType: QidianRankType,
        fallbackRank: Int = 0
    ) -> QidianBook? {
        let bid = obj.stringNumber(forKey: "bid")
        guard !bid.isEmpty else { return nil }

        let name = obj.trimmedString(forKey: "bName")
        guard !name.isEmpty else { return nil }

        let cover = String(format: coverTemplate, bid)
        return QidianBook(
            name: name,
            coverUrl: cover,
            author: obj.trimmedString(forKey: "bAuth"),
            category: obj.trimmedString(forKey: "cat"),
            subCategory: obj.trimmedString(forKey: "subCat"),
            wordCount: obj.trimmedString(forKey: "cnt"),
            bookId: bid,
            rank: obj.intNumber(forKey: "rankNum") ?? fallbackRank,
            rankName: rankType.title,
            rankCount: obj.trimmedString(forKey: "rankCnt"),
            intro: obj.trimmedString(forKey: "desc")
        )
    }
}

// MARK: - JSON 容错读取 helpers

private extension Dictionary where Key == String, Value == Any {

    /// 读 String 字段并 trim. 对齐 Android `obj.get(key)?.asString?.trim().orEmpty()`
    func trimmedString(forKey key: String) -> String {
        guard let v = self[key] else { return "" }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// 读"可能是 String/Int/Int64/NSNumber/Double 的数字 ID", 统一转 String.
    /// 对齐 Android `bidEl.asString` (String) / `asLong.toString()` (Number) 双路径.
    func stringNumber(forKey key: String) -> String {
        guard let v = self[key] else { return "" }
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber {
            // Int64 优先 — 起点 bid 现在已经接近 11 位, 32-bit Int 装不下
            // (NSNumber.int64Value 总能正确 round-trip 整数, 即使内部存的是 Double)
            if CFNumberIsFloatType(n) {
                return String(Int64(n.doubleValue))
            }
            return n.stringValue
        }
        return ""
    }

    /// 读"可能是 Int/NSNumber/数值字符串" 的整数. 对齐 Android `runCatching { ?.asInt }`.
    func intNumber(forKey key: String) -> Int? {
        guard let v = self[key] else { return nil }
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String, let i = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return i
        }
        return nil
    }
}

private extension String {
    /// 空字符串返 nil — 给 `?? fallback` 链路用
    var nonEmpty: String? { isEmpty ? nil : self }
}
