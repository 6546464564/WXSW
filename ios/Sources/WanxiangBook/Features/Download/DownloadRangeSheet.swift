//
//  DownloadRangeSheet.swift
//  万象书屋 iOS · 章节范围下载 sheet (M2.8 Gap 2)
//
//  对应 Android: 缓存对话框里 "[start, end]" 输入框
//
//  让用户选 [start, end] 范围下载, 不必整本下. 三种快捷模式:
//   - 下载全本 (默认)
//   - 下载新章 (从 durChapterIndex 开始到结尾)
//   - 自定义 (拖滑块或点 +/- 微调)
//

import SwiftUI

public struct DownloadRangeSheet: View {

    public let bookName: String
    public let totalChapters: Int
    /// 用户当前阅读位置 (1-based), 用来给"从这里开始"快捷
    public let currentChapter: Int?
    public let onConfirm: (ClosedRange<Int>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startIdx: Int = 1
    @State private var endIdx: Int = 1
    @State private var preset: Preset = .all

    enum Preset: String, CaseIterable {
        case all = "全本"
        case fromCurrent = "从这里开始"
        case custom = "自定义"
    }

    public init(bookName: String, totalChapters: Int, currentChapter: Int?,
                onConfirm: @escaping (ClosedRange<Int>) -> Void) {
        self.bookName = bookName
        self.totalChapters = totalChapters
        self.currentChapter = currentChapter
        self.onConfirm = onConfirm
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(bookName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WanxiangColors.textSecondary)
                    .padding(.top, 4)

                Picker("范围", selection: $preset) {
                    ForEach(filteredPresets(), id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: preset) { _, new in applyPreset(new) }

                // 范围摘要
                VStack(spacing: 8) {
                    Text(rangeText)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(WanxiangColors.primary)
                    Text("共 \(endIdx - startIdx + 1) 章")
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(WanxiangColors.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // 自定义模式才显示滑块
                if preset == .custom {
                    customSliders
                }

                Spacer()

                Button {
                    onConfirm(startIdx...endIdx)
                    dismiss()
                } label: {
                    Text("开始下载 (\(endIdx - startIdx + 1) 章)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(WanxiangColors.accent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal)
                .padding(.bottom, 20)
            }
            .background(WanxiangColors.background.ignoresSafeArea())
            .navigationTitle("下载本书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                applyPreset(preset)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func filteredPresets() -> [Preset] {
        // currentChapter 没意义时不显示"从这里开始"
        if currentChapter == nil || (currentChapter ?? 0) <= 1 {
            return [.all, .custom]
        }
        return Preset.allCases
    }

    private var rangeText: String {
        if startIdx == endIdx { return "第 \(startIdx) 章" }
        return "第 \(startIdx) - \(endIdx) 章"
    }

    private func applyPreset(_ p: Preset) {
        switch p {
        case .all:
            startIdx = 1
            endIdx = totalChapters
        case .fromCurrent:
            startIdx = currentChapter ?? 1
            endIdx = totalChapters
        case .custom:
            // 保持当前值
            break
        }
    }

    @ViewBuilder
    private var customSliders: some View {
        VStack(spacing: 12) {
            HStack {
                Text("起始: 第 \(startIdx) 章")
                    .font(.caption.monospacedDigit())
                    .frame(width: 110, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(startIdx) },
                    set: {
                        startIdx = Int($0)
                        if endIdx < startIdx { endIdx = startIdx }
                    }
                ), in: 1...Double(totalChapters), step: 1)
                .tint(WanxiangColors.primary)
            }
            HStack {
                Text("结束: 第 \(endIdx) 章")
                    .font(.caption.monospacedDigit())
                    .frame(width: 110, alignment: .leading)
                Slider(value: Binding(
                    get: { Double(endIdx) },
                    set: {
                        endIdx = Int($0)
                        if startIdx > endIdx { startIdx = endIdx }
                    }
                ), in: 1...Double(totalChapters), step: 1)
                .tint(WanxiangColors.primary)
            }
        }
        .padding(.horizontal)
    }
}
