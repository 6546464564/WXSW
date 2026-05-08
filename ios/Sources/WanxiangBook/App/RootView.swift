//
//  RootView.swift
//  万象书屋 iOS · 根 TabBar 容器 (M2.1.3)
//
//  对应 Android: io.legado.app.ui.main.MainActivity 底部 BottomNavigationView
//  3 Tab: 书架 / 书城 / 我的
//

import SwiftUI

struct RootView: View {

    @EnvironmentObject private var appState: AppState
    @StateObject private var theme = ThemeManager.shared
    @StateObject private var eyeCare = EyeCareModeManager.shared

    /// 跟 Android `default_home_page` 偏好对齐 (默认书架)
    /// 万象书屋: launch argument `-DefaultTab male/female/my` 可在 App Store 截图脚本里指定
    @State private var selectedTab: Tab = {
        // 万象书屋: 单 dash `-DefaultTab` 会被 simctl 当 `-D` 短选项吞掉, 用 `--DefaultTab`
        let args = ProcessInfo.processInfo.arguments
        for key in ["--DefaultTab", "-DefaultTab"] {
            if let i = args.firstIndex(of: key), i + 1 < args.count {
                switch args[i + 1] {
                case "bookstore": return .bookStore
                case "my": return .my
                default: return .bookshelf
                }
            }
        }
        return .bookshelf
    }()

    enum Tab: Hashable {
        case bookshelf, bookStore, my
    }

    /// Debug deep-link: --OpenBook <bookUrl> 启动直接进 ReaderView (用于测试)
    @State private var deepLinkBook: ShelfBook? = nil
    @State private var deepLinkTtsBook: ShelfBook? = nil
    @State private var deepLinkSearchKeyword: String? = nil
    @State private var isTabBarHidden = false

