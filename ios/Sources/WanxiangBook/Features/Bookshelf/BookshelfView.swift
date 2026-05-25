//
//  BookshelfView.swift
//  万象书屋 iOS · 书架 Tab — 1:1 对齐 Android `BookshelfFragment1`
//
//  对应 Android: io.legado.app.ui.main.bookshelf.style1.BookshelfFragment1
//                + io.legado.app.ui.main.bookshelf.style1.books.BooksFragment
//                + main_bookshelf.xml (D-17 隐藏后菜单)
//
//  Toolbar 菜单 (与 Android `main_bookshelf.xml` D-17 当前可见 5 项一致):
//   - 搜索 (always action)
//   - 三点菜单:
//     · 更新目录   (R.id.menu_update_toc)
//     · 添加本地   (R.id.menu_add_local)
//     · 书架管理   (R.id.menu_bookshelf_manage)
//     · 分组管理   (R.id.menu_group_manage)     ← Sheet
//     · 书架布局   (R.id.menu_bookshelf_layout) ← Sheet (configBookshelf)
//
//  Android 当前隐藏 (visible=false), iOS 同步藏起来不再放主菜单:
//   - menu_add_url        (网址添加书源, 易踩黄站)
//   - menu_download       (批量下载)
//   - menu_export_bookshelf
//   - menu_import_bookshelf
//   - menu_log
//
//  布局 / 排序 / 显示开关全部走 BookshelfLayoutConfigView (集中弹窗).
//

import SwiftUI

struct BookshelfView: View {

    @StateObject private var vm = BookshelfViewModel()
    @StateObject private var downloader = BookDownloader.shared

    // 万象书屋: 跟 Android `MainViewModel.saveTabPosition` 对齐, 切回书架记住上次 group
    @AppStorage("wanxiang.shelf.selected_group") private var selectedGroupIdRaw: Int = Int(BookGroup.allId)

    private var selectedGroupId: Int64 {
        get { Int64(selectedGroupIdRaw) }
        nonmutating set { selectedGroupIdRaw = Int(newValue) }
    }

    // sheets
    @State private var searchPresented = false
    @State private var showLayoutConfig = false
    @State private var showGroupManage = false
    @State private var showCreateGroup = false
    @State private var newGroupName = ""

    @State private var deleteConfirm: ShelfBook?
    @State private var renamingGroup: BookGroup?
    @State private var renameInput = ""
    @State private var tocUpdateHint: String?
    @State private var tocUpdateTask: Task<Void, Never>?
    @State private var didInitialTask = false
    @State private var isUpdatingToc = false

    #if DEBUG
    @State private var _autoNavBook: ShelfBook? = nil
    @State private var _autoNavActive = false
    #endif

    // 万象书屋: 持久化 — 跟 Android AppConfig.bookshelfLayout / bookshelfSort / 各 show* 对齐
    @AppStorage("wanxiang.shelf.style") private var styleRaw: Int = 1       // 0=列表 1=网格 (默认网格)
    @AppStorage("wanxiang.shelf.cols") private var cols: Int = 3
    @AppStorage("wanxiang.shelf.sort") private var sortRaw: Int = ShelfSort.latestRead.rawValue
    @AppStorage("wanxiang.shelf.show_unread") private var showUnread: Bool = false
    @AppStorage("wanxiang.shelf.show_last_update") private var showLastUpdateTime: Bool = true
    @AppStorage("wanxiang.shelf.show_fast_scroller") private var showFastScroller: Bool = false
    @AppStorage("wanxiang.startup.refreshShelf") private var autoRefreshShelf: Bool = true

