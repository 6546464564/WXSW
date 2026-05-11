//
//  ThemeSettingsView.swift
//  万象书屋 iOS · 主题设置 (M2.10.2)
//
//  对应 Android: pref_config_theme.xml (~15 项)
//

import SwiftUI
import SQLite3

struct ThemeSettingsView: View {
    @StateObject private var theme = ThemeManager.shared
    @AppStorage("wanxiang.ui.scale") private var uiScale: Double = 1.0
    @AppStorage("wanxiang.ui.immersiveStatusBar") private var immersiveStatusBar: Bool = false

    var body: some View {
        Form {
            Section("主题模式") {
                Picker("主题", selection: $theme.mode) {
                    ForEach(ThemeManager.Mode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("界面") {
                HStack {
                    Text("界面字号比例")
                    Slider(value: $uiScale, in: 0.85...1.3, step: 0.05)
                        .tint(WanxiangColors.primary)
                    Text(String(format: "%.2g", uiScale))
                        .font(.caption.monospacedDigit())
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle("沉浸式状态栏", isOn: $immersiveStatusBar)
            }

            Section("配色预览") {
                HStack(spacing: 12) {
                    colorChip("主色", color: WanxiangColors.primary)
                    colorChip("强调", color: WanxiangColors.accent)
                    colorChip("背景", color: WanxiangColors.background)
                    colorChip("卡片", color: WanxiangColors.card)
                }
            }

            Section {
                NavigationLink {
                    PlaceholderView(title: "封面规则", milestone: "M2.10.3")
                } label: {
                    Label("封面规则", systemImage: "photo")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("主题设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func colorChip(_ label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Circle().fill(color).frame(width: 32, height: 32)
                .overlay(Circle().stroke(WanxiangColors.divider, lineWidth: 1))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 其它设置 (M2.10.4)

struct OtherSettingsView: View {
    @AppStorage("wanxiang.startup.openLastBook") private var openLastBook: Bool = false
    @AppStorage("wanxiang.startup.refreshShelf") private var autoRefreshShelf: Bool = true
    @AppStorage("wanxiang.shelf.preloadCovers") private var preloadCovers: Bool = false
    @AppStorage("wanxiang.shelf.wifiOnlyCovers") private var wifiOnlyCovers: Bool = true
    @AppStorage("wanxiang.cache.maxImages") private var maxImages: Int = 200
    @AppStorage("wanxiang.cache.preDownloadChapters") private var preDownloadChapters: Int = 3
    @AppStorage("wanxiang.cache.expireDays") private var expireDays: Int = 90
    @AppStorage("wanxiang.read.defaultEnableReplace") private var defaultEnableReplace: Bool = true
    /// 对齐 Android `pref_config_read` · 自动换源 (无源 / 正文失败时尝试其它书源)
    @AppStorage("wanxiang.read.auto_change_source") private var autoChangeSource: Bool = true
    @AppStorage("wanxiang.ui.showMangaEntry") private var showMangaEntry: Bool = false
    @AppStorage("wanxiang.audio.autoFocus") private var audioAutoFocus: Bool = true
    @AppStorage("wanxiang.audio.bluetoothOnExit") private var bluetoothOnExit: Bool = false
    @AppStorage("wanxiang.bg.thread") private var threadCount: Int = 8
    @AppStorage("wanxiang.bg.useSystemTextMenu") private var useSystemTextMenu: Bool = true
    @AppStorage("wanxiang.bg.logEnabled") private var logEnabled: Bool = false

    @State private var clearCacheConfirm = false
    @State private var compactDBConfirm = false

    var body: some View {
        Form {
            Section("启动") {
                Toggle("启动时打开上次阅读", isOn: $openLastBook)
                Toggle("启动时刷新书架", isOn: $autoRefreshShelf)
            }
            Section("书架") {
                Toggle("预加载封面", isOn: $preloadCovers)
                Toggle("仅 WiFi 加载封面", isOn: $wifiOnlyCovers)
            }
            Section("缓存") {
                Stepper("最大图片缓存:\(maxImages) 张", value: $maxImages, in: 50...1000, step: 50)
                Stepper("预下载章节数:\(preDownloadChapters)", value: $preDownloadChapters, in: 0...10)
                Stepper("过期清理:\(expireDays) 天", value: $expireDays, in: 7...365, step: 7)
                Button("清理缓存", role: .destructive) {
                    clearCacheConfirm = true
                }
                Button("压缩数据库") {
                    compactDBConfirm = true
                }
            }
            Section(header: Text("阅读"), footer: Text("自动换源对齐阅读 Legado:找不到书源或本章正文失败时静默尝试其它源;关闭后仅可手动换源。").font(.caption)) {
                Toggle("自动换源", isOn: $autoChangeSource)
                Toggle("默认启用替换规则", isOn: $defaultEnableReplace)
                Toggle("使用系统选词菜单", isOn: $useSystemTextMenu)
                Toggle("显示漫画入口", isOn: $showMangaEntry)
            }
            Section("音频") {
                Toggle("自动获取焦点(暂停其它音乐)", isOn: $audioAutoFocus)
                Toggle("蓝牙断开时退出播放", isOn: $bluetoothOnExit)
            }
            Section("性能") {
                Stepper("后台线程数:\(threadCount)", value: $threadCount, in: 2...16)
                Toggle("详细日志(排错用)", isOn: $logEnabled)
            }
            Section("广告") {
                NavigationLink {
                    AdConsentManageView()
                } label: {
                    Label("个性化广告管理", systemImage: "shield.lefthalf.filled")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("其它设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("清理所有图片/章节缓存?", isPresented: $clearCacheConfirm) {
            Button("取消", role: .cancel) {}
            Button("清", role: .destructive) {
                Task {
                    URLCache.shared.removeAllCachedResponses()
                }
            }
        }
        .alert("压缩 SQLite (VACUUM)?", isPresented: $compactDBConfirm) {
            Button("取消", role: .cancel) {}
            Button("压缩") {
                Task {
                    try? await DB.shared.execQuery { handle in
                        sqlite3_exec(handle, "VACUUM", nil, nil, nil)
                    }
                }
            }
        }
    }
}

// MARK: - 个性化广告管理 (PIPL 撤回入口)

struct AdConsentManageView: View {
    @StateObject private var ad = AdManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("接收个性化广告", isOn: Binding(
                    get: { ad.consented },
                    set: { newVal in
                        Task {
                            if newVal { await ad.setConsent(true) }
                            else { ad.revokeConsent() }
                        }
                    }
                ))
            } footer: {
                Text("根据《个人信息保护法》(PIPL),您可以随时关闭个性化广告。关闭后我们仍可能展示广告,但不会基于您的兴趣定制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("当前状态") {
                LabeledContent("同意状态", value: ad.consented ? "已同意" : "未同意")
                LabeledContent("SDK 初始化", value: ad.bootstrapped ? "已就绪" : "未初始化")
            }
        }
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("个性化广告")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 阅读偏好(独立入口,跟阅读器内 ReadStyleSheet 共用 ReadConfig)

struct ReadingPreferencesView: View {
    var body: some View {
        ReadStyleSheet()
            .navigationTitle("阅读偏好")
            .navigationBarTitleDisplayMode(.inline)
    }
}
