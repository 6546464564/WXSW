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
//  注意: signal handler 内可调用的 API 极受限 (async-signal-safe), 这里我们只做最小化:
//   - 把异常信息写到 NSUserDefaults / 文件
//   - 下次启动时从文件读出并上报 (deferred reporting)
//

import Foundation

enum CrashHandler {

    private static let kPendingCrash = "wanxiang.pending_crash"

    /// 在 App 启动时调一次. 跟 Android 一样, 必须在 onCreate 早期阶段安装
    static func install() {
        // 1. Objective-C 未捕获异常
        // 万象书屋: NSSetUncaughtExceptionHandler 接受 C 函数指针, Swift closure 必须 @convention(c)
        // 且不能 capture context, 所以回调内只能调静态/全局函数
        NSSetUncaughtExceptionHandler(_wanxiangUncaughtExceptionHandler)
        // 2. signal handler (UNIX signals)
        installSignalHandlers()

        // 3. 上次启动崩溃的延后上报
        Task.detached { await flushPending() }
    }

    // MARK: - 异常格式化

    private static func formatException(_ exception: NSException) -> String {
        var s = "[NSException]\n"
        s += "name: \(exception.name.rawValue)\n"
        s += "reason: \(exception.reason ?? "<nil>")\n"
        s += "userInfo: \(exception.userInfo ?? [:])\n"
        s += "callStackSymbols:\n"
        s += exception.callStackSymbols.joined(separator: "\n")
        return s
    }

    private static func formatSignal(_ sig: Int32) -> String {
        let name: String
        switch sig {
        case SIGABRT: name = "SIGABRT"
        case SIGSEGV: name = "SIGSEGV"
        case SIGBUS:  name = "SIGBUS"
        case SIGILL:  name = "SIGILL"
        case SIGTRAP: name = "SIGTRAP"
        case SIGFPE:  name = "SIGFPE"
        case SIGPIPE: name = "SIGPIPE"
        default:      name = "SIG_\(sig)"
        }
        let frames = Thread.callStackSymbols.joined(separator: "\n")
        return "[Signal \(name)/\(sig)]\n\(frames)"
    }

    private static func persist(_ dump: String) {
        // 万象书屋: 用 UserDefaults 存简单, 下次启动读出来上报
        UserDefaults.standard.set(dump, forKey: kPendingCrash)
        UserDefaults.standard.synchronize()
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
        let dump = formatSignal(sig)
        persist(dump)
    }

    static func _formatExceptionAndPersist(_ exception: NSException) {
        let dump = formatException(exception)
        persist(dump)
    }

    // MARK: - 延后上报

    private static func flushPending() async {
        guard let dump = UserDefaults.standard.string(forKey: kPendingCrash), !dump.isEmpty else {
            return
        }
        // 上报后清掉, 避免重复
        await MainActor.run {
            WanxiangAPI.shared.reportCrash(exception: extractFirstLine(dump), stack: dump)
            UserDefaults.standard.removeObject(forKey: kPendingCrash)
        }
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
    CrashHandler._formatSignalAndPersist(sig)
    signal(sig, SIG_DFL)
    raise(sig)
}
