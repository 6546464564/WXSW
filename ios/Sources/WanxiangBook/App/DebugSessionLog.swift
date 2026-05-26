//
//  DebugSessionLog.swift
//  万象书屋 iOS · Debug 会话 NDJSON 日志（设备本地 + 主机双写）
//
//  session 08d799: 用于诊断 12h 模拟测试中的内存相关崩溃.
//  设备上日志写入 Documents/debug_memory.jsonl, 测试后可通过 xcrun devicectl 拉取.
//

import Foundation
import UIKit

// #region agent log
/// 全局活动追踪 — 记录当前 app 正在做什么操作，内存采样时一并输出
final class DebugActivityTracker: @unchecked Sendable {
    static let shared = DebugActivityTracker()
    private let lock = NSLock()
    private var activities: [String: Int] = [:]

    func begin(_ tag: String) {
        lock.lock(); defer { lock.unlock() }
        activities[tag, default: 0] += 1
    }
    func end(_ tag: String) {
        lock.lock(); defer { lock.unlock() }
        if let c = activities[tag], c > 1 { activities[tag] = c - 1 }
        else { activities.removeValue(forKey: tag) }
    }
    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return activities
    }
}
// #endregion

enum DebugSessionLog {
    private static let sessionId = "08d799"
    private static let endpoint = URL(string: "http://127.0.0.1:7532/ingest/158dd9d1-7177-49ee-9212-91afccd69b9e")!
    private static let hostLogPath = "/Users/stark/Desktop/WXSW/.cursor/debug-08d799.log"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.0
        config.timeoutIntervalForResource = 2.0
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    private static let remoteEnabled: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.environment["WX_DEBUG_REMOTE_LOG"] != nil
        #endif
    }()

    // #region agent log
    /// 设备本地日志路径 (Documents/debug_memory.jsonl)
    private static let deviceLogPath: String = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("debug_memory.jsonl").path
    }()

    private static var memoryMonitorTask: Task<Void, Never>?

    /// 启动每 10 秒一次的内存采样
    static func startMemoryMonitor() {
        guard memoryMonitorTask == nil else { return }
        // 记录启动时状态
        let avail = os_proc_available_memory()
        let footprint = getFootprint()
        log(location: "app_launch", message: "App started",
            hypothesisId: "MEM", data: [
                "availMB": Int(avail) / 1_048_576,
                "footprintMB": footprint / 1_048_576,
                "physicalGB": ProcessInfo.processInfo.physicalMemory / 1_073_741_824
            ])

        memoryMonitorTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                let a = os_proc_available_memory()
                let f = getFootprint()
                let acts = DebugActivityTracker.shared.snapshot()
                var d: [String: Any] = [
                    "availMB": Int(a) / 1_048_576,
                    "footprintMB": f / 1_048_576
                ]
                if !acts.isEmpty { d["acts"] = acts }
                logDevice(location: "mem_sample", message: "periodic",
                          hypothesisId: "MEM", data: d)
            }
        }
    }

    /// 获取进程 footprint (实际占用物理内存)
    private static func getFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return Int(info.phys_footprint)
        }
        return 0
    }
    // #endregion

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

        // 写入设备本地日志
        appendDeviceLog(line)
        // 写入主机日志 (模拟器时有效)
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
        #endif
    }

    /// 轻量级设备本地日志（不走网络），用于高频内存采样
    static func logDevice(
        location: String,
        message: String,
        hypothesisId: String,
        data: [String: Any] = [:]
    ) {
        #if DEBUG
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "location": location,
            "message": message,
            "hypothesisId": hypothesisId,
        ]
        if !data.isEmpty { payload["data"] = data }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let line = String(data: body, encoding: .utf8) ?? ""
        appendDeviceLog(line)
        #endif
    }

    // #region agent log
    private static func appendDeviceLog(_ line: String) {
        let path = deviceLogPath
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: path) {
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
    // #endregion

    private static func appendHostLog(_ line: String) {
        let path = hostLogPath
        guard let handle = FileHandle(forWritingAtPath: path) else {
            FileManager.default.createFile(atPath: path, contents: (line + "\n").data(using: .utf8))
            return
        }
        handle.seekToEndOfFile()
        if let d = (line + "\n").data(using: .utf8) { handle.write(d) }
        try? handle.close()
    }
}
