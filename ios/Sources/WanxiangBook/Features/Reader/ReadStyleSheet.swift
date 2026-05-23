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

    @StateObject private var config = ReadConfig.shared
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
                    Picker("字体", selection: $config.fontFamily) {
                        ForEach(ReadConfig.chineseFonts, id: \.familyName) { f in
                            Text(f.displayName)
                                .font(f.familyName.isEmpty
                                    ? .system(size: 16)
                                    : .custom(f.familyName, size: 16))
                                .tag(f.familyName)
                        }
                    }
                    sliderRow("字号", value: $config.textSize, range: 12...32, step: 1, format: { "\(Int($0))" })
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

                // 5. 屏幕
                Section("屏幕") {
                    Toggle("保持常亮", isOn: $config.keepScreenOn)
                    Toggle("自动亮度", isOn: $config.autoBrightness)
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
        .onTapGesture {
            config.theme = t
        }
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
