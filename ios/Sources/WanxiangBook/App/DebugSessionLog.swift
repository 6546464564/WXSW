//
//  DebugSessionLog.swift
//  万象书屋 iOS · Debug 会话 NDJSON 上报 (仅 DEBUG 构建)
//
//  万象书屋 (2026-05-25): 端点是开发机 127.0.0.1:7532, 真机/无网络环境下原生
//  URLSession 默认 60s timeout 会导致 task 累积 → 占内存 + 卡 networkd. 改为:
//   - 仅在 DEBUG 构建生效 (#if DEBUG)
//   - 共享一个 1s 超时 URLSession, 真机连不上时秒失败不堆积
//   - 仅在模拟器或显式开 `WX_DEBUG_REMOTE_LOG` 时才发网络, 真机默认只写本地文件
//

import Foundation

enum DebugSessionLog {
    private static let sessionId = "c2a488"
    private static let endpoint = URL(string: "http://127.0.0.1:7532/ingest/158dd9d1-7177-49ee-9212-91afccd69b9e")!
    private static let logPath = "/Users/stark/Desktop/WXSW/.cursor/debug-c2a488.log"

    /// 短超时 session: 真机连不上 dev host 时秒失败, 不堆积 task.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 2.0
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    /// 是否往 dev host 发请求. 真机默认 false (避免 60s 累积), 模拟器或显式打开才 true.
    private static let remoteEnabled: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.environment["WX_DEBUG_REMOTE_LOG"] != nil
        #endif
    }()

    static func log(
        location: String,
        message: String,
        hypothesisId: String,
        data: [String: Any] = [:],
        runId: String = "pre-fix"
    ) {
        #if DEBUG
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "location": location,
            "message": message,
            "hypothesisId": hypothesisId,
            "runId": runId,
        ]
        if !data.isEmpty { payload["data"] = data }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let line = String(data: body, encoding: .utf8) ?? ""
        appendHostLog(line)
        if remoteEnabled {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.timeoutInterval = 1.0
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(sessionId, forHTTPHeaderField: "X-Debug-Session-Id")
            req.httpBody = body
            session.dataTask(with: req).resume()
        }
        NSLog("[DEBUG-\(sessionId)] \(hypothesisId) \(location): \(message) \(data)")
        #endif
    }

    private static func appendHostLog(_ line: String) {
        let path = logPath
        guard let handle = FileHandle(forWritingAtPath: path) else {
            FileManager.default.createFile(atPath: path, contents: (line + "\n").data(using: .utf8))
            return
        }
        handle.seekToEndOfFile()
        if let d = (line + "\n").data(using: .utf8) { handle.write(d) }
        try? handle.close()
    }
}
