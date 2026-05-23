//
//  ReaderView.swift
//  万象书屋 iOS · 阅读器主屏 (M2.5.1 + M2.5.3 + M2.5.4)
//
//  对应 Android: io.legado.app.ui.book.read.ReadBookActivity
//
//  M2.5 v1 交付:
//   - 4 种翻页 (覆盖/滑动/滚动/无, 仿真延后)
//   - 4 套主题 + 亮度
//   - 中心点击呼出菜单, 两侧点击翻页
//   - 上下章 / 进度条 / 目录 / 设置
//   - 接 ReaderEngine, 实时拉章节正文 + SQLite 缓存
//

import SwiftUI

public struct ReaderView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var readerScenePhase
    @StateObject private var engine: ReaderEngine
    @StateObject private var config = ReadConfig.shared
    /// 进入阅读器前的系统亮度快照 — 退出时还原，防止自定义亮度泄漏到全局导致黑屏
    @State private var savedSystemBrightness: CGFloat = -1

    @State private var menuVisible: Bool = false
    @GestureState private var dragStartPageId: String? = nil
    @State private var styleSheet: Bool = false
    @State private var tocSheet: Bool = false
    @State private var screenSize: CGSize = .zero
    @State private var contentCanvasSize: CGSize = .zero
    @State private var pages: [ReaderPage] = []
    @State private var currentPageId: String? = nil
    @State private var readTimer: Timer? = nil
    @State private var readingSecondsAccrued: Int = 0
    @State private var dictKeyword: String? = nil
    @State private var browserUrl: URL? = nil
    @State private var showFinishedView: Bool = false
    @State private var showTtsPlayer: Bool = false
    @State private var showSearchContent: Bool = false
    @State private var showContentEdit: Bool = false
    @State private var showChangeSource: Bool = false
    @State private var showChangeChapterSource: Bool = false
    @StateObject private var autoRead = AutoReadController.shared
    @State private var showAutoReadConfig: Bool = false
    /// 万象书屋 (M2.6.4): 阅读器内整本下载, 跟 BookDetailView.downloadRow 共用
    /// `BookDownloader.shared` 单例, 不管在哪开始下载状态都同步.
    @StateObject private var downloader = BookDownloader.shared
    @State private var showCancelDownloadConfirm = false
    /// 对齐 Android RewardedAdHelper.tryPrompt — 确认弹窗
    @State private var showRewardedPrompt = false
    /// 对齐 Android checkChapterPaywall — 章节付费墙锁屏
    @State private var showChapterPaywall = false
    @State private var chapterPaywallLoading = false
    /// 精确阅读位置（字符偏移量），用于 canvas 尺寸变化后 reflow 时保持准确位置。
    /// 初始值来自 book.durChapterPos，翻页时同步更新。
    @State private var preciseCharPos: Int = -1

    public init(book: ShelfBook, source: BookSource? = nil) {
        _engine = StateObject(wrappedValue: ReaderEngine(book: book, source: source))
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                config.theme.background.ignoresSafeArea()

                if showFinishedView {
                    BookFinishedView(
                        bookName: engine.book.name,
                        onGoBookshelf: { dismiss() },
                        onGoBookStore: { dismiss() },
                        onChangeSource: { /* M2.5.5.1 留 */ },
                        onWatchAdToContinue: {
                            Task {
                                _ = await AdManager.shared.showRewardedToUnlock()
                                showFinishedView = false
                            }
                        }
                    )
                } else {
                    VStack(spacing: 0) {
                        PurifiedTopBar()
                        contentView(canvasSize: geo.size)
                            .background(
                                GeometryReader { contentGeo in
                                    Color.clear
                                        .onAppear {
                                            contentCanvasSize = contentGeo.size
                                            debouncedRepaginate()
                                        }
                                        .onChange(of: contentGeo.size) { _, newSize in
                                            contentCanvasSize = newSize
                                            debouncedRepaginate()
                                        }
                                }
                            )
                    }
                }

                if menuVisible {
                    menuOverlay
                        .transition(.opacity)
                }

                if showChapterPaywall {
                    chapterPaywallOverlay
                        .transition(.opacity)
                }
            }
            // 上滑唤目录 (M2.5.7.3)
            .gesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        if value.translation.height < -80 && abs(value.translation.width) < 50 {
                            tocSheet = true
                        }
                    }
            )
            .sheet(item: Binding(
                get: { dictKeyword.map { DictItem(text: $0) } },
                set: { _ in dictKeyword = nil })
            ) { item in
                DictLookupSheet(keyword: item.text)
            }
            .sheet(item: Binding(
                get: { browserUrl.map { BrowserItem(url: $0) } },
                set: { _ in browserUrl = nil })
            ) { item in
                InAppBrowserScreen(url: item.url)
            }
            .onAppear {
                screenSize = geo.size
                viewAppearDate = Date()
                Task { await engine.bootstrap() }
                startReadingTimer()
                UIApplication.shared.isIdleTimerDisabled = config.keepScreenOn
                savedSystemBrightness = UIScreen.main.brightness
                applyBrightness()
                // 万象书屋: 记录「正在阅读」状态 — App 完全退出后重新打开能恢复到此书
                UserDefaults.standard.set(engine.book.bookUrl, forKey: "wx.lastOpenedBookUrl")
                // 万象书屋 (debug arg): 自动化测试入口
                let args = ProcessInfo.processInfo.arguments
                if args.contains("--ReaderShowMenu") || args.contains("-ReaderShowMenu") {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        withAnimation { menuVisible = true }
                    }
                }
                if args.contains("--ReaderShowChangeSource") || args.contains("-ReaderShowChangeSource") {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        showChangeSource = true
                    }
                }
                if args.contains("--ReaderShowChangeChapterSource") || args.contains("-ReaderShowChangeChapterSource") {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        showChangeChapterSource = true
                    }
                }
                if args.contains("--ReaderTriggerDownload") || args.contains("-ReaderTriggerDownload") {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        triggerDownloadFromReader()
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        withAnimation { menuVisible = true }
                    }
                }
                #if DEBUG
                if args.contains("--TestChapterPaywall") {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        for i in 0..<5 {
                            PurifiedReadingState.shared.markChapterOpened(uniqueKey: "test://paywall|\(i)")
                        }
                        checkChapterPaywall()
                    }
                }
                if args.contains("--TestRewardedPrompt") {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if !AdManager.shared.bootstrapped { await AdManager.shared.bootstrap() }
                        showRewardedPrompt = true
                    }
                }
                if args.contains("--TestAdGrace") {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        for _ in 1...4 {
                            let ok = await AdManager.shared.showRewardedToUnlock()
                            if PurifiedReadingState.shared.isActive || ok { break }
                        }
                    }
                }
                #endif
            }
            .onDisappear {
                stopReadingTimer()
                UIApplication.shared.isIdleTimerDisabled = false
                // 万象书屋 (P0 fix): 阅读器退出时恢复 interactivePopGestureRecognizer,
                // 让书架/详情页的返回手势恢复正常.
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first?.windows.first
                    .flatMap { findNavigationController(in: $0.rootViewController) }?
                    .interactivePopGestureRecognizer?.isEnabled = true
                // 退出阅读器时还原系统亮度，防止自定义低亮度泄漏到全局导致黑屏
                if savedSystemBrightness >= 0 {
                    UIScreen.main.brightness = savedSystemBrightness
                }
            }
            .onChange(of: readerScenePhase) { _, phase in
                switch phase {
                case .inactive, .background:
                    // 进入后台/非活跃时还原系统亮度，避免 App Switcher 截图呈现全黑
                    if savedSystemBrightness >= 0 {
                        UIScreen.main.brightness = savedSystemBrightness
                    }
                case .active:
                    // 回到前台时重新应用阅读器自定义亮度
                    applyBrightness()
                @unknown default:
                    break
                }
            }
            .onChange(of: config.brightness) { _, _ in applyBrightness() }
            .onChange(of: config.autoBrightness) { _, _ in applyBrightness() }
            .onChange(of: geo.size) { _, newSize in
                screenSize = newSize
                debouncedRepaginate()
            }
            .onChange(of: config.keepScreenOn) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
            }
            // 万象书屋: 翻页时实时持久化页内位置 (精确到章节内第几页)
            .onChange(of: currentPageId) { _, newId in
                if let id = newId { saveReadingPosition(pageId: id) }
            }
            .onChange(of: engine.currentChapterIndex) { _, newIdx in
                // 万象书屋 (跨章翻页): 如果是从 pager 滑入相邻章节触发的切章, 保持当前页不回跳首页
                let target = crossChapterTargetPageId
                crossChapterTargetPageId = nil
                repaginateCurrent(targetPageId: target)
                let key = "\(engine.book.bookUrl)|\(newIdx)"
                PurifiedReadingState.shared.markChapterOpened(uniqueKey: key)
                checkChapterPaywall()
            }
            .onChange(of: engine.loadingChapter) { _, _ in
                debouncedRepaginate()
            }
            .onChange(of: engine.chapterContentRevision) { _, _ in
                debouncedRepaginate()
            }
            // 任何排版字段变化都要重新分页
            .onReceive(config.$textSize.combineLatest(
                config.$lineSpacing,
                config.$paragraphSpacing,
                config.$paddingHorizontal
            )) { _ in
                repaginateCurrent()
            }
            // 万象书屋 (M2.8): 切字体也要重新分页
            .onReceive(config.$fontFamily) { _ in
                repaginateCurrent()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // 万象书屋 (P0 fix): TabView 默认 push 时不隐藏底部 tabBar, 阅读器必须沉浸全屏
        .toolbar(.hidden, for: .tabBar)
        // 万象书屋 (P0 fix crash): 隐藏导航栏后 iOS 的 interactivePopGestureRecognizer 仍激活,
        // 用户左边缘横划会意外退出阅读器. 在 body 上叠一个透明 UIView 并在 appear/disappear
        // 中切换 isEnabled, 阻断这个系统手势; 不影响阅读器内的翻页/上滑手势.
        .background(SwipeBackBlocker())
        .navigationBarBackButtonHidden(true)
        // 万象书屋: 阅读器 PV (跟 Android `ReadBookActivity` 自动 trackPageName 等价)
        .trackPageView("page_reader")
        .statusBarHidden(!menuVisible)
        .preferredColorScheme(config.theme.isDark ? .dark : .light)
        .sheet(isPresented: $styleSheet) {
            ReadStyleSheet().presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $tocSheet) {
            TocView(
                chapters: engine.chapters,
                currentIndex: engine.currentChapterIndex,
                bookUrl: engine.book.bookUrl
            ) { idx in
                tocSheet = false
                Task { await engine.goToChapter(idx) }
            }
        }
        .fullScreenCover(isPresented: $showTtsPlayer) {
            TtsPlayerView(
                book: engine.book,
                chapters: engine.chapters,
                startIndex: engine.currentChapterIndex
            )
        }
        .sheet(isPresented: $showSearchContent) {
            SearchContentView(
                book: engine.book,
                chapters: engine.chapters,
                currentChapterIndex: engine.currentChapterIndex
            ) { idx in
                Task { await engine.goToChapter(idx) }
            }
        }
        .confirmationDialog("净化此章", isPresented: $showContentEdit, titleVisibility: .visible) {
            Button("应用替换规则重新净化") {
                Task { await engine.retryCurrentChapter() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会重新拉取本章正文并按当前替换规则处理")
        }
        .sheet(isPresented: $showChangeSource) {
            ChangeSourceView(originalBook: engine.book) { newBook, newSource in
                Task { await engine.changeSource(to: newBook, source: newSource) }
            }
        }
        .sheet(isPresented: $showChangeChapterSource) {
            ChangeChapterSourceView(
                originalBook: engine.book,
                chapterIndex: engine.currentChapterIndex,
                chapterTitle: engine.chapters[safe: engine.currentChapterIndex]?.title ?? engine.book.durChapterTitle
            ) { body in
                Task {
                    await engine.replaceCurrentChapterBody(body)
                    await MainActor.run { showChangeChapterSource = false }
                }
            }
        }
        .sheet(isPresented: $showAutoReadConfig) {
            AutoReadConfigSheet()
        }
        .confirmationDialog("取消下载", isPresented: $showCancelDownloadConfirm, titleVisibility: .visible) {
            Button("取消下载", role: .destructive) {
                downloader.cancel(bookUrl: engine.book.bookUrl)
            }
            Button("继续下载", role: .cancel) {}
        } message: {
            Text("已下载的章节会保留, 仍可离线阅读")
        }
        // 对齐 Android RewardedAdHelper.tryPrompt: 确认弹窗
        .alert("看广告解锁纯净阅读", isPresented: $showRewardedPrompt) {
            Button("看广告") {
                Task {
                    _ = await AdManager.shared.showRewardedToUnlock()
                }
            }
            Button("跳过", role: .cancel) {}
        } message: {
            Text("看一段 30 秒广告即可解锁 30 分钟无打扰阅读")
        }
        // 万象书屋: 进入 reader 启用音量键翻页, 退出关闭
        .onAppear {
            NotificationCenter.default.post(name: .wanxiangTabBarHiddenChanged, object: true)
            VolumeKeyHandler.shared.enable(
                onUp: { Task { @MainActor in
                    autoRead.resetCountdown()
                    if currentPageId != nil { handlePageJump(to: prevPageId() ?? "") }
                } },
                onDown: { Task { @MainActor in
                    autoRead.resetCountdown()
                    if let next = nextPageId() { handlePageJump(to: next) }
                    else { Task { await engine.nextChapter() } }
                } }
            )
        }
        .onDisappear {
            VolumeKeyHandler.shared.disable()
            autoRead.stop()
            NotificationCenter.default.post(name: .wanxiangTabBarHiddenChanged, object: false)
        }
    }

    private func prevPageId() -> String? {
        guard let cur = currentPageId, let i = pages.firstIndex(where: { $0.id == cur }), i > 0 else { return nil }
        return pages[i - 1].id
    }
    private func nextPageId() -> String? {
        guard let cur = currentPageId, let i = pages.firstIndex(where: { $0.id == cur }), i + 1 < pages.count else { return nil }
        return pages[i + 1].id
    }

    // MARK: - Content (按翻页方式分发)

    @ViewBuilder
    private func contentView(canvasSize: CGSize) -> some View {
        Group {
            if engine.loadingChapter && engine.content(for: engine.currentChapterIndex) == nil {
                loadingState
            } else if engine.autoFallbackInProgress {
                // 万象书屋 (M2.8): 当前源拉失败时, ReaderEngine 后台静默尝试其他源.
                // 显示"正在尝试其他源…" 比直接 errorState 体验好.
                autoFallbackState
            } else if let err = engine.lastError {
                errorState(err)
            } else if pages.isEmpty {
                loadingState
            } else {
                switch config.pageAnim {
                case .scroll:   scrollPager
                case .simulate: simulatePager      // 仿真翻书 (UIPageViewController.pageCurl)
                default:        horizontalPager   // 覆盖 / 滑动 / 无 (TabView .page)
                }
            }
        }
        // 万象书屋: 双指捏合调字号 (M2.5.7.4)
        .gesture(
            MagnificationGesture()
                .onEnded { scale in
                    let delta = (scale - 1) * 4
                    let newSize = max(12, min(32, config.textSize + delta))
                    config.textSize = newSize
                }
        )
    }

    private var loadingState: some View {
        // 万象书屋 (M2.6 perf): spinner 时同时显示当前章节标题, 避免空白 spinner
        // 让用户感觉"卡住了". 章节标题来自 chapters[curr], 目录加载完就有.
        let curIdx = engine.currentChapterIndex
        let curTitle: String? = {
            if curIdx >= 0, curIdx < engine.chapters.count {
                return engine.chapters[curIdx].title
            }
            return nil
        }()
        return ZStack(alignment: .top) {
            VStack(spacing: 14) {
                if let title = curTitle, !title.isEmpty {
                    Text(title)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(config.theme.textColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                ProgressView()
                    .tint(config.theme.textColor)
                Text(curTitle == nil ? "加载目录…" : "加载正文…")
                    .font(.caption)
                    .foregroundStyle(config.theme.textColor.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture {
                withAnimation { menuVisible.toggle() }
            }
            // 万象书屋 (P0 fix): loading 超时时用户也能退出
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(WanxiangColors.primary.opacity(0.7))
                        .background(Circle().fill(.white.opacity(0.8)))
                }
                .padding(.leading, 16)
                .padding(.top, 50)
                Spacer()
            }
        }
    }

    /// 万象书屋 (M2.8): 当前源 fail 时 ReaderEngine 自动尝试其他源, 显示加载提示
    private var autoFallbackState: some View {
        ZStack {
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.1)
                Text("当前源拉不到, 正在尝试其他源…")
                    .font(.subheadline)
                    .foregroundStyle(WanxiangColors.textSecondary)
                Text("最长等 30 秒")
                    .font(.caption)
                    .foregroundStyle(WanxiangColors.textSecondary.opacity(0.6))
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2).foregroundStyle(WanxiangColors.textSecondary.opacity(0.5))
                    }
                    .padding(.leading, 16).padding(.top, 12)
                    Spacer()
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WanxiangColors.background)
    }

    private func errorState(_ msg: String) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(msg)
                    .font(.subheadline)
                    .foregroundStyle(config.theme.textColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            Task { await engine.retryCurrentChapter() }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(WanxiangColors.primary)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        // 万象书屋 (P1 fix): "找不到此书的源" 是后端撤源 / 用户改源后最常见错误,
                        // 之前只能"返回搜索重新加入". 这里直接给"换源"入口, 复用菜单里同一个 sheet.
                        // 用户点 → ChangeSourceView 全网搜本书 → 选新源 → engine.changeSource → 从此用新源.
                        Button { showChangeSource = true } label: {
                            Label("换源", systemImage: "arrow.triangle.2.circlepath")
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(WanxiangColors.accent)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                        Button { showChangeChapterSource = true } label: {
                            Label("本章换源", systemImage: "doc.text.magnifyingglass")
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .overlay(Capsule().stroke(WanxiangColors.accent.opacity(0.85), lineWidth: 1.5))
                                .foregroundStyle(WanxiangColors.accent)
                                .clipShape(Capsule())
                        }
                    }
                    // 万象书屋 (P0 fix): 出错状态也得能返回 (顶部 nav 默认隐藏, 这里给 fallback)
                    Button { dismiss() } label: {
                        Label("返回", systemImage: "chevron.backward")
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .overlay(Capsule().stroke(WanxiangColors.primary.opacity(0.6)))
                            .foregroundStyle(WanxiangColors.primary)
                            .clipShape(Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 万象书屋: 顶部留一个 close 按钮兜底 (即使 errorState 没渲染按钮, 用户也能退出)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(WanxiangColors.primary.opacity(0.7))
                        .background(Circle().fill(.white.opacity(0.8)))
                }
                .padding(.leading, 16)
                .padding(.top, 50)
                Spacer()
            }
        }
    }

    // MARK: - 翻页方式

    private var horizontalPager: some View {
        TabView(selection: Binding(
            get: { currentPageId ?? pages.first?.id ?? "" },
            set: { newId in
                currentPageId = newId
                handlePageJump(to: newId)
            }
        )) {
            ForEach(pages) { page in
                ReaderPageView(
                    page: page,
                    config: config,
                    bookName: engine.book.name,
                    chapterCount: engine.chapters.count,
                    onTapMenu: { withAnimation { menuVisible.toggle() } },
                    onTapPrev: {
                        if let id = prevPageId() {
                            currentPageId = id
                            handlePageJump(to: id)
                        } else {
                            Task { await engine.goToChapter(max(0, engine.currentChapterIndex - 1)) }
                        }
                    },
                    onTapNext: {
                        if let id = nextPageId() {
                            currentPageId = id
                            handlePageJump(to: id)
                        } else {
                            Task { await engine.nextChapter() }
                        }
                    },
                    onSelectionAction: { action, text in handleSelection(action: action, text: text) }
                )
                .tag(page.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(edges: [])
        // 章节边界滑动：仅当相邻章节未在 pages 缓冲中时才通过此 gesture 切章
        // (若已在缓冲中, TabView 自身已能滑过章节边界, handlePageJump 会更新 engine; 无需在此重复)
        .simultaneousGesture(
            DragGesture(minimumDistance: 40, coordinateSpace: .local)
                .updating($dragStartPageId) { _, state, _ in
                    if state == nil { state = currentPageId }
                }
                .onEnded { value in
                    let dx = value.translation.width
                    let startPage = pages.first(where: { $0.id == dragStartPageId })
                    // 只在 pages 缓冲中没有更多页时才手动切章，避免与 handlePageJump 双重触发
                    if dx < -40, startPage?.isLastPage == true, nextPageId() == nil {
                        Task { await engine.nextChapter() }
                    } else if dx > 40, startPage?.isFirstPage == true, prevPageId() == nil {
                        Task { await engine.goToChapter(max(0, engine.currentChapterIndex - 1)) }
                    }
                }
        )
    }

    /// 仿真翻书 (UIPageViewController .pageCurl, 跟 iBooks 同款)
    private var simulatePager: some View {
        PageCurlContainer(
            pages: pages.map { p in
                (id: p.id, view: ReaderPageView(
                    page: p,
                    config: config,
                    bookName: engine.book.name,
                    chapterCount: engine.chapters.count,
                    onTapMenu: { withAnimation { menuVisible.toggle() } },
                    onTapPrev: {
                        // 万象书屋: 仿真模式下不加 withAnimation, PVC 自己管理 curl 动画
                        if let id = prevPageId() {
                            currentPageId = id
                            handlePageJump(to: id)
                        } else {
                            Task { await engine.goToChapter(max(0, engine.currentChapterIndex - 1)) }
                        }
                    },
                    onTapNext: {
                        if let id = nextPageId() {
                            currentPageId = id
                            handlePageJump(to: id)
                        } else {
                            Task { await engine.nextChapter() }
                        }
                    },
                    onSelectionAction: { action, text in handleSelection(action: action, text: text) }
                ))
            },
            currentId: Binding(
                get: { currentPageId ?? pages.first?.id ?? "" },
                set: { newId in
                    currentPageId = newId
                    handlePageJump(to: newId)
                }
            ),
            // 万象书屋: 传入阅读器背景色, UIHostingController 用此色填底, 消除白闪
            backgroundColor: UIColor(config.theme.background)
        )
        .ignoresSafeArea()
    }

    private var scrollPager: some View {
        ScrollView {
            LazyVStack(spacing: config.paragraphSpacing) {
                // 滚动模式：滚到顶部时加载上一章
                // 防抖: scrollPagerPrevLoading 避免 LazyVStack 重渲染时 onAppear 连续触发多次切章
                if engine.currentChapterIndex > 0 {
                    Color.clear.frame(height: 1)
                        .onAppear {
                            guard !scrollPagerPrevLoading,
                                  Date().timeIntervalSince(lastScrollChapterSwitchDate) > 0.8 else { return }
                            scrollPagerPrevLoading = true
                            lastScrollChapterSwitchDate = Date()
                            Task {
                                await engine.previousChapter()
                                // 延迟重置防抖标记，给 LazyVStack 足够时间稳定布局
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                scrollPagerPrevLoading = false
                            }
                        }
                }
                ForEach(pages) { page in
                    chapterPageBody(page: page)
                        .padding(.horizontal, config.paddingHorizontal)
                }
                // 滚动模式：滚到底部时加载下一章
                if engine.currentChapterIndex + 1 < engine.chapters.count {
                    if let last = pages.last {
                        Color.clear.frame(height: 1)
                            .onAppear {
                                guard !scrollPagerNextLoading,
                                      Date().timeIntervalSince(lastScrollChapterSwitchDate) > 0.8 else { return }
                                scrollPagerNextLoading = true
                                lastScrollChapterSwitchDate = Date()
                                _ = last
                                Task {
                                    await engine.nextChapter()
                                    try? await Task.sleep(nanoseconds: 500_000_000)
                                    scrollPagerNextLoading = false
                                }
                            }
                    }
                }
            }
            .padding(.top, config.paddingTop)
            .padding(.bottom, config.paddingBottom)
        }
        .onTapGesture {
            withAnimation { menuVisible.toggle() }
        }
    }

    // MARK: - 菜单

    private var menuOverlay: some View {
        VStack(spacing: 0) {
            // 顶部
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(currentPageText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                // 万象书屋: 章内/全书搜索 (M2.5.7 新加)
                Button {
                    showSearchContent = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white)
                }
                // 万象书屋 (M2.6.3): 听书入口
                Button {
                    showTtsPlayer = true
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.white)
                }
                // 万象书屋: 换源 / 下载 / 章节编辑 / 自动翻页
                Menu {
                    // 万象书屋 (M2.6.4): 阅读器内换源 — 用户读到一半发现源文质量差直接切.
                    Button { showChangeSource = true } label: {
                        Label("换源", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button { showChangeChapterSource = true } label: {
                        Label("本章换源", systemImage: "doc.text.magnifyingglass")
                    }
                    // 万象书屋 (M2.6.4): 阅读器内整本下载 — 出门前点一下, 离线读全本.
                    downloadMenuItem
                    Divider()
                    Button {
                        Task { await engine.retryCurrentChapter() }
                    } label: { Label("重新加载", systemImage: "arrow.clockwise") }
                    Button { showContentEdit = true } label: {
                        Label("净化此章", systemImage: "sparkles")
                    }
                    Divider()
                    Button {
                        autoRead.toggle(onTurn: { Task { await self.engine.nextChapter() } })
                    } label: {
                        Label(autoRead.isRunning ? "停止自动翻页" : "自动翻页",
                              systemImage: autoRead.isRunning ? "stop.circle" : "play.circle")
                    }
                    Button { showAutoReadConfig = true } label: {
                        Label("自动翻页设置", systemImage: "speedometer")
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.white)
                        // 万象书屋: 下载中给 ⋯ 按钮加个小红点, 让用户知道有任务在跑
                        if let job = downloader.job(for: engine.book.bookUrl),
                           job.status == .running {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                                .offset(x: 2, y: -2)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 50)
            .padding(.bottom, 12)
            .background(.black.opacity(0.7))

            // 万象书屋 (M2.6.4): 下载中时菜单顶部 bar 下方显示一条进度, 让用户能直接看到
            // 整本下载状态, 不用再点 ⋯ 进菜单.
            if let job = downloader.job(for: engine.book.bookUrl), job.status == .running {
                downloadProgressStrip(job: job)
            }

            Spacer()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation { menuVisible = false }
                }

            // 底部
            VStack(spacing: 14) {
                // 进度条
                // 万象书屋 (2026-05-11 crash fix): chapters.count == 1 时 range = 0...0 + step 1
                // 会让 SwiftUI Slider Normalizing precondition fail (EXC_BREAKPOINT 崩溃).
                // 必须 count > 1 才显示 slider; 单章直接显示 "1/1" 文本即可.
                if engine.chapters.count > 1 {
                    HStack {
                        Text("\(engine.currentChapterIndex + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                        Slider(
                            value: Binding(
                                get: {
                                    let v = Double(engine.currentChapterIndex)
                                    let upper = Double(engine.chapters.count - 1)
                                    return min(max(0, v), upper)   // clamp 防 currentChapterIndex 越界
                                },
                                set: { newVal in
                                    Task { await engine.goToChapter(Int(newVal)) }
                                }
                            ),
                            in: 0...Double(engine.chapters.count - 1),
                            step: 1
                        )
                        .tint(WanxiangColors.primary)
                        Text("\(engine.chapters.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal)
                } else if engine.chapters.count == 1 {
                    HStack {
                        Text("1 / 1")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                // 5 个按钮: 上一章 / 目录 / 设置 / 书签 / 下一章
                HStack(spacing: 0) {
                    menuBtn("chevron.left", "上一章") {
                        Task { await engine.previousChapter() }
                    }
                    menuBtn("list.bullet", "目录") { tocSheet = true }
                    menuBtn("textformat.size", "设置") { styleSheet = true }
                    menuBtn("chevron.right", "下一章") {
                        Task {
                            if engine.currentChapterIndex + 1 >= engine.chapters.count {
                                showFinishedView = true
                            } else {
                                await engine.nextChapter()
                            }
                        }
                    }
                }
                .padding(.bottom, 28)
            }
            .background(.black.opacity(0.7))
        }
        .ignoresSafeArea()
    }

    /// 万象书屋 (M2.8 Gap 3): scrollPager 用的 page body wrapper, 跟 ReaderPageView 的
    /// ChapterPageBody 等价 (内部都是 segments 渲染).
    @ViewBuilder
    private func chapterPageBody(page: ReaderPage) -> some View {
        ChapterPageBody(pageText: page.text, chapterTitle: page.chapterTitle, config: config)
    }

    private func menuBtn(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    /// 万象书屋 (M2.6.4): 阅读器 ⋯ 菜单里的下载本书项, 三态:
    ///   未下载  → "下载本书 (1453 章)" 点击立即开始
    ///   下载中  → "下载中 234/1453 (16%)"  点击弹 confirm 取消
    ///   已完成  → "已下载 1453 章"  点击重新下载
    @ViewBuilder
    private var downloadMenuItem: some View {
        let bookUrl = engine.book.bookUrl
        let job = downloader.job(for: bookUrl)
        let chapterCount = engine.chapters.count
        let canDownload = chapterCount > 0
        if let job = job, job.status == .running {
            Button {
                showCancelDownloadConfirm = true
            } label: {
                Label("下载中 \(job.completed + job.failed)/\(job.total) · 取消",
                      systemImage: "stop.circle")
            }
        } else if let job = job, job.status == .finished {
            Button {
                triggerDownloadFromReader()
            } label: {
                Label("已下载 \(job.completed) 章 · 重新下载",
                      systemImage: "checkmark.circle")
            }
        } else if let job = job, job.status == .error {
            Button {
                triggerDownloadFromReader()
            } label: {
                Label("下载失败 · 重试", systemImage: "exclamationmark.triangle")
            }
        } else {
            Button {
                if canDownload { triggerDownloadFromReader() }
            } label: {
                if canDownload {
                    Label("下载本书", systemImage: "arrow.down.circle")
                } else {
                    Label("下载本书 (等目录…)",
                          systemImage: "arrow.down.circle")
                }
            }
            .disabled(!canDownload)
        }
    }

    /// 阅读器内触发整本下载. 用 engine.book + engine 内部 source.
    private func triggerDownloadFromReader() {
        let source = BookSourceRegistry.shared.find(origin: engine.book.origin)
        downloader.startDownload(book: engine.book, source: source)
    }

    /// menuOverlay 顶部下方的下载进度条 (仅 running 时显示).
    @ViewBuilder
    private func downloadProgressStrip(job: BookDownloader.Job) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("正在下载本书")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(job.completed + job.failed)/\(job.total) · \(Int(job.progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
                ProgressView(value: job.progress)
                    .tint(.orange)
            }
            Button {
                showCancelDownloadConfirm = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55))
    }

    private var currentPageText: String {
        // 优先读当前页自身的 chapterTitle，保证跨章缓冲翻页时实时更新
        if let page = pages.first(where: { $0.id == currentPageId }),
           !page.chapterTitle.isEmpty {
            return page.chapterTitle
        }
        let title = engine.chapters[safe: engine.currentChapterIndex]?.title ?? ""
        return title.isEmpty ? engine.book.name : title
    }

    // MARK: - 章节付费墙 UI (对齐 Android chapter_unlock_view)

    @ViewBuilder
    private var chapterPaywallOverlay: some View {
        ZStack {
            config.theme.background.opacity(0.95).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("需要解锁才能继续阅读")
                    .font(.title2.bold())
                Text("看一段广告即可解锁 30 分钟无打扰阅读")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                if chapterPaywallLoading {
                    ProgressView("加载中…")
                        .padding()
                } else {
                    VStack(spacing: 12) {
                        Button {
                            let unlock = (AdManager.shared.cachedConfig?["chapterUnlock"] as? [String: Any])
                            let minutes = (unlock?["unlockMinutes"] as? Int) ?? 30
                            triggerRewardedForPaywall(unlockMinutes: minutes)
                        } label: {
                            Label("看广告解锁", systemImage: "play.rectangle.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            showChapterPaywall = false
                            Task { await engine.previousChapter() }
                        } label: {
                            Text("返回上一章")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 40)
                }
                Spacer()
            }
            .padding()
        }
    }

    // MARK: - 章节付费墙逻辑 (对齐 Android checkChapterPaywall)

    private func checkChapterPaywall() {
        if CommandLine.arguments.contains("-uitest") {
            showChapterPaywall = false
            return
        }
        let cfg = AdManager.shared
        guard cfg.enabled, cfg.consented, !cfg.reviewMode else {
            showChapterPaywall = false
            return
        }
        let adConfig = cfg.cachedConfig ?? [:]
        guard let chapterUnlock = (adConfig["chapterUnlock"] as? [String: Any]),
              (chapterUnlock["enabled"] as? Bool) == true else {
            showChapterPaywall = false
            if AdManager.shared.shouldPromptRewarded() { showRewardedPrompt = true }
            return
        }
        let freeChapters = (chapterUnlock["freeChapters"] as? Int) ?? 3
        let blockOnSkip = (chapterUnlock["blockOnSkip"] as? Bool) ?? true

        guard PurifiedReadingState.shared.shouldRequireUnlock(freeChapters: freeChapters) else {
            showChapterPaywall = false
            if AdManager.shared.shouldPromptRewarded() { showRewardedPrompt = true }
            return
        }

        if !blockOnSkip {
            Task { _ = await AdManager.shared.showRewardedToUnlock() }
            return
        }

        showChapterPaywall = true
        chapterPaywallLoading = true
        triggerRewardedForPaywall(unlockMinutes: (chapterUnlock["unlockMinutes"] as? Int) ?? 30)
    }

    private func triggerRewardedForPaywall(unlockMinutes: Int) {
        chapterPaywallLoading = true
        Task {
            let success = await AdManager.shared.showRewardedToUnlock(minutes: unlockMinutes)
            await MainActor.run {
                // 广告成功 / 宽限期生效 / 广告失败均关闭付费墙
                // 广告失败时（模拟器/无网络/无广告填充）不卡死 UI：
                //   失败计数已在 showRewardedToUnlock 内通过 recordAdFailureAndCheckGrace 累计，
                //   连续 3 次失败后宽限期自动开启；本次放行让用户继续，paywall 下次触发时再拦。
                showChapterPaywall = false
                chapterPaywallLoading = false
            }
        }
    }

    // MARK: - 分页 / 翻页处理

    /// 万象书屋 (跨章翻页): 用户从 pager 滑入相邻章节时, 记录目标页 id.
    /// onChange(of: engine.currentChapterIndex) 用它来保持显示位置, 不回跳首页.
    @State private var crossChapterTargetPageId: String? = nil
    /// 万象书屋: 首次分页后是否已经恢复了页内进度 (每个 ReaderView 实例只恢复一次)
    @State private var hasRestoredPagePosition = false
    /// 万象书屋: 阅读计时开始时间 — 用于 stopReadingTimer 准确计算本次 session 剩余不足 60s 的秒数
    @State private var readTimerStartDate: Date? = nil
    /// 万象书屋: 滚动模式上/下章节加载防抖标记 — 防止 onAppear 在重渲染时连续触发多次切章
    @State private var scrollPagerPrevLoading = false
    @State private var scrollPagerNextLoading = false
    /// 万象书屋: 滚动模式最近一次切章时间戳 — 防止 onAppear 连锁触发 (章节内容短时哨兵立刻重新出现)
    @State private var lastScrollChapterSwitchDate: Date = .distantPast
    /// push 动画期间 canvas size 会连续变化 (tab bar / nav bar 逐渐隐藏).
    /// 记录首帧时间, 在动画完成前将 size 变化产生的 repaginate 用 debounce 合并为 1 次,
    /// 避免先分出"底部大片空白"的页面再闪烁修正.
    @State private var viewAppearDate: Date = .distantFuture
    @State private var sizeDebounceTask: Task<Void, Never>? = nil

    /// push 动画期间 (~0.7s), canvas size 连续变化 (tab bar 隐藏 + nav bar 隐藏).
    /// 在动画窗口内用 debounce 合并所有 repaginate 请求, 确保只在 viewport 稳定后
    /// 执行一次分页, 避免先显示错误 viewport 的页面再跳转到正确页面.
    /// 动画结束后的后续请求立即执行, 不引入感知延迟.
    private func debouncedRepaginate(targetPageId: String? = nil) {
        let elapsed = Date().timeIntervalSince(viewAppearDate)
        if elapsed > 1.0 {
            repaginateCurrent(targetPageId: targetPageId)
            return
        }
        sizeDebounceTask?.cancel()
        sizeDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            repaginateCurrent(targetPageId: targetPageId)
        }
    }

    /// - Parameter targetPageId: 若非 nil, 且在重建后的 pages 中存在, 则保持该页为 currentPageId.
    ///   用于跨章节翻页场景 (用户滑进相邻章节), 防止章节切换时 UI 跳回首页.
    ///   nil (默认) = 跳到当前章的第一页 (菜单跳章、进度条跳章场景).
    private func repaginateCurrent(targetPageId: String? = nil) {
        let viewport = contentCanvasSize.width > 0 ? contentCanvasSize : screenSize
        guard viewport.width > 0 else { return }
        let idx = engine.currentChapterIndex
        guard engine.content(for: idx) != nil else {
            pages = []
            return
        }

        #if DEBUG
        let ts = String(format: "%.3f", Date().timeIntervalSince(viewAppearDate))
        print("[REPAG] t=\(ts)s viewport=\(viewport) hasRestored=\(hasRestoredPagePosition) " +
              "idx=\(idx) durIdx=\(engine.book.durChapterIndex) durPos=\(engine.book.durChapterPos) " +
              "curPageId=\(currentPageId ?? "nil") targetPageId=\(targetPageId ?? "nil")")
        #endif

        // 页脚: 11pt 字体 + 8pt 顶部间距 ≈ 22pt
        let footerHeight: CGFloat = 22
        // 页眉: 11pt 字体 + 8pt 底部间距 ≈ 22pt
        let headerHeight: CGFloat = 22
        let canvasSize = CGSize(
            width: max(0, viewport.width - config.paddingHorizontal * 2),
            height: max(0, viewport.height - config.paddingTop - config.paddingBottom - footerHeight - headerHeight)
        )
        let snapshot = ReadConfigSnapshot.current(from: config)

        // 万象书屋 (跨章翻页): 把当前章 ± 1 章 (如果内容已在 contentCache 中) 一起分页并合并.
        // 这样 PageCurlContainer / TabView 的 pages 数组里包含相邻章节的页面,
        // viewControllerAfter/Before 不会在章节边界返回 nil, 用户可以用相同手势滑过章节边界.
        func paginateIfCached(_ i: Int) -> [ReaderPage] {
            guard i >= 0, i < engine.chapters.count,
                  let body = engine.content(for: i) else { return [] }
            let title = engine.chapters[safe: i]?.title ?? engine.book.name
            return PaginationEngine.paginate(text: body, chapterIndex: i,
                                             chapterTitle: title, canvasSize: canvasSize, config: snapshot)
        }

        let prevPages = paginateIfCached(idx - 1)
        let currPages = paginateIfCached(idx)
        let nextPages = paginateIfCached(idx + 1)
        let combined = prevPages + currPages + nextPages

        let oldPages = self.pages
        self.pages = combined

        // 确定 currentPageId:
        // - 跨章翻页时保持 targetPageId (已在相邻章节的页里) 不回跳
        // - 首次分页 (冷启恢复): 用 book.durChapterPos 精确恢复到上次读到的页
        // - 重新分页 (canvas 尺寸变化): 按字符偏移量定位, 而非 page ID (因为同一 ID 在
        //   不同 canvas 下对应不同文本)
        // - 普通跳章: 跳到当前章第一页
        if let target = targetPageId, combined.contains(where: { $0.id == target }) {
            self.currentPageId = target
            if let p = combined.first(where: { $0.id == target }) { preciseCharPos = p.charOffset }
            #if DEBUG
            print("[REPAG] -> targetPageId=\(target)")
            #endif
        } else if !hasRestoredPagePosition {
            hasRestoredPagePosition = true
            let savedPos = engine.book.durChapterPos
            if savedPos > 0, idx == engine.book.durChapterIndex {
                preciseCharPos = savedPos
                let restoredPage = currPages.first(where: { $0.containsPos(savedPos) }) ?? currPages.first
                self.currentPageId = restoredPage?.id ?? combined.first?.id
                #if DEBUG
                print("[REPAG] -> RESTORE savedPos=\(savedPos) -> page=\(restoredPage?.id ?? "nil") offset=\(restoredPage?.charOffset ?? -1)")
                #endif
            } else {
                self.currentPageId = currPages.first?.id ?? combined.first?.id
                #if DEBUG
                print("[REPAG] -> FIRST PAGE (no match: savedPos=\(savedPos) durIdx=\(engine.book.durChapterIndex) idx=\(idx))")
                #endif
            }
        } else {
            let posToRestore = preciseCharPos >= 0 ? preciseCharPos : {
                if let cur = currentPageId,
                   let oldPage = oldPages.first(where: { $0.id == cur }) {
                    return oldPage.charOffset
                }
                return -1
            }()
            if posToRestore >= 0 {
                let chapterIdx = oldPages.first(where: { $0.id == currentPageId })?.chapterIndex ?? idx
                let restored = combined.first(where: {
                    $0.chapterIndex == chapterIdx && $0.containsPos(posToRestore)
                })
                self.currentPageId = restored?.id ?? currPages.first?.id ?? combined.first?.id
                #if DEBUG
                print("[REPAG] -> REFLOW precisePos=\(posToRestore) -> newPage=\(restored?.id ?? "fallback") newOffset=\(restored?.charOffset ?? -1)")
                #endif
            } else {
                self.currentPageId = currPages.first?.id ?? combined.first?.id
                #if DEBUG
                print("[REPAG] -> REFLOW FALLBACK (oldPage not found in oldPages)")
                #endif
            }
        }
    }

    /// 翻页/章节切换时持久化页内字符偏移量 (对齐 Android durChapterPos)
    private func saveReadingPosition(pageId: String) {
        guard let page = pages.first(where: { $0.id == pageId }) else { return }
        UserDefaults.standard.set(page.chapterIndex, forKey: "wx.lastReadingChapterIndex")
        UserDefaults.standard.set(page.charOffset, forKey: "wx.lastReadingCharOffset")
        // 同步写入 DB durChapterPos (与 Android book.durChapterPos 对齐)
        Task.detached(priority: .utility) { [bookUrl = engine.book.bookUrl,
                                             chapterIndex = page.chapterIndex,
                                             chapterPos = page.charOffset] in
            try? await BookshelfRepository.shared.updateProgress(
                bookUrl: bookUrl,
                chapterIndex: chapterIndex,
                chapterTitle: nil,
                chapterPos: chapterPos
            )
        }
    }

    private func handlePageJump(to id: String) {
        if let page = pages.first(where: { $0.id == id }) {
            preciseCharPos = page.charOffset
        }
        // id 形如 "chapterIdx-pageIdx", 当前章内翻页不需要切章; 跨章也通过这处理
        let parts = id.split(separator: "-")
        guard parts.count == 2,
              let cIdx = Int(parts[0]) else { return }
        if cIdx != engine.currentChapterIndex {
            // 万象书屋 (跨章翻页): 记录目标页, 让 onChange(of: currentChapterIndex) 保持该页不跳回首页
            crossChapterTargetPageId = id
            Task { await engine.goToChapter(cIdx) }
        }
    }

    // MARK: - 阅读时长统计 (M2.5.7.6)

    private func startReadingTimer() {
        readingSecondsAccrued = 0
        readTimerStartDate = Date()
        readTimer?.invalidate()
        readTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                readingSecondsAccrued += 60
                let bookUrl = engine.book.bookUrl
                try? await ReadRecordRepository.shared.addSeconds(bookUrl: bookUrl, seconds: 60)
            }
        }
    }

    private func stopReadingTimer() {
        readTimer?.invalidate()
        readTimer = nil
        // 退出时把已计时但还没满 60s 的零头一并写入
        // 例: 阅读 5m45s → 定时器已累计 5×60=300s, 剩余 45s 这里补记
        let totalElapsed = readTimerStartDate.map { Int(Date().timeIntervalSince($0)) } ?? 0
        readTimerStartDate = nil
        let remaining = max(0, totalElapsed - readingSecondsAccrued)
        if readingSecondsAccrued == 0 {
            // 读了不到 1 分钟就退出 — 至少记 30 秒, 避免极短阅读完全丢失
            let toAdd = max(30, remaining)
            Task {
                try? await ReadRecordRepository.shared.addSeconds(bookUrl: engine.book.bookUrl, seconds: toAdd)
            }
        } else if remaining >= 10 {
            Task {
                try? await ReadRecordRepository.shared.addSeconds(bookUrl: engine.book.bookUrl, seconds: remaining)
            }
        }
    }

    /// 万象书屋: 应用亮度 (M2.5.4)
    private func applyBrightness() {
        if config.autoBrightness || config.brightness < 0 {
            return  // 跟随系统
        }
        UIScreen.main.brightness = CGFloat(config.brightness) / 100.0
    }

    // MARK: - 选词菜单 7 项 action 处理 (M2.5.6.1)

    private func handleSelection(action: SelectableTextView.SelectionAction, text: String) {
        guard !text.isEmpty else { return }
        switch action {
        case .copyText:
            UIPasteboard.general.string = text
        case .replace:
            // M2.5.5: 跳到 ReplaceRule 编辑页, 预填 pattern
            // 简化: 直接复制到剪贴板
            UIPasteboard.general.string = text
        case .bookmark:
            Task {
                let chapter = engine.chapters[safe: engine.currentChapterIndex]
                let b = BookmarkEntity(
                    bookUrl: engine.book.bookUrl,
                    bookName: engine.book.name,
                    chapterIndex: engine.currentChapterIndex,
                    chapterTitle: chapter?.title,
                    content: text
                )
                _ = try? await BookmarkRepository.shared.add(b)
            }
        case .dict:
            dictKeyword = text
        case .searchContent:
            // M2.5.7.7 全书搜留, 简化: 复制到剪贴板
            UIPasteboard.general.string = text
        case .browser:
            let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            if let url = URL(string: "https://www.baidu.com/s?wd=\(q)") {
                browserUrl = url
            }
        case .share:
            let av = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first?.rootViewController }
                .first?.present(av, animated: true)
        }
    }

    /// 万象书屋: 当前章节加书签 (M2.5.5.5)
    private func addBookmark() async {
        let chapter = engine.chapters[safe: engine.currentChapterIndex]
        let bookmark = BookmarkEntity(
            bookUrl: engine.book.bookUrl,
            bookName: engine.book.name,
            chapterIndex: engine.currentChapterIndex,
            chapterTitle: chapter?.title,
            chapterPos: 0,
            content: nil,
            note: nil
        )
        _ = try? await BookmarkRepository.shared.add(bookmark)
        // 简单 toast (用 UIKit 的 UIImpactFeedbackGenerator 让用户知道)
        await MainActor.run {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}

// MARK: - 选词菜单 sheet item

struct DictItem: Identifiable { let id = UUID(); let text: String }
struct BrowserItem: Identifiable { let id = UUID(); let url: URL }

// MARK: - 单页内容

private struct ReaderPageView: View {
    let page: ReaderPage
    @ObservedObject var config: ReadConfig
    /// 书名: 章节首页页眉显示书名, 其他页显示章节标题
    let bookName: String
    /// 总章节数: 用于计算页脚整体进度 %
    let chapterCount: Int
    let onTapMenu: () -> Void
    let onTapPrev: () -> Void
    let onTapNext: () -> Void
    let onSelectionAction: (SelectableTextView.SelectionAction, String) -> Void

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                // ── 页眉: 书名 (左上角, 与参考 Android 版一致) ──
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .medium))
                    Text(bookName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(config.theme.textColor.opacity(0.4))
                .padding(.bottom, 8)

                // ── 正文 (万象书屋 M2.8 Gap 3): 含 ␎WX_IMG[url]␏ 图片占位标记 ──
                ChapterPageBody(
                    pageText: page.text,
                    chapterTitle: page.chapterTitle,
                    config: config
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // ── 页脚: 时间 + 整体进度 % ──
                HStack {
                    TimelineView(.everyMinute) { ctx in
                        Text(
                            ctx.date.formatted(
                                .dateTime.hour(.twoDigits(amPM: .omitted)).minute()
                            )
                        )
                        .font(.system(size: 11, design: .monospaced))
                    }
                    Spacer()
                    let progress = chapterCount > 0
                        ? Double(page.chapterIndex) / Double(chapterCount) * 100
                        : 0
                    Text(String(format: "%.1f%%", progress))
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(config.theme.textColor.opacity(0.4))
                .padding(.top, 8)
            }
            .padding(.horizontal, config.paddingHorizontal)
            .padding(.top, config.paddingTop)
            .padding(.bottom, config.paddingBottom)
            // 三段点击区: 左 1/3 上一页, 中 1/3 菜单, 右 1/3 下一页
            .overlay(
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: geo.size.width / 3)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapPrev() }
                    Color.clear
                        .frame(width: geo.size.width / 3)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapMenu() }
                    Color.clear
                        .frame(width: geo.size.width / 3)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapNext() }
                }
            )
        }
    }
}