    private var sort: ShelfSort {
        ShelfSort(rawValue: sortRaw) ?? .latestRead
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 万象书屋: 跟 Android TabLayout 等价 — 横向 capsule chip 展示分组
                groupBar
                Group {
                    if vm.isLoading && vm.books.isEmpty {
                        ProgressView("加载中…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.books.isEmpty {
                        emptyView
                    } else {
                        booksContainer
                    }
                }
            }
            .background(WanxiangColors.background.ignoresSafeArea())
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task(id: sortRaw) {
                await vm.loadGroups()
                await vm.refresh(sort: sort, groupId: selectedGroupId)
                didInitialTask = true
                maybePreloadCovers()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--AutoOpenFirstBook"),
                   let first = vm.books.first {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await MainActor.run {
                        _autoNavBook = first
                        _autoNavActive = true
                    }
                }
                #endif
            }
            .onAppear {
                guard autoRefreshShelf, didInitialTask else { return }
                Task { await vm.refresh(sort: sort, groupId: selectedGroupId) }
            }
            .onChange(of: selectedGroupIdRaw) { _, _ in
                Task { await vm.refresh(sort: sort, groupId: selectedGroupId) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .wanxiangBookshelfChanged)) { _ in
                Task { await vm.refresh(sort: sort, groupId: selectedGroupId) }
            }
            .refreshable { await vm.refresh(sort: sort, groupId: selectedGroupId) }
            #if DEBUG
            .navigationDestination(isPresented: $_autoNavActive) {
                if let book = _autoNavBook {
                    ReaderView(book: book, source: BookSourceRegistry.shared.find(origin: book.origin))
                }
            }
            #endif
            // 万象书屋 (UX): 搜索改成 NavigationStack push 的全屏单独页, 不再用 sheet 弹框.
            .navigationDestination(isPresented: $searchPresented) {
                SearchView(embedded: true)
                    .onDisappear { Task { await vm.refresh(sort: sort) } }
            }
            // 书架布局 (configBookshelf)
            .sheet(isPresented: $showLayoutConfig) {
                BookshelfLayoutConfigView()
                    .presentationDetents([.medium, .large])
            }
            // 分组管理 (GroupManageDialog)
            .sheet(isPresented: $showGroupManage, onDismiss: {
                Task {
                    await vm.loadGroups()
                    await vm.refresh(sort: sort, groupId: selectedGroupId)
                }
            }) {
                GroupManageView()
                    .presentationDetents([.medium, .large])
            }
            // 新建分组 (groupBar 末尾 + 按钮)
            .alert("新建分组", isPresented: $showCreateGroup) {
                TextField("分组名", text: $newGroupName)
                Button("取消", role: .cancel) { newGroupName = "" }
                Button("创建") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task {
                        _ = try? await BookGroupRepository.shared.create(name: name)
                        await vm.loadGroups()
                        newGroupName = ""
                    }
                }
            }
            // 长按 Tab 重命名 (Android `tabLayout.tab.view.setOnLongClickListener` 等价)
            .alert("重命名分组", isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            )) {
                TextField("分组名", text: $renameInput)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    guard let g = renamingGroup else { return }
                    let name = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, name != g.name else { return }
                    Task {
                        try? await BookGroupRepository.shared.rename(id: g.id, newName: name)
                        await vm.loadGroups()
                    }
                }
            }
            // 删除二次确认
            .confirmationDialog(
                "确认删除「\(deleteConfirm?.name ?? "")」吗?",
                isPresented: Binding(
                    get: { deleteConfirm != nil },
                    set: { if !$0 { deleteConfirm = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let book = deleteConfirm {
                    Button("从书架删除", role: .destructive) {
                        Task { await vm.remove(book) }
                    }
                    Button("取消", role: .cancel) {}
                }
            }
            .overlay(alignment: .bottom) {
                if let hint = tocUpdateHint {
                    Text(hint)
                        .font(.caption)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.78)))
                        .foregroundStyle(.white)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Toolbar (Android main_bookshelf.xml 对齐)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 搜索 always 显示在 trailing
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                searchPresented = true
            } label: {
                Image(systemName: "magnifyingglass")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    Task { await updateAllToc() }
                } label: {
                    Label(LocalizedStringKey("shelf.menu_update_toc"), systemImage: "arrow.clockwise")
                }
                .disabled(isUpdatingToc || vm.books.isEmpty)

                NavigationLink {
                    ImportLocalView()
                } label: {
                    Label(LocalizedStringKey("shelf.menu_add_local"), systemImage: "doc.badge.plus")
                }

                NavigationLink {
                    BookshelfManageView()
                } label: {
                    Label(LocalizedStringKey("shelf.menu_manage"), systemImage: "list.bullet.rectangle")
                }

                Button {
                    showGroupManage = true
                } label: {
                    Label(LocalizedStringKey("shelf.menu_group_manage"), systemImage: "folder.badge.gearshape")
                }

                Button {
                    showLayoutConfig = true
                } label: {
                    Label(LocalizedStringKey("shelf.menu_layout"), systemImage: "rectangle.3.group")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Group bar (Android TabLayout 等价)

    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.groups, id: \.id) { g in
                    Button {
                        selectedGroupId = g.id
                    } label: {
                        let isSelected = selectedGroupId == g.id
                        HStack(spacing: 4) {
                            Text(g.name)
                                .font(.caption.weight(isSelected ? .semibold : .regular))
                            if g.bookCount > 0 {
                                Text("\(g.bookCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(isSelected
                            ? WanxiangColors.primary.opacity(0.18)
                            : Color.gray.opacity(0.12)))
                        .foregroundStyle(isSelected ? WanxiangColors.primary : WanxiangColors.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        // 万象书屋: 跟 Android 长按 Tab 弹 GroupEditDialog 等价.
                        // 「全部」不允许任何操作 (meta filter);
                        // 「未分组」允许重命名 + 隐藏 tab (group_id=0 桶仍保留, 在 GroupManageView 恢复);
                        // 用户分组重命名 + 删除都支持.
                        if g.id != BookGroup.allId {
                            Button {
                                renameInput = g.name
                                renamingGroup = g
                            } label: { Label("重命名", systemImage: "pencil") }
                            if g.id == BookGroup.ungroupedId {
                                Button(role: .destructive) {
                                    BookGroup.isUngroupedHidden = true
                                    if selectedGroupId == BookGroup.ungroupedId {
                                        selectedGroupId = BookGroup.allId
                                    }
                                    Task {
                                        await vm.loadGroups()
                                        await vm.refresh(sort: sort, groupId: selectedGroupId)
                                    }
                                } label: { Label("隐藏此 tab", systemImage: "eye.slash") }
                            } else {
                                Button(role: .destructive) {
                                    Task {
                                        try? await BookGroupRepository.shared.delete(id: g.id)
                                        await vm.loadGroups()
                                    }
                                } label: { Label("删除分组", systemImage: "trash") }
                            }
                        }
                    }
                }
                // 万象书屋 (UX 2026-05-11): "+" 改成 Menu, 同时承载 新建 / 管理 两个入口.
                // 之前是单按钮只能"创建", 用户找不到删除 → 反馈"分组只能增加不能删除".
                // 现在点 "+" 弹菜单, 显式提供"新建分组 / 管理分组 (重命名+删除)".
                // 长按 chip 弹 contextMenu 的快捷方式照样保留.
                Menu {
                    Button {
                        newGroupName = ""
                        showCreateGroup = true
                    } label: {
                        Label("新建分组", systemImage: "plus")
                    }
                    Button {
                        showGroupManage = true
                    } label: {
                        Label("管理分组 (重命名/删除)", systemImage: "folder.badge.gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().stroke(Color.gray.opacity(0.4)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Books container

    @ViewBuilder
    private var booksContainer: some View {
        if styleRaw == 1 {
            gridView
        } else {
            listView
        }
    }

    private var gridView: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: cols)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(vm.books) { book in
                    NavigationLink {
                        ReaderView(book: book, source: BookSourceRegistry.shared.find(origin: book.origin))
                    } label: {
                        BookCard(
                            book: book,
                            showLastUpdate: showLastUpdateTime,
                            showUnread: showUnread
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenuFor(book) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .scrollIndicators(showFastScroller ? .visible : .hidden)
    }

    private var listView: some View {
        Group {
            if showFastScroller && usesSectionIndex {
                sectionedListView
            } else {
                plainListView
            }
        }
    }

    private var usesSectionIndex: Bool {
        sort == .name || sort == .author
    }

    private var plainListView: some View {
        List {
            ForEach(vm.books) { book in
                NavigationLink {
                    ReaderView(book: book, source: BookSourceRegistry.shared.find(origin: book.origin))
                } label: {
                    bookListRow(book)
                }
                .contextMenu { contextMenuFor(book) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(showFastScroller ? .visible : .hidden)
    }

    private var sectionedListView: some View {
        let sections = Self.indexedSections(books: vm.books, sort: sort)
        return ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                List {
                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.books) { book in
                                NavigationLink {
                                    ReaderView(book: book, source: BookSourceRegistry.shared.find(origin: book.origin))
                                } label: {
                                    bookListRow(book)
                                }
                                .contextMenu { contextMenuFor(book) }
                            }
                        }
                        .id(section.title)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                sectionIndexBar(sections: sections) { title in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(title, anchor: .top)
                    }
                }
            }
        }
    }

    private func sectionIndexBar(sections: [ShelfBookSection], onTap: @escaping (String) -> Void) -> some View {
        VStack(spacing: 2) {
            ForEach(sections, id: \.title) { section in
                Button {
                    onTap(section.title)
                } label: {
                    Text(section.title)
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 4)
        .foregroundStyle(WanxiangColors.primary.opacity(0.85))
    }

    private func bookListRow(_ book: ShelfBook) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                BookCover(url: book.coverUrl, width: 50, height: 70, bookTitle: book.name)
                if showUnread, book.unreadChapterNum > 0 {
                    Text("\(book.unreadChapterNum)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(Capsule().fill(WanxiangColors.primary))
                        .offset(x: 4, y: -4)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(book.name).font(.subheadline.weight(.medium))
                Text(book.author).font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if book.totalChapterNum > 0 {
                        ProgressView(value: book.progress)
                            .progressViewStyle(.linear)
                            .tint(WanxiangColors.primary)
                            .frame(width: 90)
                    }
                    Text(book.progressText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if showLastUpdateTime, book.latestChapterTime > 0 {
                    Text("最后更新:\(ShelfTimeFormat.relative(book.latestChapterTime, compact: false))")
                        .font(.caption2)
                        .foregroundStyle(WanxiangColors.textSecondary.opacity(0.85))
                }
            }
            Spacer()
        }
    }

    // MARK: - Context menu (跟 Android `BooksAdapter*` 长按等价)

    @ViewBuilder
    private func contextMenuFor(_ book: ShelfBook) -> some View {
        Button { Task { await vm.pin(book) } } label: {
            Label("置顶", systemImage: "pin")
        }

        let isDownloading = downloader.isDownloading(book.bookUrl)
        if isDownloading {
            Button(role: .destructive) {
                downloader.cancel(bookUrl: book.bookUrl)
            } label: {
                Label("取消下载", systemImage: "stop.circle")
            }
        } else if !book.origin.hasPrefix("local://") {
            Button {
                let source = BookSourceRegistry.shared.find(origin: book.origin)
                downloader.startDownload(book: book, source: source)
            } label: {
                Label("下载到本地", systemImage: "arrow.down.circle")
            }
        }

        Menu {
            Button {
                Task { await vm.moveToGroup(book, groupId: BookGroup.ungroupedId, currentSort: sort) }
            } label: { Label("未分组", systemImage: "tray") }
            ForEach(vm.groups.filter { $0.id > 0 }, id: \.id) { g in
                Button {
                    Task { await vm.moveToGroup(book, groupId: g.id, currentSort: sort) }
                } label: { Label(g.name, systemImage: "folder") }
            }
        } label: {
            Label("移到分组", systemImage: "folder.badge.plus")
        }

        Button(role: .destructive) {
            deleteConfirm = book
        } label: {
            Label("从书架删除", systemImage: "trash")
        }
    }

    // MARK: - Empty state (Android `tv_empty_msg` LinearLayout 对齐)

    private var emptyView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "books.vertical")
                .font(.system(size: 64))
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.6))
            Text("书架还空着")
                .font(.title2.weight(.medium))
                .foregroundStyle(WanxiangColors.textSecondary)
            Text("先去搜索书籍添加吧!")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.8))
            Button {
                searchPresented = true
            } label: {
                Label("搜索书籍", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(WanxiangColors.primary)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func updateAllToc() async {
        guard !vm.books.isEmpty, !isUpdatingToc else { return }
        isUpdatingToc = true
        defer { isUpdatingToc = false }
        let total = vm.books.count
        showTocHint("开始更新 \(total) 本书的目录…")
        let result = await BookshelfTocUpdater.update(books: vm.books)
        await vm.refresh(sort: sort, groupId: selectedGroupId)
        showTocHint(result.failed == 0
            ? "更新完成: \(result.ok)/\(total)"
            : "更新完成: \(result.ok)/\(total) (失败 \(result.failed))")
    }

    private func showTocHint(_ msg: String) {
        tocUpdateTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) { tocUpdateHint = msg }
        tocUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.18)) { tocUpdateHint = nil }
            }
        }
    }

    private func maybePreloadCovers() {
        guard UserDefaults.standard.bool(forKey: "wanxiang.shelf.preloadCovers") else { return }
        let urls = vm.books.prefix(24).compactMap(\.coverUrl)
        Task { await BookCoverPreloader.preload(urls: urls) }
    }

    private static func indexedSections(books: [ShelfBook], sort: ShelfSort) -> [ShelfBookSection] {
        let keyed = Dictionary(grouping: books) { book -> String in
            let source = sort == .author ? book.author : book.name
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { return "#" }
            let s = String(first).uppercased()
            return s.first?.isLetter == true ? s : "#"
        }
        return keyed.keys.sorted().map { title in
            ShelfBookSection(title: title, books: keyed[title] ?? [])
        }
    }
}

