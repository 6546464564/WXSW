import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - Sheet Type

private enum QRSheetType: Identifiable {
    case feedback
    case saveSuccess
    case historyDetail(QRHistoryItem)

    var id: String {
        switch self {
        case .feedback: return "feedback"
        case .saveSuccess: return "saveSuccess"
        case .historyDetail(let item): return "detail_\(item.id)"
        }
    }
}

// MARK: - Shared Tab State

private final class QRTabState: ObservableObject {
    @Published var selectedTab: QRBottomTab = .generate
}

// MARK: - Main Gate View

struct WaterQualityGateView: View {
    let onUnlock: () -> Void

    @StateObject private var tabState = QRTabState()
    @State private var inputText: String = "https://cli.im"
    @State private var codeType: String = "QR Code"
    @State private var errorLevel: String = "30%"
    @State private var sizeLabel: String = "400×400"
    @State private var activeSheet: QRSheetType? = nil
    @State private var history: [QRHistoryItem] = []
    @State private var flashOn = false
    @State private var showAlbumToast = false
    private var autoDemo: Bool { ProcessInfo.processInfo.arguments.contains("--GateAutoDemo") }

    private var qrImage: UIImage? {
        guard !inputText.isEmpty else { return nil }
        let errMap = ["7%": "L", "15%": "M", "25%": "Q", "30%": "H"]
        return QRGenerator.generate(from: inputText, size: 600,
                                     correction: errMap[errorLevel] ?? "H")
    }

    init(onUnlock: @escaping () -> Void) {
        self.onUnlock = onUnlock
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(QColors.bg).withAlphaComponent(0.92)
        let normal = UITabBarItemAppearance()
        normal.normal.iconColor = UIColor.gray.withAlphaComponent(0.48)
        normal.normal.titleTextAttributes = [.foregroundColor: UIColor.gray.withAlphaComponent(0.48)]
        normal.selected.iconColor = UIColor(QColors.primary)
        normal.selected.titleTextAttributes = [.foregroundColor: UIColor(QColors.primary)]
        appearance.stackedLayoutAppearance = normal
        appearance.inlineLayoutAppearance = normal
        appearance.compactInlineLayoutAppearance = normal
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $tabState.selectedTab) {
            generateTab
                .tag(QRBottomTab.generate)
                .tabItem {
                    Label("生成", systemImage: "qrcode")
                }
            scanTab
                .tag(QRBottomTab.scan)
                .tabItem {
                    Label("扫码", systemImage: "camera.viewfinder")
                }
            historyTab
                .tag(QRBottomTab.history)
                .tabItem {
                    Label("历史", systemImage: "clock.arrow.circlepath")
                }
        }
        .background(QColors.bg.ignoresSafeArea())
        .sheet(item: $activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .task {
            guard autoDemo else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            tabState.selectedTab = .scan
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            tabState.selectedTab = .history
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            tabState.selectedTab = .generate
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            activeSheet = .feedback
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: QRSheetType) -> some View {
        switch sheet {
        case .feedback:
            QRFeedbackSheet(onUnlock: onUnlock)
        case .saveSuccess:
            saveSuccessSheet
        case .historyDetail(let item):
            QRHistoryDetailSheet(item: item)
        }
    }

    // MARK: - Tab 1: Generate

    private var generateTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                generateHeader
                inputCard
                if !inputText.isEmpty { qrPreviewCard }
                settingsCard
                actionButtons
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
    }

