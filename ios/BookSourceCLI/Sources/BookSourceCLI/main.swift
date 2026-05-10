//
//  BookSourceCLI · main.swift
//  万象书屋 M1-14 端到端 CLI 验证工具
//
//  用法:
//    swift run BookSourceCLI test-css        # 单测 CSS 选择器
//    swift run BookSourceCLI test-xpath      # 单测 XPath
//    swift run BookSourceCLI test-jsonpath   # 单测 JSONPath
//    swift run BookSourceCLI test-js         # 单测 JS 引擎
//    swift run BookSourceCLI fetch <URL>     # 抓页面看编码探测
//    swift run BookSourceCLI search-stub     # 用内置 stub 源跑搜索 (无网络)
//    swift run BookSourceCLI search-gutenberg <key>  # 用 Project Gutenberg 真实搜索
//

import Foundation
import BookSource

@main
struct CLI {
    static func main() async {
        // 万象书屋: 注册 WKWebViewBridge 让 BookSource 引擎能绕反爬
        // (macOS 也有 WebKit, CLI 也能用)
        await BrowserBridgeRegistry.shared.set(
            await MainActor.run { WKWebViewBridge() }
        )

        let args = Array(CommandLine.arguments.dropFirst())
        let cmd = args.first ?? "help"
        do {
            switch cmd {
            case "test-css":         try await testCSS()
            case "test-xpath":       try await testXPath()
            case "test-jsonpath":    try await testJSONPath()
            case "test-js":          try await testJS()
            case "test-dispatcher":  try await testDispatcher()
            case "test-url":         try testURLTemplate()
            case "fetch":            try await testFetch(url: args.dropFirst().first ?? "https://www.gutenberg.org/")
            case "search-stub":      try await searchStub()
            case "smoke":            try await smokeAll()
            case "debug-source":
                let name = args.dropFirst().first ?? "🍅番茄小说源"
                let key = args.dropFirst(2).first ?? "斗破苍穹"
                try await debugSource(name: name, key: key)
            case "debug-file":
                // debug-file <jsonpath> <name 子串> [<keyword>]
                let p = args.dropFirst().first ?? ""
                let nameSub = args.dropFirst(2).first ?? ""
                let key = args.dropFirst(3).first ?? "斗破苍穹"
                try await debugSourceFromFile(path: p, nameSub: nameSub, key: key)
            case "debug-toc":
                let name = args.dropFirst().first ?? "七星阁小说网"
                let url = args.dropFirst(2).first ?? "https://www.qixinge.net/info/68397/"
                try await debugToc(sourceName: name, bookUrl: url)
            case "debug-css":
                // debug-css <url> <selector>
                let url = args.dropFirst().first ?? "https://www.qixinge.net/info/68397/"
                let sel = args.dropFirst(2).first ?? ".book_list2 li a"
                try await debugCss(url: url, selector: sel)
            case "real-search":
                // real-search "<keyword>" [<source-name-filter>]
                let key = args.dropFirst().first ?? "斗破苍穹"
                let filter = args.dropFirst(2).first
                try await realSearch(key: key, sourceFilter: filter)
            case "real-search-file":
                // real-search-file /path/to/sources.json "<keyword>" [<source-name-substring>]
                let path = args.dropFirst().first ?? ""
                let key = args.dropFirst(2).first ?? "test"
                let filter = args.dropFirst(3).first
                try await realSearchFromFile(path: path, key: key, sourceFilter: filter)
            case "real-deep":
                // 端到端: search → 详情 → 目录(前 5 章) → 第 1 章正文, 验证全链路
                let key = args.dropFirst().first ?? "斗破苍穹"
                let filter = args.dropFirst(2).first
                try await realDeep(key: key, sourceFilter: filter)
            case "real-deep-file":
                // 端到端但从本地 JSON 读源 (用户提供的额外源单).
                // real-deep-file <path> "<keyword>" [<source-name-substring>]
                let path = args.dropFirst().first ?? ""
                let key = args.dropFirst(2).first ?? "斗破苍穹"
                let filter = args.dropFirst(3).first
                try await realDeepFromFile(path: path, key: key, sourceFilter: filter)
            case "merge-search":
                // merge-search "<关键字>" [true|1]   # 第二参为「精准搜索」同 iOS App
                let key = args.dropFirst().first ?? "斗破苍穹"
                let precArg = args.dropFirst(2).first?.lowercased() ?? ""
                let precision = (precArg == "1" || precArg == "true" || precArg == "yes")
                try await mergeSearch(key: key, precision: precision)
            default:                 printHelp()
            }
        } catch {
            print("❌ Error: \(error)")
            exit(1)
        }
    }

    static func printHelp() {
        print("""
        万象书屋 BookSourceCLI · M1-14 验证工具

        用法:
          swift run BookSourceCLI <command>

        命令:
          smoke           跑全套冒烟测试 (推荐)
          test-css        CSS 选择器单测
          test-xpath      XPath 单测
          test-jsonpath   JSONPath 单测
          test-js         JS 引擎单测
          test-dispatcher Dispatcher 路由测试
          test-url        URL 模板渲染测试
          fetch <URL>     抓页面看编码探测
          search-stub     用 mock HTML 源跑搜索 (无网络, 验证 SearchParser)
          real-search \"关键字\" [源名过滤]   # 走后端 /api/sources
          merge-search \"关键字\" [true]      # 全源合并 + iOS 同款去重/排序 (对照安卓列表用)
          real-search-file <legado.json> \"关键字\" [源名过滤]   # 本地 JSON
        """)
    }
}

// MARK: - 单元测试套件

