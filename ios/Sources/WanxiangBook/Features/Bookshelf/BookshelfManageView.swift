//
//  BookshelfManageView.swift
//  万象书屋 iOS · 书架管理
//
//  - 多选 / 批量删除 / 批量更新目录
//  - 阅读状态筛选 (全部/未读/在读/已读完)
//

import SwiftUI

struct BookshelfManageView: View {

    @State private var books: [ShelfBook] = []
    @State private var selectedIds: Set<String> = []
    @State private var filter: ReadFilter = .all
    /// 万象书屋 (UX 2026-05-11): 用户点禁用按钮时的临时提示 (1.5s 自动消失)
    @State private var transientHint: String? = nil
    @State private var transientHintTask: Task<Void, Never>? = nil

    enum ReadFilter: String, CaseIterable {
        case all = "全部"
        case unread = "未读"
        case reading = "在读"
        case finished = "已读完"
    }

    var filtered: [ShelfBook] {
        switch filter {
        case .all: return books
        case .unread: return books.filter { $0.durChapterIndex == 0 && $0.durChapterPos == 0 }
        case .reading: return books.filter {
            $0.durChapterIndex > 0 && ($0.totalChapterNum == 0 || $0.durChapterIndex + 1 < $0.totalChapterNum)
        }
        case .finished: return books.filter {
            $0.totalChapterNum > 0 && $0.durChapterIndex + 1 >= $0.totalChapterNum
        }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("筛选", selection: $filter) {
                ForEach(ReadFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            List(filtered, selection: $selectedIds) { book in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.name).font(.subheadline.weight(.medium))
                        Text("\(book.author) · \(book.progressText)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if book.totalChapterNum > 0 {
                        Text("\(Int(book.progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(WanxiangColors.primary)
                    }
                }
                .tag(book.bookUrl)
            }
            .environment(\.editMode, .constant(.active))
            .listStyle(.plain)
        }
        .navigationTitle(navTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleSelectAll()
                } label: {
                    Text(allSelected ? "取消全选" : "全选")
                        .font(.subheadline)
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                actionButton(label: "更新目录", systemImage: "arrow.clockwise") {
                    Task { await batchUpdate() }
                }
                Spacer()
                actionButton(label: "删除", systemImage: "trash", role: .destructive) {
                    Task { await batchDelete() }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let hint = transientHint {
                Text(hint)
                    .font(.caption)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.78)))
                    .foregroundStyle(.white)
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .background(WanxiangColors.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .task { await load() }
    }

    /// 万象书屋: 顶栏标题随选中数动态变化
    private var navTitle: String {
        if selectedIds.isEmpty { return "书架管理(\(filtered.count))" }
        return "已选 \(selectedIds.count) / \(filtered.count)"
    }

    /// 是否当前过滤集都被选中
    private var allSelected: Bool {
        let filteredIds = Set(filtered.map { $0.bookUrl })
        return !filteredIds.isEmpty && filteredIds.isSubset(of: selectedIds)
    }

    private func toggleSelectAll() {
        let filteredIds = filtered.map { $0.bookUrl }
        if allSelected {
            for id in filteredIds { selectedIds.remove(id) }
        } else {
            selectedIds.formUnion(filteredIds)
        }
    }

    /// 万象书屋: bottomBar 按钮 — 未选时给 toast 提示, 已选时执行 action.
    @ViewBuilder
    private func actionButton(label: String, systemImage: String,
                              role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(role: role) {
            if selectedIds.isEmpty {
                showTransientHint("请先勾选书籍 (点行左侧 ○)")
            } else {
                action()
            }
        } label: {
            Label(label, systemImage: systemImage)
                .opacity(selectedIds.isEmpty ? 0.55 : 1)
        }
    }

    private func showTransientHint(_ msg: String) {
        transientHintTask?.cancel()
        withAnimation(.easeInOut(duration: 0.18)) { transientHint = msg }
        transientHintTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.18)) { transientHint = nil }
            }
        }
    }

    private func load() async {
        books = (try? await BookshelfRepository.shared.listAll()) ?? []
    }

    private func batchDelete() async {
        for url in selectedIds {
            try? await ChapterRepository.shared.clearContent(bookUrl: url)
            try? await BookshelfRepository.shared.remove(bookUrl: url)
        }
        selectedIds.removeAll()
        await load()
    }

    private func batchUpdate() async {
        let booksToUpdate = books.filter { selectedIds.contains($0.bookUrl) }
        guard !booksToUpdate.isEmpty else { return }
        let total = booksToUpdate.count
        showTransientHint("开始更新 \(total) 本书的目录…")

        let result = await BookshelfTocUpdater.update(books: booksToUpdate)

        selectedIds.removeAll()
        await load()
        showTransientHint(result.failed == 0
            ? "更新完成: \(result.ok)/\(total)"
            : "更新完成: \(result.ok)/\(total) (失败 \(result.failed))")
    }

}

// MARK: - 批量更新目录 (BookshelfView / BookshelfManageView 共用)

enum BookshelfTocUpdater {

    struct Result: Sendable {
        var ok: Int
        var failed: Int
    }

    /// 并发 3 本 in-flight, 单本 30s 硬超时, 失败静默跳过.
    static func update(books: [ShelfBook]) async -> Result {
        guard !books.isEmpty else { return .init(ok: 0, failed: 0) }
        var ok = 0
        var failed = 0

        await withTaskGroup(of: Bool.self) { group in
            var iter = books.makeIterator()
            let cap = min(3, books.count)

            @discardableResult
            func addNext() -> Bool {
                guard let b = iter.next() else { return false }
                group.addTask { await updateOneBook(b) }
                return true
            }
            for _ in 0..<cap { _ = addNext() }
            while let success = await group.next() {
                if success { ok += 1 } else { failed += 1 }
                addNext()
            }
        }
        return .init(ok: ok, failed: failed)
    }

    private static func updateOneBook(_ book: ShelfBook) async -> Bool {
        guard let source = await BookSourceRegistry.shared.find(origin: book.origin) else { return false }
        let searchBook = SearchBook(
            origin: book.origin, originName: book.originName,
            name: book.name, author: book.author,
            bookUrl: book.bookUrl,
            coverUrl: book.coverUrl, intro: book.intro, kind: book.kind,
            lastChapter: book.latestChapterTitle
        )
        return await withTaskGroup(of: Bool?.self) { inner -> Bool in
            inner.addTask {
                let info = (try? await BookSourceEngine.shared.fetchInfo(of: searchBook, in: source))
                    ?? BookInfo(
                        bookUrl: book.bookUrl, name: book.name, author: book.author,
                        coverUrl: book.coverUrl, tocUrl: book.tocUrl ?? book.bookUrl
                    )
                let toc = (try? await BookSourceEngine.shared.fetchToc(of: info, in: source)) ?? []
                if toc.isEmpty { return false }
                try? await ChapterRepository.shared.saveToc(bookUrl: book.bookUrl, chapters: toc)
                try? await BookshelfRepository.shared.updateTotalChapters(
                    bookUrl: book.bookUrl,
                    total: toc.count,
                    latestTitle: toc.last?.title
                )
                return true
            }
            inner.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return nil
            }
            for await r in inner {
                inner.cancelAll()
                if let r = r { return r }
                return false
            }
            return false
        }
    }
}
