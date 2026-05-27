//
//  QidianRepositoryTests.swift
//  万象书屋 iOS · 起点书城解析器单测
//
//  覆盖:
//   - SSR HTML 抽 vite-plugin-ssr JSON (id 属性顺序 / 属性引号 / 不存在)
//   - parseMirrorRanks: bid 是 String / Int / Int64 各种类型
//   - parseRanksFromPageData: 9 个 ssrKey 各自缺失时的 graceful 行为
//   - parseBook: 字段 trim / rankNum 兜底 / coverUrl 拼接
//
//  运行:
//   xcodebuild test -project WanxiangBook.xcodeproj -scheme WanxiangBook \
//                    -destination 'platform=iOS Simulator,name=iPhone 15'
//

import XCTest
@testable import WanxiangBook

final class QidianRepositoryTests: XCTestCase {

    // MARK: - extractPageData (SSR HTML 抽 vite-ssr JSON)

    /// 标准的 id 在前 — 跟当前起点 m 站行为一致
    func test_extractPageData_idFirst_ok() async throws {
        let html = """
        <html><body>
        <script id="vite-plugin-ssr_pageContext" type="application/json">
        {"pageContext":{"pageProps":{"pageData":{"records":[],"hello":"world"}}}}
        </script>
        </body></html>
        """
        let result = try await QidianRepository.shared.extractPageData(from: html)
        XCTAssertEqual(result["hello"] as? String, "world")
    }

    /// id 在中间 — Android Jsoup CSS 选择器能拿到, iOS 之前 regex 拿不到. 验证 SwiftSoup 也行.
    func test_extractPageData_idMiddle_swiftsoup_handles() async throws {
        let html = """
        <script type="application/json" id="vite-plugin-ssr_pageContext" data-foo="bar">
        {"pageContext":{"pageProps":{"pageData":{"records":[]}}}}
        </script>
        """
        let result = try await QidianRepository.shared.extractPageData(from: html)
        XCTAssertNotNil(result["records"])
    }

    /// 没 script 时抛 ssrScriptNotFound
    func test_extractPageData_missing_throws() async {
        let html = "<html><body>404 Not Found</body></html>"
        do {
            _ = try await QidianRepository.shared.extractPageData(from: html)
            XCTFail("expected ssrScriptNotFound")
        } catch QidianRepositoryError.ssrScriptNotFound {
            // ok
        } catch {
            XCTFail("expected ssrScriptNotFound, got \(error)")
        }
    }

    /// pageData 缺失时抛 pageDataMissing
    func test_extractPageData_no_pageData_throws() async {
        let html = """
        <script id="vite-plugin-ssr_pageContext" type="application/json">
        {"pageContext":{"pageProps":{"foo":"bar"}}}
        </script>
        """
        do {
            _ = try await QidianRepository.shared.extractPageData(from: html)
            XCTFail("expected pageDataMissing")
        } catch QidianRepositoryError.pageDataMissing {
            // ok
        } catch {
            XCTFail("expected pageDataMissing, got \(error)")
        }
    }

    // MARK: - parseRanksFromPageData

    /// 9 榜单 + 部分缺失时其它仍可用
    func test_parseRanksFromPageData_partialMissing_ok() async throws {
        let pageData: [String: Any] = [
            "fyRank": [
                ["bid": "1234567", "bName": "  万古神帝  ", "bAuth": "飞天鱼",
                 "cat": "玄幻", "subCat": "东方玄幻", "cnt": "5000.00万字",
                 "desc": "测试简介", "rankNum": 1, "rankCnt": "12.04万月票"]
            ],
            "hotRank": [],   // 空数组 → 空列表, 不抛
            // dsRank/recRank/...缺失
        ]
        let ranks = try await QidianRepository.shared.parseRanksFromPageData(pageData)
        XCTAssertEqual(ranks[.yuepiao]?.count, 1)
        XCTAssertEqual(ranks[.yuepiao]?.first?.name, "万古神帝", "应 trim 前后空格")
        XCTAssertEqual(ranks[.yuepiao]?.first?.author, "飞天鱼")
        XCTAssertEqual(ranks[.yuepiao]?.first?.rank, 1)
        XCTAssertEqual(ranks[.yuepiao]?.first?.bookId, "1234567")
        XCTAssertEqual(ranks[.yuepiao]?.first?.coverUrl, "https://bookcover.yuewen.com/qdbimg/349573/1234567/180")
        XCTAssertEqual(ranks[.hotReading]?.count, 0)
    }