func testCSS() async throws {
    print("\n=== CSS 选择器测试 ===")
    let html = """
    <html><body>
      <div class="book"><a href="/b/1">水浒传</a><span class="author">施耐庵</span></div>
      <div class="book"><a href="/b/2">三国演义</a><span class="author">罗贯中</span></div>
    </body></html>
    """
    let css = CSSSelectorEngine()

    let names = try css.selectList(rule: "div.book@a@text", source: html, baseUrl: "https://x.com")
    assertEq(names, ["水浒传", "三国演义"], "CSS list")

    let firstAuthor = try css.selectString(rule: "div.book@span.author@text", source: html, baseUrl: nil)
    assertEq(firstAuthor, "施耐庵", "CSS first")

    let absHref = try css.selectString(rule: "div.book@a@href", source: html, baseUrl: "https://x.com")
    assertEq(absHref, "https://x.com/b/1", "CSS abs href")

    // 万象书屋: legado 索引语法 (主选择器后缀)
    let listHTML = """
    <ul>
      <li>A</li><li>B</li><li>C</li><li>D</li><li>E</li>
    </ul>
    """

    // 1) 老写法: ul li.0 = 第 0 个
    let firstLi = try css.selectString(rule: "ul li.0@text", source: listHTML, baseUrl: nil)
    assertEq(firstLi, "A", "legado .N old form")

    // 2) [start:end:step] - 全闭区间, end=-1 表示最后
    let evenLi = try css.selectList(rule: "ul li[0:-1:2]@text", source: listHTML, baseUrl: nil)
    assertEq(evenLi, ["A", "C", "E"], "legado [start:end:step] inclusive")

    // 3) [!1,3] = 排除 1 / 3
    let dropLi = try css.selectList(rule: "ul li[!1,3]@text", source: listHTML, baseUrl: nil)
    assertEq(dropLi, ["A", "C", "E"], "legado [!a,b] exclude")

    // 4) tag.li.-1 = 倒数第一
    let lastLi = try css.selectString(rule: "ul li.-1@text", source: listHTML, baseUrl: nil)
    assertEq(lastLi, "E", "legado negative index")

    // 5) [-1:0] = 反向输出 (legado 文档明文支持)
    let revLi = try css.selectList(rule: "ul li[-1:0]@text", source: listHTML, baseUrl: nil)
    assertEq(revLi, ["E", "D", "C", "B", "A"], "legado [-1:0] reverse")

    // 6) textNodes (直接子文本节点 join "\n")
    let nodeHTML = "<p>line1<br>line2<br>line3</p>"
    let tn = try css.selectString(rule: "p@textNodes", source: nodeHTML, baseUrl: nil)
    assertEq(tn, "line1\nline2\nline3", "legado @textNodes join")

    // 7) html extractor 去 script/style
    let dirty = "<div>正文<script>x()</script><style>.a{}</style>更多</div>"
    let cleaned = try css.selectString(rule: "div@html", source: dirty, baseUrl: nil)
    assertEq(cleaned?.contains("script") == false && cleaned?.contains("正文") == true, true, "legado @html strips script/style")

    print("✅ CSS OK")
}

func testXPath() async throws {
    print("\n=== XPath → CSS 翻译测试 ===")
    let html = """
    <html><body>
      <div class="book"><a href="/b/1">水浒传</a></div>
      <div class="book"><a href="/b/2">三国演义</a></div>
    </body></html>
    """
    let xp = XPathSelectorEngine()
    // //div[@class='book']/a/text()  →  div.book > a@text
    let names = try xp.selectList(rule: "//div[@class='book']/a/text()", source: html, baseUrl: nil)
    assertEq(names, ["水浒传", "三国演义"], "XPath text()")

    // //div[@class='book']/a/@href  →  div.book > a@href
    let hrefs = try xp.selectList(rule: "//div[@class='book']/a/@href", source: html, baseUrl: "https://x.com")
    assertEq(hrefs, ["https://x.com/b/1", "https://x.com/b/2"], "XPath @href")

    print("✅ XPath OK")
}

func testJSONPath() async throws {
    print("\n=== JSONPath 测试 ===")
    let json = """
    {
      "code": 0,
      "data": {
        "books": [
          {"id": 1, "title": "水浒传", "author": "施耐庵"},
          {"id": 2, "title": "三国演义", "author": "罗贯中"},
          {"id": 3, "title": "西游记", "author": "吴承恩"},
          {"id": 4, "title": "红楼梦", "author": "曹雪芹"}
        ]
      }
    }
    """
    let jp = JSONPathEngine()
    let titles = try jp.selectList(rule: "$.data.books[*].title", source: json, baseUrl: nil)
    assertEq(titles, ["水浒传", "三国演义", "西游记", "红楼梦"], "JSONPath list[*].title")

    let first = try jp.selectString(rule: "$.data.books[0].title", source: json, baseUrl: nil)
    assertEq(first, "水浒传", "JSONPath [0]")

    // 万象书屋: JsonPath 切片 (legado 源用 `$.items[:10]` 限制返回数)
    let top2 = try jp.selectList(rule: "$.data.books[:2]", source: json, baseUrl: nil)
    assertEq(top2.count, 2, "JSONPath [:N] slice count")

    let last = try jp.selectString(rule: "$.data.books[-1].title", source: json, baseUrl: nil)
    assertEq(last, "红楼梦", "JSONPath [-1] negative index")

    let multi = try jp.selectList(rule: "$.data.books[0,2]", source: json, baseUrl: nil)
    assertEq(multi.count, 2, "JSONPath [a,b] multi index")

    print("✅ JSONPath OK")
}

func testJS() async throws {
    print("\n=== JS 引擎测试 ===")
    let js = JSEngine()

    let v1 = try await js.evaluate(script: "1 + 2 * 3")
    assertEq("\(v1 ?? "")", "7", "JS basic math")

    let v2 = try await js.evaluate(script: "java.md5Encode('hello')")
    assertEq(v2 as? String, "5d41402abc4b2a76b9719d911017c592", "JS md5")

    let v3 = try await js.evaluate(script: "java.base64Encode('万象书屋')")
    assertEq(v3 as? String, "5LiH6LGh5Lmm5bGL", "JS base64")

    // 隐式变量 src
    let v4 = try await js.evaluate(script: "src.length", source: "abcde")
    assertEq("\(v4 ?? "")", "5", "JS src var")

    print("✅ JS OK")
}

