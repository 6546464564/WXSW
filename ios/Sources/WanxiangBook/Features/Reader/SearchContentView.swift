//
//  SearchContentView.swift
//  万象书屋 iOS · 章节内 / 全书文本搜索 (M2.5.7)
//
//  对应 Android: io.legado.app.ui.book.searchContent.SearchContentActivity + SearchMenu
//
//  - "本章" / "全书" 切换
//  - 跨章节搜索 (按章顺序遍历, 异步流式 stream 结果)
//  - 点结果跳到对应章 / 高亮 (跳章用 ReaderEngine.goToChapter)
//

import SwiftUI

public struct SearchContentView: View {

    public let book: ShelfBook
    public let chapters: [BookChapter]
    public let currentChapterIndex: Int
    public let onSelect: (Int) -> Void   // 用户点结果, callback chapterIndex

    @StateObject private var vm = SearchContentViewModel()
    @State private var keyword = ""
    @State private var scope: Scope = .currentChapter
    @State private var debounceTask: Task<Void, Never>? = nil
    @Environment(\.dismiss) private var dismiss

    public enum Scope: String, CaseIterable, Identifiable {
        case currentChapter = "本章"
        case allChapters    = "全书"
        public var id: String { rawValue }
    }

    public init(book: ShelfBook, chapters: [BookChapter],
                currentChapterIndex: Int, onSelect: @escaping (Int) -> Void) {
        self.book = book
        self.chapters = chapters
        self.currentChapterIndex = currentChapterIndex
        self.onSelect = onSelect
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索栏
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索内容", text: $keyword)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .onChange(of: keyword) { _, _ in scheduleSearch() }
                    if !keyword.isEmpty {
                        Button { keyword = ""; vm.reset() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)

                // 范围切换
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .onChange(of: scope) { _, _ in scheduleSearch() }

                Divider().padding(.top, 8)

                // 结果列表
                if vm.isSearching {
                    ProgressView("搜索中…").padding()
                }
                if vm.results.isEmpty && !keyword.isEmpty && !vm.isSearching {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.5))
                        Text("没有匹配的内容").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(Array(vm.results.enumerated()), id: \.offset) { _, hit in
                            Button {
                                onSelect(hit.chapterIndex)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(chapterTitle(for: hit.chapterIndex))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(WanxiangColors.primary)
                                    highlightedText(hit.snippet, keyword: keyword)
                                        .font(.subheadline)
                                        .lineLimit(3)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
                if vm.isSearching || (!vm.results.isEmpty && scope == .allChapters) {
                    HStack {
                        Text("已扫描 \(vm.scannedCount) / \(chapters.count) 章")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(vm.results.count) 处匹配")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                }
            }
            .navigationTitle("搜索内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func scheduleSearch() {
        debounceTask?.cancel()
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { vm.reset(); return }
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            switch scope {
            case .currentChapter:
                await vm.searchCurrentChapter(book: book, chapter: chapters[safe: currentChapterIndex],
                                               keyword: kw)
            case .allChapters:
                await vm.searchAllChapters(book: book, chapters: chapters, keyword: kw)
            }
        }
    }

    private func chapterTitle(for index: Int) -> String {
        chapters[safe: index]?.title ?? "第 \(index + 1) 章"
    }

    /// 简单高亮: 关键词加粗 + 棕金色
    private func highlightedText(_ text: String, keyword: String) -> Text {
        var result = Text("")
        var remaining = text
        while let range = remaining.range(of: keyword) {
            let pre = String(remaining[..<range.lowerBound])
            let hit = String(remaining[range])
            result = result + Text(pre) + Text(hit).bold().foregroundColor(WanxiangColors.primary)
            remaining = String(remaining[range.upperBound...])
        }
        return result + Text(remaining)
    }
}

// MARK: - ViewModel

@MainActor
final class SearchContentViewModel: ObservableObject {
    struct Hit: Sendable {
        let chapterIndex: Int
        let snippet: String   // 含关键词的片段
    }

    @Published var results: [Hit] = []
    @Published var isSearching = false
    @Published var scannedCount = 0

    func reset() {
        results = []
        scannedCount = 0
    }

    func searchCurrentChapter(book: ShelfBook, chapter: BookChapter?, keyword: String) async {
        reset()
        isSearching = true
        defer { isSearching = false }
        guard let c = chapter else { return }
        scannedCount = 1
        let hits = await searchOneChapter(book: book, chapter: c, keyword: keyword)
        results = hits
    }

    func searchAllChapters(book: ShelfBook, chapters: [BookChapter], keyword: String) async {
        reset()
        isSearching = true
        defer { isSearching = false }
        // 万象书屋: 只搜已 cache 的章节 (避免一搜就发 N 个网络请求)
        for c in chapters {
            if Task.isCancelled { return }
            let cached = (try? await ChapterRepository.shared.loadContent(
                bookUrl: book.bookUrl, chapterIndex: c.chapterIndex)) ?? ""
            scannedCount += 1
            if cached.isEmpty { continue }
            let hits = await searchOneChapter(book: book, chapter: c,
                                               keyword: keyword, providedContent: cached)
            // 每扫一章就 append 实时显示 (流式)
            results.append(contentsOf: hits)
        }
    }

    private func searchOneChapter(book: ShelfBook, chapter: BookChapter,
                                   keyword: String, providedContent: String? = nil) async -> [Hit] {
        let content: String
        if let p = providedContent {
            content = p
        } else {
            content = (try? await ChapterRepository.shared.loadContent(
                bookUrl: book.bookUrl, chapterIndex: chapter.chapterIndex)) ?? ""
        }
        if content.isEmpty { return [] }
        // 找所有出现位置, 截 ±20 字 snippet
        var hits: [Hit] = []
        var searchStart = content.startIndex
        let nsContent = content as NSString
        while let r = content.range(of: keyword, range: searchStart..<content.endIndex) {
            let lower = max(0, content.distance(from: content.startIndex, to: r.lowerBound) - 20)
            let upper = min(nsContent.length, content.distance(from: content.startIndex, to: r.upperBound) + 20)
            let snippet = nsContent.substring(with: NSRange(location: lower, length: upper - lower))
            hits.append(Hit(chapterIndex: chapter.chapterIndex, snippet: snippet))
            searchStart = r.upperBound
            if hits.count > 30 { break }   // 单章最多 30 处, 防过多
        }
        return hits
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
