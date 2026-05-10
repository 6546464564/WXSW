//
//  MyView.swift
//  万象书屋 iOS · "我的" Tab — 1:1 对齐 Android `MyFragment` (D-17/D-18 简化态)
//
//  对应 Android: io.legado.app.ui.main.my.MyFragment + pref_main.xml
//
//  布局 (跟 Android D-17 hiddenKeys 隐藏后剩下的 4 项 + 顶部解锁卡 完全一致):
//   ┌─────────────────────────────┐
//   │  解锁状态卡 (cardUnlockStatus)│  ← 仅当广告 SDK consent + 配置开启时显示
//   ├─────────────────────────────┤
//   │  跟随系统           [Switch] │  ← themeFollowSystem
//   │  护眼模式           [Switch] │  ← eyeCareMode (D-18)
//   │  阅读记录              ›     │  ← readRecord
//   │  意见反馈              ›     │  ← legal_feedback
//   ├─────────────────────────────┤
//   │  万象书屋 iOS · vX.Y · build │
//   └─────────────────────────────┘
//
//  Android `hiddenKeys` 列表里的 14 项 (规则系统 / 主题设置 / 文件管理 /
//  关于法律 5 子项 / 注销 / 书签等) 全部按 ShowHiddenItems flag 隐藏, 不
//  删除代码 — 上架前如需放开按 Android `hiddenKeys` 指引去掉对应过滤即可.
//

import SwiftUI
import UniformTypeIdentifiers

struct MyView: View {

    /// 万象书屋: 跟 Android `hiddenKeys` flag 同款 — 上架前合规需要时放开 (变 true)
    /// 当前 false 状态对齐 Android D-17 D-18 当前发布状态.
    private static let showHiddenItems = false

    @EnvironmentObject private var appState: AppState
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var eyeCare = EyeCareModeManager.shared
    @StateObject private var purified = PurifiedReadingState.shared
    @StateObject private var ad = AdManager.shared
    @StateObject private var downloader = BookDownloader.shared

    @State private var unlockToast: String? = nil

    /// 万象书屋 (M2.8 C 档): 下载管理 row 的副标题, 显示当前任务概览
    private var downloadSummarySubtitle: String {
        let running = downloader.jobs.values.filter { $0.status == .running }.count
        let finished = downloader.jobs.values.filter { $0.status == .finished }.count
        if running > 0 {
            return "\(running) 本下载中" + (finished > 0 ? " · \(finished) 已完成" : "")
        } else if finished > 0 {
            return "\(finished) 本已完成"
        }
        return "管理离线下载任务"
    }
    // 万象书屋: 上架合规 / 调试入口 (showHiddenItems = true 时才出现)
    @State private var showBookSourceImporter = false
    @State private var importSourceMessage: String?

    var body: some View {
        NavigationStack {
            List {
                // 1. 顶部解锁卡 — 跟 Android `cardUnlockStatus` 等价 (1:1 对齐).
                //    可见性: ad.consented && ad.enabled (== Android `!effectivelyDisabled && isConsented`)
                //    内容:   "纯净阅读" 标题 / 黄色倒计时 / 主色"看 1 次广告 +N 分钟" 或 灰色冷却
                if ad.consented && ad.enabled {
                    Section {
                        PurifiedReadingCard(onToast: { msg in unlockToast = msg })
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                            .listRowBackground(Color.clear)
                    }
                }

                // 2. 核心 4 项 (Android D-17 当前可见集合)
                Section {
                    // 万象书屋 D-18: 跟 Android themeFollowSystem SwitchPreference 完全等价.
                    //   ON  → ThemeManager.mode = .system  (跟随系统)
                    //   OFF → ThemeManager.mode = .day     (强制亮色, 等价 Android themeMode="1")
                    Toggle(isOn: themeFollowSystemBinding) {
                        rowLabel(
                            icon: "circle.lefthalf.filled",
                            title: "跟随系统",
                            subtitle: "开启后随系统自动切换日间/夜间"
                        )
                    }
                    .tint(WanxiangColors.primary)

                    // 万象书屋 D-18: 护眼模式 SwitchPreference. 全屏暖色滤镜 (#FAF0DC alpha 30%),
                    // RootView 层 wanxiangEyeCareOverlay 注入, 切换即时生效.
                    Toggle(isOn: $eyeCare.enabled) {
                        rowLabel(
                            icon: "sun.haze",
                            title: "护眼模式",
                            subtitle: "全屏暖色滤镜,长时间阅读更舒适"
                        )
                    }
                    .tint(WanxiangColors.primary)

                    NavigationLink {
                        ReadRecordView()
                    } label: {
                        rowLabel(
                            icon: "clock.arrow.circlepath",
                            title: "阅读记录",
                            subtitle: "查看每日阅读时长统计"
                        )
                    }

                    // 万象书屋 (M2.8 C 档): 下载管理入口, 跟 Android `CacheActivity` 等价.
                    NavigationLink {
                        DownloadCenterView()
                    } label: {
                        rowLabel(
                            icon: "arrow.down.circle",
                            title: "下载管理",
                            subtitle: downloadSummarySubtitle
                        )
                    }

                    NavigationLink {
                        FeedbackView()
                    } label: {
                        rowLabel(
                            icon: "bubble.left.and.bubble.right",
                            title: "意见反馈",
                            subtitle: "向我们提建议或报告问题"
                        )
                    }
                }

                // 3. 隐藏项 (showHiddenItems = false 时全部不显示) — 跟 Android `hiddenKeys` 一致.
                //    上架合规放开时改 showHiddenItems = true 即可. 不删代码方便维护.
                if Self.showHiddenItems {
                    hiddenRulesSection
                    hiddenSettingsSection
                    hiddenOtherSection
                    hiddenLegalSection
                }

                // 4. 版本 footer
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text("万象书屋 iOS")
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
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .listSectionSpacing(.compact)
            .fileImporter(
                isPresented: $showBookSourceImporter,
                allowedContentTypes: [UTType.json],
                allowsMultipleSelection: false
            ) { result in
                Task { await handleSourceImport(result) }
            }
            .alert(
                "书源导入",
                isPresented: Binding(
                    get: { importSourceMessage != nil },
                    set: { if !$0 { importSourceMessage = nil } }
                )
            ) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(importSourceMessage ?? "")
            }
            // 万象书屋: unlock_extended_toast — 看完广告解锁成功的提示
            // 跟 Android `act.toastOnUi(getString(R.string.unlock_extended_toast, ...))` 等价
            .alert(
                "纯净阅读",
                isPresented: Binding(
                    get: { unlockToast != nil },
                    set: { if !$0 { unlockToast = nil } }
                )
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(unlockToast ?? "")
            }
        }
    }

