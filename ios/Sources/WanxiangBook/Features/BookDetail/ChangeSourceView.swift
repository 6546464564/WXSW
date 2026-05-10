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

    /// 万象书屋: 换源对话框无关"书架"还是"搜索"来源, 只关心 (name, author, currentOrigin?).
    /// `currentOrigin` 用来在列表里把当前正在用的源高亮 / 排前 (与 Android 行为一致).
    public struct Target {
        public let name: String
        public let author: String
        public let currentOrigin: String?
        public init(name: String, author: String, currentOrigin: String? = nil) {
            self.name = name; self.author = author; self.currentOrigin = currentOrigin
        }
    }

    public let target: Target
    /// callback: 用户选了新源, 拿到新 SearchBook + 新 BookSource
    public let onSelect: (SearchBook, BookSource) -> Void

    @StateObject private var vm = ChangeSourceViewModel()
    @Environment(\.dismiss) private var dismiss

    public init(target: Target,
                onSelect: @escaping (SearchBook, BookSource) -> Void) {
        self.target = target
        self.onSelect = onSelect
    }

    /// 兼容入口: 书架场景 (用 ShelfBook)
    public init(originalBook: ShelfBook,
                onSelect: @escaping (SearchBook, BookSource) -> Void) {
        self.init(
            target: Target(name: originalBook.name,
                           author: originalBook.author,
                           currentOrigin: originalBook.origin),
            onSelect: onSelect
        )
    }

    /// 新增入口: 搜索 / 详情场景 (用 SearchBook)
    public init(searchBook: SearchBook,
                onSelect: @escaping (SearchBook, BookSource) -> Void) {
        self.init(
            target: Target(name: searchBook.name,
                           author: searchBook.author,
                           currentOrigin: searchBook.origin),
            onSelect: onSelect
        )
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("\(target.name) · \(target.author)")
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
                                    candidateRow(item)
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
                        Task { await vm.refresh(target: target) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(vm.isSearching)
                }
            }
            .task {
                if vm.candidates.isEmpty {
                    await vm.refresh(target: target)
                }
                // 万象书屋 (debug arg `--AutoPickSource <源名子串>`): 拿到候选后自动选第一个匹配的源.
                let args = ProcessInfo.processInfo.arguments
                for key in ["--AutoPickSource", "-AutoPickSource"] {
                    if let i = args.firstIndex(of: key), i + 1 < args.count {
                        let needle = args[i + 1]
                        if let hit = vm.candidates.first(where: { $0.book.originName.contains(needle) }),
                           let src = vm.sourceFor(origin: hit.book.origin) {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            onSelect(hit.book, src)
                            dismiss()
                        }
                        break
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ item: ChangeSourceViewModel.Candidate) -> some View {
        let isCurrent = (target.currentOrigin == item.book.origin)
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(item.book.originName)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(
                            isCurrent
                                ? WanxiangColors.accent.opacity(0.25)
                                : WanxiangColors.primary.opacity(0.18)
                        ))
                        .foregroundStyle(isCurrent ? WanxiangColors.accent : WanxiangColors.primary)
                    if isCurrent {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(WanxiangColors.accent)
                    }
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
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(WanxiangColors.accent)
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

    /// 多源 search, name + author 完全匹配的留下.
    /// 当前源排在第一位, 其它候选按各源回包顺序保持 (与 Android `ChangeBookSource` 行为对齐).
    func refresh(target: ChangeSourceView.Target) async {
        candidates = []
        isSearching = true
        defer { isSearching = false }
        let sources = BookSourceRegistry.shared.enabledSources
        let stream = await BookSourceEngine.shared.searchAll(in: sources, key: target.name)
        var seen = Set<String>()
        for await (_, result) in stream {
            // bug #8 fix: sheet dismiss 时 task cancel, 这里立即停, 别再写候选
            if Task.isCancelled { break }
            switch result {
            case .success(let books):
                for b in books where matches(target: target, candidate: b) {
                    let key = "\(b.origin)::\(b.bookUrl)"
                    if seen.insert(key).inserted {
                        let cand = Candidate(book: b)
                        // 当前源插到第 1 位, 其它追加
                        if let cur = target.currentOrigin, b.origin == cur {
                            candidates.insert(cand, at: 0)
                        } else {
                            candidates.append(cand)
                        }
                    }
                }
            case .failure:
                continue
            }
        }
    }

    private func matches(target: ChangeSourceView.Target, candidate: SearchBook) -> Bool {
        let n1 = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let n2 = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n1 == n2 else { return false }
        let a1 = target.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let a2 = candidate.author.trimmingCharacters(in: .whitespacesAndNewlines)
        // 作者一致 (空也算一致, 部分源没作者)
        return a1.isEmpty || a2.isEmpty || a1 == a2
    }

    func sourceFor(origin: String) -> BookSource? {
        BookSourceRegistry.shared.find(origin: origin)
    }
}
