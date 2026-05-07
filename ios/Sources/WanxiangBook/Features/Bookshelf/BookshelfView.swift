//
//  BookshelfView.swift
//  万象书屋 iOS · 书架 Tab (M2.2 P0 部分)
//
//  M2.2 P0 交付:
//   - M2.2.1 网格视图 (3 / 4 列, 偏好持久)
//   - M2.2.3 6 种排序 (跟 Android 对齐)
//   - M2.2.4 进度条角标
//   - M2.2.7 长按菜单 (置顶 / 删除)
//   - M2.2.10 拉本地 SQLite + 实时进度更新
//   - 工具栏: 搜索 + 排序 + 切换列数
//
//  待补 (M2.2.x):
//   - 列表视图 (P1)
//   - 缓存状态角标 (P1)
//   - 阅读状态筛选 (P1)
//   - 完整工具栏 11 项菜单 (M2.2.8)
//   - 分组系统 (M2.2.9)
//

import SwiftUI

struct BookshelfView: View {

    @StateObject private var vm = BookshelfViewModel()
    @StateObject private var downloader = BookDownloader.shared
    @State private var selectedGroupId: Int64 = BookGroup.allId
    @State private var showCreateGroup = false
    @State private var newGroupName = ""
    @AppStorage("wanxiang.shelf.cols") private var cols: Int = 3
    @AppStorage("wanxiang.shelf.sort") private var sortRaw: Int = ShelfSort.latestRead.rawValue
    @AppStorage("wanxiang.shelf.style") private var styleRaw: Int = 0  // 0 = 网格, 1 = 列表
    @State private var searchPresented = false
    @State private var deleteConfirm: ShelfBook? = nil
    @State private var importPicker = false
    @State private var exportSheet: ExportSheetItem? = nil

    private var sort: ShelfSort {
        ShelfSort(rawValue: sortRaw) ?? .latestRead
    }