func testDispatcher() async throws {
    print("\n=== Dispatcher 路由测试 ===")
    let html = """
    <div class="book"><a href="/b/1">水浒传</a></div>
    """
    let json = "{\"title\":\"红楼梦\"}"
    let js = JSEngine()
    let d = SelectorDispatcher(js: js)

    // 默认 CSS
    let n1 = try await d.selectString(rule: "div.book@a@text", source: html, baseUrl: nil)
    assertEq(n1, "水浒传", "default CSS")

    // 显式 @css:
    let n2 = try await d.selectString(rule: "@css:div.book@a@text", source: html, baseUrl: nil)
    assertEq(n2, "水浒传", "@css:")

    // 显式 @xpath:
    let n3 = try await d.selectString(rule: "@xpath://div[@class='book']/a/text()", source: html, baseUrl: nil)
    assertEq(n3, "水浒传", "@xpath:")

    // 默认 JSONPath ($. 开头)
    let n4 = try await d.selectString(rule: "$.title", source: json, baseUrl: nil)
    assertEq(n4, "红楼梦", "default JSONPath")

    // 显式 @js:
    let n5 = try await d.selectString(rule: "@js: src.length + 'chars'", source: "12345", baseUrl: nil)
    assertEq(n5, "5chars", "@js:")

    // 链式正则 ## (legado 语义: ##regex 删除匹配, ##regex##repl 替换)
    // "/b/1" 的非数字字符全删掉就剩 "1"
    let n6 = try await d.selectString(rule: "@css:div.book@a@href##\\D+", source: html, baseUrl: nil)
    assertEq(n6, "1", "## regex chain (strip non-digits)")
    // 确认替换语法
    let n6b = try await d.selectString(rule: "@css:div.book@a@href##\\d+##X", source: html, baseUrl: nil)
    assertEq(n6b, "/b/X", "## regex chain (replace)")

    // || 兜底 (第一个失败, 第二个成功)
    let n7 = try await d.selectString(rule: "div.notexist@text||div.book@a@text", source: html, baseUrl: nil)
    assertEq(n7, "水浒传", "|| fallback")

    // 万象书屋: %% 拉链 (yckceo 文档关键能力)
    let zipHTML = """
    <ul class="t"><li>A1</li><li>A2</li><li>A3</li></ul>
    <ul class="b"><li>B1</li><li>B2</li><li>B3</li></ul>
    """
    let zipped = try await d.selectList(rule: "ul.t li@text%%ul.b li@text", source: zipHTML, baseUrl: nil)
    assertEq(zipped, ["A1", "B1", "A2", "B2", "A3", "B3"], "%% zip interleave")

    // 万象书屋: 前缀 - 倒置最终列表 (yckceo 文档明文)
    let revList = try await d.selectList(rule: "-ul.t li@text", source: zipHTML, baseUrl: nil)
    assertEq(revList, ["A3", "A2", "A1"], "-prefix invert list")

    // 万象书屋: && 串联 (在前段结果上继续 select)
    let chained = try await d.selectString(rule: "ul.t@html&&li.0@text", source: zipHTML, baseUrl: nil)
    assertEq(chained, "A1", "&& chain reduce")

    // 万象书屋: @put / @get  (跨调用 KV 持久化, 走 putStore 而非 ctx.book)
    // 用一个虚拟 source key, 通过手动 put + 手动 get 验证 round-trip
    let testKey = "https://test.put.example.com"
    await LegadoRuleEngine.shared.putValue("水浒传", forKey: "bid", source: testKey)
    let stored = await LegadoRuleEngine.shared.getValue(forKey: "bid", source: testKey)
    assertEq(stored, "水浒传", "putValue/getValue round-trip")
    await LegadoRuleEngine.shared.resetPutStore(sourceKey: testKey)
    let cleared = await LegadoRuleEngine.shared.getValue(forKey: "bid", source: testKey)
    assertEq(cleared, nil, "resetPutStore clears bag")

    print("✅ Dispatcher OK")
}

func testURLTemplate() throws {
    print("\n=== URLTemplate 渲染测试 ===")
    let r1 = URLTemplate.render("https://x.com/search?q={{key}}", key: "斗破苍穹")
    assertContains(r1.url, "search?q=", "url template basic")
    assertEq(r1.method, "GET", "default method")

    let r2 = URLTemplate.render("https://x.com/search,{method:'POST',body:'q={{key}}'}", key: "test")
    assertEq(r2.method, "POST", "JSON opts method")
    assertContains(String(data: r2.body ?? Data(), encoding: .utf8) ?? "", "q=test", "JSON opts body")

    let r3 = URLTemplate.render("https://x.com/list?p={{page}}", page: 5)
    assertContains(r3.url, "p=5", "page var")

    print("✅ URLTemplate OK")
}

func testGBKEncoding() throws {
    print("\n=== URLTemplate GBK percent-encode ===")
    // 模拟一个 charset=gb2312 的 GET URL
    let r = URLTemplate.render("https://x.com/s?q={{key}},{\"charset\":\"gb2312\"}", key: "斗破苍穹")
    // 「斗破苍穹」按 GBK 是 B6 B7 C6 C6 B2 D4 F1 B7
    assertContains(r.url, "%B6%B7%C6%C6%B2%D4%F1%B7", "GBK key encoded as %XX (not latin-1 chars)")
    // 不能包含 latin-1 字面 (旧 bug 会出现 `Æ` `²` `ñ` 这些字符)
    let bad = ["Æ", "²", "ñ"]
    for ch in bad {
        if r.url.contains(ch) {
            print("❌ FAIL [GBK encoding leaks \(ch)]"); print("   url: \(r.url)")
            assertEq(false, true, "GBK encoding leaks latin-1 char \(ch)")
        }
    }
    print("✅ GBK URL encoding OK")
}

func testLegadoSpecial() async throws {
    print("\n=== Legado 特殊语法 (`<X,Y>`, bookInfoInit) ===")
    // <X,Y> 操作符: 第 1 页取 X, 之后取 Y
    let tplRule = "https://x.com/list<,?p={{page}}>"
    let p1 = await LegadoRuleEngine.shared.renderURL(template: tplRule, page: 1)
    assertEq(p1, "https://x.com/list", "<X,Y> page=1 → X (空)")
    let p2 = await LegadoRuleEngine.shared.renderURL(template: tplRule, page: 2)
    assertEq(p2, "https://x.com/list?p=2", "<X,Y> page=2 → Y")

    // 多个 <X,Y> 同时出现
    let multi = "https://x.com<,/p{{page}}>/list<,?from={{page}}>"
    let m1 = await LegadoRuleEngine.shared.renderURL(template: multi, page: 1)
    let m3 = await LegadoRuleEngine.shared.renderURL(template: multi, page: 3)
    assertEq(m1, "https://x.com/list", "multi <X,Y> page=1")
    assertEq(m3, "https://x.com/p3/list?from=3", "multi <X,Y> page=3")

    // {{(page-1)*20}} JS 求值 (yckceo 文档明示)
    let jsP = "https://x.com/?offset={{(page-1)*20}}"
    let v1 = await LegadoRuleEngine.shared.renderURL(template: jsP, page: 1)
    let v3 = await LegadoRuleEngine.shared.renderURL(template: jsP, page: 3)
    assertEq(v1, "https://x.com/?offset=0", "{{(page-1)*20}} page=1")
    assertEq(v3, "https://x.com/?offset=40", "{{(page-1)*20}} page=3")

    print("✅ Legado special OK")
}

func testFetch(url: String) async throws {
    print("\n=== HTTPFetcher 抓 \(url) ===")
    let resp = try await HTTPFetcher.shared.fetch(urlString: url)
    print("  status: \(resp.statusCode)")
    print("  encoding: \(resp.detectedEncoding)")
    print("  body length: \(resp.bodyData.count) bytes / \(resp.bodyText.count) chars")
    print("  headers (sample):")
    for (k, v) in resp.headers.prefix(3) {
        print("    \(k): \(v.prefix(80))")
    }
    print("✅ Fetch OK")
}

