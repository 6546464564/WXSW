//
//  AccountDeleteView.swift
//  万象书屋 iOS · 注销账号 / 清空我的数据 (M2.10.8)
//
//  对应 Android: io.legado.app.ui.about.AccountDeleteActivity
//
//  PIPL / GDPR 必备入口. 流程:
//   1. 用户进入页面 → 看到将清空哪些数据的列表
//   2. 二次确认 alert
//   3. 调 /api/me/wipe-data 清远端 (失败也继续, 因为本地是关键)
//   4. 清本地 SQLite (DB.wipeAll)
//   5. 清 Keychain (设备 token / device_id)
//   6. 清 UserDefaults (除主题模式外, 让用户进来不重新引导)
//   7. 清 ad consent (PurifiedReadingState.wipe)
//   8. 跳到 AccountDeleteFinishedView 提示用户重启 App
//

import SwiftUI

struct AccountDeleteView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var confirmAlert = false
    @State private var isWiping = false
    @State private var wipeResult: WipeResult? = nil
    @State private var navigateToFinished = false

    struct WipeResult: Identifiable {
        let id = UUID()
        let serverOK: Bool
        let localOK: Bool
        var allOK: Bool { serverOK && localOK }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 警告头
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("重要操作:不可恢复")
                            .font(.headline)
                        Text("点击「确认清空」后,以下数据将彻底删除,无法找回:")
                            .font(.subheadline)
                            .foregroundStyle(WanxiangColors.textSecondary)
                    }
                }
                .padding()
                .background(.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // 清空范围说明
                VStack(alignment: .leading, spacing: 12) {
                    bulletItem(icon: "books.vertical", text: "本地书架的所有书籍、章节缓存")
                    bulletItem(icon: "bookmark", text: "全部书签和阅读进度")
                    bulletItem(icon: "magnifyingglass", text: "搜索历史")
                    bulletItem(icon: "list.bullet.rectangle", text: "本地添加的所有规则(替换/词典/TXT 目录)")
                    bulletItem(icon: "icloud.slash", text: "服务器上跟本设备绑定的所有记录(心跳/广告事件/反馈)")
                    bulletItem(icon: "key", text: "设备身份 token、广告同意状态")
                }
                .padding()
                .background(WanxiangColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // 不影响项
                VStack(alignment: .leading, spacing: 8) {
                    Text("不会影响:")
                        .font(.subheadline.weight(.semibold))
                    bulletItem(icon: "circle.lefthalf.filled", text: "App 主题偏好(下次进来仍是您选的暗/亮模式)", color: WanxiangColors.textSecondary)
                    bulletItem(icon: "checkmark.shield", text: "您从未提供过的真实身份信息(我们从来没收过)", color: WanxiangColors.textSecondary)
                }
                .padding()

                Spacer().frame(height: 16)

                // 操作按钮
                Button(role: .destructive) {
                    confirmAlert = true
                } label: {
                    HStack {
                        Spacer()
                        if isWiping {
                            ProgressView().tint(.white)
                            Text("正在清空…").foregroundStyle(.white)
                        } else {
                            Text("确认清空所有数据").font(.headline.weight(.semibold))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(.red)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isWiping)
                .padding(.horizontal)
            }
            .padding()
        }
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("注销账号")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToFinished) {
            AccountDeleteFinishedView(result: wipeResult)
        }
        .alert("确认清空所有数据?", isPresented: $confirmAlert) {
            Button("取消", role: .cancel) {}
            Button("彻底清空", role: .destructive) {
                Task { await performWipe() }
            }
        } message: {
            Text("此操作不可撤销。请最后确认。")
        }
    }

    private func bulletItem(icon: String, text: String, color: Color = WanxiangColors.textPrimary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color == WanxiangColors.textSecondary ? color : WanxiangColors.primary)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(color)
            Spacer(minLength: 0)
        }
    }

    private func performWipe() async {
        isWiping = true
        defer { isWiping = false }

        // 1. 服务端清 (失败不阻塞本地)
        let serverOK = (try? await WanxiangAPI.shared.wipeServerData()) ?? false

        // 2. 本地 SQLite 清
        let localDBOK: Bool = await {
            do {
                try await DB.shared.wipeAll()
                return true
            } catch {
                return false
            }
        }()

        // 3. Keychain 清
        Keychain.wipeAll()

        // 4. 纯净阅读状态清
        await MainActor.run {
            PurifiedReadingState.shared.wipe()
        }

        // 5. UserDefaults 关键键清空 (保留主题偏好)
        let defaults = UserDefaults.standard
        for key in [
            "wanxiang.search.history",
            "wanxiang.pending_crash",
            "wanxiang.purified.unlock_until",
        ] {
            defaults.removeObject(forKey: key)
        }

        wipeResult = WipeResult(serverOK: serverOK, localOK: localDBOK)
        navigateToFinished = true
    }
}

// MARK: - 完成页

struct AccountDeleteFinishedView: View {
    let result: AccountDeleteView.WipeResult?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)
                .padding(.top, 60)

            Text("数据已清空")
                .font(.title.weight(.bold))

            VStack(spacing: 8) {
                if let r = result {
                    statusLine(label: "本地数据库", ok: r.localOK)
                    statusLine(label: "服务器数据", ok: r.serverOK)
                }
            }
            .padding()
            .background(WanxiangColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)

            Text("建议您手动关闭 App 后重新打开,App 将恢复到初次安装状态。")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("注销完成")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private func statusLine(label: String, ok: Bool) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            if ok {
                Label("成功", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                Label("部分失败", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            }
        }
    }
}

#Preview {
    NavigationStack { AccountDeleteView() }
}