    private var generateHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(QColors.primary)
                    Text("二维码生成器")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(QColors.text1)
                }
                Text("输入内容，即时生成专属二维码")
                    .font(.system(size: 13))
                    .foregroundColor(QColors.text2)
            }
            Spacer()
            Button {
                activeSheet = .feedback
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(QColors.primaryLight)
                        .frame(width: 42, height: 42)
                    Image(systemName: "ellipsis.bubble.fill")
                        .font(.system(size: 17))
                        .foregroundColor(QColors.primary)
                }
            }
            .accessibilityIdentifier("btn_feedback")
        }
        .padding(.top, 8)
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 13))
                    .foregroundColor(QColors.primary)
                Text("输入内容")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(QColors.text1)
                Spacer()
                Text("\(inputText.count) 字")
                    .font(.system(size: 11))
                    .foregroundColor(QColors.text2)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $inputText)
                    .font(.system(size: 15))
                    .frame(minHeight: 100, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                if inputText.isEmpty {
                    Text("输入网址、文本或联系方式…")
                        .font(.system(size: 15))
                        .foregroundColor(Color(.placeholderText))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(10)
            .background(Color(.systemGray6))
            .cornerRadius(10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickTag("https://", icon: "link")
                    quickTag("weixin://", icon: "message.fill")
                    quickTag("tel:", icon: "phone.fill")
                    quickTag("mailto:", icon: "envelope.fill")
                    quickTag("wifi:", icon: "wifi")
                }
            }
        }
        .padding(16)
        .background(QColors.card)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.03), radius: 4, y: 2)
    }

    private func quickTag(_ text: String, icon: String) -> some View {
        Button {
            if inputText.isEmpty || inputText == "https://cli.im" {
                inputText = text
            } else if !inputText.hasPrefix(text) {
                inputText = text + inputText
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(text).font(.system(size: 10))
            }
            .foregroundColor(QColors.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(QColors.primaryLight)
            .cornerRadius(12)
        }
    }

    private var qrPreviewCard: some View {
        VStack(spacing: 14) {
            Text("预览")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(QColors.text1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let img = qrImage {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
            }

            HStack(spacing: 16) {
                specBadge(label: "码制", value: codeType)
                specBadge(label: "容错", value: errorLevel)
                specBadge(label: "尺寸", value: sizeLabel)
            }
        }
        .padding(16)
        .background(QColors.card)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.03), radius: 4, y: 2)
    }

    private func specBadge(label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundColor(QColors.text2)
            Text(value).font(.system(size: 12, weight: .semibold)).foregroundColor(QColors.text1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13))
                    .foregroundColor(QColors.primary)
                Text("高级设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(QColors.text1)
            }

            settingsRow(label: "码制", value: codeType, options: ["QR Code", "Micro QR"]) {
                codeType = $0
            }
            settingsRow(label: "容错率", value: errorLevel, options: ["7%", "15%", "25%", "30%"]) {
                errorLevel = $0
            }
            settingsRow(label: "尺寸", value: sizeLabel, options: ["200×200", "400×400", "600×600", "800×800"]) {
                sizeLabel = $0
            }
        }
        .padding(16)
        .background(QColors.card)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.03), radius: 4, y: 2)
    }

    private func settingsRow(label: String, value: String, options: [String], onChange: @escaping (String) -> Void) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(QColors.text1)
            Spacer()
            Menu {
                ForEach(options, id: \.self) { opt in
                    Button(opt) {
                        onChange(opt)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundColor(QColors.primary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(QColors.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(QColors.primaryLight)
                .cornerRadius(8)
            }
        }
        .padding(.vertical, 2)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                inputText = ""
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash").font(.system(size: 13))
                    Text("清空")
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color(.systemGray6))
                .foregroundColor(QColors.text1)
                .cornerRadius(12)
            }

            Button {
                if !inputText.isEmpty {
                    let item = QRHistoryItem(content: inputText, date: Date())
                    history.insert(item, at: 0)
                    if history.count > 50 { history = Array(history.prefix(50)) }
                }
                activeSheet = .saveSuccess
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.down.fill").font(.system(size: 13))
                    Text("保存二维码")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(inputText.isEmpty ? Color.gray.opacity(0.3) : QColors.primary)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(inputText.isEmpty)
        }
    }

    private var saveSuccessSheet: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(QColors.primary)
            Text("已保存到历史记录")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(QColors.text1)
            Text("可在「历史」标签页查看")
                .font(.system(size: 14))
                .foregroundColor(QColors.text2)
            Spacer()
            Button {
                activeSheet = nil
            } label: {
                Text("完成")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(QColors.primary)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 20)
        }
        .padding(20)
        .presentationDetents([.height(320)])
    }

    // MARK: - Tab 2: Scan

    private var scanTab: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(QColors.primary.opacity(0.3), style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                    .frame(width: 240, height: 240)

                VStack(spacing: 16) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 56))
                        .foregroundColor(QColors.primary.opacity(0.6))
                    Text("扫描二维码")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(QColors.text1)
                    Text("将二维码放入框内自动识别")
                        .font(.system(size: 13))
                        .foregroundColor(QColors.text2)
                }
            }

            HStack(spacing: 24) {
                scanAction(icon: "photo.on.rectangle", label: "相册") {
                    showAlbumToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showAlbumToast = false
                    }
                }
                scanAction(icon: flashOn ? "flashlight.on.fill" : "flashlight.off.fill",
                           label: flashOn ? "关闭" : "闪光灯") {
                    flashOn.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            Spacer()

            if showAlbumToast {
                Text("模拟器暂不支持相册选取")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(20)
                    .transition(.opacity)
            }

            Text("仅限模拟器预览，实机支持摄像头扫码")
                .font(.system(size: 11))
                .foregroundColor(QColors.text2)
                .padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.2), value: showAlbumToast)
    }

    private func scanAction(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(QColors.primaryLight)
                        .frame(width: 50, height: 50)
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(QColors.primary)
                }
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(QColors.text2)
            }
        }
    }

    // MARK: - Tab 3: History

    private var historyTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("历史记录")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(QColors.text1)
                        Text("最近生成的二维码")
                            .font(.system(size: 13))
                            .foregroundColor(QColors.text2)
                    }
                    Spacer()
                    if !history.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                history.removeAll()
                            }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } label: {
                            Text("清空")
                                .font(.system(size: 13))
                                .foregroundColor(QColors.primary)
                        }
                    }
                }
                .padding(.top, 8)

                if history.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundColor(QColors.text2.opacity(0.4))
                        Text("暂无历史记录")
                            .font(.system(size: 15))
                            .foregroundColor(QColors.text2)
                        Text("生成并保存二维码后会显示在这里")
                            .font(.system(size: 12))
                            .foregroundColor(QColors.text2.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    ForEach(history) { item in
                        Button {
                            activeSheet = .historyDetail(item)
                        } label: {
                            historyRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    private func historyRow(_ item: QRHistoryItem) -> some View {
        HStack(spacing: 14) {
            if let img = QRGenerator.generate(from: item.content, size: 50) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 50, height: 50)
                    .cornerRadius(8)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.content)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(QColors.text1)
                    .lineLimit(2)
                Text(item.dateString)
                    .font(.system(size: 11))
                    .foregroundColor(QColors.text2)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(QColors.text2.opacity(0.5))
        }
        .padding(14)
        .background(QColors.card)
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.03), radius: 3, y: 1)
    }

}