    private struct ExportSheetItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                groupBar
                Group {
                    if vm.books.isEmpty && !vm.isLoading {
                        emptyView
                    } else {
                        gridView
                    }
                }
            }
            .background(WanxiangColors.background.ignoresSafeArea())
            .navigationTitle("书架")
            // 万象书屋: 收紧 large 标题, 让书架网格更早可见
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("视图", selection: $styleRaw) {
                            Label("网格", systemImage: "square.grid.3x2").tag(0)
                            Label("列表", systemImage: "list.bullet").tag(1)
                        }
                        Divider()
                        Picker("排序", selection: $sortRaw) {
                            ForEach(ShelfSort.allCases, id: \.rawValue) { s in
                                Text(s.displayName).tag(s.rawValue)
                            }
                        }
                        Divider()
                        if styleRaw == 0 {
                            Picker("列数", selection: $cols) {
                                ForEach(3...5, id: \.self) { n in
                                    Text("\(n) 列").tag(n)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        searchPresented = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    Menu {
                        Button { Task { await vm.refresh(sort: sort) } } label: {
                            Label("更新目录", systemImage: "arrow.clockwise")
                        }
                        NavigationLink {
                            ImportLocalView()
                        } label: { Label("添加本地", systemImage: "doc.badge.plus") }
                        NavigationLink {
                            BookshelfManageView()
                        } label: { Label("书架管理", systemImage: "list.bullet.rectangle") }
                        NavigationLink {
                            CacheView()
                        } label: { Label("缓存导出", systemImage: "arrow.down.circle") }
                        Divider()
                        Button {
                            Task { await exportShelf() }
                        } label: { Label("导出书架 JSON", systemImage: "square.and.arrow.up") }
                        Button {
                            importPicker = true
                        } label: { Label("导入书架 JSON", systemImage: "square.and.arrow.down") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .fileImporter(
                isPresented: $importPicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                Task { await importShelf(result: result) }
            }
            .sheet(item: $exportSheet) { item in
                ShareSheet(items: [item.url])
            }
            .task(id: sortRaw) {
                await vm.loadGroups()
                await vm.refresh(sort: sort)
            }
            .refreshable {
                await vm.refresh(sort: sort)
            }
            .sheet(isPresented: $searchPresented) {
                SearchView()
                    .onDisappear {
                        // 从搜索回来,可能加了书,刷一次
                        Task { await vm.refresh(sort: sort) }
                    }
            }
            .confirmationDialog(
                "确认删除「\(deleteConfirm?.name ?? "")」吗?",
                isPresented: Binding(get: { deleteConfirm != nil }, set: { if !$0 { deleteConfirm = nil } }),
                titleVisibility: .visible
            ) {
                if let book = deleteConfirm {
                    Button("删除", role: .destructive) {
                        Task { await vm.remove(book) }
                    }
                    Button("取消", role: .cancel) {}
                }
            }
        }
    }

    // MARK: - Subviews

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

    @ViewBuilder
    private var gridView: some View {
        if styleRaw == 1 {
            listStyleView
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: cols)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(vm.books) { book in
                        NavigationLink {
                            ReaderView(book: book, source: nil)
                        } label: {
                            BookCard(book: book)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenuFor(book) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
    }

    private var listStyleView: some View {
        List {
            ForEach(vm.books) { book in
                NavigationLink {
                    ReaderView(book: book, source: nil)
                } label: {
                    HStack(spacing: 12) {
                        BookCover(url: book.coverUrl, width: 40, height: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(book.name).font(.subheadline.weight(.medium))
                            Text(book.author).font(.caption2).foregroundStyle(.secondary)
                            HStack {
                                if book.totalChapterNum > 0 {
                                    ProgressView(value: book.progress)
                                        .progressViewStyle(.linear)
                                        .tint(WanxiangColors.primary)
                                        .frame(width: 100)
                                }
                                Text(book.progressText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
                .contextMenu { contextMenuFor(book) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func contextMenuFor(_ book: ShelfBook) -> some View {
        Button { Task { await vm.pin(book) } } label: {
            Label("置顶", systemImage: "pin")
        }
        // 万象书屋: 下载到本地 (整书所有章节缓存到 SQLite)
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
        // 万象书屋: 移到分组
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
        // 万象书屋: 导出 TXT/EPUB
        Menu {
            Button {
                Task { await exportBook(book, format: .txt) }
            } label: { Label("TXT", systemImage: "doc.text") }
            Button {
                Task { await exportBook(book, format: .epub) }
            } label: { Label("EPUB", systemImage: "book.closed") }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        Button(role: .destructive) {
            deleteConfirm = book
        } label: {
            Label("从书架删除", systemImage: "trash")
        }
    }

    /// 万象书屋: 顶部 group bar (分组切换 + 新建)
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
                            Text(g.name).font(.caption.weight(isSelected ? .semibold : .regular))
                            if g.bookCount > 0 {
                                Text("\(g.bookCount)").font(.caption2)
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
                        if g.id != BookGroup.allId && g.id != BookGroup.ungroupedId {
                            Button(role: .destructive) {
                                Task {
                                    try? await BookGroupRepository.shared.delete(id: g.id)
                                    await vm.loadGroups()
                                }
                            } label: { Label("删除分组", systemImage: "trash") }
                        }
                    }
                }
                Button {
                    showCreateGroup = true
                } label: {
                    Image(systemName: "plus")
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
        .alert("新建分组", isPresented: $showCreateGroup) {
            TextField("分组名", text: $newGroupName)
            Button("取消", role: .cancel) { newGroupName = "" }
            Button("创建") {
                let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    Task {
                        _ = try? await BookGroupRepository.shared.create(name: name)
                        await vm.loadGroups()
                        newGroupName = ""
                    }
                }
            }
        }
    }

    private enum ExportFormat { case txt, epub }
    private func exportBook(_ book: ShelfBook, format: ExportFormat) async {
        let chapters = (try? await ChapterRepository.shared.loadToc(bookUrl: book.bookUrl)) ?? []
        guard !chapters.isEmpty else {
            // TODO: 弹 toast 提示先下载
            return
        }
        do {
            let url: URL
            switch format {
            case .txt:  url = try await BookExporter.shared.exportTxt(book: book, chapters: chapters)
            case .epub: url = try await BookExporter.shared.exportEpub(book: book, chapters: chapters)
            }
            // 弹分享 sheet
            await MainActor.run { exportSheet = ExportSheetItem(url: url) }
        } catch {
            print("[Export] failed: \(error)")
        }
    }

    // MARK: - 导入导出

    private func exportShelf() async {
        let books = vm.books
        let arr = books.map { b -> [String: Any] in
            return [
                "bookUrl": b.bookUrl,
                "name": b.name,
                "author": b.author,
                "origin": b.origin,
                "originName": b.originName,
                "coverUrl": b.coverUrl ?? "",
                "intro": b.intro ?? "",
                "kind": b.kind ?? "",
                "tocUrl": b.tocUrl ?? "",
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wanxiang-shelf-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: url)
            exportSheet = ExportSheetItem(url: url)
        } catch {
            print("[Bookshelf] export failed: \(error)")
        }
    }

    private func importShelf(result: Result<[URL], Error>) async {
        switch result {
        case .failure: return
        case .success(let urls):
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            for dict in arr {
                guard let bookUrl = dict["bookUrl"] as? String,
                      let name = dict["name"] as? String else { continue }
                var b = ShelfBook(
                    bookUrl: bookUrl,
                    name: name,
                    author: dict["author"] as? String ?? "",
                    origin: dict["origin"] as? String ?? "",
                    originName: dict["originName"] as? String ?? "",
                    coverUrl: dict["coverUrl"] as? String,
                    intro: dict["intro"] as? String,
                    kind: dict["kind"] as? String,
                    tocUrl: dict["tocUrl"] as? String
                )
                b.canUpdate = true
                try? await BookshelfRepository.shared.add(b)
            }
            await vm.refresh(sort: sort)
        }
    }
}

// MARK: - Share Sheet (UIKit 包装)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - 单个书卡片

private struct BookCard: View {
    let book: ShelfBook
    @ObservedObject private var downloader = BookDownloader.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                // 万象书屋: 用 GeometryReader 控宽, BookCover 接受高度=宽 * 4.2/3
                GeometryReader { geo in
                    let h = geo.size.width * 4.2 / 3
                    BookCover(url: book.coverUrl, width: geo.size.width, height: h)
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
                // 万象书屋: 下载状态角标 (右下角)
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
        // bug #6 fix: 移动后必须 refresh, 否则当前 group 列表不更新
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
