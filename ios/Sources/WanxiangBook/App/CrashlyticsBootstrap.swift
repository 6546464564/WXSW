import Foundation
import FirebaseCore
import FirebaseCrashlytics

enum CrashlyticsBootstrap {

    private(set) static var isActive = false

    /// 条件初始化：仅当 GoogleService-Info.plist 存在于 Bundle 中时才启动 Firebase。
    /// 没有 plist 时静默跳过，不会崩溃。
    static func configure() {
        guard Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil else {
            NSLog("[Crashlytics] GoogleService-Info.plist not found, skipping Firebase init")
            return
        }
        FirebaseApp.configure()
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        isActive = true
        NSLog("[Crashlytics] Firebase + Crashlytics initialized")
    }

    /// 记录非致命错误（如网络超时、解析失败等），出现在 Crashlytics 面板但不算崩溃
    static func record(error: Error, context: [String: Any] = [:]) {
        guard isActive else { return }
        let cl = Crashlytics.crashlytics()
        for (k, v) in context {
            cl.setCustomValue(v, forKey: k)
        }
        cl.record(error: error)
    }

    /// 设置用户标识，方便在 Crashlytics 面板按用户筛选崩溃
    static func setUser(_ uid: String) {
        guard isActive else { return }
        Crashlytics.crashlytics().setUserID(uid)
    }

    /// 添加自定义日志行，崩溃时会附带最近的日志
    static func log(_ msg: String) {
        guard isActive else { return }
        Crashlytics.crashlytics().log(msg)
    }
}