    /// 全空数据时 throw parseFailed (跟 Android `if (total == 0) throw`)
    func test_parseRanksFromPageData_allEmpty_throws() async {
        let pageData: [String: Any] = [
            "fyRank": [], "hotRank": [], "dsRank": [],
        ]
        do {
            _ = try await QidianRepository.shared.parseRanksFromPageData(pageData)
            XCTFail("expected parseFailed")
        } catch QidianRepositoryError.parseFailed {
            // ok
        } catch {
            XCTFail("expected parseFailed, got \(error)")
        }
    }

    // MARK: - parseMirrorRanks (bid 是 String 或 Int)

    func test_parseMirrorRanks_bidAsInt_ok() async {
        let mirror: [String: Any] = [
            "fyRank": [
                ["bid": 1234567, "name": "诡秘之主", "author": "爱潜水的乌贼",
                 "cat": "奇幻", "subCat": "异世大陆", "wordCount": "439.43万字",
                 "rank": 1, "rankCount": "8万月票", "intro": "蒸汽与机械"]
            ]
        ]
        let result = await QidianRepository.shared.parseMirrorRanks(mirror)
        XCTAssertEqual(result[.yuepiao]?.count, 1)
        XCTAssertEqual(result[.yuepiao]?.first?.bookId, "1234567")
        XCTAssertEqual(result[.yuepiao]?.first?.name, "诡秘之主")
    }

    func test_parseMirrorRanks_bidAsString_ok() async {
        let mirror: [String: Any] = [
            "hotRank": [
                ["bid": "9876543", "name": "斗破苍穹", "author": "天蚕土豆",
                 "cat": "玄幻", "wordCount": "534.71万字", "rank": 1]
            ]
        ]
        let result = await QidianRepository.shared.parseMirrorRanks(mirror)
        XCTAssertEqual(result[.hotReading]?.first?.bookId, "9876543")
    }

    /// bid 缺失时该 entry 被跳过, 不影响其它
    func test_parseMirrorRanks_bidMissing_skipped() async {
        let mirror: [String: Any] = [
            "fyRank": [
                ["name": "无 bid 的书", "author": "X"],   // 没 bid → 跳过
                ["bid": "12345", "name": "正常的书"],
            ]
        ]
        let result = await QidianRepository.shared.parseMirrorRanks(mirror)
        XCTAssertEqual(result[.yuepiao]?.count, 1, "没 bid 的应被过滤")
        XCTAssertEqual(result[.yuepiao]?.first?.name, "正常的书")
    }

    // MARK: - QidianRankType.ssrKey 反查 (跟 Android 同款)

    func test_ssrKey_mapping_complete() {
        XCTAssertEqual(QidianRankType.yuepiao.ssrKey, "fyRank")
        XCTAssertEqual(QidianRankType.hotReading.ssrKey, "hotRank")
        XCTAssertEqual(QidianRankType.bestseller.ssrKey, "dsRank")
        XCTAssertEqual(QidianRankType.recommend.ssrKey, "recRank")
        XCTAssertEqual(QidianRankType.update.ssrKey, "updRank")
        XCTAssertEqual(QidianRankType.sign.ssrKey, "signRank")
        XCTAssertEqual(QidianRankType.newAuthor.ssrKey, "newpRank")
        XCTAssertEqual(QidianRankType.newBook.ssrKey, "newbRank")
        XCTAssertEqual(QidianRankType.fans.ssrKey, "newFans")
        // /finish/
        XCTAssertEqual(QidianRankType.finishClassic.ssrKey, "classic")
        XCTAssertEqual(QidianRankType.finishMovie.ssrKey, "movie")
        XCTAssertEqual(QidianRankType.finishBestSell.ssrKey, "bestSell")
        XCTAssertEqual(QidianRankType.finishDs.ssrKey, "ds")
    }
}
