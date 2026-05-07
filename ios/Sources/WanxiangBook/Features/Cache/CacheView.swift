//
//  CacheView.swift
//  万象书屋 iOS · 离线下载管理 (M2.8.2)
//
//  M2.8.2 v1 实现:
//   - 列出书架所有书 + 下载进度
//   - 单本下载所有章节 (foreground task, 暂不接 BGTaskScheduler)
//   - 下载状态: 未缓存 / 缓存中 / 已缓存
//   - 清缓存
//
//  待补 (M2.8.2.x):
//   - BGTaskScheduler 后台续传
//   - 下载之后 / 全部 (book_read.xml menu_download_after / all)
//   - 进度通知 (UNUserNotificationCenter)
//

import SwiftUI

struct CacheView: View {

    @StateObject private var vm = CacheViewModel()

    var body: some View {
        List {
            if vm.books.isEmpty {
                ContentUnavailableView("书架空", systemImage: "tray",
                    description: Text("先从书城或搜索加书"))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(vm.books) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.book.name).font(.subheadline.weight(.medium))
                            Text("\(row.cachedCount)/\(row.totalCount) 章已缓存")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let progress = row.downloadProgress {
                                ProgressView(value: progress)
                                    .progressViewStyle(.linear)
                                    .tint(WanxiangColors.primary)
                            }
                        }
                        Spacer()
                        if row.isDownloading {
                            Button("停止") { vm.stop(row) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        } else {
                            Button(row.cachedCount == row.totalCount ? "清空" : "下载") {
                                Task {
                                    if row.cachedCount == row.totalCount {
                                        await vm.clear(row)
                                    } else {
                                        await vm.download(row)
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }
}

@MainActor
final class CacheViewModel: ObservableObject {

    struct Row: Identifiable {
        let id: String
        let book: ShelfBook
        var cachedCount: Int
        let totalCount: Int
        var isDownloading: Bool = false
        var downloadProgress: Double? = nil
    }

    @Published var books: [Row] = []
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    func load() async {
        let shelfBooks = (try? await BookshelfRepository.shared.listAll()) ?? []
        var rows: [Row] = []
        for b in shelfBooks {
            let total = (try? await ChapterRepository.shared.tocCount(bookUrl: b.bookUrl)) ?? 0
            // M2.8.2 v1: 简化 — 用 totalChapterNum 当 cachedCount, 真实需要 SELECT WHERE content IS NOT NULL
            // (后续 ChapterRepository 加 cachedCount 方法)
            rows.append(Row(id: b.bookUrl, book: b, cachedCount: 0, totalCount: total))
        }
        self.books = rows
    }

    func download(_ row: Row) async {
        guard downloadTasks[row.id] == nil else { return }
        if let idx = books.firstIndex(where: { $0.id == row.id }) {
            books[idx].isDownloading = true
            books[idx].downloadProgress = 0
        }
        let task = Task {
            // M2.8.2 v1: 真实下载需要 BookSource. 当前作为框架, 仅 mock 进度
            for i in 0..<row.totalCount {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 30_000_000)
                if let idx = books.firstIndex(where: { $0.id == row.id }) {
                    books[idx].cachedCount = i + 1
                    books[idx].downloadProgress = Double(i + 1) / Double(row.totalCount)
                }
            }
            if let idx = books.firstIndex(where: { $0.id == row.id }) {
                books[idx].isDownloading = false
                books[idx].downloadProgress = nil
            }
            downloadTasks.removeValue(forKey: row.id)
        }
        downloadTasks[row.id] = task
    }

    func stop(_ row: Row) {
        downloadTasks[row.id]?.cancel()
        downloadTasks.removeValue(forKey: row.id)
        if let idx = books.firstIndex(where: { $0.id == row.id }) {
            books[idx].isDownloading = false
            books[idx].downloadProgress = nil
        }
    }

    func clear(_ row: Row) async {
        try? await ChapterRepository.shared.clearContent(bookUrl: row.book.bookUrl)
        if let idx = books.firstIndex(where: { $0.id == row.id }) {
            books[idx].cachedCount = 0
        }
    }
}