    // MARK: - Theme follow-system 双向 binding

    /// 跟 Android `themeFollowPref.setOnPreferenceChangeListener` 等价:
    ///   true  → ThemeManager.mode = .system  (跟随系统)
    ///   false → ThemeManager.mode = .day     (强制亮色, Android themeMode="1")
    /// 老用户旧值 .night 仍可读, 但 UI 简化为单 Toggle 后, 只要切一次开关就同步.
    private var themeFollowSystemBinding: Binding<Bool> {
        Binding(
            get: { theme.mode == .system },
            set: { newValue in theme.mode = newValue ? .system : .day }
        )
    }

    // MARK: - Hidden sections (Android `hiddenKeys` 镜像, showHiddenItems=true 才进入)

    @ViewBuilder
    private var hiddenRulesSection: some View {
        Section {
            NavigationLink { TxtTocRuleListView() } label: {
                rowLabel(icon: "list.bullet.rectangle", title: "TXT 目录规则")
            }
            NavigationLink { ReplaceRuleListView() } label: {
                rowLabel(icon: "arrow.triangle.2.circlepath", title: "替换净化")
            }
            NavigationLink { DictRuleListView() } label: {
                rowLabel(icon: "character.book.closed", title: "词典规则")
            }
        }
    }

    @ViewBuilder
    private var hiddenSettingsSection: some View {
        Section("设置") {
            NavigationLink { ThemeSettingsView() } label: {
                rowLabel(icon: "paintpalette", title: "主题设置")
            }
            NavigationLink { OtherSettingsView() } label: {
                rowLabel(icon: "slider.horizontal.3", title: "其它设置")
            }
            NavigationLink { ReadingPreferencesView() } label: {
                rowLabel(icon: "textformat", title: "阅读偏好")
            }
        }
    }

    @ViewBuilder
    private var hiddenOtherSection: some View {
        Section("其它") {
            Button { showBookSourceImporter = true } label: {
                rowLabel(icon: "square.and.arrow.down.on.square", title: "导入书源 (JSON)")
            }
            NavigationLink { AllBookmarkView() } label: {
                rowLabel(icon: "bookmark", title: "书签")
            }
            NavigationLink { ImportLocalView() } label: {
                rowLabel(icon: "folder", title: "本地导入")
            }
        }
    }

