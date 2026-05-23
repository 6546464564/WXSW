//
//  ReadStyleSheet.swift
//  万象书屋 iOS · 阅读样式底部面板 (M2.5.6.2 ReadStyleDialog 等价)
//
//  对应 Android: io.legado.app.ui.book.read.config.ReadStyleDialog
//
//  4 大组:
//   1. 主题 (4 套预设)
//   2. 字号 / 行距 / 段距 (滑杆)
//   3. 页边距 / 字间距 / 缩进 (滑杆)
//   4. 翻页方式 (5 选 1)
//

import SwiftUI

struct ReadStyleSheet: View {

    @ObservedObject private var config = ReadConfig.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // 1. 主题
                Section("主题") {
                    HStack(spacing: 12) {
                        ForEach(ReaderThemeKind.allCases, id: \.rawValue) { t in
                            themeCircle(t)
                        }
                    }
                    .padding(.vertical, 6)
                }

                // 2. 排版
                Section("排版") {
                    HStack {
                        Text("字号").frame(width: 36, alignment: .leading)

                        Button {
                            config.textSize = max(12, config.textSize - 1)
                        } label: {
                            Text("A-")
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 48, height: 34)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.borderless)

                        Text("\(Int(config.textSize))")
                            .font(.system(size: 18, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 36)

                        Button {
                            config.textSize = min(32, config.textSize + 1)
                        } label: {
                            Text("A+")
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 48, height: 34)
                                .background(Color(.systemGray5))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.borderless)
                    }

                    Picker("字体", selection: $config.fontFamily) {
                        ForEach(ReadConfig.availableChineseFonts) { f in
                            Text(f.displayName).tag(f.familyName)
                        }
                    }
                }

                // 4. 翻页
                Section("翻页方式") {
                    Picker("", selection: $config.pageAnim) {
                        ForEach(PageAnim.allCases, id: \.rawValue) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("阅读样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - 子组件

    private func themeCircle(_ t: ReaderThemeKind) -> some View {
        Button {
            config.theme = t
        } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(t.background)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Circle()
                            .stroke(WanxiangColors.primary, lineWidth: t == config.theme ? 2.5 : 0)
                    )
                    .overlay(
                        Text("阅")
                            .font(.caption2)
                            .foregroundStyle(t.textColor)
                    )
                Text(t.displayName)
                    .font(.caption2)
                    .foregroundStyle(WanxiangColors.textSecondary)
            }
        }
        .buttonStyle(.borderless)
    }

    private func sliderRow<V: BinaryFloatingPoint>(
        _ label: String,
        value: Binding<V>,
        range: ClosedRange<V>,
        step: V.Stride,
        format: @escaping (V) -> String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .tint(WanxiangColors.primary)
            Text(format(value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(WanxiangColors.textSecondary)
        }
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int.Stride,
        format: @escaping (Int) -> String
    ) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .tint(WanxiangColors.primary)
            Text(format(value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(WanxiangColors.textSecondary)
        }
    }
}

#Preview {
    ReadStyleSheet()
}
