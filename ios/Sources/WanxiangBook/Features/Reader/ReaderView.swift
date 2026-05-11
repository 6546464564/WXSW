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
    @StateObject private var engine: ReaderEngine
    @StateObject private var config = ReadConfig.shared

    @State private var menuVisible: Bool = false
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
                                            repaginateCurrent()
                                        }
                                        .onChange(of: contentGeo.size) { _, newSize in
                                            contentCanvasSize = newSize
                                            repaginateCurrent()
                                        }
                                }
                            )
                    }
                }

                if menuVisible {
                    menuOverlay
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
                NotificationCenter.default.post(name: .wanxiangTabBarHiddenChanged, object: true)
                Task { await engine.bootstrap() }
                startReadingTimer()
                UIApplication.shared.isIdleTimerDisabled = config.keepScreenOn
                applyBrightness()
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
            }
            .onDisappear {
                stopReadingTimer()
                UIApplication.shared.isIdleTimerDisabled = false
                NotificationCenter.default.post(name: .wanxiangTabBarHiddenChanged, object: false)
            }
            .onChange(of: config.brightness) { _, _ in applyBrightness() }
            .onChange(of: config.autoBrightness) { _, _ in applyBrightness() }
            .onChange(of: geo.size) { _, newSize in
                screenSize = newSize
                repaginateCurrent()
            }
            .onChange(of: config.keepScreenOn) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
            }
            .onChange(of: engine.currentChapterIndex) { _, _ in
                repaginateCurrent()
            }
            .onChange(of: engine.loadingChapter) { _, _ in
                repaginateCurrent()
            }
            .onChange(of: engine.chapterContentRevision) { _, _ in
                repaginateCurrent()
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
                    onTapMenu: { withAnimation { menuVisible.toggle() } },
                    onSelectionAction: { action, text in handleSelection(action: action, text: text) }
                )
                .tag(page.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea(edges: [])
    }

    /// 仿真翻书 (UIPageViewController .pageCurl, 跟 iBooks 同款)
    private var simulatePager: some View {
        PageCurlContainer(
            pages: pages.map { p in
                (id: p.id, view: ReaderPageView(
                    page: p,
                    config: config,
                    onTapMenu: { withAnimation { menuVisible.toggle() } },
                    onSelectionAction: { action, text in handleSelection(action: action, text: text) }
                ))
            },
            currentId: Binding(
                get: { currentPageId ?? pages.first?.id ?? "" },
                set: { newId in
                    currentPageId = newId
                    handlePageJump(to: newId)
                }
            )
        )
        .ignoresSafeArea()
    }

    private var scrollPager: some View {
        ScrollView {
            LazyVStack(spacing: config.paragraphSpacing) {
                ForEach(pages) { page in
                    // 万象书屋 (M2.8 Gap 3): 按 ␎WX_IMG[url]␏ 标记切段, text/image 分别渲染
                    chapterPageBody(page: page)
                        .padding(.horizontal, config.paddingHorizontal)
                }
                // bug fix: 滚动模式下滚到底部, 自动 load 下一章 (跟 Android 对齐)
                if let last = pages.last {
                    Color.clear.frame(height: 1)
                        .onAppear {
                            // 用户已滚到末尾, 触发下一章
                            Task { await engine.nextChapter() }
                            _ = last
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
                if !engine.chapters.isEmpty {
                    HStack {
                        Text("\(engine.currentChapterIndex + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                        Slider(
                            value: Binding(
                                get: { Double(engine.currentChapterIndex) },
                                set: { newVal in
                                    Task { await engine.goToChapter(Int(newVal)) }
                                }
                            ),
                            in: 0...Double(max(0, engine.chapters.count - 1)),
                            step: 1
                        )
                        .tint(WanxiangColors.primary)
                        Text("\(engine.chapters.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
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
        ChapterPageBody(pageText: page.text, config: config)
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
        let title = engine.chapters[safe: engine.currentChapterIndex]?.title ?? ""
        return title.isEmpty ? engine.book.name : title
    }

    // MARK: - 分页 / 翻页处理

    private func repaginateCurrent() {
        let viewport = contentCanvasSize.width > 0 ? contentCanvasSize : screenSize
        guard viewport.width > 0 else { return }
        let idx = engine.currentChapterIndex
        guard let body = engine.content(for: idx) else {
            pages = []
            return
        }
        let title = engine.chapters[safe: idx]?.title ?? engine.book.name
        // 万象书屋: 给 paginate 文字真实可用区 (减去 ReaderPageView 内的 padding + footer)
        // ReaderPageView 页脚 + 最后一行安全缓冲。
        // 过小会让正文压到页脚; 过大又会每页底部空白。52pt 是当前字号/行距下的平衡值。
        let footerHeight: CGFloat = 52
        let canvasSize = CGSize(
            width: max(0, viewport.width - config.paddingHorizontal * 2),
            height: max(0, viewport.height - config.paddingTop - config.paddingBottom - footerHeight)
        )
        let snapshot = ReadConfigSnapshot.current(from: config)
        let result = PaginationEngine.paginate(
            text: body,
            chapterIndex: idx,
            chapterTitle: title,
            canvasSize: canvasSize,
            config: snapshot
        )
        self.pages = result
        if let first = result.first { self.currentPageId = first.id }
    }

    private func handlePageJump(to id: String) {
        // id 形如 "chapterIdx-pageIdx", 当前章内翻页不需要切章; 跨章也通过这处理
        let parts = id.split(separator: "-")
        guard parts.count == 2,
              let cIdx = Int(parts[0]) else { return }
        if cIdx != engine.currentChapterIndex {
            Task { await engine.goToChapter(cIdx) }
        }
    }

    // MARK: - 阅读时长统计 (M2.5.7.6)

    private func startReadingTimer() {
        readingSecondsAccrued = 0
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
        // 退出时把不足 1 分钟的零头也算上 (取整 30 秒以上算 1 分钟)
        if readingSecondsAccrued == 0 {
            Task {
                try? await ReadRecordRepository.shared.addSeconds(bookUrl: engine.book.bookUrl, seconds: 30)
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
    let onTapMenu: () -> Void
    let onSelectionAction: (SelectableTextView.SelectionAction, String) -> Void

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                // 万象书屋 (M2.8 Gap 3): page.text 可能含 ␎WX_IMG[url]␏ 占位标记,
                // 切成 text/image 段分别渲染. 没有 image 时保持跟之前的纯 Text 等价.
                ChapterPageBody(
                    pageText: page.text,
                    config: config
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                // 页脚
                HStack {
                    Text(page.chapterTitle)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer()
                    Text("\(page.pageIndex + 1) / \(page.totalPages)")
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(config.theme.textColor.opacity(0.5))
                .padding(.top, 8)
            }
            .padding(.horizontal, config.paddingHorizontal)
            .padding(.top, config.paddingTop)
            .padding(.bottom, config.paddingBottom)
            // 三段点击区: 左 1/3 上一页, 中 1/3 菜单, 右 1/3 下一页
            // (TabView .page 模式下右滑/左滑天然翻页, 这里只处理 tap 中心)
            .overlay(
                HStack(spacing: 0) {
                    Color.clear.frame(width: geo.size.width / 3)
                    Color.clear
                        .frame(width: geo.size.width / 3)
                        .contentShape(Rectangle())
                        .onTapGesture { onTapMenu() }
                    Color.clear.frame(width: geo.size.width / 3)
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
    @ObservedObject var config: ReadConfig

    /// 万象书屋 (M2.8): 用户选的中文字体. fontFamily 空 = 系统默认 .system.
    private var bodyFont: Font {
        if config.fontFamily.isEmpty {
            return .system(size: config.textSize)
        }
        return .custom(config.fontFamily, size: config.textSize)
    }

    var body: some View {
        let segs = parseChapterPageSegments(pageText)
        // 没图片就用单 Text, 跟历史行为等价 (不让 VStack 改变行间距 / 文本选择)
        if segs.count == 1, case .text(let txt, _) = segs[0] {
            Text(txt)
                .font(bodyFont)
                .foregroundStyle(config.theme.textColor)
                .lineSpacing(config.textSize * (config.lineSpacing - 1))
                .kerning(config.letterSpacing)
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(segs) { seg in
                    switch seg {
                    case .text(let txt, _):
                        Text(txt)
                            .font(bodyFont)
                            .foregroundStyle(config.theme.textColor)
                            .lineSpacing(config.textSize * (config.lineSpacing - 1))
                            .kerning(config.letterSpacing)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .image(let url, _):
                        ChapterImageBlock(imageUrl: url, textColor: config.theme.textColor)
                    }
                }
            }
        }
    }
}
