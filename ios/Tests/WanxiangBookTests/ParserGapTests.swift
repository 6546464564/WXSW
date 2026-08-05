//
//  ParserGapTests.swift
//  万象书屋 iOS · 低覆盖纯逻辑模块补测
//
//  覆盖覆盖率报告里 <25% 的可测纯逻辑:
//    - ExploreParser.parseExploreKinds (频道文本/@js 解析, 不联网)
//    - SourcePerformanceTracker.Stats (成功率/均耗时/评分/healthLevel)
//    - SourceVariableStore + SourceVariableSnapshot (书源 KV)
//    - ContentParser / TocParser 的 static 工具函数
//    - JsLibCache 本地缓存 get/clear
//

import XCTest
@testable import WanxiangBook

final class ParserGapTests: XCTestCase {

    private func makeSource(exploreUrl: String? = nil) -> BookSource {
        var s = BookSource(bookSourceUrl: "https://gap.example.com", bookSourceName: "补测源")
        s.exploreUrl = exploreUrl
        return s
    }

    // MARK: - 1. ExploreParser.parseExploreKinds

    func test_explore_parseKinds_standardLines() async {
        let parser = ExploreParser(dispatcher: SelectorDispatcher(js: JSEngine()))
        let source = makeSource(exploreUrl: """
            热门::https://x.com/hot
            完结::https://x.com/done
            分类::/category
            """)
        let kinds = await parser.parseExploreKinds(of: source)
        XCTAssertEqual(kinds.count, 3)
        XCTAssertEqual(kinds[0].title, "热门")
        XCTAssertEqual(kinds[0].url, "https://x.com/hot")
        XCTAssertEqual(kinds[1].title, "完结")
        XCTAssertEqual(kinds[2].title, "分类")
        XCTAssertEqual(kinds[2].url, "/category")
    }

    func test_explore_parseKinds_emptyAndMalformed() async {
        let parser = ExploreParser(dispatcher: SelectorDispatcher(js: JSEngine()))
        // 空 exploreUrl
        let empty = await parser.parseExploreKinds(of: makeSource(exploreUrl: nil))
        XCTAssertTrue(empty.isEmpty)
        // 只有无效行: 无 :: / 空 title / 空 url
        let malformed = await parser.parseExploreKinds(of: makeSource(exploreUrl: """
            没有分隔符
            ::只有url
            标题::
            """))
        XCTAssertTrue(malformed.isEmpty)
    }

