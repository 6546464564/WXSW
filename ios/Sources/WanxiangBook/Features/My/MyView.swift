//
//  MyView.swift
//  万象书屋 iOS · "我的" Tab (M2.1.4)
//
//  对应 Android: io.legado.app.ui.main.my.MyFragment + MyPreferenceFragment + pref_main.xml
//
//  布局结构 (1:1 对齐 Android):
//   ┌─────────────────────────────┐
//   │  纯净阅读卡片 (顶部, 倒计时)    │  ← M2.1.5
//   ├─────────────────────────────┤
//   │  TXT 目录规则               │
//   │  替换净化                   │
//   │  词典规则                   │
//   │  主题模式 (随系统/日/夜)     │  ← M2.1.6
//   ├──── 设置 ────────────────────┤
//   │  主题设置                   │
//   │  其它设置                   │
//   ├──── 其它 ────────────────────┤
//   │  书签                       │
//   │  阅读记录                   │
//   │  文件管理                   │
//   ├──── 关于与法律 ──────────────┤
//   │  关于                       │
//   │  隐私政策                   │
//   │  用户协议                   │
//   │  个人信息收集清单            │
//   │  第三方 SDK 清单            │
//   │  开源协议                   │
//   │  反馈                       │
//   │  注销账号                   │
//   └─────────────────────────────┘
//

import SwiftUI
import UniformTypeIdentifiers

struct MyView: View {

    @EnvironmentObject private var appState: AppState
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var purified = PurifiedReadingState.shared
    @State private var showBookSourceImporter = false
    @State private var importSourceMessage: String?

    var body: some View {
        NavigationStack {
            List {
                // 1. 纯净阅读卡片
                Section {
                    PurifiedReadingCard()
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowBackground(Color.clear)
                }

                // 2. 规则系统
                Section {
                    NavigationLink {
                        TxtTocRuleListView()
                    } label: {
                        rowLabel(icon: "list.bullet.rectangle", title: "TXT 目录规则")
                    }
                    NavigationLink {
                        ReplaceRuleListView()
                    } label: {
                        rowLabel(icon: "arrow.triangle.2.circlepath", title: "替换净化")
                    }
                    NavigationLink {
                        DictRuleListView()
                    } label: {
                        rowLabel(icon: "character.book.closed", title: "词典规则")
                    }
                    // 主题模式: 内嵌 Picker
                    Picker(selection: $theme.mode) {
                        ForEach(ThemeManager.Mode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    } label: {
                        rowLabel(icon: "circle.lefthalf.filled", title: "主题模式")
                    }
                    .pickerStyle(.menu)
                }

                // 3. 设置
                Section("设置") {
                    NavigationLink {
                        ThemeSettingsView()
                    } label: {
                        rowLabel(icon: "paintpalette", title: "主题设置")
                    }
                    NavigationLink {
                        OtherSettingsView()
                    } label: {
                        rowLabel(icon: "slider.horizontal.3", title: "其它设置")
                    }
                    NavigationLink {
                        ReadingPreferencesView()
                    } label: {
                        rowLabel(icon: "textformat", title: "阅读偏好")
                    }
                }

                // 4. 其它
                Section("其它") {
                    Button {
                        showBookSourceImporter = true
                    } label: {
                        rowLabel(icon: "square.and.arrow.down.on.square", title: "导入书源 (JSON)")
                    }
                    NavigationLink {
                        AllBookmarkView()
                    } label: {
                        rowLabel(icon: "bookmark", title: "书签")
                    }
                    NavigationLink {
                        ReadRecordView()
                    } label: {
                        rowLabel(icon: "clock.arrow.circlepath", title: "阅读记录")
                    }
                    NavigationLink {
                        ImportLocalView()
                    } label: {
                        rowLabel(icon: "folder", title: "本地导入")
                    }
                }

                // 5. 关于与法律
                Section("关于与法律") {
                    NavigationLink {
                        AboutView()
                    } label: {
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
                    NavigationLink {
                        FeedbackView()
                    } label: {
                        rowLabel(icon: "bubble.left.and.bubble.right", title: "意见反馈")
                    }
                    NavigationLink {
                        AccountDeleteView()
                    } label: {
                        rowLabel(icon: "person.crop.circle.badge.xmark", title: "注销账号")
                            .foregroundStyle(.red)
                    }
                }

                // 6. 版本信息 (footer)
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
            // 万象书屋: 收紧顶部空白 — large 标题在底部 tab 容器下占 96pt 太空
            .navigationBarTitleDisplayMode(.inline)
            // 万象书屋: List section 之间默认间距 35pt 偏宽, 改 compact 收到 ~14pt
            .listSectionSpacing(.compact)
            .fileImporter(
                isPresented: $showBookSourceImporter,
                allowedContentTypes: [UTType.json],
                allowsMultipleSelection: false
            ) { result in
                Task {
                    switch result {
                    case .success(let urls):
                        guard let url = urls.first else { return }
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        do {
                            let data = try Data(contentsOf: url)
                            let n = try await BookSourceRegistry.shared.importFromLocalJson(data: data)
                            await MainActor.run {
                                importSourceMessage = "已合并导入 \(n) 个书源（与服务器书源共存，仅本地多出的 URL 会保留）"
                            }
                        } catch {
                            await MainActor.run {
                                importSourceMessage = "导入失败：\(error.localizedDescription)"
                            }
                        }
                    case .failure(let err):
                        await MainActor.run {
                            importSourceMessage = "无法打开文件：\(err.localizedDescription)"
                        }
                    }
                }
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
        }
    }

    private func rowLabel(icon: String, title: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(WanxiangColors.primary)
        }
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private func appBuild() -> String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - 纯净阅读卡片

private struct PurifiedReadingCard: View {

    @StateObject private var state = PurifiedReadingState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("纯净阅读", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if state.isActive {
                    Text(state.formattedRemaining)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white)
                }
            }

            if state.isActive {
                Text("当前已解锁,享受无广告阅读")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                Button {
                    // M2.5.8 接激励视频; M2.1 阶段 mock 加 30 分钟
                    state.extendUnlock(byMinutes: 30)
                } label: {
                    Text("延长 30 分钟")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.25))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            } else {
                Text("看一段广告解锁 30 分钟无广告体验")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                Button {
                    state.extendUnlock(byMinutes: 30)
                } label: {
                    Label("看广告解锁", systemImage: "play.rectangle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.25))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [WanxiangColors.primary, WanxiangColors.accent],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - 关于页

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

                    // 万象书屋: ICP 备案号 (备案下来后填)
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

// MARK: - 占位 View (其它子页面 M2 阶段陆续做)

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
