//
//  SourceVariableStore.swift
//  万象书屋 iOS · 书源 KV 存储 (对应 Android BaseSource.getVariable / setVariable)
//
//  legado 给每个源一个 KV (key = sourceVariable_{bookSourceUrl}),
//  源 JS 用 source.getVariable() / source.setVariable(json) 读写自己的状态.
//
//  iOS 实现: 用独立 UserDefaults suite，避免触发 SwiftUI @AppStorage 通知.
//

import Foundation

public actor SourceVariableStore {

    public static let shared = SourceVariableStore()

    static let defaults = UserDefaults(suiteName: "wx.jsdata") ?? .standard

    private let prefix = "wx.sourceVariable."
    private let loginPrefix = "wx.sourceLogin."

    private init() {}

    public func get(sourceUrl: String) -> String {
        Self.defaults.string(forKey: prefix + sourceUrl) ?? ""
    }

    public func set(sourceUrl: String, value: String?) {
        let k = prefix + sourceUrl
        if let v = value {
            Self.defaults.set(v, forKey: k)
        } else {
            Self.defaults.removeObject(forKey: k)
        }
    }

    public func getLoginInfo(sourceUrl: String) -> [String: String] {
        guard let raw = Self.defaults.string(forKey: loginPrefix + sourceUrl),
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    public func setLoginInfo(sourceUrl: String, info: [String: String]) {
        if let data = try? JSONSerialization.data(withJSONObject: info),
           let s = String(data: data, encoding: .utf8) {
            Self.defaults.set(s, forKey: loginPrefix + sourceUrl)
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
        self.variable = SourceVariableStore.defaults.string(forKey: "wx.sourceVariable." + sourceUrl) ?? ""
        if let raw = SourceVariableStore.defaults.string(forKey: "wx.sourceLogin." + sourceUrl),
           let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            self.loginInfo = dict
        } else {
            self.loginInfo = [:]
        }
    }

    public func writeBack() {
        SourceVariableStore.defaults.set(variable, forKey: "wx.sourceVariable." + sourceUrl)
        if let data = try? JSONSerialization.data(withJSONObject: loginInfo),
           let s = String(data: data, encoding: .utf8) {
            SourceVariableStore.defaults.set(s, forKey: "wx.sourceLogin." + sourceUrl)
        }
    }
}