func searchStub() async throws {
    print("\n=== SearchParser stub 测试 (mock HTTP) ===")
    // 用一个 mock HTML, 不需要真实网络
    let mockHTML = """
    <html><body>
      <ul class="search-list">
        <li class="book-item">
          <a href="/book/1" class="title">三体</a>
          <span class="author">刘慈欣</span>
          <span class="intro">人类首次面对外星文明...</span>
        </li>
        <li class="book-item">
          <a href="/book/2" class="title">球状闪电</a>
          <span class="author">刘慈欣</span>
          <span class="intro">关于球状闪电的科幻探索...</span>
        </li>
      </ul>
    </body></html>
    """
    // 用 CSS 后代选择(空格), 而不是 @ 链 (@ 是属性提取符)
    let css = CSSSelectorEngine()
    let books = try css.selectList(rule: "ul.search-list li.book-item", source: mockHTML, baseUrl: "https://x.com")
    print("  搜出 \(books.count) 个节点")
    assertEq(books.count, 2, "stub 节点数 = 2")
    for b in books {
        let title = try css.selectString(rule: "a.title@text", source: b, baseUrl: "https://x.com") ?? ""
        let author = try css.selectString(rule: "span.author@text", source: b, baseUrl: nil) ?? ""
        let url = try css.selectString(rule: "a.title@href", source: b, baseUrl: "https://x.com") ?? ""
        print("    📖 \(title) / \(author) → \(url)")
        assertEq(url.hasPrefix("https://x.com/book/"), true, "abs url")
    }
    print("✅ Search stub OK")
}

func smokeAll() async throws {
    try await testCSS()
    try await testXPath()
    try await testJSONPath()
    try await testJS()
    try await testDispatcher()
    try testURLTemplate()
    try testGBKEncoding()
    try await testLegadoSpecial()
    try await searchStub()
    print("\n🎉 所有冒烟测试通过 (无网络)")
    print("    手动跑: swift run BookSourceCLI fetch https://www.gutenberg.org/  ← 真实抓页面验证编码探测")
}

// MARK: - Debug CSS selector against URL

func debugCss(url: String, selector: String) async throws {
    let resp = try await HTTPFetcher.shared.fetch(urlString: url)
    print("html.len = \(resp.bodyText.count) chars, encoding=\(resp.detectedEncoding)")
    let css = CSSSelectorEngine()
    let nodes = (try? css.selectList(rule: selector, source: resp.bodyText, baseUrl: url)) ?? []
    print("selector \"\(selector)\" → \(nodes.count) nodes")
    if let f = nodes.first { print("first 200 chars: \(String(f.prefix(200)))") }
    // 试些 fallback
    for s in [".book_list2", ".book_list", "li a", "a", ".book_list2 a"] {
        let n = (try? css.selectList(rule: s, source: resp.bodyText, baseUrl: url)) ?? []
        print("  \(s) → \(n.count)")
    }
}

// MARK: - Debug toc fetch

func debugToc(sourceName: String, bookUrl: String) async throws {
    print("=== Debug toc: \(sourceName) / \(bookUrl) ===\n")
    let url = URL(string: "http://localhost:3000/api/sources")!
    var req = URLRequest(url: url)
    req.setValue("ios", forHTTPHeaderField: "X-Platform")
    req.setValue("cli-debug", forHTTPHeaderField: "X-Device-Id")
    let (data, _) = try await URLSession.shared.data(for: req)
    let raw = try JSONSerialization.jsonObject(with: data)
    var rawArr: [Any] = []
    if let dict = raw as? [String: Any], let arr = dict["sources"] as? [Any] { rawArr = arr }
    else if let arr = raw as? [Any] { rawArr = arr }
    var source: BookSource? = nil
    for item in rawArr {
        guard let dict = item as? [String: Any] else { continue }
        let d = try JSONSerialization.data(withJSONObject: dict)
        let bs = try JSONDecoder().decode(BookSource.self, from: d)
        if bs.bookSourceName == sourceName { source = bs; break }
    }
    guard let s = source else { print("找不到源"); return }
    print("source URL: \(s.bookSourceUrl)")
    print("ruleToc.chapterList: \(s.ruleToc?.chapterList ?? "(nil)")")
    print("ruleToc.chapterName: \(s.ruleToc?.chapterName ?? "(nil)")")
    print("ruleToc.chapterUrl: \(s.ruleToc?.chapterUrl ?? "(nil)")")
    print()

    let info = BookInfo(bookUrl: bookUrl, name: "test", author: "",
                         coverUrl: nil, tocUrl: bookUrl)
    let toc = try await BookSourceEngine.shared.fetchToc(of: info, in: s)
    print("toc.count = \(toc.count)")
    for c in toc.prefix(5) {
        print("  [\(c.chapterIndex)] \(c.title) → \(c.chapterUrl ?? "")")
    }
}

// MARK: - Debug single source from local JSON (避后端依赖)

func debugSourceFromFile(path: String, nameSub: String, key: String) async throws {
    print("=== Debug from file ===")
    print("文件: \(path)")
    print("源名子串: \(nameSub)")
    print("关键字: \(key)\n")
    guard !path.isEmpty, !nameSub.isEmpty else {
        print("用法: debug-file <jsonpath> <name 子串> [<keyword>]"); return
    }
    let sources = try loadSourcesFromLegadoJson(path: path)
    guard let s = sources.first(where: { $0.bookSourceName.contains(nameSub) }) else {
        print("❌ 源没找到 (子串=\(nameSub))"); return
    }
    print("源 URL: \(s.bookSourceUrl)")
    print("searchUrl 模板:\n\(s.searchUrl ?? "(nil)")")
    print()
    print("ruleSearch.bookList: \(s.ruleSearch?.bookList ?? "(nil)")")
    print("ruleSearch.name: \(s.ruleSearch?.name ?? "(nil)")")
    print("ruleSearch.bookUrl: \(s.ruleSearch?.bookUrl ?? "(nil)")")
    print()

    let dbgEngine = JSEngine()
    let rendered = await URLTemplate.renderAsync(s.searchUrl ?? "",
        bookSource: s, jsEngine: dbgEngine,
        baseURL: s.bookSourceUrl, key: key, page: 1)
    print("渲染后 URL: \(rendered.url)")
    print("方法: \(rendered.method), body bytes: \(rendered.body?.count ?? 0)")
    if let b = rendered.body, let str = String(data: b, encoding: .utf8) {
        print("body: \(String(str.prefix(160)))")
    }
    print()

    guard !rendered.url.isEmpty else {
        print("❌ URL 渲染为空, 不能 fetch")
        return
    }
    let resp: HTTPResponse
    do {
        resp = try await HTTPFetcher.shared.fetch(
            urlString: rendered.url,
            method: rendered.method,
            body: rendered.body,
            headers: s.parseHeaders().merging(rendered.headers, uniquingKeysWith: { _, b in b }),
            sourceKey: s.bookSourceUrl)
    } catch {
        print("❌ HTTP 失败: \(error)"); return
    }
    let body = resp.bodyText
    print("HTTP 长度: \(body.count) bytes,  encoding=\(resp.detectedEncoding)")
    print("响应前 240: \(String(body.prefix(240)).replacingOccurrences(of: "\n", with: " "))")
    print()

    let dispatcher = SelectorDispatcher(js: JSEngine())
    let listRule = s.ruleSearch?.bookList ?? ""
    print("listSelector: \(listRule)")
    let nodes = try await dispatcher.selectList(rule: listRule, source: body, baseUrl: rendered.url)
    print("nodes = \(nodes.count)")
    if let f = nodes.first { print("first node 200: \(String(f.prefix(200)).replacingOccurrences(of: "\n", with: " "))") }
    print()

    if let firstNode = nodes.first {
        let r = s.ruleSearch
        print("--- 抽字段 (节点[0]) ---")
        for (label, rule) in [
            ("name", r?.name), ("author", r?.author), ("kind", r?.kind),
            ("bookUrl", r?.bookUrl), ("coverUrl", r?.coverUrl), ("intro", r?.intro),
        ] {
            guard let rule, !rule.isEmpty else { print("  \(label): (no rule)"); continue }
            let v = try? await dispatcher.selectString(rule: rule, source: firstNode, baseUrl: rendered.url)
            print("  \(label) [\(String(rule.prefix(50)))]: \((v?.prefix(80)).map(String.init) ?? "(nil)")")
        }
    }
}

