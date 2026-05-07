//
//  ChangeSourceView.swift
//  万象书屋 iOS · 换源 (M2.5.5)
//
//  对应 Android: io.legado.app.ui.book.changesource.ChangeBookSourceDialog
//
//  - 拿当前书的 name + author, 在所有 enabled 源里 search
//  - 列出每个找到的 候选 (name == 当前书 name && author 匹配)
//  - 用户点候选 → 切换 origin/bookUrl 到新源, 清章节 cache, 重新加载 toc
//

import SwiftUI

public struct ChangeSourceView: View {

    public let originalBook: ShelfBook
    /// callback: 用户选了新源, 拿到新 SearchBook + 新 BookSource
    public let onSelect: (SearchBook, BookSource) -> Void

    @StateObject private var vm = ChangeSourceViewModel()
    @Environment(\.dismiss) private var dismiss

    public init(originalBook: ShelfBook,
                onSelect: @escaping (SearchBook, BookSource) -> Void) {
        self.originalBook = originalBook
        self.onSelect = onSelect
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("\(originalBook.name) · \(originalBook.author)")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if vm.isSearching {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .padding()

                Divider()

                if vm.candidates.isEmpty && !vm.isSearching {
                    Spacer()
                    Text("没找到此书的其它源")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(vm.candidates, id: \.bookUrl) { item in
                                Button {
                                    if let source = vm.sourceFor(origin: item.book.origin) {
                                        onSelect(item.book, source)
                                        dismiss()
                                    }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(item.book.originName)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                                    .background(Capsule().fill(WanxiangColors.primary.opacity(0.18)))
                                                    .foregroundStyle(WanxiangColors.primary)
                                                if let last = item.book.lastChapter, !last.isEmpty {
                                                    Text("最新: \(last)")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            HStack {
                                                Text(item.book.name).font(.subheadline.weight(.medium))
                                                Spacer()
                                                Text(item.book.author).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("找到 \(vm.candidates.count) 个候选源")
                                .font(.caption)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await vm.refresh(book: originalBook) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isSearching)
                }
            }
            .task {
                if vm.candidates.isEmpty {
                    await vm.refresh(book: originalBook)
                }
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ChangeSourceViewModel: ObservableObject {

    struct Candidate: Sendable {
        let book: SearchBook
        var bookUrl: String { book.bookUrl }
    }

    @Published var candidates: [Candidate] = []
    @Published var isSearching = false

    /// 多源 search, name + author 完全匹配的留下
    func refresh(book: ShelfBook) async {
        candidates = []
        isSearching = true
        defer { isSearching = false }
        let sources = BookSourceRegistry.shared.enabledSources
        let stream = await BookSourceEngine.shared.searchAll(in: sources, key: book.name)
        var seen = Set<String>()
        for await (_, result) in stream {
            // bug #8 fix: sheet dismiss 时 task cancel, 这里立即停, 别再写候选
            if Task.isCancelled { break }
            switch result {
            case .success(let books):
                for b in books where matches(book: book, candidate: b) {
                    let key = "\(b.origin)::\(b.bookUrl)"
                    if seen.insert(key).inserted {
                        candidates.append(Candidate(book: b))
                    }
                }
            case .failure:
                continue
            }
        }
    }

    private func matches(book: ShelfBook, candidate: SearchBook) -> Bool {
        let n1 = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let n2 = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n1 == n2 else { return false }
        let a1 = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let a2 = candidate.author.trimmingCharacters(in: .whitespacesAndNewlines)
        // 作者一致 (空也算一致, 部分源没作者)
        return a1.isEmpty || a2.isEmpty || a1 == a2
    }

    func sourceFor(origin: String) -> BookSource? {
        BookSourceRegistry.shared.find(origin: origin)
    }
}
