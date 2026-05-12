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
    @State private var selectedGroupId: Int64 = BookGroup.allId

    // sheets
    @State private var searchPresented = false
    @State private var showLayoutConfig = false
    @State private var showGroupManage = false
    @State private var showCreateGroup = false
    @State private var newGroupName = ""

    @State private var deleteConfirm: ShelfBook?
    @State private var renamingGroup: BookGroup?
    @State private var renameInput = ""

    // 万象书屋: 持久化 — 跟 Android AppConfig.bookshelfLayout / bookshelfSort / 各 show* 对齐
    @AppStorage("wanxiang.shelf.style") private var styleRaw: Int = 1       // 0=列表 1=网格 (默认网格)
    @AppStorage("wanxiang.shelf.cols") private var cols: Int = 3
    @AppStorage("wanxiang.shelf.sort") private var sortRaw: Int = ShelfSort.latestRead.rawValue
    @AppStorage("wanxiang.shelf.show_unread") private var showUnread: Bool = true
    @AppStorage("wanxiang.shelf.show_last_update") private var showLastUpdateTime: Bool = true

    private var sort: ShelfSort {
        ShelfSort(rawValue: sortRaw) ?? .latestRead
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 万象书屋: 跟 Android TabLayout 等价 — 横向 capsule chip 展示分组
                groupBar
                Group {
                    if vm.books.isEmpty && !vm.isLoading {
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
            }
            .refreshable { await vm.refresh(sort: sort) }
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
                    Task { await vm.refresh(sort: sort) }
                } label: { Label("更新目录", systemImage: "arrow.clockwise") }

                NavigationLink {
                    ImportLocalView()
                } label: { Label("添加本地", systemImage: "doc.badge.plus") }

                NavigationLink {
                    BookshelfManageView()
                } label: { Label("书架管理", systemImage: "list.bullet.rectangle") }

                Button {
                    showGroupManage = true
                } label: { Label("分组管理", systemImage: "folder.badge.gearshape") }

                Button {
                    showLayoutConfig = true
                } label: { Label("书架布局", systemImage: "rectangle.3.group") }
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
                        Task { await vm.refresh(sort: sort, groupId: g.id) }
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
                        BookCard(book: book, showLastUpdate: showLastUpdateTime)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenuFor(book) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private var listView: some View {
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
    }

    private func bookListRow(_ book: ShelfBook) -> some View {
        HStack(spacing: 12) {
            BookCover(url: book.coverUrl, width: 50, height: 70, bookTitle: book.name)
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
                    Text("最后更新:\(formatRelative(book.latestChapterTime))")
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

    /// "1m 前 / 2h 前 / 3d 前 / yyyy-MM-dd"
    private func formatRelative(_ ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<0: return "刚刚"
        case 0..<60: return "\(Int(diff))秒前"
        case 60..<3600: return "\(Int(diff/60))分钟前"
        case 3600..<86400: return "\(Int(diff/3600))小时前"
        case 86400..<(86400*30): return "\(Int(diff/86400))天前"
        default:
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: date)
        }
    }
}

// MARK: - 单个书卡片 (网格)

private struct BookCard: View {
    let book: ShelfBook
    let showLastUpdate: Bool
    @ObservedObject private var downloader = BookDownloader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                GeometryReader { geo in
                    let h = geo.size.width * 4.2 / 3
                    BookCover(url: book.coverUrl, width: geo.size.width, height: h, bookTitle: book.name)
                }
                .aspectRatio(3.0/4.2, contentMode: .fit)
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
            if showLastUpdate, book.latestChapterTime > 0 {
                Text(BookCard.formatRelative(book.latestChapterTime))
                    .font(.system(size: 9))
                    .foregroundStyle(WanxiangColors.textSecondary.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }

    static func formatRelative(_ ts: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        let diff = Date().timeIntervalSince(date)
        switch diff {
        case ..<0: return "刚刚"
        case 0..<60: return "\(Int(diff))s 前"
        case 60..<3600: return "\(Int(diff/60))m 前"
        case 3600..<86400: return "\(Int(diff/3600))h 前"
        case 86400..<(86400*30): return "\(Int(diff/86400))d 前"
        default:
            let f = DateFormatter()
            f.dateFormat = "MM-dd"
            return f.string(from: date)
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
        await refresh(sort: .manual)
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
