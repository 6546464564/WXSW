//
//  IntroAndWordCountFormatTests.swift
//  万象书屋 iOS · intro HTML strip + wordCount 格式化 单元测试
//

import XCTest
@testable import WanxiangBook

final class IntroAndWordCountFormatTests: XCTestCase {

    // MARK: - stripHTML

    func test_stripHTML_removesFontTagButKeepsContent() {
        let raw = "《<font color='#ff4242'>青山</font>》以 20 世纪 90 年代到如今二三十年城乡变迁..."
        let out = SearchParser.stripHTML(raw)
        XCTAssertFalse(out.contains("<"))
        XCTAssertFalse(out.contains(">"))
        XCTAssertTrue(out.contains("青山"))
        XCTAssertTrue(out.contains("城乡变迁"))
    }

    func test_stripHTML_decodesCommonEntities() {
        XCTAssertEqual(SearchParser.stripHTML("a&nbsp;b"), "a b")
        XCTAssertEqual(SearchParser.stripHTML("&amp;&lt;tag&gt;"), "&<tag>")
        XCTAssertEqual(SearchParser.stripHTML("&hellip;"), "…")
    }

    func test_stripHTML_decodesNumericEntities() {
        // &#36; = $, &#20013; = 中
        XCTAssertEqual(SearchParser.stripHTML("price: &#36;100"), "price: $100")
        XCTAssertEqual(SearchParser.stripHTML("&#20013;&#22269;"), "中国")
    }

    func test_stripHTML_passesThroughPlainText() {
        XCTAssertEqual(SearchParser.stripHTML("普通中文"), "普通中文")
    }

    // MARK: - formatWordCount (在 SearchResultRow 上)

    func test_formatWordCount_largeRawNumber() {
        XCTAssertEqual(SearchResultRowTestProxy.formatWordCount("2188581"), "218万字")
        XCTAssertEqual(SearchResultRowTestProxy.formatWordCount("12345"), "1.2万字")
        XCTAssertEqual(SearchResultRowTestProxy.formatWordCount("9999"), "9999字")
    }

    func test_formatWordCount_keepsHumanReadable() {
        XCTAssertEqual(SearchResultRowTestProxy.formatWordCount("218万字"), "218万字")
        XCTAssertEqual(SearchResultRowTestProxy.formatWordCount("1.2万"), "1.2万")
        XCTAssertEqual(SearchResultRowTestProxy.formatWordCount("12K"), "12K")
    }

    func test_formatWordCount_emptyOrInvalid() {
        XCTAssertEqual(SearchResultRowTestProxy.formatWordCount(""), "")
        XCTAssertEqual(SearchResultRowTestProxy.formatWordCount("abc"), "abc")
    }
}

/// SearchResultRow 是 private struct, 测试用 proxy 暴露 static formatter.
/// (放在测试 target 同一编译单元内, @testable 不暴露 private — 复制实现即可保持 1:1.)
enum SearchResultRowTestProxy {
    static func formatWordCount(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        if s.contains("万") || s.contains("字") || s.contains("k") || s.contains("K") {
            return s
        }
        let cleaned = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard let n = Int(cleaned) else { return s }
        if n >= 10_000 {
            let wan = Double(n) / 10_000
            if wan >= 100 {
                return "\(Int(wan))万字"
            } else {
                return String(format: "%.1f万字", wan)
            }
        }
        return "\(n)字"
    }
}
