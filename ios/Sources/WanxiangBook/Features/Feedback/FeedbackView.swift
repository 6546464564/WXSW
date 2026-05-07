//
//  FeedbackView.swift
//  万象书屋 iOS · 反馈页 (M2.10.7)
//
//  对应 Android: io.legado.app.ui.about.FeedbackActivity
//
//  规则 (1:1 对齐 Android):
//   - type: bug / content / suggest / other
//   - content: 5-2000 字符
//   - contact: 选填邮箱/QQ
//

import SwiftUI

struct FeedbackView: View {

    enum FeedbackType: String, CaseIterable, Identifiable {
        case bug = "bug"
        case content = "content"
        case suggest = "suggest"
        case other = "other"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .bug: return "应用 Bug"
            case .content: return "内容举报"
            case .suggest: return "功能建议"
            case .other: return "其它"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    @State private var type: FeedbackType = .bug
    @State private var content: String = ""
    @State private var contact: String = ""
    @State private var isSubmitting = false
    @State private var resultAlert: AlertItem? = nil

    /// 简单的 alert 包装,SwiftUI 用 Identifiable
    private struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let dismissOnOK: Bool
    }

    var body: some View {
        Form {
            Section("反馈类型") {
                Picker("类型", selection: $type) {
                    ForEach(FeedbackType.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ZStack(alignment: .topLeading) {
                    if content.isEmpty {
                        Text("请详细描述您遇到的问题或建议(5-2000 字)")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                    }
                    TextEditor(text: $content)
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                }

                HStack {
                    Spacer()
                    Text("\(content.count)/2000")
                        .font(.caption)
                        .foregroundStyle(content.count > 2000 ? .red : .secondary)
                }
            } header: {
                Text("详细描述")
            } footer: {
                Text("提交后我们会在 1-3 个工作日内处理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("邮箱 / QQ(选填)", text: $contact)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("联系方式(选填,留下我们才能回复您)")
            } footer: {
                Text("不填我们也会处理,但无法回复您。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Text("提交反馈")
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(canSubmit ? WanxiangColors.primary : WanxiangColors.divider)
                .disabled(!canSubmit || isSubmitting)
            }
        }
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("意见反馈")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $resultAlert) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("好的")) {
                    if item.dismissOnOK { dismiss() }
                }
            )
        }
    }

    private var canSubmit: Bool {
        let len = content.trimmingCharacters(in: .whitespacesAndNewlines).count
        return len >= 5 && len <= 2000
    }

    private func submit() async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let ok = try await WanxiangAPI.shared.submitFeedback(
                type: type.rawValue,
                content: trimmed,
                contact: contact.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if ok {
                resultAlert = AlertItem(
                    title: "已提交",
                    message: "感谢您的反馈,我们会尽快处理。",
                    dismissOnOK: true
                )
            } else {
                resultAlert = AlertItem(
                    title: "提交失败",
                    message: "服务器拒绝,请稍后重试。",
                    dismissOnOK: false
                )
            }
        } catch {
            resultAlert = AlertItem(
                title: "网络错误",
                message: "\(error.localizedDescription)",
                dismissOnOK: false
            )
        }
    }
}

#Preview {
    NavigationStack { FeedbackView() }
}