// MARK: - 端到端实战 (search → info → toc → content)

/// 万象书屋: 跟 realDeep 一样的端到端测试, 但 sources 从本地 legado JSON 文件读.
/// 用户拿外部 JSON 源单时不必导入 backend 就能跑.
func realDeepFromFile(path: String, key: String, sourceFilter: String?) async throws {
    print("=== 端到端 (from file: \(path)) ===")
    print("关键字: \(key)\n源过滤: \(sourceFilter ?? "(all)")\n")
    var sources = try loadSourcesFromLegadoJson(path: path)
    if let f = sourceFilter, !f.isEmpty {
        sources = sources.filter { $0.bookSourceName.contains(f) }
    }
    sources = sources.filter { !$0.bookSourceUrl.isEmpty && !$0.bookSourceName.isEmpty }
    print("待测 \(sources.count) 源\n")
    await runRealDeep(sources: sources, key: key)
}

func realDeep(key: String, sourceFilter: String?) async throws {
    print("=== 端到端 (search → info → toc → 第 1 章正文) ===")
    print("关键字: \(key)\n源过滤: \(sourceFilter ?? "(all)")\n")

    let url = URL(string: "http://localhost:3000/api/sources")!
    var req = URLRequest(url: url)
    req.setValue("ios", forHTTPHeaderField: "X-Platform")
    req.setValue("cli-deep", forHTTPHeaderField: "X-Device-Id")
    let (data, _) = try await URLSession.shared.data(for: req)
    let raw = try JSONSerialization.jsonObject(with: data)
    var rawArr: [Any] = []
    if let dict = raw as? [String: Any], let arr = dict["sources"] as? [Any] { rawArr = arr }
    else if let arr = raw as? [Any] { rawArr = arr }

    var sources: [BookSource] = []
    for item in rawArr {
        guard let dict = item as? [String: Any] else { continue }
        let d = try JSONSerialization.data(withJSONObject: dict)
        let bs = try JSONDecoder().decode(BookSource.self, from: d)
        if bs.bookSourceUrl.isEmpty || bs.bookSourceName.isEmpty { continue }
        if let f = sourceFilter, !bs.bookSourceName.contains(f) { continue }
        sources.append(bs)
    }
    print("待测 \(sources.count) 源\n")
    await runRealDeep(sources: sources, key: key)
}

/// 端到端跑测的共用逻辑, 让 realDeep / realDeepFromFile 复用.
func runRealDeep(sources: [BookSource], key: String) async {
    let timeoutSec: TimeInterval = TimeInterval(Int(ProcessInfo.processInfo.environment["WX_TIMEOUT"] ?? "20") ?? 20)
    let engine = await BookSourceEngine.shared

    var nSearch = 0, nInfo = 0, nToc = 0, nContent = 0
    var details: [String] = []

    for s in sources {
        let label = s.bookSourceName.padding(toLength: 28, withPad: " ", startingAt: 0)
        do {
            let books = try await withTimeout(seconds: timeoutSec) {
                try await engine.search(in: s, key: key)
            }
            guard let firstBook = books.first else {
                details.append("\(label) 🔇 search 0 hit"); continue
            }
            nSearch += 1
            let info: BookInfo
            do {
                info = try await withTimeout(seconds: timeoutSec) {
                    try await engine.fetchInfo(of: firstBook, in: s)
                }
                nInfo += 1
            } catch {
                details.append("\(label) ❌ info fail (\(String(describing: error).prefix(60)))"); continue
            }
            let toc: [BookChapter]
            do {
                toc = try await withTimeout(seconds: timeoutSec) {
                    try await engine.fetchToc(of: info, in: s)
                }
                if toc.isEmpty {
                    details.append("\(label) ⚠️ toc 0 chapter"); continue
                }
                nToc += 1
            } catch {
                details.append("\(label) ❌ toc fail (\(String(describing: error).prefix(60)))"); continue
            }
            do {
                let cn = try await withTimeout(seconds: timeoutSec) {
                    try await engine.fetchContent(of: toc[0], in: s)
                }
                if cn.content.count < 100 {
                    details.append("\(label) ⚠️ content too short (\(cn.content.count) chars)"); continue
                }
                nContent += 1
                details.append("\(label) ✓ all 4 stages OK · 章节数=\(toc.count) 正文=\(cn.content.count) chars")
            } catch {
                details.append("\(label) ❌ content fail (\(String(describing: error).prefix(60)))")
            }
        } catch {
            details.append("\(label) ❌ search fail (\(String(describing: error).prefix(60)))")
        }
    }

    for d in details { print(d) }
    print("\n=== Summary ===")
    print("  search ✓:  \(nSearch) / \(sources.count)")
    print("  info   ✓:  \(nInfo)   / \(nSearch)")
    print("  toc    ✓:  \(nToc)    / \(nInfo)")
    print("  content✓: \(nContent) / \(nToc)")
}

// MARK: - Debug single source (一步步打印中间结果)

