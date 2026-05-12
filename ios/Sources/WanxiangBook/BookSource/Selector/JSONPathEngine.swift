//
//  JSONPathEngine.swift
//  万象书屋 iOS · 简易 JSONPath 实现
//
//  legado 书源用的 JSONPath 子集 (90% case):
//   $.book                          根下取 book
//   $.book.list                     嵌套字段
//   $.book.list[0]                  数组索引
//   $.book.list[*].title            通配 + 取每个的 title
//   $..title                        递归找所有 title
//   $.book.list[?(@.id==123)]       谓词 (略复杂, M1 不实现, 真要用切到 @js)
//
//  实现策略:
//   - JSONSerialization 解析成 [String: Any] / [Any]
//   - 用简单 token 解释器走表达式
//   - 不引第三方库 (legado 是 Java jayway/JsonPath, iOS 没有等价 Swift 包)
//

import Foundation

public struct JSONPathEngine: SelectorEngine {

    public init() {}

    public func selectList(rule: String, source: String, baseUrl: String?) throws -> [String] {
        guard let data = source.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            throw SelectorError.parseFailed("源不是合法 JSON")
        }
        let results = evaluate(rule: rule, on: root)
        // 万象书屋 (P0 fix): selectList 语义 = 给后续 extractBook 一个个调.
        // 若 evaluate 返回 1 个 array, 应展开成 N 个元素分别 stringify.
        // (legado `bookList` 规则就是要拿 list, 上层 SearchParser 期望 [item, item, ...])
        if results.count == 1, let arr = results[0] as? [Any] {
            return arr.map { stringify($0) }
        }
        return results.map { stringify($0) }
    }

    public func selectString(rule: String, source: String, baseUrl: String?) throws -> String? {
        guard let data = source.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            throw SelectorError.parseFailed("源不是合法 JSON")
        }
        let results = evaluate(rule: rule, on: root)
        return results.first.map { stringify($0) }
    }

    // MARK: - JSONPath 解释器

    /// 主入口
    private func evaluate(rule: String, on root: Any) -> [Any] {
        var path = rule.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("$") { path.removeFirst() }
        // 万象书屋 (2026-05-12 fix): legado 部分源把根数组写成 `$.[*]` 而不是标准 `$[*]`
        //   米读小说 / 长佩文学等 chapterList 用 `$.[*]` 取根数组每项. 之前 walk 在 `.[*]`
        //   里走 `.field` 分支, readToken 拿空 token ⇒ 返回空集 ⇒ toc 0.
        if path.hasPrefix(".[") {
            path.removeFirst()
        }
        return walk([root], path: path)
    }

    /// 递归走路径. path 形如:
    ///   .book.list[0].title
    ///   .list[*].title
    ///   ..title  (descendant)
    private func walk(_ inputs: [Any], path: String) -> [Any] {
        if path.isEmpty { return inputs }
        var p = path

        // ..title  → 递归找所有名为 title 的字段
        if p.hasPrefix("..") {
            p.removeFirst(2)
            // 取下一段 token
            let (token, rest) = readToken(p)
            var out: [Any] = []
            for v in inputs {
                out.append(contentsOf: descendant(v, key: token))
            }
            return walk(out, path: rest)
        }

        // 万象书屋 (M2.8 fix bug): `.*` 通配符 — 展开所有元素 (array) / 所有 values (dict).
        // 爱奇艺漫画等源 chapterList = `$.data.episodes.*`. 之前不支持 `.*` ⇒ readToken
        // 把 `*` 当字段名查 dict["*"] ⇒ 没命中 ⇒ chapterList 0 ⇒ toc 0.
        if p.hasPrefix(".*") {
            p.removeFirst(2)
            var out: [Any] = []
            for v in inputs {
                if let arr = v as? [Any] { out.append(contentsOf: arr) }
                else if let dict = v as? [String: Any] { out.append(contentsOf: Array(dict.values)) }
            }
            return walk(out, path: p)
        }

        // .field
        if p.hasPrefix(".") {
            p.removeFirst()
            let (token, rest) = readToken(p)
            var out: [Any] = []
            for v in inputs {
                if let dict = v as? [String: Any], let next = dict[token] {
                    out.append(next)
                }
            }
            return walk(out, path: rest)
        }

        // [n] / [*] / [start:end] / [start:end:step] / [a,b,c] (multi index)
        if p.hasPrefix("[") {
            guard let end = p.firstIndex(of: "]") else { return [] }
            let inner = String(p[p.index(after: p.startIndex)..<end]).trimmingCharacters(in: .whitespaces)
            let rest = String(p[p.index(after: end)...])
            var out: [Any] = []
            for v in inputs {
                guard let arr = v as? [Any] else { continue }
                out.append(contentsOf: arrayBracketSelect(arr, inner: inner))
            }
            return walk(out, path: rest)
        }

        return inputs
    }

    /// JsonPath `[...]` 内部支持: `*` / `N` / `-N` / `start:end[:step]` / `a,b,c`
    private func arrayBracketSelect(_ arr: [Any], inner: String) -> [Any] {
        let len = arr.count
        if inner == "*" { return arr }
        // 切片 (含 `:`)
        if inner.contains(":") {
            let parts = inner.split(separator: ":", omittingEmptySubsequences: false).map { String($0) }
            let startStr = parts.count > 0 ? parts[0].trimmingCharacters(in: .whitespaces) : ""
            let endStr   = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            let stepStr  = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            // start: 默认 0  (负数 = len + n)
            var start = startStr.isEmpty ? 0 : (Int(startStr) ?? 0)
            // end: 默认 len  (Python 风格 半开区间, 负数 = len + n)
            var end = endStr.isEmpty ? len : (Int(endStr) ?? len)
            let step = stepStr.isEmpty ? 1 : (Int(stepStr) ?? 1)
            if start < 0 { start = max(0, len + start) }
            if end < 0 { end = max(0, len + end) }
            start = min(max(0, start), len)
            end = min(max(0, end), len)
            var out: [Any] = []
            if step > 0, start < end {
                var i = start
                while i < end { out.append(arr[i]); i += step }
            } else if step < 0, start > end {
                var i = start - 1
                while i >= end { if i < len { out.append(arr[i]) }; i += step }
            }
            return out
        }
        // 多索引 `a,b,c`
        if inner.contains(",") {
            var out: [Any] = []
            for tok in inner.split(separator: ",") {
                if let n = Int(tok.trimmingCharacters(in: .whitespaces)) {
                    let real = n >= 0 ? n : len + n
                    if real >= 0, real < len { out.append(arr[real]) }
                }
            }
            return out
        }
        // 单 index
        if let idx = Int(inner) {
            let real = idx >= 0 ? idx : len + idx
            if real >= 0, real < len { return [arr[real]] }
        }
        return []
    }

    /// 读到下个 . [ 之前的 token
    private func readToken(_ s: String) -> (String, String) {
        var token = ""
        var rest = s
        while let c = rest.first, c != ".", c != "[" {
            token.append(c)
            rest.removeFirst()
        }
        return (token, rest)
    }

    /// 递归找 key
    private func descendant(_ v: Any, key: String) -> [Any] {
        var out: [Any] = []
        if let dict = v as? [String: Any] {
            for (k, val) in dict {
                if k == key { out.append(val) }
                out.append(contentsOf: descendant(val, key: key))
            }
        } else if let arr = v as? [Any] {
            for item in arr { out.append(contentsOf: descendant(item, key: key)) }
        }
        return out
    }

    /// 把 Any 序列化成字符串.
    /// - String → 直接
    /// - Number/Bool → "\(v)"
    /// - Dict/Array → JSON serialize
    private func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber {
            // bool 装成 NSNumber(false) 时 boolValue 仍 false
            return "\(n)"
        }
        // 万象书屋 (M2.8 fix bug): JSONSerialization.data(withJSONObject:) 对 String/Number/Bool
        // 等 fragment 类型直接 throw NSException (`Invalid top-level type in JSON write`),
        // 不是 Swift try/catch 能拦的 — **直接 crash 整个 App**.
        // 实测 1109 源单某些源 search 时拿到这种 fragment 触发. 必须先用
        // isValidJSONObject 守卫 (它只放行 dict / array 顶层).
        if JSONSerialization.isValidJSONObject(v),
           let data = try? JSONSerialization.data(withJSONObject: v),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        // fragment / 不可序列化对象 → fallback Swift 描述
        return String(describing: v)
    }
}
