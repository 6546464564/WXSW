//
//  SafeRegexTests.swift
//  万象书屋 iOS · ReDoS 保护 + LRU 缓存测试
//

import XCTest
@testable import WanxiangBook

final class SafeRegexTests: XCTestCase {

    // MARK: - LRU 缓存

    func test_compile_cachesSamePattern() async {
        let r = SafeRegex.shared
        let r1 = await r.compile("hello")
        let r2 = await r.compile("hello")
        XCTAssertNotNil(r1)
        XCTAssertTrue(r1 === r2, "同 pattern 应返回同一实例 (LRU 命中)")
    }

    func test_compile_invalidPattern_returnsNil() async {
        let r = SafeRegex.shared
        // 非法的 (?z 不存在的 group reference
        let r1 = await r.compile("(?z)bad")
        XCTAssertNil(r1)
    }

    // MARK: - 短输入快速路径

    func test_replace_shortInput_works() async {
        let result = await SafeRegex.shared.replace(
            in: "hello world", pattern: "wo(\\w+)d", replacement: "Wo$1D"
        )
        XCTAssertEqual(result, "hello WorlD")
    }

    /// replaceFirst 只替换首个匹配
    func test_replace_replaceFirst_onlyFirst() async {
        let result = await SafeRegex.shared.replace(
            in: "abc abc abc", pattern: "abc", replacement: "X", replaceFirst: true
        )
        // legado 行为: replaceFirst=true → 只对 firstMatch 的局部子串替换, 返回那段替换后内容
        // (即 "abc" → "X", 而不是 "X abc abc")
        XCTAssertEqual(result, "X")
    }

    /// 全匹配模式
    func test_replace_replaceAll() async {
        let result = await SafeRegex.shared.replace(
            in: "abc abc abc", pattern: "abc", replacement: "X"
        )
        XCTAssertEqual(result, "X X X")
    }

    // MARK: - 同步 compileCached (UnsafeRegexCache)

    func test_compileCached_returnsSameInstance() {
        let r1 = SafeRegex.compileCached("\\d+")
        let r2 = SafeRegex.compileCached("\\d+")
        XCTAssertNotNil(r1)
        XCTAssertTrue(r1 === r2)
    }

    func test_compileCached_invalidPattern_nil() {
        let r = SafeRegex.compileCached("[unclosed")
        XCTAssertNil(r)
    }

    // MARK: - 长输入 timeout (基本路径)
    /// 验证长输入正常 regex 走 timeout 路径但不超时
    func test_replace_longInput_normalRegex_completes() async {
        let longText = String(repeating: "abc", count: 2000) // 6000 字
        let result = await SafeRegex.shared.replace(
            in: longText, pattern: "abc", replacement: "X"
        )
        XCTAssertEqual(result.count, 2000)
        XCTAssertTrue(result.allSatisfy { $0 == "X" })
    }
}
