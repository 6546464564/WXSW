//
//  JsoupShim.swift
//  万象书屋 iOS · org.jsoup.Jsoup JS 桥
//
//  legado 源在 JS 内部经常调用 `org.jsoup.Jsoup.parse(html, baseUrl)`.text() / .select(...) 等.
//  Android 上 Rhino 直接暴露 Java 类, iOS JavaScriptCore 必须自己 wrap.
//
//  设计:
//   - SwiftSoup.Element / Elements 不能直接 export 给 JS (没实现 JSExport).
//   - 用一个全局 NSMapTable 把 Element 实例 stash 起来, JS 端拿到 dict {nodeId, kind}
//   - 在 JS 端定义 wrapper 类 (DocumentJS / ElementJS / ElementsJS), method 调 native bridge
//   - 跟 Android Java jsoup 1:1 接口: parse / select / text / html / attr / size / get / first
//

import Foundation
import JavaScriptCore
import SwiftSoup

/// 万象书屋: 给 JS 用的 jsoup shim
/// JS 端会看到 `org.jsoup.Jsoup` 对象 + 一组 wrapper 类
public enum JsoupShim {

    // 万象书屋: 用 NSMapTable 把 SwiftSoup Element/Elements 跟 nodeId 关联,
    // JS 端不接触原生对象, 全部通过 nodeId 调 bridge
    private static var nodes: [String: AnyObject] = [:]
    private static var nextId: Int = 0
    private static let lock = NSLock()

    private static func registerNode(_ obj: AnyObject) -> String {
        lock.lock()
        defer { lock.unlock() }
        nextId += 1
        let id = "n\(nextId)"
        nodes[id] = obj
        return id
    }

