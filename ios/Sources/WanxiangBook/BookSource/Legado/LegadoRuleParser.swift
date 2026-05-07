//
//  LegadoRuleParser.swift
//  万象书屋 iOS · legado 规则字符串切分
//
//  对应 Android RuleAnalyzer.splitRule + AnalyzeRule.splitSourceRule
//
//  关键: `&&` `||` `%%` 在 [...] 和 (...) 平衡组里要忽略, 否则
//   ".item:nth-child(2)" 的 ":2" 会被当成正则.
//

import Foundation

public enum LegadoRuleParser {

    /// 顶层入口: 一段 ruleStr → [SourceRule]
    /// 拆 && / || / %%, 但 [...] (...) 内的不拆.
    /// 切完后每段:
    ///   - 推断 mode (prefix / format hint)
    ///   - 切 ##regex##replace[##]
    ///   - 标占位符 (Mode 升级)
    public static func split(_ ruleStr: String) -> [LegadoSourceRule] {
        guard !ruleStr.isEmpty else { return [] }
        let chunks = splitTop(ruleStr, separators: ["&&", "||"])
        return chunks.map { parseSingle(String($0)) }
    }

    // MARK: - 单段解析

    static func parseSingle(_ s: String) -> LegadoSourceRule {
        var raw = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 万象书屋: 处理 "@@" 强制 Default
        if raw.hasPrefix("@@") {
            raw = String(raw.dropFirst(2))
        }
        // 显式前缀
        var mode: LegadoMode = .css
        var isAllInOneRegex = false
        let lower = raw.lowercased()
        if lower.hasPrefix("@css:") {
            mode = .css; raw = String(raw.dropFirst(5))
        } else if lower.hasPrefix("@xpath:") {
            mode = .xpath; raw = String(raw.dropFirst(7))
        } else if lower.hasPrefix("@json:") {
            mode = .json; raw = String(raw.dropFirst(6))
        } else if lower.hasPrefix("@js:") {
            mode = .js; raw = String(raw.dropFirst(4))
        } else if lower.hasPrefix("@regex:") {
            mode = .regex; raw = String(raw.dropFirst(7))
        } else if raw.hasPrefix(":") {
            // 万象书屋: 正则之 AllInOne, 只能在 searchList / exploreList / bookInfoInit / tocList 等列表场景使用
            // 语法 `:pattern`, 后续字段可用 `$1` `$2` 抽捕获组
            mode = .regex; raw = String(raw.dropFirst()); isAllInOneRegex = true
        } else if raw.hasPrefix("$.") || raw.hasPrefix("$[") {
            mode = .json
        } else if raw.hasPrefix("//") {
            mode = .xpath
        } else if raw.hasPrefix("/") && !raw.hasPrefix("//") {
            // 万象书屋: legado 单 / 也是 XPath (//html 的简化), 但 "/path" URL 不是
            // 经验: 含 [@ 或 @text 的 / 开头 = XPath
            if raw.contains("[@") || raw.contains("/text(") || raw.contains("/@") {
                mode = .xpath
            }
        }
        // {{...}} / @get: / <js>...</js> 占位符 → 升级 Regex 模板模式
        let hasPlaceholder = raw.contains("{{") || raw.contains("@get:") || raw.contains("<js>")

        // 切 ##regex##replace[##]
        var rule = raw
        var replaceRegex = ""
        var replacement = ""
        var replaceFirst = false
        if rule.contains("##") {
            let parts = splitChainSafe(rule, separator: "##")
            rule = String(parts[0])
            if parts.count >= 2 { replaceRegex = String(parts[1]) }
            if parts.count >= 3 { replacement = String(parts[2]) }
            if parts.count >= 4 { replaceFirst = true }
        }

        // 占位符模式且没有 select 类前缀, mode 升级 regex
        if hasPlaceholder, mode == .css {
            if rule.hasPrefix("{{") && rule.hasSuffix("}}") {
                mode = .regex
            } else if rule.hasPrefix("<js>") {
                // 万象书屋: legado bookList 经常整段就是 `<js>(function(){... return arr;})()</js>`
                // 此时 JS 直接产出列表 (而非"求值后字符串再选" 模板模式)
                // 把它当 .js 走 runJS, 返回数组时按元素散开成 list of JSON strings
                let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("<js>"), let end = trimmed.range(of: "</js>"),
                   trimmed[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    mode = .js
                    rule = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<end.lowerBound])
                } else {
                    mode = .regex
                }
            } else if rule.hasPrefix("http") || rule.hasPrefix("/") {
                // URL 模板
                mode = .regex
            }
        }

        return LegadoSourceRule(
            mode: mode,
            rule: rule.trimmingCharacters(in: .whitespacesAndNewlines),
            replaceRegex: replaceRegex,
            replacement: replacement,
            replaceFirst: replaceFirst,
            isAllInOneRegex: isAllInOneRegex,
            hasPlaceholder: hasPlaceholder
        )
    }

    // MARK: - 平衡组感知的分割

    /// 把字符串按 separators 分割, 但 [...] (...) <...> 平衡组里的不分.
    /// 字符串 "abc&&[def&&ghi]&&jkl" 分成 ["abc", "[def&&ghi]", "jkl"]
    static func splitTop(_ s: String, separators: [String]) -> [Substring] {
        var out: [Substring] = []
        var depthSquare = 0   // [ ]
        var depthRound = 0    // ( )
        var depthAngle = 0    // < > (用于 <js>)
        var inSingleQ = false
        var inDoubleQ = false

        let chars = Array(s)
        var sliceStart = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            // 引号 (legado 平衡组规则: 单/双引号内不算嵌套)
            if !inDoubleQ, c == "'" { inSingleQ.toggle(); i += 1; continue }
            if !inSingleQ, c == "\"" { inDoubleQ.toggle(); i += 1; continue }
            if inSingleQ || inDoubleQ { i += 1; continue }

            switch c {
            case "[": depthSquare += 1
            case "]": depthSquare = max(0, depthSquare - 1)
            case "(": depthRound += 1
            case ")": depthRound = max(0, depthRound - 1)
            case "<":
                // 只对 <js> 等明显的 tag 计深度, 避免与 < 比较运算符冲突
                let rest = chars[i...]
                if rest.starts(with: "<js>") || rest.starts(with: "</js>") {
                    if rest.starts(with: "</js>") {
                        depthAngle = max(0, depthAngle - 1)
                        i += 5; continue
                    } else {
                        depthAngle += 1
                        i += 4; continue
                    }
                }
            default: break
            }

            // 仅顶层 (所有 depth 都 0) 才 try 切
            var matchedSep = false
            if depthSquare == 0, depthRound == 0, depthAngle == 0 {
                for sep in separators {
                    let sepChars = Array(sep)
                    if i + sepChars.count <= chars.count,
                       Array(chars[i..<(i + sepChars.count)]) == sepChars {
                        let segment = String(chars[sliceStart..<i])
                        out.append(Substring(segment))
                        sliceStart = i + sepChars.count
                        i += sepChars.count
                        matchedSep = true
                        break
                    }
                }
            }
            if !matchedSep { i += 1 }
        }
        // 最后一段
        let last = String(chars[sliceStart..<chars.count])
        if !last.isEmpty || !out.isEmpty {
            out.append(Substring(last))
        }
        return out
    }

    /// 安全切 ##: 不切 [...] (...) 内的 ##
    static func splitChainSafe(_ s: String, separator: String) -> [Substring] {
        return splitTop(s, separators: [separator])
    }
}