func debugSource(name: String, key: String) async throws {
    print("=== Debug: \(name) / 关键字: \(key) ===\n")

    // 1. 拉源
    let url = URL(string: "http://localhost:3000/api/sources")!
    var req = URLRequest(url: url)
    req.setValue("ios", forHTTPHeaderField: "X-Platform")
    req.setValue("cli-debug", forHTTPHeaderField: "X-Device-Id")
    let (data, _) = try await URLSession.shared.data(for: req)
    let raw = try JSONSerialization.jsonObject(with: data)
    var rawArr: [Any] = []
    if let dict = raw as? [String: Any], let arr = dict["sources"] as? [Any] {
        rawArr = arr
    } else if let arr = raw as? [Any] {
        rawArr = arr
    }

    var source: BookSource? = nil
    for item in rawArr {
        guard let dict = item as? [String: Any] else { continue }
        let d = try JSONSerialization.data(withJSONObject: dict)
        let bs = try JSONDecoder().decode(BookSource.self, from: d)
        if bs.bookSourceName == name { source = bs; break }
    }
    guard let s = source else {
        print("❌ 找不到源: \(name)"); return
    }
    print("源 URL: \(s.bookSourceUrl)")
    print("searchUrl 模板: \(s.searchUrl ?? "(nil)")")
    print("ruleSearch.bookList: \(s.ruleSearch?.bookList ?? "(nil)")")
    print("ruleSearch.name: \(s.ruleSearch?.name ?? "(nil)")")
    print("ruleSearch.bookUrl: \(s.ruleSearch?.bookUrl ?? "(nil)")")
    print()

    // 2. 渲染 URL (async — 真执行 <js>, 注入 source/cookie/host 全局)
    let dbgEngine = JSEngine()
    let rendered = await URLTemplate.renderAsync(s.searchUrl ?? "",
        bookSource: s, jsEngine: dbgEngine,
        baseURL: s.bookSourceUrl, key: key, page: 1)
    print("渲染后 URL: \(rendered.url)")
    print("方法: \(rendered.method), body: \(rendered.body?.count ?? 0) bytes")
    print()

    // 3. fetch
    let fetcher = HTTPFetcher.shared
    let resp = try await fetcher.fetch(
        urlString: rendered.url,
        method: rendered.method,
        body: rendered.body,
        headers: s.parseHeaders().merging(rendered.headers, uniquingKeysWith: { _, b in b }),
        sourceKey: s.bookSourceUrl
    )
    let body = resp.bodyText
    print("HTTP 响应长度: \(body.count) bytes")
    print("响应头 200 chars: \(String(body.prefix(200)))")
    print()

    // 4. 选 list
    let dispatcher = SelectorDispatcher(js: JSEngine())
    let listRule = s.ruleSearch?.bookList ?? ""
    print("用 listSelector: \"\(listRule)\"")
    let nodes = try await dispatcher.selectList(rule: listRule, source: body, baseUrl: rendered.url)
    print("拿到 \(nodes.count) 个 node")
    if let first = nodes.first {
        print("第 1 node: \(String(first.prefix(300)))")
    }
    print()

    // 5. 抽字段 (全部)
    if let firstNode = nodes.first {
        print("--- 抽字段 (第 1 节点全部) ---")
        let r = s.ruleSearch
        for (label, rule) in [
            ("name", r?.name), ("author", r?.author), ("kind", r?.kind),
            ("bookUrl", r?.bookUrl), ("coverUrl", r?.coverUrl), ("intro", r?.intro),
            ("lastChapter", r?.lastChapter), ("updateTime", r?.updateTime),
            ("wordCount", r?.wordCount),
        ] {
            guard let rule, !rule.isEmpty else {
                print("  \(label): (no rule)")
                continue
            }
            let v = try? await dispatcher.selectString(rule: rule, source: firstNode, baseUrl: rendered.url)
            print("  \(label) [\(String(rule.prefix(40)))]: \((v?.prefix(80)).map(String.init) ?? "(nil)")")
        }
    }
}

// MARK: - Real search (拉真后端 + 真发起搜索, 验证书源能用否)

func realSearch(key: String, sourceFilter: String?) async throws {
    print("=== 真书源搜索测试 ===")
    print("关键字: \(key)")
    print("source 过滤: \(sourceFilter ?? "(all)")")
    print()

    // 1. 拉后端 sources
    let url = URL(string: "http://localhost:3000/api/sources")!
    var req = URLRequest(url: url)
    req.setValue("ios", forHTTPHeaderField: "X-Platform")
    req.setValue("cli-test-real-search", forHTTPHeaderField: "X-Device-Id")
    let (data, _) = try await URLSession.shared.data(for: req)

    let raw = try JSONSerialization.jsonObject(with: data)
    var rawArr: [Any] = []
    if let dict = raw as? [String: Any], let arr = dict["sources"] as? [Any] {
        rawArr = arr
    } else if let arr = raw as? [Any] {
        rawArr = arr
    }
    print("[debug] raw response items: \(rawArr.count)")

    // 2. 解析 BookSource
    var sources: [BookSource] = []
    var skipped = 0
    for (idx, item) in rawArr.enumerated() {
        guard let dict = item as? [String: Any] else {
            skipped += 1
            continue
        }
        do {
            let d = try JSONSerialization.data(withJSONObject: dict)
            let bs = try JSONDecoder().decode(BookSource.self, from: d)
            if bs.bookSourceUrl.isEmpty || bs.bookSourceName.isEmpty {
                skipped += 1
                if skipped < 5 {
                    print("[debug] skip empty url/name: idx=\(idx) name=\(bs.bookSourceName) url=\(bs.bookSourceUrl)")
                }
                continue
            }
            if let f = sourceFilter, !bs.bookSourceName.contains(f) { continue }
            sources.append(bs)
        } catch {
            skipped += 1
            print("[debug] skip decode err idx=\(idx): \(error.localizedDescription)")
        }
    }
    print("拿到 \(sources.count) 个源 (skipped: \(skipped))\n")

    // 3. 并发发请求 (默认并发 8, 单源 6s 超时)
    let timeoutSec: TimeInterval = TimeInterval(Int(ProcessInfo.processInfo.environment["WX_TIMEOUT"] ?? "6") ?? 6)
    let concurrency = Int(ProcessInfo.processInfo.environment["WX_CONCURRENCY"] ?? "8") ?? 8
    print("[debug] concurrency=\(concurrency) timeout=\(Int(timeoutSec))s")
    let engine = await BookSourceEngine.shared
    var ok = 0, fail = 0, timeout = 0, parseEmpty = 0
    let dump = ProcessInfo.processInfo.environment["WX_DUMP_RESULTS"] != nil

    typealias R = (name: String, status: String)
    var lines: [R] = []

    await withTaskGroup(of: R.self) { group in
        var inflight = 0
        var iter = sources.makeIterator()

        @Sendable
        func makeTask(_ s: BookSource) -> @Sendable () async -> R {
            return {
                let label = s.bookSourceName.padding(toLength: 28, withPad: " ", startingAt: 0)
                do {
                    let result = try await withTimeout(seconds: timeoutSec) {
                        try await engine.search(in: s, key: key)
                    }
                    if result.isEmpty {
                        return (label, "⚠️ 0 hit")
                    }
                    let first = result.first!
                    var line = "✓ \(result.count) hit · \(first.name) / \(first.author)"
                    if dump {
                        for (i, b) in result.prefix(5).enumerated() {
                            line += "\n      [\(i)] \(b.name) / \(b.author)"
                        }
                    }
                    return (label, line)
                } catch is CancellationError {
                    return (label, "⏱  timeout")
                } catch {
                    let msg = String(describing: error).prefix(80)
                    return (label, "❌ \(msg)")
                }
            }
        }

        while let s = iter.next() {
            while inflight >= concurrency {
                if let r = await group.next() {
                    lines.append(r)
                    print("  \(r.name) \(r.status)")
                    inflight -= 1
                }
            }
            inflight += 1
            let task = makeTask(s)
            group.addTask { await task() }
        }
        for await r in group {
            lines.append(r)
            print("  \(r.name) \(r.status)")
        }
    }

    for r in lines {
        if r.status.hasPrefix("✓") { ok += 1 }
        else if r.status.hasPrefix("⚠️") { parseEmpty += 1 }
        else if r.status.hasPrefix("⏱") { timeout += 1 }
        else { fail += 1 }
    }

    print("\n=== Summary ===")
    print("  ✓ 有结果:    \(ok) / \(sources.count)")
    print("  ⚠️ 0 hit:    \(parseEmpty)")
    print("  ❌ 异常:      \(fail)")
    print("  ⏱  timeout:  \(timeout)")
}

