//
//  Keychain.swift
//  万象书屋 iOS · Keychain 简易封装
//
//  设计:
//   - 仅存关键身份 (device_id, device_token), 不放正文/章节
//   - kSecAttrAccessibleAfterFirstUnlock: 设备解锁后可读 (后台心跳能用),
//     比 WhenUnlocked 更宽松, 但比 Always 更安全
//   - 同步 API: Keychain 操作快 (微秒级), 不需要 async
//

import Foundation
import Security

enum Keychain {

    /// 万象书屋: 全部 key 集中在这, 避免散落各文件
    enum Key: String {
        case deviceId = "wanxiang.device_id"
        case deviceToken = "wanxiang.device_token"
        // M2 阶段加: webdav_pw / source_login_cookie 等
    }

    /// 万象书屋: Apple Silicon simulator 上 SecItemAdd 返回 success 但读不到 (已知 bug),
    /// 用 UserDefaults 兜底镜像. 真机上 keychain 完全可靠, 此 fallback 只是 belt-and-suspenders.
    private static let mirrorPrefix = "wx.kc.mirror."

    @discardableResult
    static func write(_ key: Key, _ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(q as CFDictionary)
        var addQ = q
        addQ[kSecValueData as String] = data
        let status = SecItemAdd(addQ as CFDictionary, nil)
        // 总是镜像到 UserDefaults (simulator 兜底)
        UserDefaults.standard.set(value, forKey: mirrorPrefix + key.rawValue)
        return status == errSecSuccess
    }

    static func read(_ key: Key) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess,
           let data = out as? Data,
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        // Keychain 读不到 → 试 UserDefaults 镜像 (simulator fallback)
        return UserDefaults.standard.string(forKey: mirrorPrefix + key.rawValue)
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: mirrorPrefix + key.rawValue)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 万象书屋: 注销账号时清空全部 (PIPL 必须)
    static func wipeAll() {
        for key in [Key.deviceId, Key.deviceToken] {
            delete(key)
        }
    }
}