    @ViewBuilder
    private var hiddenLegalSection: some View {
        Section("关于与法律") {
            NavigationLink { AboutView() } label: {
                rowLabel(icon: "info.circle", title: "关于")
            }
            NavigationLink { LegalView(doc: .privacyPolicy) } label: {
                rowLabel(icon: "lock.shield", title: "隐私政策")
            }
            NavigationLink { LegalView(doc: .userAgreement) } label: {
                rowLabel(icon: "doc.text", title: "用户服务协议")
            }
            NavigationLink { LegalView(doc: .collectList) } label: {
                rowLabel(icon: "list.clipboard", title: "个人信息收集清单")
            }
            NavigationLink { LegalView(doc: .sdkList) } label: {
                rowLabel(icon: "shippingbox", title: "第三方 SDK 清单")
            }
            NavigationLink { LegalView(doc: .license) } label: {
                rowLabel(icon: "doc.badge.gearshape", title: "开源协议")
            }
            NavigationLink { AccountDeleteView() } label: {
                rowLabel(icon: "person.crop.circle.badge.xmark", title: "注销账号")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    /// 标准条目: 左 icon + 主 title + 副 subtitle
    /// (跟 Android `Preference.title` + `Preference.summary` 双行布局对齐)
    @ViewBuilder
    private func rowLabel(icon: String, title: String, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(WanxiangColors.primary)
                .frame(width: 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(WanxiangColors.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func handleSourceImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let n = try await BookSourceRegistry.shared.importFromLocalJson(data: data)
                await MainActor.run {
                    importSourceMessage = "已合并导入 \(n) 个书源(与服务器书源共存,仅本地多出的 URL 会保留)"
                }
            } catch {
                await MainActor.run {
                    importSourceMessage = "导入失败:\(error.localizedDescription)"
                }
            }
        case .failure(let err):
            await MainActor.run {
                importSourceMessage = "无法打开文件:\(err.localizedDescription)"
            }
        }
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private func appBuild() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - 解锁状态卡 (1:1 对齐 Android `cardUnlockStatus` + R.layout.fragment_my_config)

/// 跟 Android `cardUnlockStatus` 完全对齐:
///   - 卡片背景: #1A1B23 深色 + 圆角 12dp (cardBackgroundColor / cardCornerRadius)
///   - 标题:    "纯净阅读" 白色 14sp (tvUnlockCardTitle)
///   - 倒计时:  #EACE3F 黄色 18sp 粗体 (tvUnlockCardRemaining)
///              · remainingSeconds > 0 → "剩余 HH:MM:SS"  (string unlock_card_remaining)
///              · remainingSeconds = 0 → "暂无解锁时长"   (string unlock_card_remaining_zero)
///   - 按钮:    主色 / 冷却时灰色 50% alpha + disabled (btnUnlockCardExtend)
///              · 冷却中 → "广告冷却中 MM:SS"  (string unlock_card_button_cooldown)
///              · 可看  → "看 1 次广告 +N 分钟" (string unlock_card_button_extend)
///   - 触发:    AdManager.showRewardedToUnlock — SDK 走完会调 PurifiedReadingState.markRewardedSuccess
///              成功后 toast: "+N 分钟纯净阅读 (累计 HH:MM:SS)" (string unlock_extended_toast)
private struct PurifiedReadingCard: View {

    @StateObject private var state = PurifiedReadingState.shared
    @StateObject private var ad = AdManager.shared
    let onToast: (String) -> Void

    /// Android `placements.rewardedReadingUnlock.unlockMinutes` 默认值 (后端 ad-config 决定).
    /// iOS 拉同样的 /api/ad-config 但当前 AdManager 没暴露 placements 子字段, 先用默认 30.
    private let unlockMinutes = PurifiedReadingState.defaultUnlockMinutes

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 标题: "纯净阅读" 白 14sp
                Text("纯净阅读")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                // 倒计时: 黄 18sp bold
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
                    .background(buttonBackground)
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

    // MARK: - Derived strings (跟 Android string resources 对齐)

    private var remainingText: String {
        if state.remainingSeconds <= 0 {
            // unlock_card_remaining_zero
            return "暂无解锁时长"
        }
        // unlock_card_remaining ("剩余 %1$s")
        return "剩余 \(state.formattedRemainingHms)"
    }

    private var isCooldown: Bool {
        state.cooldownSecondsRemaining > 0
    }

    private var buttonText: String {
        if isCooldown {
            // unlock_card_button_cooldown ("广告冷却中 %1$s")
            return "广告冷却中 \(state.formattedCooldown)"
        }
        // unlock_card_button_extend ("看 1 次广告 +%1$d 分钟")
        return "看 1 次广告 +\(unlockMinutes) 分钟"
    }

    private var buttonBackground: some View {
        // 跟 Android bg_book_finished_button_primary 对齐 — 主色 (棕金)
        WanxiangColors.primary
    }

    // MARK: - Action

    private func tapExtend() {
        guard !isCooldown else { return }
        Task {
            // AdManager 走 SDK; 成功时 PurifiedReadingState.markRewardedSuccess 已被自动调
            let ok = await AdManager.shared.showRewardedToUnlock(minutes: unlockMinutes)
            if ok {
                // unlock_extended_toast ("+%1$d 分钟纯净阅读 (累计 %2$s)")
                let total = state.formattedRemainingHms
                onToast("+\(unlockMinutes) 分钟纯净阅读(累计 \(total))")
            }
        }
    }
}

// MARK: - 关于 (showHiddenItems=true 走这里)

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "book.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(WanxiangColors.primary)
                    .padding(.top, 32)
                Text("万象书屋")
                    .font(.title.weight(.bold))
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0")")
                    .font(.caption)
                    .foregroundStyle(WanxiangColors.textSecondary)

                VStack(spacing: 8) {
                    Text("万象书屋是一款开源的电子书阅读器,基于 GPLv3 协议")
                        .multilineTextAlignment(.center)
                        .font(.subheadline)
                        .foregroundStyle(WanxiangColors.textSecondary)
                    Text("ICP 备案号:待备案")
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary)
                }
                .padding(.horizontal)
                .padding(.top, 16)

                Spacer().frame(height: 40)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 占位

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
        .environmentObject(AppState())
}