// MARK: - merge-search (iOS SearchViewModel 等价快照)

/// 与 iOS `SearchViewModel` + `SearchLegadoOrdering` 一致: 多源并发 → `dedupeKey` 合并多源 (`mergedSource*`) → 分层排序.
private func relevanceTierMergeSearch(book: SearchBook, k: String) -> Int {
    if book.name == k || book.author == k { return 0 }
    if book.name.contains(k) || book.author.contains(k) { return 1 }
    return 2
}

private func sortMergedLikeIosSearchView(books: [SearchBook], key k: String, precision: Bool) -> [SearchBook] {
    let key = k.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return books }
    let indexed = books.enumerated().map { ($0.offset, $0.element) }
    var filtered = indexed
    if precision {
        filtered = indexed.filter { relevanceTierMergeSearch(book: $0.1, k: key) < 2 }
    }
    let sorted = filtered.sorted { lhs, rhs in
        let ta = relevanceTierMergeSearch(book: lhs.1, k: key)
        let tb = relevanceTierMergeSearch(book: rhs.1, k: key)
        if ta != tb { return ta < tb }
        let ca = lhs.1.distinctOriginCount
        let cb = rhs.1.distinctOriginCount
        if ca != cb { return ca > cb }
        return lhs.0 < rhs.0
    }
    return sorted.map { $0.1 }
}

func mergeSearch(key rawKey: String, precision: Bool) async throws {
    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    print("=== merge-search (iOS App 列表逻辑: dedupeKey + Legado 排序) ===")
    print("关键字: \(key)   精准搜索: \(precision ? "开" : "关")\n")

    let url = URL(string: "http://localhost:3000/api/sources")!
    var req = URLRequest(url: url)
    req.setValue("ios", forHTTPHeaderField: "X-Platform")
    req.setValue("cli-merge-search", forHTTPHeaderField: "X-Device-Id")
    let (data, _) = try await URLSession.shared.data(for: req)
    let raw = try JSONSerialization.jsonObject(with: data)
    var rawArr: [Any] = []
    if let dict = raw as? [String: Any], let arr = dict["sources"] as? [Any] {
        rawArr = arr
    } else if let arr = raw as? [Any] {
        rawArr = arr
    }
    var sources: [BookSource] = []
    for item in rawArr {
        guard let dict = item as? [String: Any] else { continue }
        guard let d = try? JSONSerialization.data(withJSONObject: dict),
              let bs = try? JSONDecoder().decode(BookSource.self, from: d),
              !bs.bookSourceUrl.isEmpty, !bs.bookSourceName.isEmpty else { continue }
        sources.append(bs)
    }
    print("书源数: \(sources.count) (X-Platform: ios)\n")

    let engine = await BookSourceEngine.shared
    var merged: [SearchBook] = []
    var dedupeRowIndex: [String: Int] = [:]
    let stream = await engine.searchAll(in: sources, key: key)
    for await (_, result) in stream {
        switch result {
        case .success(let books):
            for b in books {
                if precision && relevanceTierMergeSearch(book: b, k: key) >= 2 { continue }
                let dk = b.androidStrictMergeKey
                if let idx = dedupeRowIndex[dk] {
                    var row = merged[idx]
                    var seen = Set<String>([row.origin])
                    seen.formUnion(row.mergedSourceURLs)
                    if !seen.contains(b.origin) {
                        row.mergedSourceURLs.append(b.origin)
                        row.mergedSourceNames.append(b.originName)
                    }
                    let rowIntroEmpty = row.intro.map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    } ?? true
                    if rowIntroEmpty,
                       let bi = b.intro?.trimmingCharacters(in: .whitespacesAndNewlines), !bi.isEmpty {
                        row.intro = b.intro
                    }
                    if (row.coverUrl?.isEmpty ?? true), let c = b.coverUrl, !c.isEmpty { row.coverUrl = c }
                    if (row.lastChapter?.isEmpty ?? true), let l = b.lastChapter, !l.isEmpty {
                        row.lastChapter = l
                    }
                    merged[idx] = row
                } else {
                    var first = b
                    first.mergedSourceURLs = []
                    first.mergedSourceNames = []
                    dedupeRowIndex[dk] = merged.count
                    merged.append(first)
                }
            }
        case .failure(let err):
            print("[源失败] \(err.localizedDescription)")
        }
    }
    let sorted = sortMergedLikeIosSearchView(books: merged, key: key, precision: precision)
    print("合并后 \(sorted.count) 条 (dedupeKey 多源合并, 与 iOS SearchViewModel 一致)\n")
    print("--- 前 45 条 (书名 / 作者 | 全部源名) ---")
    for (i, b) in sorted.prefix(45).enumerated() {
        let idx = i + 1
        let n = b.distinctOriginCount
        let allNames = ([b.originName] + b.mergedSourceNames)
            .map { $0.replacingOccurrences(of: "\n", with: " ").prefix(20) }
            .joined(separator: ", ")
        let line = "\(idx). \(b.name) / \(b.author)  |  ×\(n)  [\(allNames)]"
        print(line)
    }
    // 万象书屋: 如果用户搜某关键词时关心特定源 (例如 "为什么 iOS 没显示速读谷?"),
    // 单独打印每个源命中的全部书 (按"主源"或"合并源"维度) 帮助排查.
    let interestingSources = ["速读谷", "QQ浏览器柳树", "🍅番茄", "番茄"]
    for needle in interestingSources {
        let lines = sorted.enumerated().compactMap { (i, b) -> String? in
            let allNames = [b.originName] + b.mergedSourceNames
            guard allNames.contains(where: { $0.contains(needle) }) else { return nil }
            let role = b.originName.contains(needle) ? "主源" : "合并"
            return "  #\(i + 1)  \(role)  \(b.name) / \(b.author)"
        }
        if !lines.isEmpty {
            print("\n--- 命中 \"\(needle)\" 的行 (共 \(lines.count) 条) ---")
            lines.prefix(20).forEach { print($0) }
        }
    }
}