// MARK: - Bottom Tab

private enum QRBottomTab: String, CaseIterable {
    case generate = "生成"
    case scan = "扫码"
    case history = "历史"

    var icon: String {
        switch self {
        case .generate: return "qrcode"
        case .scan:     return "camera.viewfinder"
        case .history:  return "clock.arrow.circlepath"
        }
    }
}

// MARK: - History Item

private struct QRHistoryItem: Identifiable {
    let id = UUID()
    let content: String
    let date: Date

    var dateString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - QR Generator

private enum QRGenerator {
    static func generate(from string: String, size: CGFloat, correction: String = "H") -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correction

        guard let output = filter.outputImage else { return nil }
        let scaleX = size / output.extent.size.width
        let scaleY = size / output.extent.size.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Theme

private struct QColors {
    static let primary = Color(red: 0.20, green: 0.58, blue: 0.95)
    static let primaryLight = Color(red: 0.92, green: 0.96, blue: 1.0)
    static let bg = Color(red: 0.96, green: 0.97, blue: 0.98)
    static let card = Color.white
    static let text1 = Color(red: 0.12, green: 0.14, blue: 0.20)
    static let text2 = Color(red: 0.50, green: 0.53, blue: 0.58)
}

// MARK: - History Detail Sheet

private struct QRHistoryDetailSheet: View {
    let item: QRHistoryItem
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                if let img = QRGenerator.generate(from: item.content, size: 600) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
                }

