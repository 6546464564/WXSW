import SwiftUI

struct ReadStyleSheet: View {

    @StateObject private var config = ReadConfig.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // 亮度
            HStack(spacing: 12) {
                Text("亮度").font(.subheadline).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(config.brightness) / 100.0 },
                        set: { config.brightness = Int($0 * 100); UIScreen.main.brightness = CGFloat($0) }
                    ),
                    in: 0...1
                )
                .tint(WanxiangColors.primary)
                Toggle("跟随系统", isOn: $config.autoBrightness)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // 字号 + 字体
            HStack(spacing: 0) {
                Text("字号").font(.subheadline).foregroundStyle(.secondary)
                    .frame(width: 36)

                Button {
                    config.textSize = max(12, config.textSize - 1)
                } label: {
                    Text("A-")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 44, height: 36)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Text("\(Int(config.textSize))")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .frame(width: 44)

                Button {
                    config.textSize = min(32, config.textSize + 1)
                } label: {
                    Text("A+")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 44, height: 36)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Spacer()

                NavigationLink {
                    fontPicker
                } label: {
                    Text(config.fontFamily.isEmpty ? "系统字体" : config.fontFamily)
                        .font(.subheadline)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            // 主题色
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(ReaderThemeKind.allCases, id: \.rawValue) { t in
                        themeCircle(t)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 14)

            // 功能按钮行
            HStack(spacing: 0) {
                actionButton(
                    config.theme == .eye ? "关闭护眼" : "护眼模式",
                    icon: config.theme == .eye ? "eye.slash" : "eye"
                ) {
                    config.theme = config.theme == .eye ? .default : .eye
                }

                Divider().frame(height: 20)

                actionButton("翻页方式", icon: "book.pages") {
                    cyclePageAnim()
                }

                Divider().frame(height: 20)

                actionButton("更多设置", icon: "gearshape") {
                    dismiss()
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - 主题圆

    private func themeCircle(_ t: ReaderThemeKind) -> some View {
        Circle()
            .fill(t.background)
            .frame(width: 36, height: 36)
            .overlay(
                Circle().stroke(
                    t == config.theme ? WanxiangColors.primary : Color.clear,
                    lineWidth: 2.5
                )
            )
            .onTapGesture {
                config.theme = t
            }
    }

    // MARK: - 功能按钮

    private func actionButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                Text(title)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 翻页方式循环切换

    private func cyclePageAnim() {
        let all = PageAnim.allCases
        guard let idx = all.firstIndex(of: config.pageAnim) else { return }
        config.pageAnim = all[(idx + 1) % all.count]
    }

    // MARK: - 字体选择

    private var fontPicker: some View {
        List {
            ForEach(ReadConfig.chineseFonts, id: \.familyName) { f in
                Button {
                    config.fontFamily = f.familyName
                } label: {
                    HStack {
                        Text(f.displayName)
                            .font(f.familyName.isEmpty
                                ? .system(size: 17)
                                : .custom(f.familyName, size: 17))
                        Spacer()
                        if config.fontFamily == f.familyName {
                            Image(systemName: "checkmark")
                                .foregroundStyle(WanxiangColors.primary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("选择字体")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Checkbox Toggle Style

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? WanxiangColors.primary : .secondary)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}

private extension ToggleStyle where Self == CheckboxToggleStyle {
    static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}

#Preview {
    ReadStyleSheet()
}