/// 从 legado 导出 JSON 载入书源并搜索 (不等后端)
func loadSourcesFromLegadoJson(path: String) throws -> [BookSource] {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let obj = try JSONSerialization.jsonObject(with: data)
    let rawArr: [Any]
    if let arr = obj as? [Any] {
        rawArr = arr
    } else if let dict = obj as? [String: Any], let arr = dict["sources"] as? [Any] {
        rawArr = arr
    } else {
        throw NSError(domain: "CLI", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "JSON 须为书源数组或 {\"sources\":[]}"])
    }
    var sources: [BookSource] = []
    var skipped = 0
    for (idx, item) in rawArr.enumerated() {
        guard let dict = item as? [String: Any] else {
            skipped += 1
            continue
        }
        do {
            let d = try JSONSerialization.data(withJSONObject: dict)
            let bs = try JSONDecoder().decode(BookSource.self, from: d)
            if bs.bookSourceUrl.isEmpty || bs.bookSourceName.isEmpty {
                skipped += 1
                continue
            }
            sources.append(bs)
        } catch {
            skipped += 1
            if skipped <= 5 {
                print("[debug] skip decode idx=\(idx): \(error.localizedDescription)")
            }
        }
    }
    print("[loadSourcesFromLegadoJson] parsed \(sources.count) (skipped \(skipped))\n")
    return sources
}

func realSearchFromFile(path: String, key: String, sourceFilter: String?) async throws {
    print("=== 本地 JSON                 书源搜索 ===")
    print("文件: \(path)")
    print("关键字: \(key)")
    print("源名过滤: \(sourceFilter ?? "(全部)")\n")
    var sources = try loadSourcesFromLegadoJson(path: path)
    if let f = sourceFilter, !f.isEmpty {
        sources = sources.filter { $0.bookSourceName.contains(f) }
    }
    guard !sources.isEmpty else {
        print("❌ 没有可测书源")
        return
    }
    print("待测 \(sources.count) 个源\n")

    let timeoutSec: TimeInterval = TimeInterval(Int(ProcessInfo.processInfo.environment["WX_TIMEOUT"] ?? "12") ?? 12)
    let concurrency = Int(ProcessInfo.processInfo.environment["WX_CONCURRENCY"] ?? "6") ?? 6
    let engine = await BookSourceEngine.shared
    var ok = 0, fail = 0, timeout = 0, parseEmpty = 0
    let dump = ProcessInfo.processInfo.environment["WX_DUMP_RESULTS"] != nil
    typealias R = (name: String, status: String)
    var lines: [R] = []

    await withTaskGroup(of: R.self) { group in
        var inflight = 0
        var iter = sources.makeIterator()

        @Sendable
        func makeTask(_ s: BookSource) -> @Sendable () async -> R {
            return {
                let label = s.bookSourceName.padding(toLength: 28, withPad: " ", startingAt: 0)
                do {
                    let result = try await withTimeout(seconds: timeoutSec) {
                        try await engine.search(in: s, key: key)
                    }
                    if result.isEmpty {
                        return (label, "⚠️ 0 hit")
                    }
                    let first = result.first!
                    var line = "✓ \(result.count) hit · \(first.name) / \(first.author)"
                    if dump {
                        for (i, b) in result.prefix(5).enumerated() {
                            line += "\n      [\(i)] \(b.name) / \(b.author)"
                        }
                    }
                    return (label, line)
                } catch is CancellationError {
                    return (label, "⏱  timeout")
                } catch {
                    let msg = String(describing: error).prefix(120)
                    return (label, "❌ \(msg)")
                }
            }
        }

        while let s = iter.next() {
            while inflight >= concurrency {
                if let r = await group.next() {
                    lines.append(r)
                    print("  \(r.name) \(r.status)")
                    inflight -= 1
                }
            }
            inflight += 1
            group.addTask { await makeTask(s)() }
        }
        for await r in group {
            lines.append(r)
            print("  \(r.name) \(r.status)")
        }
    }

    for r in lines {
        if r.status.hasPrefix("✓") { ok += 1 }
        else if r.status.hasPrefix("⚠️") { parseEmpty += 1 }
        else if r.status.hasPrefix("⏱") { timeout += 1 }
        else { fail += 1 }
    }
    print("\n=== Summary (file) ===")
    print("  ✓ 有结果:    \(ok) / \(sources.count)")
    print("  ⚠️ 0 hit:    \(parseEmpty)")
    print("  ❌ 异常:      \(fail)")
    print("  ⏱  timeout:  \(timeout)")
}

func withTimeout<T: Sendable>(seconds: TimeInterval, op: @escaping @Sendable () async throws -> T) async throws -> T {
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let v = try await group.next()!
        group.cancelAll()
        return v
    }
}

// MARK: - Assert helper

func assertEq<T: Equatable>(_ a: T, _ b: T, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if a == b { return }
    print("❌ FAIL [\(msg)]\n   expected: \(b)\n   got:      \(a)\n   at \(file):\(line)")
    exit(2)
}

func assertEq<T: Equatable>(_ a: T?, _ b: T?, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if a == b { return }
    print("❌ FAIL [\(msg)]\n   expected: \(String(describing: b))\n   got:      \(String(describing: a))\n   at \(file):\(line)")
    exit(2)
}

func assertContains(_ haystack: String, _ needle: String, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if haystack.contains(needle) { return }
    print("❌ FAIL [\(msg)]\n   expected to contain: \(needle)\n   got: \(haystack)\n   at \(file):\(line)")
    exit(2)
}