private struct ShelfBookSection {
    let title: String
    let books: [ShelfBook]
}

enum ShelfTimeFormat {
    /// "1m 前 / 2h 前 / 3d 前 / yyyy-MM-dd" (compact 用于网格卡片)
    static func relative(_ ts: Int64, compact: Bool) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<0: return "刚刚"
        case 0..<60: return compact ? "\(Int(diff))s 前" : "\(Int(diff))秒前"
        case 60..<3600: return compact ? "\(Int(diff/60))m 前" : "\(Int(diff/60))分钟前"
        case 3600..<86400: return compact ? "\(Int(diff/3600))h 前" : "\(Int(diff/3600))小时前"
        case 86400..<(86400*30): return compact ? "\(Int(diff/86400))d 前" : "\(Int(diff/86400))天前"
        default:
            let f = DateFormatter()
            f.dateFormat = compact ? "MM-dd" : "yyyy-MM-dd"
            return f.string(from: date)
        }
    }
}

// MARK: - 单个书卡片 (网格)

private struct BookCard: View {
    let book: ShelfBook
    let showLastUpdate: Bool
    let showUnread: Bool
    @ObservedObject private var downloader = BookDownloader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geo in
                    let h = geo.size.width * 4.2 / 3
                    BookCover(url: book.coverUrl, width: geo.size.width, height: h, bookTitle: book.name)
                }
                .aspectRatio(3.0/4.2, contentMode: .fit)
                if showUnread, book.unreadChapterNum > 0 {
                    Text("\(book.unreadChapterNum)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(WanxiangColors.primary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(4)
                }
                if book.progress > 0 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(WanxiangColors.primary)
                            .frame(width: geo.size.width * book.progress, height: 3)
                            .offset(y: geo.size.height - 3)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if let job = downloader.job(for: book.bookUrl), job.status == .running {
                    VStack {
                        Text("\(Int(job.progress * 100))%")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(WanxiangColors.primary.opacity(0.9))
                            .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(4)
                }
                if let job = downloader.job(for: book.bookUrl), job.status == .finished {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            Text(book.name)
                .font(.caption)
                .foregroundStyle(WanxiangColors.textPrimary)
                .lineLimit(1)
            Text(book.progressText)
                .font(.caption2)
                .foregroundStyle(WanxiangColors.textSecondary)
                .lineLimit(1)
            // 始终占位，保持每张卡片等高，避免网格行错位
            Text(showLastUpdate && book.latestChapterTime > 0
                 ? ShelfTimeFormat.relative(book.latestChapterTime, compact: true) : " ")
                .font(.system(size: 9))
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.75))
                .lineLimit(1)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class BookshelfViewModel: ObservableObject {

    @Published var books: [ShelfBook] = []
    @Published var isLoading: Bool = false
    @Published var groups: [BookGroup] = [.all, .ungrouped]
    private var currentGroupId: Int64 = BookGroup.allId

    func refresh(sort: ShelfSort, groupId: Int64? = nil) async {
        isLoading = true
        defer { isLoading = false }
        if let g = groupId { currentGroupId = g }
        books = (try? await BookshelfRepository.shared.listAll(
            sortedBy: sort,
            groupId: currentGroupId == BookGroup.allId ? nil : currentGroupId
        )) ?? []
        await loadGroups()
    }

    func loadGroups() async {
        groups = (try? await BookGroupRepository.shared.listAll()) ?? [.all, .ungrouped]
    }

    func pin(_ book: ShelfBook) async {
        try? await BookshelfRepository.shared.pin(bookUrl: book.bookUrl)
        await refresh(sort: .manual, groupId: currentGroupId)
    }

    func moveToGroup(_ book: ShelfBook, groupId: Int64, currentSort: ShelfSort) async {
        try? await BookGroupRepository.shared.moveBook(bookUrl: book.bookUrl, toGroupId: groupId)
        await refresh(sort: currentSort)
    }

    func remove(_ book: ShelfBook) async {
        try? await BookshelfRepository.shared.remove(bookUrl: book.bookUrl)
        books.removeAll { $0.bookUrl == book.bookUrl }
    }
}

#Preview {
    BookshelfView()
}