    var body: some View {
        mainContent
            .modifier(SystemDialogsModifier(appState: appState))
            // 万象书屋: 跟 Android `EyeCareLifecycleCallback` 给所有 Activity 注入 overlay 等价.
            // 放在最外层 — 所有子页面 / sheet / fullScreenCover 都被这层暖色覆盖.
            .wanxiangEyeCareOverlay(eyeCare)
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            Group {
                // 万象书屋: 跟 Android `BaseActivity.trackPageName` 自动 PV 埋点等价.
                // 命名跟 Android 同步使用 snake_case (page_*).
                switch selectedTab {
                case .bookshelf: BookshelfView().trackPageView("page_bookshelf")
                case .bookStore: BookStoreView().trackPageView("page_bookstore")
                case .my:        MyView().trackPageView("page_my")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 万象书屋: 不再把 tabBar 放 safeAreaInset.
            // 实测 iOS 26 Simulator 下内容 switch 会刷新, 但 safeAreaInset 的自定义 tabBar
            // 手点切换后偶发不重绘颜色。放回普通 VStack 主树里, selectedTab 改变时一定重算。
            if !isTabBarHidden {
                CustomTabBar(selected: $selectedTab)
                    .id(selectedTab)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .wanxiangThemed(theme)
        .overlay(alignment: .top) {
            // bug #4 fix: 用 bootstrapFailed 跟 isBootstrapped 解耦
            if let err = appState.lastError, appState.bootstrapFailed {
                Button {
                    appState.bootstrapFailed = false
                } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("启动初始化失败,点关闭:\(err)").lineLimit(2)
                    }
                    .font(.caption).padding(8)
                    .background(.orange.opacity(0.92))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 8).padding(.top, 8)
                }
            }
        }
        .fullScreenCover(item: $deepLinkBook) { book in
            NavigationStack {
                ReaderView(book: book, source: BookSourceRegistry.shared.find(origin: book.origin))
            }
        }
        .fullScreenCover(item: $deepLinkTtsBook) { book in
            TtsDeepLinkLoader(book: book)
        }
        .sheet(item: Binding(
            get: { deepLinkSearchKeyword.map { IdentifiableString(value: $0) } },
            set: { deepLinkSearchKeyword = $0?.value }
        )) { kw in
            NavigationStack {
                SearchView(initialKeyword: kw.value)
            }
        }
        .task {
            let args = ProcessInfo.processInfo.arguments
            // --OpenBook <bookUrl>: 进 reader
            for key in ["--OpenBook", "-OpenBook"] {
                if let i = args.firstIndex(of: key), i + 1 < args.count {
                    let url = args[i + 1]
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let book = try? await BookshelfRepository.shared.get(bookUrl: url) {
                        await MainActor.run { deepLinkBook = book }
                    }
                    break
                }
            }
            // --OpenTts <bookUrl>: 进听书
            for key in ["--OpenTts", "-OpenTts"] {
                if let i = args.firstIndex(of: key), i + 1 < args.count {
                    let url = args[i + 1]
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if let book = try? await BookshelfRepository.shared.get(bookUrl: url) {
                        await MainActor.run { deepLinkTtsBook = book }
                    }
                    break
                }
            }
            // --Search <keyword>: 直接打开搜索 (debug 用)
            for key in ["--Search", "-Search"] {
                if let i = args.firstIndex(of: key), i + 1 < args.count {
                    let kw = args[i + 1]
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await MainActor.run { deepLinkSearchKeyword = kw }
                    break
                }
            }
            // 万象书屋 debug: --AutoCycleTabs 让 app 每 1.5s 自动切 tab, 给外部录视频/截图验证
            if args.contains("--AutoCycleTabs") || args.contains("-AutoCycleTabs") {
                Task { @MainActor in
                    let order: [Tab] = [.bookshelf, .bookStore, .my]
                    var i = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        selectedTab = order[i % order.count]
                        i += 1
                    }
                }
            }
            // --AddDemoBook: 注入一本 mock 离线书 + 5 章, 给 reader/TTS 测试用
            if args.contains("--AddDemoBook") || args.contains("-AddDemoBook") {
                await Self.injectDemoBook()
                if args.contains("--OpenDemoReader") {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let book = try? await BookshelfRepository.shared.get(bookUrl: "demo://wanxiang/test-book") {
                        await MainActor.run { deepLinkBook = book }
                    }
                }
                if args.contains("--OpenDemoTts") {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let book = try? await BookshelfRepository.shared.get(bookUrl: "demo://wanxiang/test-book") {
                        await MainActor.run { deepLinkTtsBook = book }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wanxiangTabBarHiddenChanged)) { note in
            let hidden = (note.object as? Bool) ?? false
            withAnimation(.easeInOut(duration: 0.20)) {
                isTabBarHidden = hidden
            }
        }
    }


    /// 万象书屋 debug: 注入 demo 书,共 5 章, 每章 600+ 字
    private static func injectDemoBook() async {
        let bookUrl = "demo://wanxiang/test-book"
        var book = ShelfBook(
            bookUrl: bookUrl,
            name: "测试小说·万象之旅",
            author: "万象书屋",
            origin: "demo://local",
            originName: "本地测试源",
            coverUrl: nil,
            intro: "用于深度测试 TTS / 翻页 / 自动滚动等功能的离线 demo 书。",
            kind: "玄幻",
            tocUrl: bookUrl
        )
        book.totalChapterNum = 5
        book.durChapterTitle = "第一章 楔子"
        book.latestChapterTitle = "第五章 终章"
        try? await BookshelfRepository.shared.add(book)

        let titles = [
            "第一章 楔子",
            "第二章 启程",
            "第三章 深渊",
            "第四章 觉醒",
            "第五章 终章"
        ]
        let bodies = [
            "这是测试 TTS 功能的第一章。万象书屋自动语音播放可以读出这段文字。点击播放按钮开始,音量键可以翻页,设置里可以调整语速、音色和句子高亮模式。系统会自动按句拆分,并使用 AVSpeechSynthesizer 进行离线合成。",
            "第二章。下面是若干较长的中文段落,用来测试断句和换页效果。江风浩荡,扁舟一叶载着主角驶向远方;山间云雾缭绕,如梦似幻。他不知前路凶险几何,但心中只有一个念头:寻得真相,救出故人。",
            "第三章。地心深处的呢喃在他耳畔回响,低沉、缓慢、却带着不可抗拒的诱惑。他闭上眼,任由意识沉入暗流之中。回忆如同破碎的水镜,一片一片地被打磨重组,最终凝结成一条清晰的线索。",
            "第四章。觉醒之夜,星河倒悬,雷霆撕裂苍穹。他高举右手,体内的力量如同洪流奔涌而出,瞬间冲破层层桎梏。从此以后,他将不再是那个唯唯诺诺的少年,而是这个时代的执剑者。",
            "第五章 终章。万象归一,众生有道。当最后一缕光照在山巅时,他终于停下脚步,回望来路。剑入鞘,书卷掩,故事在此画上句点 — 但传说,才刚刚开始。"
        ]

        var chapters: [BookChapter] = []
        for i in 0..<5 {
            let chapter = BookChapter(
                chapterIndex: i,
                chapterUrl: "\(bookUrl)#\(i)",
                title: titles[i]
            )
            chapters.append(chapter)
        }
        try? await ChapterRepository.shared.saveToc(bookUrl: bookUrl, chapters: chapters)
        for i in 0..<5 {
            try? await ChapterRepository.shared.saveContent(
                bookUrl: bookUrl,
                chapterIndex: i,
                content: String(repeating: bodies[i] + "\n\n", count: 6)
            )
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppState())
}

// MARK: - 自定义 TabBar

/// 万象书屋: 自定义 TabBar (替代系统 TabView 默认 tabBar)
/// - 白色卡片背景 + 顶部细分割线
/// - 3 个 tab 平均分布: 图标在上, 文字在下
/// - 选中态 棕金主色, 未选中灰色
/// - 安全区适配 (底部 home indicator)
private struct CustomTabBar: View {
    @Binding var selected: RootView.Tab

    /// 万象书屋: tab 图标用「未选 outline + 已选 fill」两套, 让选中态对比强
    /// 之前 `face.smiling.inverse` / `storefront.fill` 是 SF Symbols 多色符号,
    /// 默认渲染模式带自身颜色, 会覆盖 `foregroundStyle(...)` —— 这就是用户报"图标颜色没变"的根因.
    /// 解决: 1) 换成纯线性 `book.closed` `building.2` `person` 系列  2) 强制 `.symbolRenderingMode(.monochrome)`
    private let items: [(tab: RootView.Tab, iconOff: String, iconOn: String, label: String)] = [
        (.bookshelf, "books.vertical",     "books.vertical.fill", "书架"),
        (.bookStore, "building.2",         "building.2.fill",     "书城"),
        (.my,        "person.crop.circle", "person.crop.circle.fill", "我的"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(items, id: \.tab) { item in
                    tabButton(item: item)
                }
            }
            // 万象书屋: iOS 26 Simulator 上 safeAreaInset 内的 Button label 偶发不随 @State
            // 重绘颜色。给整排 tab 绑定 identity, 选中 tab 改变时强制重建 label tree。
            .id(selected)
            // 万象书屋: 底部操作区保持 54pt, 比系统 tabbar 略紧凑但不挤
            .frame(height: 54)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            // home indicator 区留白由外层承担, 不参与选中胶囊布局
            .padding(.bottom, max(8, safeAreaBottom - 18))
        }
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(WanxiangColors.background.opacity(0.72))
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private func tabButton(item: (tab: RootView.Tab, iconOff: String, iconOn: String, label: String)) -> some View {
        let isSelected = selected == item.tab
        let activeColor = WanxiangColors.primary
        let inactiveColor = Color.gray.opacity(0.52)
        let tabColor = isSelected ? activeColor : inactiveColor
        Button {
            selected = item.tab
            // 万象书屋: 切换轻反馈
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isSelected ? item.iconOn : item.iconOff)
                    .renderingMode(.template)
                    .font(.system(size: 21, weight: isSelected ? .semibold : .regular))
                    // 万象书屋: 强制 monochrome — 否则 .fill / multicolor SF Symbol
                    // 会用自身颜色, foregroundStyle(...) 不生效, 选中态颜色看不出
                    .symbolRenderingMode(.monochrome)
                    // 万象书屋: 这里必须直接作用在 Image 上, 不能只依赖父 VStack 的 foregroundStyle.
                    // 实测 Simulator 手点切换时页面会变, 但父级 foregroundStyle 偶尔不刷新到 SF Symbol。
                    .foregroundColor(tabColor)
                Text(item.label)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(tabColor)
            }
            .frame(width: 76, height: 46)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(WanxiangColors.primary.opacity(0.16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(WanxiangColors.primary.opacity(0.10), lineWidth: 0.5)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // 万象书屋: 颜色 / 字重 / icon 切换都做 0.18s 缓动, 反馈更"活"
            .animation(.easeInOut(duration: 0.18), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    /// 取当前 device 底部安全区高度 (home indicator)
    private var safeAreaBottom: CGFloat {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        return scenes.first?.windows.first?.safeAreaInsets.bottom ?? 0
    }
}

private struct IdentifiableString: Identifiable {
    let value: String
    var id: String { value }
}

extension Notification.Name {
    static let wanxiangTabBarHiddenChanged = Notification.Name("wanxiang.tabBarHiddenChanged")
}

private struct AnnouncementWrapper: Identifiable {
    let info: AnnouncementInfo
    var id: Int { info.id }
}

/// 万象书屋: 系统级 dialog (公告/版本) — 抽出来给主 body 减表达式负担
private struct SystemDialogsModifier: ViewModifier {
    @ObservedObject var appState: AppState

    func body(content: Content) -> some View {
        content
            .alert(item: Binding(
                get: { appState.announcement.map { AnnouncementWrapper(info: $0) } },
                set: { _ in appState.markAnnouncementSeen() }
            )) { wrapper in
                Alert(
                    title: Text(wrapper.info.title),
                    message: Text(wrapper.info.body),
                    dismissButton: .default(Text("知道了")) {
                        appState.markAnnouncementSeen()
                    }
                )
            }
            .sheet(item: Binding(
                get: { appState.versionUpdate.map { VersionUpdateWrapper(info: $0) } },
                set: { _ in appState.versionUpdate = nil }
            )) { wrapper in
                VersionUpdateSheet(info: wrapper.info,
                                    onDismiss: { appState.versionUpdate = nil })
            }
    }
}

private struct VersionUpdateWrapper: Identifiable {
    let info: VersionUpdateInfo
    var id: String { info.latestVersion }
}

/// 万象书屋: 版本升级 sheet
private struct VersionUpdateSheet: View {
    let info: VersionUpdateInfo
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(WanxiangColors.primary)
            Text("发现新版本 \(info.latestVersion)")
                .font(.title3.weight(.semibold))
            Text("当前版本 \(info.currentVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(info.releaseNotes.isEmpty ? "性能优化和 bug 修复" : info.releaseNotes)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            .frame(maxHeight: 200)
            HStack(spacing: 12) {
                if !info.mandatory {
                    Button("稍后") { onDismiss() }
                        .buttonStyle(.bordered)
                }
                if let url = info.downloadUrl, let parsed = URL(string: url) {
                    Button("去更新") {
                        UIApplication.shared.open(parsed)
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(WanxiangColors.primary)
                }
            }
        }
        .padding()
        .presentationDetents([.medium])
        .interactiveDismissDisabled(info.mandatory)
    }
}

/// 万象书屋 debug: 给 deeplink 用的 TTS 加载器 (异步拿章节后再开 TtsPlayerView)
private struct TtsDeepLinkLoader: View {
    let book: ShelfBook
    @State private var chapters: [BookChapter]? = nil
    var body: some View {
        Group {
            if let cs = chapters {
                TtsPlayerView(book: book, chapters: cs, startIndex: 0)
            } else {
                ProgressView("加载章节...")
                    .task {
                        chapters = (try? await ChapterRepository.shared.loadToc(bookUrl: book.bookUrl)) ?? []
                    }
            }
        }
    }
}
