//
//  SourceVariableStore.swift
//  万象书屋 iOS · 书源 KV 存储 (对应 Android BaseSource.getVariable / setVariable)
//
//  legado 给每个源一个 KV (key = sourceVariable_{bookSourceUrl}),
//  源 JS 用 source.getVariable() / source.setVariable(json) 读写自己的状态.
//
//  iOS 实现: 用 UserDefaults (单机 KV 够用).
//

import Foundation

public actor SourceVariableStore {

    public static let shared = SourceVariableStore()

    private let prefix = "wx.sourceVariable."
    private let loginPrefix = "wx.sourceLogin."

    private init() {}

    public func get(sourceUrl: String) -> String {
        UserDefaults.standard.string(forKey: prefix + sourceUrl) ?? ""
    }

    public func set(sourceUrl: String, value: String?) {
        let k = prefix + sourceUrl
        if let v = value {
            UserDefaults.standard.set(v, forKey: k)
        } else {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    public func getLoginInfo(sourceUrl: String) -> [String: String] {
        guard let raw = UserDefaults.standard.string(forKey: loginPrefix + sourceUrl),
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    public func setLoginInfo(sourceUrl: String, info: [String: String]) {
        if let data = try? JSONSerialization.data(withJSONObject: info),
           let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: loginPrefix + sourceUrl)
        }
    }
}

/// 同步访问的快照, 给 JSEngine 在评估前注入用 (避免 JS 调用 source.getVariable 时还要 await actor)
public struct SourceVariableSnapshot: Sendable {
    public let sourceUrl: String
    public var variable: String
    public var loginInfo: [String: String]

    public init(sourceUrl: String) {
        self.sourceUrl = sourceUrl
        self.variable = UserDefaults.standard.string(forKey: "wx.sourceVariable." + sourceUrl) ?? ""
        if let raw = UserDefaults.standard.string(forKey: "wx.sourceLogin." + sourceUrl),
           let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            self.loginInfo = dict
        } else {
            self.loginInfo = [:]
        }
    }

    public func writeBack() {
        UserDefaults.standard.set(variable, forKey: "wx.sourceVariable." + sourceUrl)
        if let data = try? JSONSerialization.data(withJSONObject: loginInfo),
           let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: "wx.sourceLogin." + sourceUrl)
        }
    }
}
