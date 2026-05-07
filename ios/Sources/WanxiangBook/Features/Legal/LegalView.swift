//
//  LegalView.swift
//  万象书屋 iOS · 法律文档展示 (M2.10.6)
//
//  对应 Android: io.legado.app.ui.about.LegalActivity
//
//  渲染 5 份 markdown:
//   - userAgreement.md     用户协议
//   - privacyPolicy.md     隐私政策
//   - collectList.md       个人信息收集清单 (PIPL)
//   - sdkList.md           第三方 SDK 清单 (注意: 这份要改写成 iOS SDK,M3 阶段做)
//   - license.md           开源协议
//
//  iOS 15+ 的 AttributedString.init(markdown:) 已经支持基础 markdown,不需要第三方库
//

import SwiftUI

/// 法律文档枚举 (路径白名单, 对应 Android LegalActivity 内的 path 校验)
enum LegalDoc: String, CaseIterable, Identifiable {
    case userAgreement = "userAgreement"
    case privacyPolicy = "privacyPolicy"
    case collectList = "collectList"
    case sdkList = "sdkList"
    case license = "license"

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .userAgreement: return "用户服务协议"
        case .privacyPolicy: return "隐私政策"
        case .collectList: return "个人信息收集清单"
        case .sdkList: return "第三方 SDK 清单"
        case .license: return "开源协议"
        }
    }

    var fileName: String { "\(rawValue).md" }
}

struct LegalView: View {

    let doc: LegalDoc

    @State private var content: String = ""
    @State private var loadError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let err = loadError {
                    Text("加载失败:\(err)")
                        .foregroundStyle(.red)
                        .padding()
                } else if content.isEmpty {
                    ProgressView().padding()
                } else {
                    // 万象书屋: AttributedString init(markdown:) 是 iOS 15+ 系统能力,
                    // 不支持复杂表格 / 列表嵌套, 但够覆盖我们 5 份合规文档
                    renderMarkdown(content)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(doc.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .background(WanxiangColors.background.ignoresSafeArea())
        .task { load() }
    }

    private func load() {
        // 先从主 bundle 读, 失败则报错
        if let url = Bundle.main.url(forResource: doc.rawValue, withExtension: "md", subdirectory: "legal")
            ?? Bundle.main.url(forResource: doc.rawValue, withExtension: "md") {
            do {
                content = try String(contentsOf: url, encoding: .utf8)
            } catch {
                loadError = "\(error)"
            }
        } else {
            loadError = "找不到资源 \(doc.fileName)"
        }
    }

    /// 简单 markdown 渲染:按行拆 → 识别 # / ## / ### / ** 等
    /// 系统的 AttributedString(markdown:) 不支持 # 标题,我们手动处理
    @ViewBuilder
    private func renderMarkdown(_ md: String) -> some View {
        let blocks = md.split(separator: "\n", omittingEmptySubsequences: false)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, line in
                renderLine(String(line))
            }
        }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2)))
                .font(.title.weight(.bold))
                .foregroundStyle(WanxiangColors.primary)
                .padding(.top, 8)
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3)))
                .font(.title2.weight(.semibold))
                .foregroundStyle(WanxiangColors.textPrimary)
                .padding(.top, 6)
        } else if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4)))
                .font(.title3.weight(.semibold))
                .foregroundStyle(WanxiangColors.textPrimary)
                .padding(.top, 4)
        } else if line.isEmpty {
            // 空行 → 8pt 间距
            Spacer().frame(height: 4)
        } else {
            // 普通段落: 用 AttributedString(markdown:) 处理 inline ** _ [link] 等
            if let attr = try? AttributedString(
                markdown: line,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attr)
                    .foregroundStyle(WanxiangColors.textPrimary)
                    .lineSpacing(3)
            } else {
                Text(line)
                    .foregroundStyle(WanxiangColors.textPrimary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        LegalView(doc: .userAgreement)
    }
}
