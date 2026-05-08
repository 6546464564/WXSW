//
//  FeedbackView.swift
//  万象书屋 iOS · 意见反馈 — 1:1 对齐 Android `FeedbackActivity` D-16 (L4)
//
//  对应 Android: io.legado.app.ui.about.FeedbackActivity + activity_feedback.xml
//
//  布局 (跟 Android XML 完全对齐):
//   ┌─────────────────────────────┐
//   │  ← 意见反馈                    │  ← 顶部栏 (返回 + 居中标题)
//   ├─────────────────────────────┤
//   │  feedback_intro 多行欢迎语     │
//   │                              │
//   │  我要反馈 (必填)               │
//   │  ┌─────────────────────────┐ │  ← bg_feedback_input #F5F5F5 圆角 10
//   │  │                         │ │
//   │  │                  0/120  │ │  ← 字数计数右下
//   │  └─────────────────────────┘ │
//   │  联系方式 (必填)               │
//   │  ┌─────────────────────────┐ │
//   │  │ 请输入手机号/QQ号         │ │
//   │  └─────────────────────────┘ │
//   │  ╭─────────────────────────╮ │  ← 棕金胶囊
//   │  │       提  交              │ │
//   │  ╰─────────────────────────╯ │
//   │  feedback_legal_notice 灰字   │
//   └─────────────────────────────┘
//
//  关键约束 (跟 Android 完全对齐):
//   - 内容: 必填, 5-120 字 (Android MIN/MAX)
//   - 联系方式: 必填 (旧 iOS 是选填, 这次改成必填)
//   - type 字段固定 "suggest" (旧 iOS 4 选 picker, Android 已下线类型选择)
//

import SwiftUI

struct FeedbackView: View {

    private static let minContent = 5      // 跟 Android MIN_CONTENT
    private static let maxContent = 120    // 跟 Android MAX_CONTENT

    @Environment(\.dismiss) private var dismiss

    @State private var content: String = ""
    @State private var contact: String = ""
    @State private var isSubmitting = false
    @State private var resultAlert: AlertItem?

    private struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let dismissOnOK: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 1. 欢迎说明
                Text(introText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0x55/255.0, green: 0x55/255.0, blue: 0x55/255.0))
                    .lineSpacing(4)
                    .padding(.top, 20)

                // 2. 我要反馈 (必填)
                sectionHeader(title: "我要反馈")
                    .padding(.top, 28)

                ZStack(alignment: .bottomTrailing) {
                    TextEditor(text: Binding(
                        get: { content },
                        set: { content = String($0.prefix(Self.maxContent)) }
                    ))
                    .scrollContentBackground(.hidden)
                    .frame(height: 170)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
                    .background(feedbackInputBg)
                    .overlay(alignment: .topLeading) {
                        if content.isEmpty {
                            Text("为更好解决您遇到的问题,请尽量将问题描述详细")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(red: 0xA0/255.0, green: 0xA0/255.0, blue: 0xA0/255.0))
                                .padding(.top, 16)
                                .padding(.leading, 18)
                                .allowsHitTesting(false)
                        }
                    }

                    Text("\(content.count)/\(Self.maxContent)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0xA0/255.0, green: 0xA0/255.0, blue: 0xA0/255.0))
                        .padding(.trailing, 14)
                        .padding(.bottom, 10)
                }
                .padding(.top, 12)

                // 3. 联系方式 (必填)
                sectionHeader(title: "联系方式")
                    .padding(.top, 28)

                TextField("请输入手机号/QQ号", text: $contact)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 0x22/255.0, green: 0x22/255.0, blue: 0x22/255.0))
                    .frame(height: 50)
                    .padding(.horizontal, 14)
                    .background(feedbackInputBg)
                    .padding(.top, 12)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)

                // 4. 提交按钮 (棕金胶囊)
                Button(action: { Task { await submit() } }) {
                    HStack {
                        Spacer()
                        if isSubmitting {
                            ProgressView().tint(.white)
                        } else {
                            Text("提交")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .frame(height: 50)
                    .background(submitButtonBg)
                    .clipShape(Capsule())
                }
                .disabled(!canSubmit || isSubmitting)
                .padding(.top, 36)

                // 5. legal notice
                Text("本反馈不收集您的真实身份信息. 提交即表示您同意我们将所提供内容用于产品改进与内容审核.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0xB0/255.0, green: 0xB0/255.0, blue: 0xB0/255.0))
                    .lineSpacing(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
        }
        .background(Color.white.ignoresSafeArea())
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

    // MARK: - Subviews

    private func sectionHeader(title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(red: 0x22/255.0, green: 0x22/255.0, blue: 0x22/255.0))
            Text("(必填)")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0x99/255.0, green: 0x99/255.0, blue: 0x99/255.0))
        }
    }

    /// bg_feedback_input.xml 等价: #F5F5F5 圆角 10dp
    private var feedbackInputBg: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(red: 0xF5/255.0, green: 0xF5/255.0, blue: 0xF5/255.0))
    }

    /// bg_feedback_submit.xml 等价: WanxiangColors.primary (#B8956B), disabled 时 50% alpha
    private var submitButtonBg: some View {
        WanxiangColors.primary.opacity(canSubmit ? 1.0 : 0.5)
    }

    // MARK: - Validation (跟 Android `submit` 顺序对齐)

    private var canSubmit: Bool {
        let len = content.trimmingCharacters(in: .whitespacesAndNewlines).count
        let contactLen = contact.trimmingCharacters(in: .whitespacesAndNewlines).count
        return len >= Self.minContent
            && len <= Self.maxContent
            && contactLen > 0
    }

    private func submit() async {
        let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let ct = contact.trimmingCharacters(in: .whitespacesAndNewlines)

        // 跟 Android `submit()` 校验顺序一致
        if c.isEmpty {
            resultAlert = .init(title: "提示", message: "请填写您的反馈内容", dismissOnOK: false); return
        }
        if c.count < Self.minContent {
            resultAlert = .init(title: "提示", message: "反馈内容太短(至少 \(Self.minContent) 字)", dismissOnOK: false); return
        }
        if c.count > Self.maxContent {
            resultAlert = .init(title: "提示", message: "反馈内容超长(最多 \(Self.maxContent) 字)", dismissOnOK: false); return
        }
        if ct.isEmpty {
            resultAlert = .init(title: "提示", message: "请填写联系方式,我们才能回复您", dismissOnOK: false); return
        }

        WanxiangAnalytics.shared.track("feedback_submit", type: "click")
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let ok = try await WanxiangAPI.shared.submitFeedback(
                type: "suggest",   // 跟 Android 同步 — 类型已下线, 固定 suggest
                content: c,
                contact: ct
            )
            if ok {
                resultAlert = .init(title: "已收到", message: "感谢您的反馈,我们会尽快处理。", dismissOnOK: true)
            } else {
                resultAlert = .init(title: "提交失败", message: "服务器拒绝,请稍后重试。", dismissOnOK: false)
            }
        } catch {
            resultAlert = .init(title: "网络错误", message: error.localizedDescription, dismissOnOK: false)
        }
    }

    // MARK: - Strings (跟 Android strings.xml 原文对齐)

    private var introText: String {
        // feedback_intro
        "您好!欢迎您给我们提出使用中遇到的问题或意见!\n请详细描述您遇到的问题:比如 哪本小说无法阅读或者其他问题!\n请勿提交恶意谩骂以及反动词语! 谢谢~"
    }
}

#Preview {
    NavigationStack { FeedbackView() }
}
