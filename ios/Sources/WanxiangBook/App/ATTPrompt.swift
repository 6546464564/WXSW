//
//  ATTPrompt.swift
//  万象书屋 iOS · App Tracking Transparency 弹窗 (M2.10.10)
//
//  iOS 14.5+ 强制要求: 想拿 IDFA 必须先弹 ATT 让用户授权.
//  万象书屋默认不追踪用户身份 (PrivacyInfo.xcprivacy NSPrivacyTracking=false),
//  但接广告 SDK (M3) 后, Pangle / GDT 拿 IDFA 能让广告填充率涨 30-50%.
//
//  我们的策略 (跟 PLAN.md M3-8 对齐):
//   - 首启不立即弹, 让用户先看到主界面
//   - 用户进入"我的"页或 "纯净阅读"卡时弹一次 (上下文相关, 通过率高)
//   - 拒绝了不强制再弹 (Apple 规定 ATT 一旦决定就不能反复弹)
//   - "其它设置→个性化广告"提供反向引导 (Settings.app → 重置 ATT)
//
//  M2.10.10 阶段:
//   - 提供 request() / status / shouldRequest 三个 API
//   - 真正接广告时 M3 调
//

import Foundation
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
import AdSupport
#endif

@MainActor
enum ATTPrompt {

    enum Status: String {
        case notDetermined  // 还没问过用户
        case restricted     // 系统/家长/MDM 限制
        case denied         // 用户拒绝
        case authorized     // 用户允许
        case unsupported    // iOS < 14.5 (M2 deployment target = 17, 不会触发但留 fallback)
    }

    static var status: Status {
        #if canImport(AppTrackingTransparency)
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .notDetermined
        }
        #else
        return .unsupported
        #endif
    }

    /// 判断是否应该弹 (没问过 + 没接广告时不弹, M3 接广告再开)
    static var shouldRequest: Bool {
        status == .notDetermined
    }

    /// 弹 ATT 弹窗. 系统会自动判断 (问过就不重弹, 不需要我们判断).
    /// 调用方应在用户主动操作上下文里调 (例如点"我的→纯净阅读卡片→延长解锁"前)
    @discardableResult
    static func request() async -> Status {
        #if canImport(AppTrackingTransparency)
        // ATT 弹窗必须在 active 状态下弹 (后台时调会立即返 .notDetermined 而不弹)
        let raw = await ATTrackingManager.requestTrackingAuthorization()
        switch raw {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        @unknown default: return .notDetermined
        }
        #else
        return .unsupported
        #endif
    }

    /// 取 IDFA (用户授权后才有值; 拒绝则 '00000000-0000-0000-0000-000000000000')
    static var idfa: String? {
        #if canImport(AdSupport)
        let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        if id == "00000000-0000-0000-0000-000000000000" { return nil }
        return id
        #else
        return nil
        #endif
    }
}
