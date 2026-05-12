//
//  LegadoMustacheTests.swift
//  万象书屋 iOS · LegadoRuleEngine 模板替换回归测试
//
//  Bug 复现: 用户在搜索 "青山" 时, "晴天小说 5.0" 源返回的最新章节字段渲染成
//   "{顶点} {}". 根因是单括号 `\{(\$\.[^}]+)\}` regex 把双括号 `{{$.source}}` 里的
//   内层 `{$.source}` 误当成单括号 mustache 匹配, 替换后只剥掉内层引号, 外层 `{` `}`
//   留下来, 加上内层值为空时形成 `{}`.
//
//  Fix: 单括号 regex 加 negative lookbehind/lookahead 防止匹配双括号内层.
//

import XCTest
@testable import WanxiangBook

final class LegadoMustacheTests: XCTestCase {

    /// 双括号 `{{$.source}} {{$.last_chapter_title}}` 在 JSON 源上应该完整渲染,
    /// 不应保留任何 `{` / `}`.
    func test_doubleBraceMustache_doesNotLeakSingleBraceArtifacts() async {
        let json = #"""
        {"source": "顶点", "last_chapter_title": "第654章 掏心"}
        """#
        let template = "{{$.source}} {{$.last_chapter_title}}"
        let out = await LegadoRuleEngine.shared.selectString(rule: template, source: json) ?? ""
        XCTAssertEqual(out, "顶点 第654章 掏心",
                       "双括号模板必须完整去掉所有 {{ }} 包裹, 不残留单括号")
    }

    /// 退化场景: `{{$.x}}` 里的 x 在 JSON 中不存在 → 应该替换为空, 而不是留 `{}`.
    func test_doubleBraceMustache_emptyValue_leavesNoBrace() async {
        let json = #"{"source": "顶点"}"#
        let template = "{{$.source}} {{$.last_chapter_title}}"
        let out = await LegadoRuleEngine.shared.selectString(rule: template, source: json) ?? ""
        XCTAssertEqual(out, "顶点 ",
                       "缺失字段应该静默成空字符串, 不留 `{}` 残骸")
    }

    // 注: 单括号 `{$.field}` 走的是 `expandTemplate` 内部路径, 它只在 rule 模板被
    // applyRule 调用时才展开 (例如 URL 拼接). 顶层 selectString 调用时引擎会按
    // "/" 前缀分发到 XPath, 整体语义不一样, 无法直接构造一个干净的 unit test —
    // regression 由 `{{$.x}}` 测试覆盖即可 (两者共享 lookbehind/lookahead fix).
}
