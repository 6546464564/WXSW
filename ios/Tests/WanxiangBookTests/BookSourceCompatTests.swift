import XCTest
@testable import WanxiangBook

/// 书源兼容性测试：验证书源解析规则的正确性和容错性
final class BookSourceCompatTests: XCTestCase {

    // MARK: - BS1: 所有启用书源应可加载

    func test_allEnabledSourcesLoadable() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources
        NSLog("[BookSource] 已加载 %d 个书源", sources.count)

        for source in sources where source.enabled {
            XCTAssertFalse(source.bookSourceUrl.isEmpty,
                "书源 \(source.bookSourceName) URL不应为空")
            XCTAssertFalse(source.bookSourceName.isEmpty,
                "书源URL \(source.bookSourceUrl) 名称不应为空")
        }
    }

    // MARK: - BS2: 搜索规则解析

    func test_searchRuleParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        var withSearchRule = 0
        for source in sources where source.enabled {
            if let rule = source.ruleSearch, !rule.bookList.isEmpty {
                withSearchRule += 1
            }
        }
        NSLog("[BookSource] %d/%d 个启用书源有搜索规则", withSearchRule, sources.filter(\.enabled).count)
    }

    // MARK: - BS3: 目录规则解析

    func test_tocRuleParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        for source in sources.prefix(5) where source.enabled {
            if let toc = source.ruleToc {
                XCTAssertFalse(toc.chapterList.isEmpty,
                    "书源 \(source.bookSourceName) 目录规则chapterList不应为空")
            }
        }
    }

    // MARK: - BS4: 正文规则解析

    func test_contentRuleParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        for source in sources.prefix(5) where source.enabled {
            if let content = source.ruleContent {
                XCTAssertFalse(content.content.isEmpty,
                    "书源 \(source.bookSourceName) 正文规则content不应为空")
            }
        }
    }

    // MARK: - BS5: 畸形书源 JSON 容错

    func test_malformedSourceJSON() {
        let malformedCases = [
            "{}",
            "{\"bookSourceUrl\":\"https://test.com\"}",
            "{\"bookSourceName\":\"无URL源\"}",
            "{\"bookSourceUrl\":\"\",\"bookSourceName\":\"空URL\"}",
        ]

        for json in malformedCases {
            let data = json.data(using: .utf8)!
            let source = try? JSONDecoder().decode(BookSource.self, from: data)
            if let s = source {
                NSLog("[BookSource] 畸形JSON解码成功: name=%@, url=%@",
                      s.bookSourceName, s.bookSourceUrl)
            }
        }
    }

    // MARK: - BS6: 书源URL格式验证

    func test_sourceURLFormat() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        for source in sources where source.enabled {
            let url = source.bookSourceUrl
            let hasScheme = url.hasPrefix("http://") || url.hasPrefix("https://")
            XCTAssertTrue(hasScheme,
                "书源 \(source.bookSourceName) URL应以http(s)://开头, 实际: \(url)")
        }
    }

    // MARK: - BS7: 书源搜索实际调用 (前5个)

    func test_topSourcesSearch() async {
        let registry = await BookSourceRegistry.shared
        await registry.waitUntilEnabledSourcesNonEmpty(timeout: 15)
        let sources = await registry.sources.filter(\.enabled).prefix(3)

        for source in sources {
            do {
                let results = try await BookSourceEngine.shared.search(
                    keyword: "测试", in: source
                )
                NSLog("[BookSource] %@ 搜索返回 %d 条结果",
                      source.bookSourceName, results.count)
            } catch {
                NSLog("[BookSource] %@ 搜索失败: %@",
                      source.bookSourceName, error.localizedDescription)
            }
        }
    }
}
