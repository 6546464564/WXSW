import XCTest
@testable import WanxiangBook

/// 书源兼容性测试：验证书源解析规则的正确性和容错性
final class BookSourceCompatTests: XCTestCase {

    func test_allEnabledSourcesLoadable() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources
        NSLog("[BookSource] 已加载 %d 个书源", sources.count)

        for source in sources where source.enabled {
            XCTAssertFalse(source.bookSourceUrl.isEmpty,
                "书源 \(source.bookSourceName) 的 URL 不应为空")
            XCTAssertFalse(source.bookSourceName.isEmpty,
                "书源 URL=\(source.bookSourceUrl) 的名称不应为空")
        }
    }

    func test_searchRuleParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        var withSearchRule = 0
        for source in sources where source.enabled {
            if let rule = source.ruleSearch, !(rule.bookList ?? "").isEmpty {
                withSearchRule += 1
            }
        }
        NSLog("[BookSource] %d/%d 个启用书源有搜索规则", withSearchRule, sources.filter(\.enabled).count)
    }

    func test_tocRuleParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        for source in sources.prefix(5) where source.enabled {
            if let toc = source.ruleToc {
                XCTAssertFalse((toc.chapterList ?? "").isEmpty,
                    "书源 \(source.bookSourceName) 目录规则chapterList不应为空")
            }
        }
    }

    func test_contentRuleParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        for source in sources.prefix(5) where source.enabled {
            if let content = source.ruleContent {
                XCTAssertFalse((content.content ?? "").isEmpty,
                    "书源 \(source.bookSourceName) 正文规则content不应为空")
            }
        }
    }

    func test_malformedSourceGracefulFailure() async {
        let malformed = BookSource(
            bookSourceUrl: "",
            bookSourceName: "MalformedTest",
            searchUrl: "{{invalid}}"
        )

        do {
            let results = try await BookSourceEngine.shared.search(
                in: malformed, key: "测试"
            )
            NSLog("[BookSource] 畸形书源搜索返回 %d 条结果 (应为空)", results.count)
        } catch {
            NSLog("[BookSource] 畸形书源搜索正确抛出异常: %@", error.localizedDescription)
        }
    }

    func test_emptyBookSourceDefaults() {
        let source = BookSource(bookSourceUrl: "", bookSourceName: "")
        XCTAssertTrue(source.bookSourceUrl.isEmpty)
        XCTAssertTrue(source.bookSourceName.isEmpty)
        XCTAssertNil(source.ruleSearch)
        XCTAssertNil(source.ruleToc)
        XCTAssertNil(source.ruleContent)
    }

    func test_sourceGroupParsing() async {
        let registry = await BookSourceRegistry.shared
        let sources = await registry.sources

        let groups = Set(sources.compactMap(\.bookSourceGroup))
        NSLog("[BookSource] 书源分组: %@", groups.joined(separator: ", "))
    }

    func test_topSourcesSearch() async {
        let registry = await BookSourceRegistry.shared
        await registry.waitUntilEnabledSourcesNonEmpty(timeout: 15)
        let sources = await registry.sources.filter(\.enabled).prefix(3)

        for source in sources {
            do {
                let results = try await BookSourceEngine.shared.search(
                    in: source, key: "测试"
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
