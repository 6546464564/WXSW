//
//  CrashHandler.swift
//  万象书屋 iOS · 全局崩溃捕获 → /api/crash-log (M2.1.7)
//
//  对应 Android: io.legado.app.help.CrashHandler
//
//  捕获范围:
//   - NSSetUncaughtExceptionHandler (Objective-C 异常)
//   - signal handlers (SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGTRAP/SIGFPE/SIGPIPE)
//
//  上报到后端 /api/crash-log (WanxiangAPI.reportCrash)
//
//  设计原则 (2026-05-25 重构):
//   - **崩溃路径绝对不写 UserDefaults**: SE crash 报告 47EA1745 / A2B0A7E6 显示
//     UserDefaults.set → NSUserDefaultsDidChangeNotification → SwiftUI
//     UserDefaultObserver → Update.enqueueAction → _MovableLockLock 与主线程死锁,
//     把 OOM 放大成 hang. signal/NSException 两条路都改为只写文件,延后启动时上报.
//   - **崩溃路径不调 String 拼接 / Array bridge**: 上面同一份报告里 OOM 时
//     `formatSignal` 还在跑 `joined(separator:)` / `_arrayForceCast` 触发再次分配 →
//     swift_abortAllocationFailure 递归. signal 只写固定字节, NSException 路径
//     用预分配缓冲区 + 截断保护.
//

import Foundation
import Darwin

private let wxCrashSigABRT: [UInt8] = [0x5b, 0x53, 0x49, 0x47, 0x41, 0x42, 0x52, 0x54, 0x5d, 0x0a]
private let wxCrashSigSEGV: [UInt8] = [0x5b, 0x53, 0x49, 0x47, 0x53, 0x45, 0x47, 0x56, 0x5d, 0x0a]
private let wxCrashSigBUS:  [UInt8] = [0x5b, 0x53, 0x49, 0x47, 0x42, 0x55, 0x53, 0x5d, 0x0a]
private let wxCrashSigOther: [UInt8] = [0x5b, 0x53, 0x49, 0x47, 0x5d, 0x0a]

enum CrashHandler {

    private static let kPendingCrash = "wanxiang.pending_crash"
    /// signal handler 内只能用 open/write/close (async-signal-safe). 启动时预计算路径.
    private static var signalCrashFilePath: UnsafeMutablePointer<CChar>?
    /// NSException handler 也走文件而不是 UserDefaults, 否则 OOM 时通知触发 SwiftUI 死锁.
    private static var exceptionCrashFilePath: UnsafeMutablePointer<CChar>?

    /// NSException 路径上限: 64KB 已经够装 callStackSymbols + breadcrumbs;
    /// 超过则截断, 避免 OOM 进程里再做大字符串拼接二次崩溃.
    private static let exceptionDumpMaxBytes = 64 * 1024

    /// 在 App 启动时调一次. 跟 Android 一样, 必须在 onCreate 早期阶段安装
    static func install() {
        if signalCrashFilePath == nil {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let path = caches.appendingPathComponent("wanxiang_pending_crash.sig").path
            signalCrashFilePath = strdup(path)
        }
        if exceptionCrashFilePath == nil {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let path = caches.appendingPathComponent("wanxiang_pending_crash.exc").path
            exceptionCrashFilePath = strdup(path)
        }
        // 1. Objective-C 未捕获异常
        // 万象书屋: NSSetUncaughtExceptionHandler 接受 C 函数指针, Swift closure 必须 @convention(c)
        // 且不能 capture context, 所以回调内只能调静态/全局函数
        NSSetUncaughtExceptionHandler(_wanxiangUncaughtExceptionHandler)
        // 2. signal handler (UNIX signals)
        installSignalHandlers()

        // 3. 上次启动崩溃的延后上报
        // 先读旧 breadcrumbs（崩溃前的状态），再写新 breadcrumb 避免覆盖
        let oldCrumbs = CrashBreadcrumb.snapshot()
        CrashBreadcrumb.leave("app.launch")
        Task.detached { await flushPending(previousBreadcrumbs: oldCrumbs) }
    }

    // MARK: - 异常格式化

    /// 万象书屋: 崩溃路径专用, 限制总长 + 单段截断, 避免 OOM 时分配大块字符串触发递归崩溃.
    private static func formatExceptionSafe(_ exception: NSException) -> String {
        var s = "[NSException]\n"
        s.reserveCapacity(8 * 1024)
        s += "name: "
        s += exception.name.rawValue
        s += "\n"
        s += "reason: "
        if let reason = exception.reason {
            s += String(reason.prefix(2048))
        } else {
            s += "<nil>"
        }
        s += "\n"
        // userInfo: 只取 description 前 1KB, 不调 dictionary serialization
        if let userInfo = exception.userInfo {
            s += "userInfo: "
            s += String(String(describing: userInfo).prefix(1024))
            s += "\n"
        }
        // breadcrumbs: 文件已经 max 32 行
        let crumbs = CrashBreadcrumb.snapshot()
        if !crumbs.isEmpty {
            s += "breadcrumbs:\n"
            s += String(crumbs.prefix(8 * 1024))
            s += "\n"
        }
        // callStackSymbols: 取前 30 帧, 每帧最多 256 字节
        let symbols = exception.callStackSymbols
        s += "callStackSymbols:\n"
        let frameCount = Swift.min(symbols.count, 30)
        for i in 0..<frameCount {
            s += String(symbols[i].prefix(256))
            s += "\n"
            if s.utf8.count > exceptionDumpMaxBytes { break }
        }
        if s.utf8.count > exceptionDumpMaxBytes {
            // 硬截断, 保证写入不再增长
            let cap = s.index(s.startIndex, offsetBy: exceptionDumpMaxBytes, limitedBy: s.endIndex) ?? s.endIndex
            return String(s[..<cap])
        }
        return s
    }

