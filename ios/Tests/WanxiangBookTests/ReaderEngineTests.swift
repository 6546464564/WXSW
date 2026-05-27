import XCTest
@testable import WanxiangBook

final class ReaderEngineTests: XCTestCase {

    // MARK: - URLTemplate.render (sync 版, 纯函数, 无外部依赖)

    func test_render_simpleKeySubstitution() {
        let r = URLTemplate.render(
            "https://example.com/search?q={{key}}",
            key: "斗破苍穹"
        )
        XCTAssertTrue(r.url.contains("example.com/search?q="))
        XCTAssertFalse(r.url.contains("{{key}}"))
        XCTAssertEqual(r.method, "GET")
    }

    func test_render_pageSubstitution() {
        let r = URLTemplate.render(
            "https://example.com/list?p={{page}}",
            page: 3
        )
        XCTAssertTrue(r.url.contains("p=3"))
    }

    func test_render_multipleVars() {
        let r = URLTemplate.render(
            "https://example.com/api?q={{key}}&p={{page}}&t={{type}}",
            key: "test",
            page: 2,
            vars: ["type": "novel"]
        )
        XCTAssertTrue(r.url.contains("q=test"))
        XCTAssertTrue(r.url.contains("p=2"))
        XCTAssertTrue(r.url.contains("t=novel"))
    }

    func test_render_postMethodWithBody() {
        let r = URLTemplate.render(
            "https://example.com/api,{\"method\":\"POST\",\"body\":\"q={{key}}\"}",
            key: "test"
        )
        XCTAssertEqual(r.method, "POST")
        XCTAssertNotNil(r.body)
        if let body = r.body, let bodyStr = String(data: body, encoding: .utf8) {
            XCTAssertTrue(bodyStr.contains("q=test"))
        }
    }

    func test_render_headersExtracted() {
        let r = URLTemplate.render(
            "https://example.com/api,{\"headers\":{\"X-Token\":\"abc\"}}"
        )
        XCTAssertEqual(r.headers["X-Token"], "abc")
    }

    func test_render_webViewFlag() {
        let r = URLTemplate.render(
            "https://example.com/page,{\"webView\":true}"
        )
        XCTAssertTrue(r.useWebView)
    }

    func test_render_retryOption() {
        let r = URLTemplate.render(
            "https://example.com/api,{\"retry\":3}"
        )
        XCTAssertEqual(r.retry, 3)
    }

    func test_render_jsTemplateStripped_inSyncMode() {
        let r = URLTemplate.render(
            "<js>encodeURIComponent(key)</js>https://example.com/search"
        )
        XCTAssertTrue(r.url.contains("example.com/search"),
                       "sync render 应剥掉 <js> 标签, 保留后续 URL")
    }

    func test_render_relativeURL_absolutized() {
        let r = URLTemplate.render(
            "/api/search?q={{key}}",
            baseURL: "https://example.com",
            key: "test"
        )
        XCTAssertTrue(r.url.hasPrefix("https://example.com/api/search"))
    }

    func test_render_protocolRelativeURL() {
        let r = URLTemplate.render(
            "//cdn.example.com/search",
            baseURL: "https://example.com"
        )
        XCTAssertTrue(r.url.hasPrefix("https://"))
        XCTAssertTrue(r.url.contains("cdn.example.com"))
    }

    func test_render_absoluteURL_unchanged() {
        let r = URLTemplate.render(
            "https://other.com/page",
            baseURL: "https://example.com"
        )
        XCTAssertTrue(r.url.hasPrefix("https://other.com/page"))
    }

    func test_render_singleQuoteJSONNormalized() {
        let r = URLTemplate.render(
            "https://example.com/api,{'method':'POST','body':'q={{key}}'}"
        )
        XCTAssertEqual(r.method, "POST")
    }

    func test_render_unquotedKeyJSONNormalized() {
        let r = URLTemplate.render(
            "https://example.com/api,{method:'POST'}"
        )
        XCTAssertEqual(r.method, "POST")
    }

    func test_render_charsetOption() {
        let r = URLTemplate.render(
            "https://example.com/api,{\"charset\":\"gbk\"}"
        )
        XCTAssertEqual(r.charset, "gbk")
    }

    func test_render_emptyTemplate() {
        let r = URLTemplate.render("")
        XCTAssertTrue(r.url.isEmpty)
        XCTAssertEqual(r.method, "GET")
    }
}
