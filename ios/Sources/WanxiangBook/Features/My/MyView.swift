//
//  MyView.swift
//  万象书屋 iOS · "我的" Tab — 1:1 对齐 Android `MyFragment` (D-17/D-18 简化态)
//
//  可见项: 主题模式 / 护眼 / 意见反馈 / 下载管理 / 应用伪装
//

import SwiftUI

struct MyView: View {

    @StateObject private var theme = ThemeManager.shared
    @StateObject private var eyeCare = EyeCareModeManager.shared
    @StateObject private var ad = AdManager.shared
    @StateObject private var downloader = BookDownloader.shared

    @State private var unlockToast: String? = nil
    @State private var showRelockConfirm = false

    private var downloadSummarySubtitle: String {
        let running = downloader.jobs.values.filter { $0.status == .running }.count
        let finished = downloader.jobs.values.filter { $0.status == .finished }.count
        if running > 0, finished > 0 {
            return String(format: String(localized: "my.download_summary_running_finished"), running, finished)
        }
        if running > 0 {
            return String(format: String(localized: "my.download_summary_running"), running)
        }
        if finished > 0 {
            return String(format: String(localized: "my.download_summary_finished"), finished)
        }
        return String(localized: "my.download_summary_idle")
    }

    var body: some View {
        NavigationStack {
            List {
                if ad.consented && ad.enabled {
                    Section {
                        PurifiedReadingCard(onToast: { msg in unlockToast = msg })
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .listRowBackground(Color.clear)
                    }
                }

                Section {
                    Picker(selection: $theme.mode) {
                        ForEach(ThemeManager.Mode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    } label: {
                        MyRowLabel(
                            icon: "circle.lefthalf.filled",
                            title: "my.theme_mode",
                            subtitleText: themeModeSummary
                        )
                    }
                    .accessibilityIdentifier("my.row.theme_mode")

                    Toggle(isOn: $eyeCare.enabled) {
                        MyRowLabel(
                            icon: "sun.haze",
                            title: "my.eye_care_mode",
                            subtitle: "my.eye_care_mode_summary"
                        )
                    }
                    .tint(WanxiangColors.primary)

                    NavigationLink {
                        FeedbackView()
                    } label: {
                        MyRowLabel(
                            icon: "bubble.left.and.bubble.right",
                            title: "my.feedback",
                            subtitle: "my.feedback_summary"
                        )
                    }
                    .accessibilityIdentifier("my.row.feedback")
                    .accessibilityLabel("意见反馈")
                    .accessibilityAddTraits(.isButton)

                    NavigationLink {
                        DownloadCenterView()
                    } label: {
                        MyRowLabel(
                            icon: "arrow.down.circle",
                            title: "my.download_manage",
                            subtitleText: downloadSummarySubtitle
                        )
                    }
                    .accessibilityIdentifier("my.row.download_manage")
                    .accessibilityLabel("下载管理")
                    .accessibilityAddTraits(.isButton)

                    if !ProcessInfo.processInfo.arguments.contains("-uitest") {
                        Button {
                            showRelockConfirm = true
                        } label: {
                            MyRowLabel(
                                icon: "lock.shield",
                                title: "my.app_disguise",
                                subtitle: "my.app_disguise_summary"
                            )
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text("my.app_name_ios")
                                .font(.caption)
                                .foregroundStyle(WanxiangColors.textSecondary)
                            Text("v\(appVersion()) · build \(appBuild())")
                                .font(.caption2)
                                .foregroundStyle(WanxiangColors.textSecondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(WanxiangColors.background.ignoresSafeArea())
            .navigationTitle("tab.my")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.defaultMinListRowHeight, 10)
            .alert(String(localized: "my.app_disguise_confirm_title"), isPresented: $showRelockConfirm) {
                Button(String(localized: "my.cancel"), role: .cancel) {}
                Button(String(localized: "my.app_disguise_confirm_action"), role: .destructive) {
                    UserDefaults.standard.set(false, forKey: "wx.game.unlocked")
                    NotificationCenter.default.post(name: Notification.Name("wx.game.relocked"), object: nil)
                }
            } message: {
                Text("my.app_disguise_confirm_message")
            }
            .alert(
                String(localized: "unlock_card_title"),
                isPresented: Binding(
                    get: { unlockToast != nil },
                    set: { if !$0 { unlockToast = nil } }
                )
            ) {
                Button(String(localized: "my.ok"), role: .cancel) {}
            } message: {
                Text(unlockToast ?? "")
            }
        }
    }

    private var themeModeSummary: String {
        switch theme.mode {
        case .system: return String(localized: "my.theme_mode_summary_system")
        case .day: return String(localized: "my.theme_mode_summary_day")
        case .night: return String(localized: "my.theme_mode_summary_night")
        }
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private func appBuild() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - 解锁状态卡

private struct PurifiedReadingCard: View {

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var state = PurifiedReadingState.shared
    let onToast: (String) -> Void

    private let unlockMinutes = PurifiedReadingState.defaultUnlockMinutes

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0x1A / 255.0, green: 0x1B / 255.0, blue: 0x23 / 255.0)
            : Color(red: 0x2C / 255.0, green: 0x2A / 255.0, blue: 0x26 / 255.0)
    }

    private var titleColor: Color { .white.opacity(colorScheme == .dark ? 1 : 0.95) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("unlock_card_title")
                    .font(.system(size: 14))
                    .foregroundStyle(titleColor)
                Text(remainingText)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(red: 0xEA / 255.0, green: 0xCE / 255.0, blue: 0x3F / 255.0))
            }
            Spacer(minLength: 8)

            Button(action: tapExtend) {
                Text(buttonText)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(WanxiangColors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(isCooldown ? 0.5 : 1.0)
            }
            .disabled(isCooldown)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var remainingText: String {
        if state.remainingSeconds <= 0 {
            return String(localized: "unlock_card_remaining_zero")
        }
        return String(format: String(localized: "unlock_card_remaining"), state.formattedRemainingHms)
    }

    private var isCooldown: Bool {
        state.cooldownSecondsRemaining > 0
    }

    private var buttonText: String {
        if isCooldown {
            return String(format: String(localized: "unlock_card_button_cooldown"), state.formattedCooldown)
        }
        return String(format: String(localized: "unlock_card_button_extend"), unlockMinutes)
    }

    private func tapExtend() {
        guard !isCooldown else { return }
        Task {
            let ok = await AdManager.shared.showRewardedToUnlock(minutes: unlockMinutes)
            if ok {
                let total = state.formattedRemainingHms
                onToast(String(format: String(localized: "unlock_extended_toast"), unlockMinutes, total))
            }
        }
    }
}

// MARK: - 共享行样式

struct MyRowLabel: View {
    let icon: String
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var subtitleText: String?

    init(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, subtitleText: String? = nil) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.subtitleText = subtitleText
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(WanxiangColors.primary)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(WanxiangColors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary)
                        .lineLimit(2)
                } else if let subtitleText, !subtitleText.isEmpty {
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

#Preview {
    MyView()
}
