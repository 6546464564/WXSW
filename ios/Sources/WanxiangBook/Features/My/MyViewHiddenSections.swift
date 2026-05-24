//
//  MyViewHiddenSections.swift
//  万象书屋 iOS ·「我的」隐藏菜单 (Android hiddenKeys 镜像)
//
//  showHiddenItems = false 时整文件不参与 UI; 上架合规放开时改 MyFeatureFlags.showHiddenItems.
//

import SwiftUI
import UniformTypeIdentifiers

/// 跟 Android `MyFragment.hiddenKeys` 对齐 — 上架前按需改为 true.
enum MyFeatureFlags {
    static let showHiddenItems = false
}

/// Android hiddenKeys 对应的全部隐藏入口 (规则 / 设置 / 法律 / 书源导入等).
struct MyHiddenItemsPanel: View {

    @Binding var showBookSourceImporter: Bool
    @Binding var importSourceMessage: String?

    var body: some View {
        hiddenRulesSection
        hiddenSettingsSection
        hiddenOtherSection
        hiddenLegalSection
    }

    @ViewBuilder
    private var hiddenRulesSection: some View {
        Section {
            NavigationLink { TxtTocRuleListView() } label: {
                MyRowLabel(icon: "list.bullet.rectangle", title: "TXT 目录规则")
            }
            NavigationLink { ReplaceRuleListView() } label: {
                MyRowLabel(icon: "arrow.triangle.2.circlepath", title: "替换净化")
            }
            NavigationLink { DictRuleListView() } label: {
                MyRowLabel(icon: "character.book.closed", title: "词典规则")
            }
        }
    }

    @ViewBuilder
    private var hiddenSettingsSection: some View {
        Section("设置") {
            NavigationLink { ThemeSettingsView() } label: {
                MyRowLabel(icon: "paintpalette", title: "主题设置")
            }
            NavigationLink { OtherSettingsView() } label: {
                MyRowLabel(icon: "slider.horizontal.3", title: "其它设置")
            }
            NavigationLink { ReadingPreferencesView() } label: {
                MyRowLabel(icon: "textformat", title: "阅读偏好")
            }
        }
    }

    @ViewBuilder
    private var hiddenOtherSection: some View {
        Section("其它") {
            Button { showBookSourceImporter = true } label: {
                MyRowLabel(icon: "square.and.arrow.down.on.square", title: "导入书源 (JSON)")
            }
            NavigationLink { AllBookmarkView() } label: {
                MyRowLabel(icon: "bookmark", title: "书签")
            }
            NavigationLink { ImportLocalView() } label: {
                MyRowLabel(icon: "folder", title: "本地导入")
            }
            NavigationLink { DownloadCenterView() } label: {
                MyRowLabel(icon: "arrow.down.circle", title: "my.download_manage")
            }
            NavigationLink { CacheView() } label: {
                MyRowLabel(icon: "internaldrive", title: "缓存管理")
            }
        }
    }

    @ViewBuilder
    private var hiddenLegalSection: some View {
        Section("关于与法律") {
            NavigationLink { AboutView() } label: {
                MyRowLabel(icon: "info.circle", title: "关于")
            }
            NavigationLink { LegalView(doc: .privacyPolicy) } label: {
                MyRowLabel(icon: "lock.shield", title: "隐私政策")
            }
            NavigationLink { LegalView(doc: .userAgreement) } label: {
                MyRowLabel(icon: "doc.text", title: "用户服务协议")
            }
            NavigationLink { LegalView(doc: .collectList) } label: {
                MyRowLabel(icon: "list.clipboard", title: "个人信息收集清单")
            }
            NavigationLink { LegalView(doc: .sdkList) } label: {
                MyRowLabel(icon: "shippingbox", title: "第三方 SDK 清单")
            }
            NavigationLink { LegalView(doc: .license) } label: {
                MyRowLabel(icon: "doc.badge.gearshape", title: "开源协议")
            }
            NavigationLink { AccountDeleteView() } label: {
                MyRowLabel(icon: "person.crop.circle.badge.xmark", title: "注销账号")
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - 关于

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

// MARK: - 书源导入

enum MyBookSourceImporter {
    static func handle(_ result: Result<[URL], Error>, importMessage: @escaping (String) -> Void) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let n = try await BookSourceRegistry.shared.importFromLocalJson(data: data)
                await MainActor.run {
                    importMessage(String(format: String(localized: "my.import_source_success"), n))
                }
            } catch {
                await MainActor.run {
                    importMessage(String(format: String(localized: "my.import_source_failed"), error.localizedDescription))
                }
            }
        case .failure(let err):
            await MainActor.run {
                importMessage(String(format: String(localized: "my.import_source_open_failed"), err.localizedDescription))
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
