import Foundation
import MetricKit

/// 系统级诊断收集器。
/// MetricKit 由 iOS 系统自动收集性能指标和崩溃日志（包括 App 退出原因、
/// 挂起诊断、磁盘写入异常等），24h 汇总后回调。
/// 收到的诊断数据同时：
///   1. 写入本地文件（Documents/MetricKit/）供调试
///   2. 上报后端 /api/crash-log
///   3. 如果 Crashlytics 已初始化，也记录一条非致命错误
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber {

    static let shared = MetricKitSubscriber()
    private override init() { super.init() }

    func start() {
        MXMetricManager.shared.add(self)
        NSLog("[MetricKit] subscriber registered")
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let json = payload.jsonRepresentation()
            save(data: json, prefix: "metric")
            NSLog("[MetricKit] received metric payload (%d bytes)", json.count)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let json = payload.jsonRepresentation()
            save(data: json, prefix: "diagnostic")

            let summary = extractDiagnosticSummary(payload)
            NSLog("[MetricKit] diagnostic: %@", summary)

            Task.detached {
                await MainActor.run {
                    WanxiangAPI.shared.reportCrash(
                        exception: "[MetricKit] \(summary)",
                        stack: String(data: json, encoding: .utf8) ?? ""
                    )
                }
            }

        }
    }

    // MARK: - Helpers

    private func save(data: Data, prefix: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MetricKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date())
        let file = dir.appendingPathComponent("\(prefix)_\(ts).json")
        try? data.write(to: file)
    }

    private func extractDiagnosticSummary(_ payload: MXDiagnosticPayload) -> String {
        var parts: [String] = []
        if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
            parts.append("crashes=\(crashes.count)")
        }
        if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
            parts.append("hangs=\(hangs.count)")
        }
        if let cpuExceptions = payload.cpuExceptionDiagnostics, !cpuExceptions.isEmpty {
            parts.append("cpuExceptions=\(cpuExceptions.count)")
        }
        if let diskWrites = payload.diskWriteExceptionDiagnostics, !diskWrites.isEmpty {
            parts.append("diskWriteExceptions=\(diskWrites.count)")
        }
        return parts.isEmpty ? "unknown diagnostic" : parts.joined(separator: ", ")
    }
}
