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
                    sliderRow("字号", value: $config.textSize, range: 12...32, step: 1, format: { "\(Int($0))" })
                    sliderRow("行距", value: $config.lineSpacing, range: 0.8...2.5, step: 0.05, format: { String(format: "%.2f", $0) })
                    sliderRow("段距", value: $config.paragraphSpacing, range: 0...30, step: 1, format: { "\(Int($0))" })
                    sliderRow("字间距", value: $config.letterSpacing, range: 0...3, step: 0.1, format: { String(format: "%.1f", $0) })
                    Picker("首行缩进", selection: $config.indentChars) {
                        Text("不缩进").tag(0)
                        Text("1 字").tag(1)
                        Text("2 字").tag(2)
                        Text("3 字").tag(3)
                        Text("4 字").tag(4)
                    }
                }

                // 3. 边距
                Section("边距") {
                    sliderRow("上下", value: $config.paddingTop, range: 8...60, step: 1, format: { "\(Int($0))" })
                    sliderRow("左右", value: $config.paddingHorizontal, range: 8...60, step: 1, format: { "\(Int($0))" })
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