    private static func node(_ id: String) -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        return nodes[id]
    }

    /// 万象书屋: 在 ctx 上注入 org.jsoup.Jsoup + wrapper 类
    /// 必须每个 ctx (即每个 JSEngine 实例) 调用一次
    public static func install(in ctx: JSContext) {

        // === native bridge — 这些 closure 实际操作 SwiftSoup ===

        // jsoup.parse(html, baseUrl?) → {nodeId: "n1", kind: "doc"}
        let parse: @convention(block) (String, String?) -> [String: String] = { html, baseUrl in
            do {
                let doc = try LegadoHTMLParse.parseDocument(source: html, baseUrl: baseUrl ?? "")
                let id = registerNode(doc)
                return ["nodeId": id, "kind": "doc"]
            } catch {
                return ["nodeId": "", "kind": "doc"]
            }
        }
        ctx.setObject(parse, forKeyedSubscript: "__wx_jsoup_parse" as NSString)

        // node.text(nodeId) → string
        let text: @convention(block) (String) -> String = { id in
            guard let obj = node(id) else { return "" }
            if let el = obj as? Element { return (try? el.text()) ?? "" }
            if let els = obj as? Elements { return (try? els.text()) ?? "" }
            return ""
        }
        ctx.setObject(text, forKeyedSubscript: "__wx_jsoup_text" as NSString)

        // node.html(nodeId) → string (innerHtml)
        let html: @convention(block) (String) -> String = { id in
            guard let obj = node(id) else { return "" }
            if let el = obj as? Element { return (try? el.html()) ?? "" }
            if let els = obj as? Elements { return (try? els.html()) ?? "" }
            return ""
        }
        ctx.setObject(html, forKeyedSubscript: "__wx_jsoup_html" as NSString)

        // node.outerHtml(nodeId) → string
        let outer: @convention(block) (String) -> String = { id in
            guard let obj = node(id) else { return "" }
            if let el = obj as? Element { return (try? el.outerHtml()) ?? "" }
            if let els = obj as? Elements { return (try? els.outerHtml()) ?? "" }
            return ""
        }
        ctx.setObject(outer, forKeyedSubscript: "__wx_jsoup_outerHtml" as NSString)

        // node.attr(nodeId, name) → string
        // 万象书屋: legado 源很爱 attr("abs:src") / attr("abs:href") 直接拿绝对 URL
        let attr: @convention(block) (String, String) -> String = { id, name in
            guard let obj = node(id) else { return "" }
            if let el = obj as? Element {
                if name.hasPrefix("abs:") {
                    return (try? el.attr(name)) ?? ""   // SwiftSoup 支持 abs:
                }
                return (try? el.attr(name)) ?? ""
            }
            if let els = obj as? Elements {
                return (try? els.attr(name)) ?? ""
            }
            return ""
        }
        ctx.setObject(attr, forKeyedSubscript: "__wx_jsoup_attr" as NSString)

        // node.select(nodeId, selector) → {nodeId: "n2", kind: "els"}
        let select: @convention(block) (String, String) -> [String: String] = { id, selector in
            guard let obj = node(id) else { return ["nodeId": "", "kind": "els"] }
            do {
                let els: Elements
                if let el = obj as? Element { els = try el.select(selector) }
                else if let e = obj as? Elements { els = try e.select(selector) }
                else { els = Elements() }
                let nid = registerNode(els)
                return ["nodeId": nid, "kind": "els"]
            } catch {
                return ["nodeId": "", "kind": "els"]
            }
        }
        ctx.setObject(select, forKeyedSubscript: "__wx_jsoup_select" as NSString)

        // els.size(nodeId) → int
        let size: @convention(block) (String) -> Int = { id in
            guard let obj = node(id) else { return 0 }
            if let els = obj as? Elements { return els.size() }
            if obj is Element { return 1 }
            return 0
        }
        ctx.setObject(size, forKeyedSubscript: "__wx_jsoup_size" as NSString)

        // els.get(nodeId, i) → {nodeId, kind: "el"}
        let getEl: @convention(block) (String, Int) -> [String: String] = { id, i in
            guard let obj = node(id) else { return ["nodeId": "", "kind": "el"] }
            if let els = obj as? Elements, i >= 0, i < els.size() {
                let el = els.get(i)
                let nid = registerNode(el)
                return ["nodeId": nid, "kind": "el"]
            }
            if let el = obj as? Element, i == 0 {
                let nid = registerNode(el)
                return ["nodeId": nid, "kind": "el"]
            }
            return ["nodeId": "", "kind": "el"]
        }
        ctx.setObject(getEl, forKeyedSubscript: "__wx_jsoup_get" as NSString)

        // els.first(nodeId) → {nodeId, kind: "el"}
        let first: @convention(block) (String) -> [String: String] = { id in
            guard let obj = node(id) else { return ["nodeId": "", "kind": "el"] }
            if let els = obj as? Elements, let el = els.first() {
                return ["nodeId": registerNode(el), "kind": "el"]
            }
            if let el = obj as? Element {
                return ["nodeId": registerNode(el), "kind": "el"]
            }
            return ["nodeId": "", "kind": "el"]
        }
        ctx.setObject(first, forKeyedSubscript: "__wx_jsoup_first" as NSString)

        let last: @convention(block) (String) -> [String: String] = { id in
            guard let obj = node(id) else { return ["nodeId": "", "kind": "el"] }
            if let els = obj as? Elements, let el = els.last() {
                return ["nodeId": registerNode(el), "kind": "el"]
            }
            return ["nodeId": "", "kind": "el"]
        }
        ctx.setObject(last, forKeyedSubscript: "__wx_jsoup_last" as NSString)

        // === JS 端 wrapper class ===
        // 万象书屋: 在 JS 端定义 ElementJS / ElementsJS 类, 方法 → native bridge
        ctx.evaluateScript("""
        (function() {
          function wrap(node) {
            if (!node || !node.nodeId) return null;
            return {
              _id: node.nodeId,
              _kind: node.kind,
              text: function() { return __wx_jsoup_text(this._id); },
              html: function() { return __wx_jsoup_html(this._id); },
              outerHtml: function() { return __wx_jsoup_outerHtml(this._id); },
              attr: function(name) { return __wx_jsoup_attr(this._id, name); },
              select: function(sel) { return wrap(__wx_jsoup_select(this._id, sel)); },
              size: function() { return __wx_jsoup_size(this._id); },
              get: function(i) { return wrap(__wx_jsoup_get(this._id, i)); },
              first: function() { return wrap(__wx_jsoup_first(this._id)); },
              last: function() { return wrap(__wx_jsoup_last(this._id)); },
              eq: function(i) { return wrap(__wx_jsoup_get(this._id, i)); },
              // 万象书屋 (M2.8 fix bug): Java Elements.isEmpty() / hasText() / parent()
              // 等常用 method 补齐 — 禁忌书屋等用 isEmpty() 判 select 结果空, 之前没暴露
              // 直接 TypeError ⇒ content 0 chars.
              isEmpty: function() { return __wx_jsoup_size(this._id) === 0; },
              hasText: function() { return (__wx_jsoup_text(this._id) || '').length > 0; },
              // alias
              ownText: function() { return __wx_jsoup_text(this._id); },
              data: function() { return __wx_jsoup_text(this._id); },
              // forEach for els
              forEach: function(fn) {
                var n = __wx_jsoup_size(this._id);
                for (var i = 0; i < n; i++) {
                  var el = wrap(__wx_jsoup_get(this._id, i));
                  if (el) fn(el, i);
                }
              },
              // 万象书屋 (M2.8 fix bug): legado 大量源 chapterList JS 用 `result.toArray()`
              // 把 jsoup Elements 转 Array. 不暴露这方法 ⇒ TypeError ⇒ JS 整段 fail.
              // 兼容 Java/Rhino: Elements.toArray() 返 Element[].
              toArray: function() {
                var n = __wx_jsoup_size(this._id);
                var arr = [];
                for (var i = 0; i < n; i++) {
                  var el = wrap(__wx_jsoup_get(this._id, i));
                  if (el) arr.push(el);
                }
                return arr;
              },
              // Java Iterator 风格: iterator() 返带 hasNext/next 的对象 (一些源用)
              iterator: function() {
                var idx = 0;
                var that = this;
                return {
                  hasNext: function() { return idx < __wx_jsoup_size(that._id); },
                  next: function() { return wrap(__wx_jsoup_get(that._id, idx++)); }
                };
              },
              // Array-like .length (一些源直接 result.length)
              get length() { return __wx_jsoup_size(this._id); },
            };
          }
          var Jsoup = {
            parse: function(html, baseUrl) { return wrap(__wx_jsoup_parse(String(html||''), baseUrl||'')); },
          };
          var org = { jsoup: { Jsoup: Jsoup, nodes: {} } };
          if (typeof globalThis !== 'undefined') {
            globalThis.org = org;
            globalThis.Jsoup = Jsoup;
          }
          this.org = org;
          this.Jsoup = Jsoup;
        }).call(this);
        """)
    }

    /// 万象书屋: 释放 nodes (JSEngine deinit 或 evaluate 完成时调)
    /// 暂不实现 GC, 内存爆再加
    public static func clearNodes() {
        lock.lock(); defer { lock.unlock() }
        nodes.removeAll(keepingCapacity: false)
    }
}
