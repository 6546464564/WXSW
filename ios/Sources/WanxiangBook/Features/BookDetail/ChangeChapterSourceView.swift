//
//  ChangeChapterSourceView.swift
//  万象书屋 iOS · 本章换源
//
//  对应 Android: io.legado.app.ui.book.changesource.ChangeChapterSourceDialog
//  - 全网搜同名书 → 拉候选源目录 → 映射当前章节位置 → 用户选异源目录中的一章
//  - 拉取正文后仅替换**当前章**缓存 (不切全书 bookUrl), 与 Legado `saveContent` 语义一致.
//

import SwiftUI

public struct ChangeChapterSourceView: View {

    public let target: ChangeSourceView.Target
    public let chapterIndex: Int
    public let chapterTitle: String?
    /// 用户确认一节正文后回调 (通常为 ReaderEngine.replaceCurrentChapterBody).
    public let onReplaceChapterBody: (String) -> Void

    @StateObject private var vm = ChangeSourceViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    public init(
        target: ChangeSourceView.Target,
        chapterIndex: Int,
        chapterTitle: String?,
        onReplaceChapterBody: @escaping (String) -> Void
    ) {
        self.target = target
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.onReplaceChapterBody = onReplaceChapterBody
    }

    public init(
        originalBook: ShelfBook,
        chapterIndex: Int,
        chapterTitle: String?,
        onReplaceChapterBody: @escaping (String) -> Void
    ) {
        self.init(
            target: ChangeSourceView.Target(
                name: originalBook.name,
                author: originalBook.author,
                currentOrigin: originalBook.origin
            ),
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            onReplaceChapterBody: onReplaceChapterBody
        )
    }

    public var body: some View {
        NavigationStack(path: $path) {
            candidateList
                .navigationTitle("本章换源")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { dismiss() }
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
                .navigationDestination(for: AlternatePickAnchor.self) { anchor in
                    AlternateChapterPickScreen(
                        anchor: anchor,
                        readerChapterIndex: chapterIndex,
                        readerChapterTitle: chapterTitle,
                        onReplaceChapterBody: onReplaceChapterBody
                    )
                }
                .task {
                    if vm.candidates.isEmpty {
                        await vm.refresh(target: target)
                    }
                }
        }
    }

    private var candidateList: some View {
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
                                guard let source = vm.sourceFor(origin: item.book.origin) else { return }
                                path.append(AlternatePickAnchor(book: item.book, source: source))
                            } label: {
                                candidateRow(item)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("找到 \(vm.candidates.count) 个候选源 · 点选后加载目录")
                            .font(.caption)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ item: ChangeSourceViewModel.Candidate) -> some View {
        let isCurrent = (target.currentOrigin == item.book.origin)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
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
                    Spacer(minLength: 0)
                    Text(item.book.author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.book.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Navigation anchor

private struct AlternatePickAnchor: Hashable {
    let book: SearchBook
    let source: BookSource
}

// MARK: - 异源目录 + 选章

private struct AlternateChapterPickScreen: View {

    let anchor: AlternatePickAnchor
    let readerChapterIndex: Int
    let readerChapterTitle: String?
    let onReplaceChapterBody: (String) -> Void

    @State private var toc: [BookChapter] = []
    @State private var tocLoadError: String?
    @State private var chapterFetchError: String?
    @State private var loadingToc = true
    @State private var fetchingIndex: Int?

    private var searchBook: SearchBook { anchor.book }
    private var source: BookSource { anchor.source }

    private var suggestedIndex: Int {
        guard !toc.isEmpty else { return 0 }
        let raw = BookChapterMigration.mappedDurChapterIndex(
            oldDurChapterIndex: readerChapterIndex,
            oldDurChapterTitle: readerChapterTitle,
            newChapters: toc,
            oldChapterListSize: 0
        )
        return min(max(0, raw), toc.count - 1)
    }

    var body: some View {
        Group {
            if loadingToc {
                ProgressView("加载目录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = tocLoadError {
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let ce = chapterFetchError {
                        Section {
                            Text(ce)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Section {
                        ForEach(Array(toc.enumerated()), id: \.offset) { idx, chapter in
                            let isPick = (fetchingIndex == idx)
                            Button {
                                chapterFetchError = nil
                                Task { await fetchAndReplace(index: idx, chapter: chapter) }
                            } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(chapter.title)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        if chapter.isVolume {
                                            Text("卷")
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    if idx == suggestedIndex {
                                        Text("推荐")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Capsule().fill(WanxiangColors.accent.opacity(0.2)))
                                            .foregroundStyle(WanxiangColors.accent)
                                    }
                                    if isPick {
                                        ProgressView().scaleEffect(0.75)
                                    }
                                }
                            }
                            .disabled(fetchingIndex != nil)
                        }
                    } header: {
                        Text("选用一节替换当前阅读章正文 · \(searchBook.originName)")
                            .font(.caption)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("目录")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: searchBook.bookUrl) {
            await loadToc()
        }
    }

    private func loadToc() async {
        loadingToc = true
        tocLoadError = nil
        chapterFetchError = nil
        toc = []
        defer { loadingToc = false }
        let info = BookInfo(
            bookUrl: searchBook.bookUrl,
            name: searchBook.name,
            author: searchBook.author,
            coverUrl: searchBook.coverUrl,
            tocUrl: searchBook.bookUrl
        )
        do {
            let list = try await BookSourceEngine.shared.fetchToc(of: info, in: source)
            if Task.isCancelled { return }
            if list.isEmpty {
                tocLoadError = "该源目录为空"
            } else {
                toc = list
            }
        } catch {
            tocLoadError = "目录加载失败:\(error.localizedDescription)"
        }
    }

    private func fetchAndReplace(index: Int, chapter: BookChapter) async {
        fetchingIndex = index
        defer { fetchingIndex = nil }
        do {
            let content = try await BookSourceEngine.shared.fetchContent(of: chapter, in: source)
            if Task.isCancelled { return }
            let body = content.content
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run {
                    chapterFetchError = "正文为空,请换一章或其它源"
                }
                return
            }
            await MainActor.run {
                onReplaceChapterBody(body)
            }
        } catch is CancellationError {
            // ignore
        } catch {
            await MainActor.run {
                chapterFetchError = "正文加载失败:\(error.localizedDescription)"
            }
        }
    }
}