// MARK: - 安全下标

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}

// MARK: - 自动翻页配置

private struct AutoReadConfigSheet: View {
    @StateObject private var auto = AutoReadController.shared
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Double] = [5, 10, 15, 20, 25, 30, 45, 60]

    var body: some View {
        NavigationStack {
            Form {
                Section("当前状态") {
                    HStack {
                        Image(systemName: auto.isRunning ? "play.circle.fill" : "pause.circle")
                            .foregroundStyle(auto.isRunning ? Color.green : Color.secondary)
                        Text(auto.isRunning ? "运行中" : "已停止")
                        Spacer()
                        if auto.isRunning {
                            Text("\(Int(ceil(auto.countdown))) 秒后翻页")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(header: Text("翻页间隔")) {
                    ForEach(speeds, id: \.self) { s in
                        Button {
                            auto.setSpeed(s)
                        } label: {
                            HStack {
                                Text("\(Int(s)) 秒/页")
                                Spacer()
                                if Int(auto.secondsPerPage) == Int(s) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section(footer: Text("说明:启用后每隔指定秒数自动翻下一页。在阅读页面菜单 ⋯ 内可启动/停止。音量键也可用于翻页:音量↑上一页,音量↓下一页 (真机)。")) {
                    EmptyView()
                }
            }
            .navigationTitle("自动翻页")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - ChapterPageBody (M2.8 Gap 3)

/// 万象书屋: 一页正文的渲染 wrapper, 按 ␎WX_IMG[url]␏ 占位标记切成 text/image 段,
/// text 段用 SwiftUI Text, image 段用 ChapterImageBlock (AsyncImage + 全屏点击).
/// 没有 image 时整页作为单个 Text 渲染, 跟之前行为完全等价 (零回归).
struct ChapterPageBody: View {
    let pageText: String
    let chapterTitle: String
    @ObservedObject var config: ReadConfig

    /// 万象书屋 (M2.8): 用户选的中文字体. fontFamily 空 = 系统默认 .system.
    private var bodyFont: Font {
        if config.fontFamily.isEmpty {
            return .system(size: config.textSize)
        }
        return .custom(config.fontFamily, size: config.textSize)
    }

    /// 万象书屋 (排版): 章节标题字号 = 正文 × chapterTitleScale (跟 PaginationEngine 一致).
    private var titleFontSize: CGFloat {
        (config.textSize * PaginationEngine.chapterTitleScale).rounded()
    }

    private var titleFont: Font {
        if config.fontFamily.isEmpty {
            return .system(size: titleFontSize, weight: .bold)
        }
        return .custom(config.fontFamily, size: titleFontSize).weight(.bold)
    }

    /// 万象书屋 (排版): 第一页 page.text 以章节标题开头 (`title\n` 形式),
    /// 砍下来单独渲染. 其它页保持原样.
    private func stripChapterTitleIfFirstPage(_ s: String) -> (title: String?, body: String) {
        let t = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return (nil, s) }
        guard s.hasPrefix(t) else { return (nil, s) }
        let rest = s.dropFirst(t.count)
        // 标题后面通常是单 \n (PaginationEngine 已加), 跳过它
        if rest.hasPrefix("\n") {
            return (t, String(rest.dropFirst()))
        }
        return (t, String(rest))
    }

    var body: some View {
        let (title, restText) = stripChapterTitleIfFirstPage(pageText)
        VStack(alignment: .leading, spacing: 0) {
            if let title = title {
                chapterTitleHeader(title)
            }
            chapterBody(restText)
        }
    }

    @ViewBuilder
    private func chapterTitleHeader(_ title: String) -> some View {
        Text(title)
            .font(titleFont)
            .foregroundStyle(config.theme.textColor)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 不加 padding(.top): config.paddingTop 已提供顶部留白
            // padding(.bottom, 24) 与 titlePara.paragraphSpacing = 24 对应, 确保 CoreText/SwiftUI 高度一致
            .padding(.bottom, 24)
    }

    @ViewBuilder
    private func chapterBody(_ text: String) -> some View {
        let segs = parseChapterPageSegments(text)
        let uiTextColor = UIColor(config.theme.textColor)
        if segs.count == 1, case .text(let txt, _) = segs[0] {
            BodyTextUIView(attrText: bodyNSAttributedString(txt, textColor: uiTextColor))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(segs) { seg in
                    switch seg {
                    case .text(let txt, _):
                        BodyTextUIView(attrText: bodyNSAttributedString(txt, textColor: uiTextColor))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let url, _):
                        ChapterImageBlock(imageUrl: url, textColor: config.theme.textColor)
                    }
                }
            }
        }
    }

    /// 正文 NSAttributedString: UIKit 直接可用, 与 PaginationEngine.makeAttributedString 保持完全一致的 lineSpacing/paragraphSpacing.
    private func bodyNSAttributedString(_ text: String, textColor: UIColor) -> NSAttributedString {
        let uiFont: UIFont = config.fontFamily.isEmpty
            ? UIFont.systemFont(ofSize: config.textSize)
            : (UIFont(name: config.fontFamily, size: config.textSize)
                ?? UIFont.systemFont(ofSize: config.textSize))
        let lineSpacingPt = config.textSize * max(0, config.lineSpacing - 1.0)
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = lineSpacingPt
        paraStyle.paragraphSpacing = config.paragraphSpacing
        paraStyle.lineBreakMode = .byCharWrapping
        let nsAttr = NSMutableAttributedString(string: text)
        let range = NSRange(location: 0, length: (text as NSString).length)
        nsAttr.addAttribute(.font, value: uiFont, range: range)
        nsAttr.addAttribute(.paragraphStyle, value: paraStyle, range: range)
        nsAttr.addAttribute(.foregroundColor, value: textColor, range: range)
        if config.letterSpacing != 0 {
            nsAttr.addAttribute(.kern, value: NSNumber(value: Float(config.letterSpacing)), range: range)
        }
        return nsAttr
    }
}

// MARK: - 阻断 NavigationStack 侧滑返回 (P0 fix: 看小说意外退出)

/// 递归在 VC 层级里找 UINavigationController
private func findNavigationController(in vc: UIViewController?) -> UINavigationController? {
    guard let vc else { return nil }
    if let nav = vc as? UINavigationController { return nav }
    for child in vc.children {
        if let found = findNavigationController(in: child) { return found }
    }
    return findNavigationController(in: vc.presentedViewController)
}

// UIViewRepresentable 透明占位视图, appear 时关闭 interactivePopGestureRecognizer,
// onDisappear 时恢复, 不影响阅读器自身的翻页/上滑手势.
private struct SwipeBackBlocker: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let nav = uiView.responderNavigationController() {
                nav.interactivePopGestureRecognizer?.isEnabled = false
            }
        }
    }
}

private extension UIView {
    /// 沿 responder chain 向上找最近的 UINavigationController
    func responderNavigationController() -> UINavigationController? {
        var r: UIResponder? = self
        while let cur = r {
            if let nav = cur as? UINavigationController { return nav }
            r = cur.next
        }
        return nil
    }
}

// MARK: - UITextView 正文渲染器 (与 CoreText 同一引擎, lineSpacing/paragraphSpacing 完全匹配分页计算)

private struct BodyTextUIView: UIViewRepresentable {
    let attrText: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.attributedText != attrText {
            tv.attributedText = attrText
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
