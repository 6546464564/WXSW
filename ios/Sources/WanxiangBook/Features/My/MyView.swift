//
//  MyView.swift
//  万象书屋 iOS · "我的" Tab — 1:1 对齐 Android `MyFragment` (D-17/D-18 简化态)
//
//  可见项: 解锁卡 (广告 consent 时) + 跟随系统 / 护眼 / 阅读记录 / 意见反馈 / 下载管理 / 应用伪装
//  隐藏项: 见 MyViewHiddenSections.swift (`MyFeatureFlags.showHiddenItems`)
//

import SwiftUI
import UniformTypeIdentifiers

struct MyView: View {

    @StateObject private var theme = ThemeManager.shared
    @StateObject private var eyeCare = EyeCareModeManager.shared
    @StateObject private var ad = AdManager.shared
    @StateObject private var downloader = BookDownloader.shared

    @State private var unlockToast: String? = nil
    @State private var showRelockConfirm = false

    @State private var showBookSourceImporter = false
    @State private var importSourceMessage: String?

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
                    Toggle(isOn: themeFollowSystemBinding) {
                        MyRowLabel(
                            icon: "circle.lefthalf.filled",
                            title: "my.theme_follow_system",
                            subtitle: "my.theme_follow_system_summary"
                        )
                    }
                    .tint(WanxiangColors.primary)

                    Toggle(isOn: $eyeCare.enabled) {
                        MyRowLabel(
                            icon: "sun.haze",
                            title: "my.eye_care_mode",
                            subtitle: "my.eye_care_mode_summary"
                        )
                    }
                    .tint(WanxiangColors.primary)

                    NavigationLink {
                        ReadRecordView()
                    } label: {
                        MyRowLabel(
                            icon: "clock.arrow.circlepath",
                            title: "my.read_record",
                            subtitle: "my.read_record_summary"
                        )
                    }
                    .accessibilityIdentifier("my.row.read_record")
                    .accessibilityLabel("阅读记录")
                    .accessibilityAddTraits(.isButton)

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

                if MyFeatureFlags.showHiddenItems {
                    MyHiddenItemsPanel(
                        showBookSourceImporter: $showBookSourceImporter,
                        importSourceMessage: $importSourceMessage
                    )
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
            .listSectionSpacing(.compact)
            .fileImporter(
                isPresented: $showBookSourceImporter,
                allowedContentTypes: [UTType.json],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    await MyBookSourceImporter.handle(result) { msg in
                        importSourceMessage = msg
                    }
                }
            }
            .alert(
                String(localized: "my.import_source_title"),
                isPresented: Binding(
                    get: { importSourceMessage != nil },
                    set: { if !$0 { importSourceMessage = nil } }
                )
            ) {
                Button(String(localized: "my.ok"), role: .cancel) {}
            } message: {
                Text(importSourceMessage ?? "")
            }
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

    private var themeFollowSystemBinding: Binding<Bool> {
        Binding(
            get: { theme.mode == .system },
            set: { newValue in theme.mode = newValue ? .system : .day }
        )
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

    @StateObject private var state = PurifiedReadingState.shared
    let onToast: (String) -> Void

    private let unlockMinutes = PurifiedReadingState.defaultUnlockMinutes

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("unlock_card_title")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
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
        .background(Color(red: 0x1A / 255.0, green: 0x1B / 255.0, blue: 0x23 / 255.0))
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

// MARK: - 占位 (ThemeSettingsView 封面规则等)

struct PlaceholderView: View {
    let title: String
    let milestone: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer")
                .font(.system(size: 64))
                .foregroundStyle(WanxiangColors.textSecondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text("待 \(milestone) 实现")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    MyView()
}
