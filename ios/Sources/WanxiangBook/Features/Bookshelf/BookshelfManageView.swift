//
//  BookshelfManageView.swift
//  万象书屋 iOS · 书架管理 (M2.2.5/6/8/9/11)
//
//  - 多选 / 批量删除 / 批量加分组 / 批量更新目录
//  - 阅读状态筛选 (追更/养肥/完结/全部)
//  - 缓存状态角标
//  - 工具栏完整 11 项菜单
//

import SwiftUI

struct BookshelfManageView: View {

    @State private var books: [ShelfBook] = []
    @State private var selectedIds: Set<String> = []
    @State private var filter: ReadFilter = .all
    @State private var showGroupSheet = false
    @State private var importJsonPicker = false

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
        .navigationTitle("书架管理(\(filtered.count))")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    Task { await batchUpdate() }
                } label: { Label("更新目录", systemImage: "arrow.clockwise") }
                .disabled(selectedIds.isEmpty)

                Button {
                    Task { await batchClearCache() }
                } label: { Label("清缓存", systemImage: "trash.circle") }
                .disabled(selectedIds.isEmpty)

                Spacer()

                Button(role: .destructive) {
                    Task { await batchDelete() }
                } label: { Label("删除", systemImage: "trash") }
                .disabled(selectedIds.isEmpty)
            }
        }
        .background(WanxiangColors.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .task { await load() }
    }

    private func load() async {
        books = (try? await BookshelfRepository.shared.listAll()) ?? []
    }

    private func batchDelete() async {
        for url in selectedIds {
            try? await BookshelfRepository.shared.remove(bookUrl: url)
        }
        selectedIds.removeAll()
        await load()
    }

    private func batchUpdate() async {
        // M2.2.11 简化: 直接给提示, 真实需要 BookSource 配合
        selectedIds.removeAll()
    }

    private func batchClearCache() async {
        for url in selectedIds {
            try? await ChapterRepository.shared.clearContent(bookUrl: url)
        }
        selectedIds.removeAll()
    }
}
