//
//  LogicGapTests.swift
//  万象书屋 iOS · 低覆盖纯逻辑模块补测
//
//  覆盖覆盖率报告里 0% 的可测逻辑:
//    - ReplacementEngine (净化规则引擎, RulesRepository.swift)
//    - CookieJarStore     (cookie 读写, BookSource/JS/CookieJarStore.swift)
//    - SyncHTTP           (同步 HTTP + 缓存 + 错误处理, BookSource/JS/SyncHTTP.swift)
//      (起本地 HTTP server, 走真实网络链路)
//

import XCTest
@testable import WanxiangBook

// MARK: - 极简本地 HTTP server (127.0.0.1, 随机端口)
//
// 用途: 给 SyncHTTP 提供真实 HTTP 响应, 避免 URLProtocol mock 在 iOS 上不生效.

private final class MiniHTTPServer {
    private var socketFD: Int32 = -1
    private(set) var port: UInt16 = 0
    private var acceptThread: Thread?
    private var shouldRun = false

    /// handler: 返回 (statusCode, headers, body)
    var handler: ((URLRequest) -> (Int, [String: String], String))?

    func start() throws {
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw NSError(domain: "sock", code: 1) }
        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // 随机
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                bind(socketFD, p, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { throw NSError(domain: "bind", code: 2) }
        // 取端口
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &got) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                getsockname(socketFD, p, &len)
            }
        }
        port = UInt16(bigEndian: got.sin_port)
        guard listen(socketFD, 16) == 0 else { throw NSError(domain: "listen", code: 3) }
        shouldRun = true
        acceptThread = Thread { [weak self] in self?.acceptLoop() }
        acceptThread?.name = "mini-http-accept"
        acceptThread?.start()
    }

    func stop() {
        shouldRun = false
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
    }

    private func acceptLoop() {
        while shouldRun {
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else {
                // 非致命 (如 stop 时 close 触发), 略作退避防忙转
                usleep(10_000)
                continue
            }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        // 读请求 (最多 16KB)
        var buf = [UInt8](repeating: 0, count: 16384)
        var reqData = Data()
        while reqData.count < 16384 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            reqData.append(contentsOf: buf[0..<n])
            if reqData.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        // 解析第一行 + Host 头
        let text = String(data: reqData, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? "GET / HTTP/1.1"
        let parts = firstLine.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        let path = parts.count > 1 ? String(parts[1]) : "/"
        var host = "127.0.0.1"
        for l in lines where l.lowercased().hasPrefix("host:") {
            host = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        var url = URL(string: "http://\(host)\(path)")
        if url == nil { url = URL(string: "http://127.0.0.1:\(port)\(path)") }
        var request = URLRequest(url: url!)
        request.httpMethod = method
        for l in lines.dropFirst() where l.contains(":") {
            let kv = l.split(separator: ":", maxSplits: 1).map(String.init)
            request.setValue(kv[1].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: kv[0])
        }

        let (status, headers, body) = handler?(request) ?? (404, [:], "not found")
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 404: statusText = "Not Found"
        default: statusText = "Status"
        }
        var h = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\n"
        for (k, v) in headers { h += "\(k): \(v)\r\n" }
        h += "Connection: close\r\n\r\n"
        let resp = h.data(using: .utf8)! + body.data(using: .utf8)!
        _ = resp.withUnsafeBytes { raw in
            send(client, raw.baseAddress!, resp.count, 0)
        }
    }
}

// MARK: - 1. ReplacementEngine

final class LogicGapTests: XCTestCase {

    private var server: MiniHTTPServer?

    override func tearDown() {
        server?.stop()
        server = nil
        CookieJarStore.clearAll()
        SyncHTTP.clearCache()
        super.tearDown()
    }

    private func startServer(handler: @escaping (URLRequest) -> (Int, [String: String], String)) throws -> String {
        let s = MiniHTTPServer()
        s.handler = handler
        try s.start()
        server = s
        return "http://127.0.0.1:\(s.port)"
    }

    private func rule(_ name: String, pattern: String, replacement: String,
                      isRegex: Bool = true, scope: String = "") -> ReplaceRuleEntity {
        ReplaceRuleEntity(name: name, pattern: pattern, replacement: replacement,
                          isRegex: isRegex, scope: scope)
    }

    // MARK: ReplacementEngine

    func test_replacementEngine_regexReplace() {
        let rules = [
            rule("去广告", pattern: #"<script>.*?</script>"#, replacement: ""),
            rule("替换词", pattern: #"草泥马"#, replacement: "***"),
        ]
        let input = "<p>草泥马，这是正文</p><script>ads</script>"
        let out = ReplacementEngine.apply(rules: rules, to: input, sourceUrl: "https://a.com")
        XCTAssertEqual(out, "<p>***，这是正文</p>")
    }

    func test_replacementEngine_plainReplace() {
        let rules = [
            rule("全角空格", pattern: "　", replacement: " ", isRegex: false),
        ]
        let out = ReplacementEngine.apply(rules: rules, to: "你好　世界", sourceUrl: nil)
        XCTAssertEqual(out, "你好 世界")
    }

    func test_replacementEngine_scopeFilter() {
        // scope 限定 "a.com" — 只对命中 URL 的源生效
        let scoped = rule("限A站", pattern: "旧词", replacement: "新词", scope: "a.com,b.com")
        // 命中 → 替换
        let hit = ReplacementEngine.apply(rules: [scoped], to: "这里有旧词", sourceUrl: "https://a.com/x")
        XCTAssertEqual(hit, "这里有新词")
        // 未命中 → 不替换
        let miss = ReplacementEngine.apply(rules: [scoped], to: "这里有旧词", sourceUrl: "https://other.com/x")
        XCTAssertEqual(miss, "这里有旧词")
    }

    func test_replacementEngine_disabledRuleSkipped() {
        var disabled = rule("停用", pattern: "A", replacement: "B")
        disabled.enabled = false
        let out = ReplacementEngine.apply(rules: [disabled], to: "ABC", sourceUrl: nil)
        XCTAssertEqual(out, "ABC")
    }

    func test_replacementEngine_badRegexTolerated() {
        // 非法正则不应崩溃, 保持原文
        let bad = rule("坏正则", pattern: "([a-z", replacement: "x")
        let out = ReplacementEngine.apply(rules: [bad], to: "hello", sourceUrl: nil)
        XCTAssertEqual(out, "hello")
    }

    // MARK: CookieJarStore

    func test_cookieJar_setGetRemove() {
        let url = "https://cookietest.example.com/path"
        CookieJarStore.setCookie(url: url, cookie: "session=abc123; theme=dark")
        let got = CookieJarStore.getCookie(url: url)
        XCTAssertTrue(got.contains("session=abc123"), "应含 session cookie, 实际: \(got)")
        XCTAssertTrue(got.contains("theme=dark"), "应含 theme cookie, 实际: \(got)")
        // 按 key 取
        XCTAssertEqual(CookieJarStore.getCookieValue(url: url, key: "session"), "abc123")
        // 移除全部
        CookieJarStore.removeCookie(url: url)
        XCTAssertEqual(CookieJarStore.getCookie(url: url), "")
    }

    func test_cookieJar_emptyAndNil() {
        CookieJarStore.setCookie(url: "https://nil.example.com", cookie: nil)
        CookieJarStore.setCookie(url: "https://nil.example.com", cookie: "")
        XCTAssertEqual(CookieJarStore.getCookie(url: "https://nil.example.com"), "")
        // 非法 URL 不崩
        XCTAssertEqual(CookieJarStore.getCookie(url: "not a url"), "")
        CookieJarStore.setCookie(url: "not a url", cookie: "k=v")
    }

    // MARK: SyncHTTP (本地 HTTP server)

    func test_syncHTTP_get_returnsBodyAndStatus() throws {
        let base = try startServer { req in
            (200, ["X-Test": "hello"], "<html>OK</html>")
        }
        let result = SyncHTTP.get(url: "\(base)/page")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.body, "<html>OK</html>")
        XCTAssertEqual(result.headers["x-test"], "hello")
    }

    func test_syncHTTP_malformedURL() {
        let result = SyncHTTP.get(url: "")
        XCTAssertEqual(result.statusCode, 0)
        XCTAssertTrue(result.body.contains("Malformed URL"), "实际: \(result.body)")
    }

    func test_syncHTTP_post_sendsMethodAndBody() throws {
        let base = try startServer { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            return (200, [:], "posted")
        }
        let result = SyncHTTP.post(url: "\(base)/api", body: "a=1")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.body, "posted")
    }

    func test_syncHTTP_get_usesCache() throws {
        var callCount = 0
        let base = try startServer { _ in
            callCount += 1
            return (200, [:], "cached body")
        }
        let url = "\(base)/cacheable"
        let r1 = SyncHTTP.get(url: url)
        XCTAssertEqual(r1.body, "cached body")
        // 无 headers 的 GET 会进 cache → 第二次不再发请求
        let r2 = SyncHTTP.get(url: url)
        XCTAssertEqual(r2.body, "cached body")
        XCTAssertEqual(callCount, 1, "缓存命中应只发一次请求")
        SyncHTTP.clearCache()
        let r3 = SyncHTTP.get(url: url)
        XCTAssertEqual(r3.body, "cached body")
        XCTAssertEqual(callCount, 2, "清缓存后应重新请求")
    }

    func test_syncHTTP_serverErrorReturnsBody() throws {
        let base = try startServer { _ in
            (404, [:], "<h1>not found</h1>")
        }
        let result = SyncHTTP.get(url: "\(base)/missing")
        XCTAssertEqual(result.statusCode, 404)
        XCTAssertEqual(result.body, "<h1>not found</h1>")
    }
}