    func test_explore_parseKinds_jsArray() async {
        let js = JSEngine()
        let parser = ExploreParser(dispatcher: SelectorDispatcher(js: js), jsEngine: js)
        let source = makeSource(exploreUrl: #"@js:JSON.stringify([{title:"热门",url:"/hot"},{title:"完结",url:"/done"}])"#)
        let kinds = await parser.parseExploreKinds(of: source)
        XCTAssertEqual(kinds.count, 2)
        XCTAssertEqual(kinds[0].title, "热门")
        XCTAssertEqual(kinds[0].url, "/hot")
        XCTAssertEqual(kinds[1].title, "完结")
    }

    func test_explore_parseKinds_jsArrayMissingUrlDefaultsEmpty() async {
        let js = JSEngine()
        let parser = ExploreParser(dispatcher: SelectorDispatcher(js: js), jsEngine: js)
        let source = makeSource(exploreUrl: #"@js:[{title:"只有标题"}]"#)
        let kinds = await parser.parseExploreKinds(of: source)
        XCTAssertEqual(kinds.count, 1)
        XCTAssertEqual(kinds[0].url, "")
    }

    // MARK: - 2. SourcePerformanceTracker.Stats

    func test_stats_successRate() {
        XCTAssertEqual(SourcePerformanceTracker.Stats().successRate, 0.5, "空样本应为中性 0.5")
        var s = SourcePerformanceTracker.Stats()
        s.samples = [.init(ok: true, ms: 100, ts: 1), .init(ok: true, ms: 200, ts: 2)]
        XCTAssertEqual(s.successRate, 1.0)
        s.samples.append(.init(ok: false, ms: 300, ts: 3))
        XCTAssertEqual(s.successRate, 2.0 / 3.0, accuracy: 0.001)
    }

    func test_stats_avgSuccessMs() {
        XCTAssertEqual(SourcePerformanceTracker.Stats().avgSuccessMs, Int.max, "无成功记录应为 Int.max")
        var s = SourcePerformanceTracker.Stats()
        s.samples = [.init(ok: true, ms: 100, ts: 1), .init(ok: false, ms: 999, ts: 2), .init(ok: true, ms: 300, ts: 3)]
        XCTAssertEqual(s.avgSuccessMs, 200, "只算成功样本的平均")
    }

    func test_stats_score() {
        var s = SourcePerformanceTracker.Stats()
        s.samples = [.init(ok: true, ms: 1000, ts: 1)]
        XCTAssertEqual(s.score, 90.0, accuracy: 0.001, "100% 成功率 1s 响应 = 100 - 10")
        // 无数据 → 0.5*100 - 50 = 0
        XCTAssertEqual(SourcePerformanceTracker.Stats().score, 0.0, accuracy: 0.001)
    }

    func test_stats_lastFailTag() {
        var s = SourcePerformanceTracker.Stats()
        // 最后成功 → nil (已恢复)
        s.samples = [.init(ok: false, ms: 100, ts: 1, failTag: "搜索失效"), .init(ok: true, ms: 50, ts: 2)]
        XCTAssertNil(s.lastFailTag)
        // 最后失败 → tag
        s.samples.append(.init(ok: false, ms: 200, ts: 3, failTag: "校验超时"))
        XCTAssertEqual(s.lastFailTag, "校验超时")
    }

    func test_stats_healthLevel() {
        let make = { (oks: Bool...) -> SourcePerformanceTracker.Stats in
            var s = SourcePerformanceTracker.Stats()
            s.samples = oks.map { .init(ok: $0, ms: 100, ts: 1) }
            return s
        }
        XCTAssertEqual(make().healthLevel, .unknown, "无样本 → unknown")
        XCTAssertEqual(make(true, true, true, true, true).healthLevel, .good, "100% → good")
        XCTAssertEqual(make(true, true, true, true, false).healthLevel, .good, "80% → good")
        XCTAssertEqual(make(true, true, false).healthLevel, .moderate, "66% → moderate")
        XCTAssertEqual(make(true, false, false).healthLevel, .poor, "33% → poor")
    }

    // MARK: - 3. ContentParser static 工具

    func test_content_resolveAbsoluteURL() {
        // /path 以 / 开头是绝对路径 → 替换 host 后的整个 path
        XCTAssertEqual(ContentParser.resolveAbsoluteURL("/chapter/1", base: "https://x.com/book/"), "https://x.com/chapter/1")
        XCTAssertEqual(ContentParser.resolveAbsoluteURL("https://y.com/c", base: "https://x.com/"), "https://y.com/c")
        XCTAssertNil(ContentParser.resolveAbsoluteURL("", base: "https://x.com/"))
    }

    func test_content_chapterFieldsForScope() {
        let ch = BookChapter(chapterIndex: 3, chapterUrl: "https://x.com/c/3", title: "第三章", isVip: true, isPay: false)
        let dict = ContentParser.chapterFieldsForScope(ch)
        XCTAssertEqual(dict["title"] as? String, "第三章")
        XCTAssertEqual(dict["index"] as? Int, 3)
        XCTAssertEqual(dict["isVip"] as? Bool, true)
        XCTAssertEqual(dict["isPay"] as? Bool, false)
        XCTAssertEqual(dict["url"] as? String, "https://x.com/c/3")
    }

    // MARK: - 4. TocParser static 工具

    func test_toc_bookFieldsForScope() {
        let info = BookInfo(bookUrl: "https://x.com/b/1", name: "测试书", author: "作者", intro: "简介", kind: "玄幻", coverUrl: "https://x.com/c.jpg", tocUrl: "https://x.com/toc")
        let dict = TocParser.bookFieldsForScope(info)
        XCTAssertEqual(dict["name"] as? String, "测试书")
        XCTAssertEqual(dict["author"] as? String, "作者")
        XCTAssertEqual(dict["bookUrl"] as? String, "https://x.com/b/1")
        XCTAssertEqual(dict["kind"] as? String, "玄幻")
    }

    func test_toc_absolutize() {
        let parser = TocParser(dispatcher: SelectorDispatcher(js: JSEngine()))
        XCTAssertEqual(parser.absolutize("https://x.com/c", baseUrl: "https://x.com/"), "https://x.com/c", "绝对 URL 原样")
        // /c/1 以 / 开头是绝对路径 → 替换整个 path
        XCTAssertEqual(parser.absolutize("/c/1", baseUrl: "https://x.com/toc/"), "https://x.com/c/1", "绝对路径相对 base host 拼接")
        XCTAssertEqual(parser.absolutize("", baseUrl: "https://x.com/"), nil, "空 URL → nil")
        XCTAssertNil(parser.absolutize("{json}", baseUrl: "https://x.com/"), "JSON 段 → nil")
        XCTAssertNil(parser.absolutize("<html>", baseUrl: "https://x.com/"), "HTML 段 → nil")
    }

    // MARK: - 5. SourceVariableStore (actor KV)

    func test_sourceVariableStore_setGetRemove() async {
        let url = "https://kv.test.example.com/source"
        let store = SourceVariableStore.shared
        await store.set(sourceUrl: url, value: "{\"page\":1}")
        let got = await store.get(sourceUrl: url)
        XCTAssertEqual(got, "{\"page\":1}")
        await store.set(sourceUrl: url, value: nil)
        let afterRemove = await store.get(sourceUrl: url)
        XCTAssertEqual(afterRemove, "")
        // 清理
        await store.set(sourceUrl: url, value: nil)
    }

    func test_sourceVariableStore_loginInfo() async {
        let url = "https://kv.test.example.com/login"
        let store = SourceVariableStore.shared
        await store.setLoginInfo(sourceUrl: url, info: ["token": "abc123", "user": "小明"])
        let got = await store.getLoginInfo(sourceUrl: url)
        XCTAssertEqual(got["token"], "abc123")
        XCTAssertEqual(got["user"], "小明")
        // 覆盖写
        await store.setLoginInfo(sourceUrl: url, info: ["token": "new"])
        let after = await store.getLoginInfo(sourceUrl: url)
        XCTAssertEqual(after["token"], "new")
        XCTAssertNil(after["user"])
        // 清理
        await store.set(sourceUrl: url, value: nil)
    }

    func test_sourceVariableSnapshot_initAndWriteBack() async {
        let url = "https://kv.test.example.com/snap"
        let store = SourceVariableStore.shared
        await store.set(sourceUrl: url, value: "snap-value")

        var snap = SourceVariableSnapshot(sourceUrl: url)
        XCTAssertEqual(snap.variable, "snap-value")
        snap.variable = "snap-updated"
        snap.loginInfo = ["k": "v"]
        snap.writeBack()

        let got = await store.get(sourceUrl: url)
        XCTAssertEqual(got, "snap-updated")
        let login = await store.getLoginInfo(sourceUrl: url)
        XCTAssertEqual(login["k"], "v")
        // 清理
        await store.set(sourceUrl: url, value: nil)
    }

    // MARK: - 6. JsLibCache 本地缓存

    func test_jsLibCache_getUncachedNilAndClear() {
        // 未缓存 URL → nil (不触发网络, 因为 get 只查内存/磁盘)
        XCTAssertNil(JsLibCache.get(url: "https://not-cached.example.com/lib.js"))
        // clear 不应崩
        JsLibCache.clear()
        XCTAssertNil(JsLibCache.get(url: "https://not-cached.example.com/lib.js"))
    }

    // MARK: - 7. SelectorDispatcher.selectUrlList / mustache

    func test_dispatcher_selectUrlList_extractsAbsolutizesDedupes() async throws {
        let dispatcher = SelectorDispatcher(js: JSEngine())
        let html = """
            <div class="item"><a href="/c/1">一</a></div>
            <div class="item"><a href="/c/2">二</a></div>
            <div class="item"><a href="/c/1">重复</a></div>
            <div class="item"><a>空href</a></div>
            """
        let urls = try await dispatcher.selectUrlList(
            rule: "div.item a@href", source: html, baseUrl: "https://x.com/book/"
        )
        XCTAssertEqual(urls, ["https://x.com/c/1", "https://x.com/c/2"], "应提取+绝对化+去重")
    }

    func test_dispatcher_selectString_jsonMustache() async throws {
        let dispatcher = SelectorDispatcher(js: JSEngine())
        let json = #"{"articleid":"12345","lang":"zh"}"#
        let result = try await dispatcher.selectString(
            rule: #"https://x.com/detail/{{$.articleid}}?lang={{$.lang}}"#,
            source: json,
            baseUrl: nil
        )
        XCTAssertEqual(result, "https://x.com/detail/12345?lang=zh", "{{$.xxx}} 应从 JSON 解出")
    }

    func test_dispatcher_selectString_emptyRule() async throws {
        let dispatcher = SelectorDispatcher(js: JSEngine())
        let r = try await dispatcher.selectString(rule: "   ", source: "<html></html>", baseUrl: nil)
        XCTAssertNil(r, "空规则 → nil")
    }

    func test_dispatcher_selectList_emptyRuleThrows() async {
        let dispatcher = SelectorDispatcher(js: JSEngine())
        do {
            _ = try await dispatcher.selectList(rule: "  ", source: "<html></html>", baseUrl: nil)
            XCTFail("空规则应抛错")
        } catch {
            // 预期抛错
        }
    }
}
