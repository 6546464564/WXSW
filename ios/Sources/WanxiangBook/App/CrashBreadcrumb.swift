//
//  CrashBreadcrumb.swift
//  万象书屋 iOS · 崩溃前行为轨迹 (对齐 Firebase Crashlytics breadcrumbs)
//
//  写入 Caches/wanxiang_breadcrumbs.log，下次启动由 CrashHandler 一并上报。
//  signal/OOM 路径无法安全堆分配，靠启动时读此文件定位「闪退前在干什么」。
//

import Foundation

enum CrashBreadcrumb {

    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let maxLines = 32

    private static let fileURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("wanxiang_breadcrumbs.log")
    }()

    /// 记录一条轨迹（线程安全，尽量短）
    static func leave(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(message)"
        lock.lock()
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        let snapshot = lines.joined(separator: "\n")
        lock.unlock()
        persist(snapshot)
        #if DEBUG
        NSLog("[WX-CRUMB] %@", message)
        #endif
    }

    static func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        if !lines.isEmpty { return lines.joined(separator: "\n") }
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return ""
        }
        return text
    }

    static func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func persist(_ text: String) {
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
