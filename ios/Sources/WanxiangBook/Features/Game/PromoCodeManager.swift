import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class PromoCodeManager: ObservableObject {

    static let shared = PromoCodeManager()

    @Published private(set) var promoCodes: [PromoCodeItem] = []
    @Published private(set) var usageRecords: [PromoUsageRecord] = []

    private let codesKey = "wx.promo.codes"
    private let usageKey = "wx.promo.usage"

    private init() {
        loadLocal()
        // UI 测试时注入测试激活码
        if CommandLine.arguments.contains("-uitest") {
            if promoCodes.isEmpty {
                promoCodes = [PromoCodeItem(code: "UITEST", agentName: "UITest")]
            }
        }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        loadLocal()
        // UI 测试时跳过网络同步，避免覆盖注入的测试激活码
        guard !CommandLine.arguments.contains("-uitest") else { return }
        await fetchRemoteCodes()
    }

    // MARK: - Validate code

    enum ValidationResult {
        case success(code: String, agentName: String)
        case invalidCode
    }

    func validate(inputCode: String) -> ValidationResult {
        let trimmed = inputCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .invalidCode }

        guard let matched = promoCodes.first(where: { $0.code.lowercased() == trimmed.lowercased() }) else {
            reportAttempt(code: trimmed, success: false)
            return .invalidCode
        }

        let record = PromoUsageRecord(
            code: matched.code,
            agentName: matched.agentName,
            deviceId: currentDeviceId(),
            deviceModel: currentDeviceModel(),
            timestamp: Date(),
            systemVersion: currentSystemVersion()
        )
        usageRecords.append(record)
        saveLocal()

        reportAttempt(code: trimmed, success: true)
        reportUsageToServer(record: record)

        return .success(code: matched.code, agentName: matched.agentName)
    }

    // MARK: - Remote sync

    private func fetchRemoteCodes() async {
        // 使用临时 URLSession（不继承 Alt-Svc 缓存），避免 QUIC 连接因本地 DNS 重定向
        // 导致 URLSession 对过期的 CF QUIC IP 发起连接并 ECONNREFUSED 的问题。
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        let freshSession = URLSession(configuration: cfg)
        defer { freshSession.invalidateAndCancel() }

        do {
            var r = WanxiangAPI.shared.request(path: "/api/promo/codes", method: "GET")
            r.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await freshSession.data(for: r)
            guard let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }

            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = dict["codes"] as? [[String: Any]] else { return }

            var codes: [PromoCodeItem] = []
            for item in items {
                guard let code = item["code"] as? String else { continue }
                let agentName = (item["agentName"] as? String) ?? (item["agent_name"] as? String) ?? "代理"
                codes.append(PromoCodeItem(code: code, agentName: agentName))
            }

            if !codes.isEmpty {
                self.promoCodes = codes
                saveLocal()
            }
        } catch {
            // Network failure - use local cache
        }
    }

    private func reportAttempt(code: String, success: Bool) {
        Task.detached {
            let api = WanxiangAPI.shared
            var r = api.request(path: "/api/promo/attempt", method: "POST")
            let body: [String: Any] = [
                "code": code,
                "success": success,
                "device_id": await self.currentDeviceId(),
                "device_model": await self.currentDeviceModel(),
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ]
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            api.sendIgnoreResult(r)
        }
    }

    private func reportUsageToServer(record: PromoUsageRecord) {
        Task.detached {
            let api = WanxiangAPI.shared
            var r = api.request(path: "/api/promo/usage", method: "POST")
            let body: [String: Any] = [
                "code": record.code,
                "agent_name": record.agentName,
                "device_id": record.deviceId,
                "device_model": record.deviceModel,
                "system_version": record.systemVersion,
                "timestamp": ISO8601DateFormatter().string(from: record.timestamp),
            ]
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            api.sendIgnoreResult(r)
        }
    }

    // MARK: - Local persistence

    private func loadLocal() {
        if let data = UserDefaults.standard.data(forKey: codesKey),
           let items = try? JSONDecoder().decode([PromoCodeItem].self, from: data) {
            self.promoCodes = items
        }
        // 不设本地兜底：完全以后端为准，后端设什么 code 才能解锁

        if let data = UserDefaults.standard.data(forKey: usageKey),
           let records = try? JSONDecoder().decode([PromoUsageRecord].self, from: data) {
            self.usageRecords = records
        }
    }

    private func saveLocal() {
        if let data = try? JSONEncoder().encode(promoCodes) {
            UserDefaults.standard.set(data, forKey: codesKey)
        }
        if let data = try? JSONEncoder().encode(usageRecords) {
            UserDefaults.standard.set(data, forKey: usageKey)
        }
    }

    // MARK: - Device info

    private func currentDeviceId() -> String {
        WanxiangAPI.shared.deviceId
    }

    private func currentDeviceModel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "unknown"
        #endif
    }

    private func currentSystemVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}

// MARK: - Models

struct PromoCodeItem: Codable, Identifiable {
    var id: String { code }
    let code: String
    let agentName: String
}

struct PromoUsageRecord: Codable, Identifiable {
    var id: String { "\(code)_\(deviceId)_\(timestamp.timeIntervalSince1970)" }
    let code: String
    let agentName: String
    let deviceId: String
    let deviceModel: String
    let timestamp: Date
    let systemVersion: String
}