    /// 写文件版本 — 不走 UserDefaults, 不发通知, 不触发 SwiftUI Update lock.
    private static func persistExceptionToFile(_ dump: String) {
        guard let path = exceptionCrashFilePath else { return }
        let fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // 直接 write, 不经过 Foundation Data init
        dump.withCString { cstr in
            let len = strlen(cstr)
            var written: Int = 0
            while written < len {
                let n = write(fd, cstr + written, len - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    /// signal handler 专用: 固定字节数组 + write(), 禁止 UserDefaults/堆分配 (OOM 时会触发 SwiftUI 二次死锁).
    static func persistSignalSafe(_ sig: Int32) {
        guard let path = signalCrashFilePath else { return }
        let fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes: [UInt8]
        switch sig {
        case SIGABRT: bytes = wxCrashSigABRT
        case SIGSEGV: bytes = wxCrashSigSEGV
        case SIGBUS:  bytes = wxCrashSigBUS
        default:      bytes = wxCrashSigOther
        }
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    // MARK: - signal handler 安装

    private static var signalsInstalled = false

    private static func installSignalHandlers() {
        guard !signalsInstalled else { return }
        signalsInstalled = true
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGPIPE] {
            signal(sig, _wanxiangSignalHandler)
        }
    }

    /// 暴露给 C 函数指针调用 (internal 让 helper 函数可见)
    static func _formatSignalAndPersist(_ sig: Int32) {
        persistSignalSafe(sig)
    }

    static func _formatExceptionAndPersist(_ exception: NSException) {
        let dump = formatExceptionSafe(exception)
        persistExceptionToFile(dump)
    }

    // MARK: - 延后上报

    private static func flushPending(previousBreadcrumbs: String) async {
        var dump: String?
        // 优先读 NSException 文件 (内容更丰富)
        if let path = exceptionCrashFilePath {
            let url = URL(fileURLWithPath: String(cString: path))
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                dump = String(data: data, encoding: .utf8)
                try? FileManager.default.removeItem(at: url)
            }
        }
        // 再读 signal 标记文件
        if dump == nil || dump?.isEmpty == true, let path = signalCrashFilePath {
            let url = URL(fileURLWithPath: String(cString: path))
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                dump = String(data: data, encoding: .utf8)
                try? FileManager.default.removeItem(at: url)
            }
        }
        // 兼容历史 UserDefaults (老版本写过)
        if dump == nil || dump?.isEmpty == true {
            dump = UserDefaults.standard.string(forKey: kPendingCrash)
        }
        if dump == nil || dump?.isEmpty == true, let path = signalCrashFilePath {
            let sigName = String(cString: path).hasSuffix(".sig") ? readSignalMarker(path) : nil
            if let sigName { dump = "[Signal \(sigName)]" }
        }
        // 用崩溃前保存的 breadcrumbs（而非当前 session 的）
        if var text = dump, !text.isEmpty, !previousBreadcrumbs.isEmpty, !text.contains("breadcrumbs:") {
            text += "\nbreadcrumbs:\n\(previousBreadcrumbs)"
            dump = text
        }
        guard let dump, !dump.isEmpty else { return }
        saveLocalCrashLog(dump)
        await MainActor.run {
            WanxiangAPI.shared.reportCrash(exception: extractFirstLine(dump), stack: dump)
            UserDefaults.standard.removeObject(forKey: kPendingCrash)
        }
        CrashBreadcrumb.clear()
    }

    private static func saveLocalCrashLog(_ dump: String) {
        let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = baseDir.appendingPathComponent("CrashLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("last_crash.txt")
        try? dump.write(to: file, atomically: true, encoding: .utf8)
        NSLog("[WX-CRASH] saved local crash log → %@", file.path)
        DebugSessionLog.logDevice(
            location: "CrashHandler.flushPending",
            message: "prev crash found",
            hypothesisId: "CRASH-C",
            data: ["dump": String(dump.prefix(500))]
        )
    }

    private static func enrichWithBreadcrumbs(_ dump: String?) -> String? {
        guard var text = dump, !text.isEmpty else { return dump }
        let crumbs = CrashBreadcrumb.snapshot()
        guard !crumbs.isEmpty, !text.contains("breadcrumbs:") else { return text }
        text += "\nbreadcrumbs:\n\(crumbs)"
        return text
    }

    private static func readSignalMarker(_ path: UnsafeMutablePointer<CChar>) -> String? {
        let url = URL(fileURLWithPath: String(cString: path))
        guard let data = try? Data(contentsOf: url), let raw = String(data: data, encoding: .utf8) else {
            return nil
        }
        if raw.contains("SIGABRT") { return "SIGABRT" }
        if raw.contains("SIGSEGV") { return "SIGSEGV" }
        if raw.contains("SIGBUS") { return "SIGBUS" }
        return "SIG"
    }

    private static func extractFirstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? "crash"
    }
}

// MARK: - C 函数指针 (放文件作用域才能被 NSSetUncaughtExceptionHandler 接受)
//
// 万象书屋: NSSetUncaughtExceptionHandler 和 signal() 都要求 @convention(c) 函数指针,
// 不允许 Swift closure 捕获上下文. 这两个函数纯转发到 CrashHandler 的静态方法.

private func _wanxiangUncaughtExceptionHandler(_ exception: NSException) {
    CrashHandler._formatExceptionAndPersist(exception)
}

private func _wanxiangSignalHandler(_ sig: Int32) {
    CrashHandler.persistSignalSafe(sig)
    signal(sig, SIG_DFL)
    raise(sig)
}
