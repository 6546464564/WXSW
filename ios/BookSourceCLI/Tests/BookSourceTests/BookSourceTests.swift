//
//  BookSourceTests.swift
//  万象书屋 M1 单元测试
//

import XCTest
@testable import BookSource

final class BookSourceModelTests: XCTestCase {

    func testDecodeMinimalSource() throws {
        let json = """
        {
          "bookSourceUrl": "https://x.com",
          "bookSourceName": "测试源",
          "ruleSearch": {
            "bookList": "div.book",
            "name": "a@text"
          }
        }
        """
        let data = json.data(using: .utf8)!
        let s = try JSONDecoder().decode(BookSource.self, from: data)
        XCTAssertEqual(s.bookSourceUrl, "https://x.com")
        XCTAssertEqual(s.bookSourceName, "测试源")
        XCTAssertEqual(s.ruleSearch?.bookList, "div.book")
    }

    func testDecodeFlexibleEnabled() throws {
        // legado 历史: enabled 可能是 0/1 (Int) 或 true/false (Bool) 或 "1" (String)
        for (raw, expected) in [
            (#"{"bookSourceUrl":"x","enabled":1}"#, true),
            (#"{"bookSourceUrl":"x","enabled":0}"#, false),
            (#"{"bookSourceUrl":"x","enabled":true}"#, true),
            (#"{"bookSourceUrl":"x","enabled":false}"#, false),
            (#"{"bookSourceUrl":"x","enabled":"1"}"#, true),
            (#"{"bookSourceUrl":"x","enabled":"true"}"#, true),
            (#"{"bookSourceUrl":"x","enabled":"yes"}"#, true),
        ] {
            let s = try JSONDecoder().decode(BookSource.self, from: raw.data(using: .utf8)!)
            XCTAssertEqual(s.enabled, expected, "for input: \(raw)")
        }
    }

    func testParseHeaders() throws {
        let s = BookSource(bookSourceUrl: "https://x.com", bookSourceName: "x")
        var withHeader = s
        withHeader.header = #"{"X-Token":"abc","Cookie":"a=1"}"#
        let h = withHeader.parseHeaders()
        XCTAssertEqual(h["X-Token"], "abc")
        XCTAssertEqual(h["Cookie"], "a=1")
    }

    func testParseConcurrentRate() throws {
        var s = BookSource(bookSourceUrl: "https://x.com", bookSourceName: "x")
        s.concurrentRate = "5/1000"
        let r = s.parseConcurrentRate()
        XCTAssertEqual(r?.count, 5)
        XCTAssertEqual(r?.periodMs, 1000)

        s.concurrentRate = "0/0"
        XCTAssertNil(s.parseConcurrentRate())
    }
}

final class CSSEngineTests: XCTestCase {

    let html = """
    <html><body>
      <div class="book"><a href="/b/1">水浒传</a><span class="author">施耐庵</span></div>
      <div class="book"><a href="/b/2">三国演义</a><span class="author">罗贯中</span></div>
    </body></html>
    """
    let engine = CSSSelectorEngine()

    func testSelectList() throws {
        let names = try engine.selectList(rule: "div.book@a@text", source: html, baseUrl: nil)
        XCTAssertEqual(names, ["水浒传", "三国演义"])
    }

    func testSelectString() throws {
        let first = try engine.selectString(rule: "div.book@span.author@text", source: html, baseUrl: nil)
        XCTAssertEqual(first, "施耐庵")
    }

    func testAbsoluteHref() throws {
        let abs = try engine.selectString(rule: "div.book@a@href", source: html, baseUrl: "https://x.com")
        XCTAssertEqual(abs, "https://x.com/b/1")
    }
}

final class XPathEngineTests: XCTestCase {

    let html = """
    <html><body>
      <div class="book"><a href="/b/1">水浒传</a></div>
      <div class="book"><a href="/b/2">三国演义</a></div>
    </body></html>
    """
    let engine = XPathSelectorEngine()

    func testTextFunction() throws {
        let names = try engine.selectList(rule: "//div[@class='book']/a/text()", source: html, baseUrl: nil)
        XCTAssertEqual(names, ["水浒传", "三国演义"])
    }

    func testHrefAttr() throws {
        let hrefs = try engine.selectList(rule: "//div[@class='book']/a/@href", source: html, baseUrl: "https://x.com")
        XCTAssertEqual(hrefs, ["https://x.com/b/1", "https://x.com/b/2"])
    }
}

final class JSONPathEngineTests: XCTestCase {

    let json = """
    { "data": { "books": [
      {"id":1,"title":"水浒传","author":"施耐庵"},
      {"id":2,"title":"三国演义","author":"罗贯中"}
    ]}}
    """
    let engine = JSONPathEngine()

    func testWildcard() throws {
        let titles = try engine.selectList(rule: "$.data.books[*].title", source: json, baseUrl: nil)
        XCTAssertEqual(titles, ["水浒传", "三国演义"])
    }

    func testIndex() throws {
        let first = try engine.selectString(rule: "$.data.books[0].title", source: json, baseUrl: nil)
        XCTAssertEqual(first, "水浒传")
    }

    func testDescendant() throws {
        let allTitles = try engine.selectList(rule: "$..title", source: json, baseUrl: nil)
        XCTAssertEqual(Set(allTitles), Set(["水浒传", "三国演义"]))
    }
}

final class DispatcherTests: XCTestCase {
    func testRoutePrefixes() async throws {
        let html = #"<div class="x"><a href="/b">书名</a></div>"#
        let json = #"{"title":"红楼梦"}"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)

        // XCTAssertEqual 用 autoclosure 不支持 async, 先 await 出值再断言
        let r1 = try await d.selectString(rule: "div.x@a@text", source: html, baseUrl: nil)
        XCTAssertEqual(r1, "书名")
        let r2 = try await d.selectString(rule: "@css:div.x@a@text", source: html, baseUrl: nil)
        XCTAssertEqual(r2, "书名")
        let r3 = try await d.selectString(rule: "$.title", source: json, baseUrl: nil)
        XCTAssertEqual(r3, "红楼梦")
        let r4 = try await d.selectString(rule: "@js:src.length", source: "abcd", baseUrl: nil)
        XCTAssertEqual(r4, "4")
    }

    func testRegexChain() async throws {
        let html = #"<a href="/book/12345">名</a>"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        // 万象书屋: legado 真实语义 — `##regex##replace` 是替换. 提取数字用 `.*?(\d+).*##$1`
        let r = try await d.selectString(rule: "@css:a@href##.*?(\\d+).*##$1", source: html, baseUrl: nil)
        XCTAssertEqual(r, "12345")
    }

    func testFallbackOr() async throws {
        let html = #"<a class="real">真名</a>"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r = try await d.selectString(rule: ".missing@text||.real@text", source: html, baseUrl: nil)
        XCTAssertEqual(r, "真名")
    }

    // 万象书屋: legado 完整 DSL 回归

    func testIndexSyntax() async throws {
        // tag.0 = 第 0 个 tag (jsoup :eq(0))
        let html = #"<ul><li>A</li><li>B</li><li>C</li></ul>"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r1 = try await d.selectString(rule: "li.0@text", source: html, baseUrl: nil)
        XCTAssertEqual(r1, "A")
        let r2 = try await d.selectString(rule: "li.2@text", source: html, baseUrl: nil)
        XCTAssertEqual(r2, "C")
    }

    func testNestedAtSelector() async throws {
        // div@a@text = "在每个 div 里选 a, 取 text"
        let html = #"<div class="x"><span><a href="/b">书名</a></span></div>"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r = try await d.selectString(rule: "div.x@a@text", source: html, baseUrl: nil)
        XCTAssertEqual(r, "书名")
    }

    func testReplaceRegex() async throws {
        // ##regex##replace 标准替换
        let html = #"<a href="/book/12345">名</a>"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r = try await d.selectString(rule: "a@href##/book/##", source: html, baseUrl: nil)
        XCTAssertEqual(r, "12345")
    }

    func testJSONPathListExpand() async throws {
        // selectList: $.items 应展开 array, 不能当 1 个 string
        let json = #"{"items":[{"n":"a"},{"n":"b"},{"n":"c"}]}"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r = try await d.selectList(rule: "$.items", source: json, baseUrl: nil)
        XCTAssertEqual(r.count, 3)
    }

    func testMustacheJSONPath() async throws {
        // bookUrl 模板 {{$.id}} 用 JSONPath 解出来填回
        let json = #"{"id":42,"name":"X"}"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r = try await d.selectString(rule: "https://x.com/book/{{$.id}}.html", source: json, baseUrl: nil)
        XCTAssertEqual(r, "https://x.com/book/42.html")
    }

    /// 万象书屋: `a@title` 应该能跳过没 title 的 a 拿到第一个有 title 的
    func testAttrSkipEmpty() async throws {
        let html = """
        <li>
         <a href="/x">无 title</a>
         <a href="/x" title="真名">真名</a>
        </li>
        """
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r = try await d.selectString(rule: "a@title", source: html, baseUrl: nil)
        XCTAssertEqual(r, "真名")
    }

    func testTagKeyword() async throws {
        // selector@tag.X = "在 selector 里选所有 X 子元素"
        let html = #"<div class="u-list"><li>A</li><li>B</li><li>C</li></div>"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r = try await d.selectList(rule: ".u-list@tag.li@text", source: html, baseUrl: nil)
        XCTAssertEqual(r, ["A", "B", "C"])
    }

    func testCompoundJSWithSelector() async throws {
        // <js>...</js> 跑完返新 source, 后续 selector 在新 source 上选
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r = try await d.selectString(
            rule: "<js>'<a class=\"x\">真名</a>'</js>\n.x@text",
            source: "原始", baseUrl: nil
        )
        XCTAssertEqual(r, "真名")
    }

    func testFallbackOrPicksSecond() async throws {
        // 第一段空 → 跑第二段
        let html = #"<a class="real">真名</a>"#
        let js = JSEngine()
        let d = SelectorDispatcher(js: js)
        let r = try await d.selectString(rule: ".missing@text||.real@text", source: html, baseUrl: nil)
        XCTAssertEqual(r, "真名")
    }
}

final class LegadoRuleParserTests: XCTestCase {
    func testSplitOr() {
        let segs = LegadoRuleParser.splitTop("a||b||c", separators: ["||"])
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(String(segs[0]), "a")
    }

    func testSplitAnd() {
        let segs = LegadoRuleParser.splitTop("a&&b", separators: ["&&"])
        XCTAssertEqual(segs.count, 2)
    }

    func testSplitProtectedByBrackets() {
        // [a||b] 内的 || 不切
        let segs = LegadoRuleParser.splitTop(":nth-child(1)||.x", separators: ["||"])
        XCTAssertEqual(segs.count, 2)
        // (...) 内的 || 也不切
        let segs2 = LegadoRuleParser.splitTop("foo(a||b)||c", separators: ["||"])
        XCTAssertEqual(segs2.count, 2)
        XCTAssertEqual(String(segs2[0]), "foo(a||b)")
    }

    func testParseSingleMode() {
        XCTAssertEqual(LegadoRuleParser.parseSingle("$.foo").mode, .json)
        XCTAssertEqual(LegadoRuleParser.parseSingle("//div/text()").mode, .xpath)
        XCTAssertEqual(LegadoRuleParser.parseSingle("@css:.foo").mode, .css)
        XCTAssertEqual(LegadoRuleParser.parseSingle("@js:src.length").mode, .js)
        XCTAssertEqual(LegadoRuleParser.parseSingle("a@href").mode, .css)
    }
}

final class JSEngineTests: XCTestCase {
    func testBasicEval() async throws {
        let js = JSEngine()
        let v = try await js.evaluate(script: "1+2*3")
        let s = "\(v ?? "")"
        XCTAssertEqual(s, "7")
    }

    func testBuiltinJavaShim() async throws {
        let js = JSEngine()
        let md5 = try await js.evaluate(script: "java.md5Encode('hello')") as? String
        XCTAssertEqual(md5, "5d41402abc4b2a76b9719d911017c592")

        let b64 = try await js.evaluate(script: "java.base64Encode('hi')") as? String
        XCTAssertEqual(b64, "aGk=")
    }

    func testImplicitVars() async throws {
        let js = JSEngine()
        let v = try await js.evaluate(script: "src.length", source: "12345")
        let s = "\(v ?? "")"
        XCTAssertEqual(s, "5")
    }
}

final class URLTemplateTests: XCTestCase {
    func testBasic() {
        let r = URLTemplate.render("https://x.com/q={{key}}", key: "搜索词")
        XCTAssertTrue(r.url.hasPrefix("https://x.com/q="))
        XCTAssertEqual(r.method, "GET")
    }

    func testJSONOpts() {
        let r = URLTemplate.render(
            "https://x.com/api,{method:'POST',body:'q={{key}}',headers:{'X-Token':'a'}}",
            key: "test"
        )
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.headers["X-Token"], "a")
        if let body = r.body {
            XCTAssertTrue(String(data: body, encoding: .utf8)!.contains("q=test"))
        }
    }

    func testPageVar() {
        let r = URLTemplate.render("https://x.com/list?p={{page}}", page: 7)
        XCTAssertTrue(r.url.contains("p=7"))
    }
}