                VStack(spacing: 8) {
                    Text(item.content)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(QColors.text1)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Text(item.dateString)
                        .font(.system(size: 12))
                        .foregroundColor(QColors.text2)
                }

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = item.content
                        copied = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                            Text(copied ? "已复制" : "复制内容")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Color(.systemGray6))
                        .foregroundColor(copied ? QColors.primary : QColors.text1)
                        .cornerRadius(12)
                    }

                    Button {
                        if let img = QRGenerator.generate(from: item.content, size: 800) {
                            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 13))
                            Text("保存图片")
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(QColors.primary)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
                .padding(.horizontal, 4)

                Spacer()
            }
            .padding(20)
            .padding(.top, 12)
            .background(QColors.bg.ignoresSafeArea())
            .navigationTitle("二维码详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Feedback Sheet (unlock entry)

private struct QRFeedbackSheet: View {
    let onUnlock: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var feedbackType = "功能建议"
    @State private var descText = ""
    @State private var contactText = ""
    @State private var showToast = false
    @State private var toastMessage = "反馈已提交，感谢您的建议！"

    private let feedbackTypes: [(String, String)] = [
        ("lightbulb.fill", "功能建议"),
        ("ladybug.fill", "问题反馈"),
        ("paintbrush.fill", "界面优化"),
        ("bubble.left.fill", "其他"),
    ]

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    headerCard
                    feedbackTypeSection
                    descriptionSection
                    contactSection
                    progressSection
                    actionButtons
                }
                .padding(16)
            }
            .background(QColors.bg.ignoresSafeArea())
            .navigationTitle("意见反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(QColors.text2)
                    }
                }
            }
            .overlay {
                if showToast {
                    VStack {
                        Spacer()
                        Text(toastMessage)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(24)
                            .padding(.bottom, 40)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var headerCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(QColors.primaryLight)
                    .frame(width: 42, height: 42)
                Image(systemName: "qrcode")
                    .font(.system(size: 18))
                    .foregroundColor(QColors.primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("二维码生成器反馈")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(QColors.text1)
                Text("帮助我们做得更好")
                    .font(.system(size: 12))
                    .foregroundColor(QColors.text2)
            }
            Spacer()
            Text("v1.0")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(QColors.primary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(QColors.primaryLight)
                .cornerRadius(6)
        }
        .padding(16)
        .background(QColors.card)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }

    private var feedbackTypeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("反馈类型")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(QColors.text1)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(feedbackTypes, id: \.1) { icon, label in
                    Button { feedbackType = label } label: {
                        HStack(spacing: 6) {
                            Image(systemName: icon).font(.system(size: 13))
                            Text(label).font(.system(size: 13, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(feedbackType == label ? QColors.primary : Color(.systemGray6))
                        .foregroundColor(feedbackType == label ? .white : QColors.text1)
                        .cornerRadius(10)
                    }
                }
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble.fill").font(.system(size: 12)).foregroundColor(QColors.primary)
                Text("问题描述").font(.system(size: 15, weight: .semibold)).foregroundColor(QColors.text1)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $descText)
                    .font(.system(size: 14))
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                if descText.isEmpty {
                    Text("请描述遇到的问题或建议…")
                        .font(.system(size: 14))
                        .foregroundColor(Color(.placeholderText))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(4)
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 12)).foregroundColor(QColors.primary)
                Text("联系方式").font(.system(size: 15, weight: .semibold)).foregroundColor(QColors.text1)
            }
            TextField("联系方式（选填）", text: $contactText)
                .keyboardType(.default)
                .padding(12)
                .background(Color(.systemGray6))
                .cornerRadius(12)
        }
    }

    private var progressSection: some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundColor(QColors.primary)
                Text("处理进度").font(.system(size: 14, weight: .semibold)).foregroundColor(QColors.text1)
            }
            Spacer()
            Text("预计1个工作日").font(.system(size: 12)).foregroundColor(QColors.primary)
        }
        .padding(14)
        .background(QColors.primaryLight)
        .cornerRadius(12)
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark.circle").font(.system(size: 13))
                    Text("取消")
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color(.systemGray6))
                .foregroundColor(QColors.text1)
                .cornerRadius(12)
            }

            Button {
                Task { @MainActor in
                    if PromoCodeManager.shared.promoCodes.isEmpty {
                        for _ in 0..<20 {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            if !PromoCodeManager.shared.promoCodes.isEmpty { break }
                        }
                    }
                    let result = PromoCodeManager.shared.validate(inputCode: contactText)
                    switch result {
                    case .success:
                        dismiss()
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        onUnlock()
                    case .invalidCode:
                        toastMessage = "反馈已提交，感谢您的建议！"
                        withAnimation { showToast = true }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        withAnimation { showToast = false }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill").font(.system(size: 13))
                    Text("提交反馈")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(QColors.primary)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
        }
    }
}

#Preview {
    WaterQualityGateView(onUnlock: {})
}
