//
//  ExploreShowView.swift
//  万象书屋 iOS · 发现某频道书列表 (M2.3 v2)
//
//  对应 Android: io.legado.app.ui.book.explore.ExploreShowActivity
//
//  - 进入: source + 该 explore kind (玄幻/都市/穿越...)
//  - 拉 BookSourceEngine.fetchExplore → list of SearchBook
//  - 显示 grid (跟搜索结果同款行卡)
//  - 翻页: 滚到底部自动加载下一页
//

import SwiftUI

public struct ExploreShowView: View {

    let source: BookSource
    let kind: ExploreParser.Kind

    @StateObject private var vm = ExploreShowViewModel()

    public init(source: BookSource, kind: ExploreParser.Kind) {
        self.source = source
        self.kind = kind
    }

    public var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 16
            ) {
                ForEach(vm.books, id: \.bookUrl) { book in
                    NavigationLink {
                        BookDetailView(book: book, source: source)
                    } label: {
                        BookGridCell(book: book)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        // 万象书屋: 滚到末尾时自动拉下一页
                        if book.bookUrl == vm.books.last?.bookUrl, !vm.isLoadingMore, vm.hasMore {
                            Task { await vm.loadMore(source: source, kind: kind) }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            if vm.isLoading || vm.isLoadingMore {
                ProgressView().padding()
            }
            if !vm.hasMore && !vm.books.isEmpty {
                Text("到底了").font(.caption).foregroundStyle(.secondary).padding()
            }
        }
        .background(WanxiangColors.background)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if vm.books.isEmpty {
                await vm.loadFirst(source: source, kind: kind)
            }
        }
        .overlay {
            if let err = vm.error, vm.books.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text(err).font(.subheadline).multilineTextAlignment(.center).padding(.horizontal)
                    Button("重试") { Task { await vm.loadFirst(source: source, kind: kind) } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

// MARK: - 单本卡

private struct BookGridCell: View {
    let book: SearchBook

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let h = geo.size.width * 4.2 / 3
                BookCover(url: book.coverUrl, width: geo.size.width, height: h)
            }
            .aspectRatio(3.0/4.2, contentMode: .fit)
            Text(book.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(WanxiangColors.textPrimary)
                .lineLimit(1)
            Text(book.author)
                .font(.caption2)
                .foregroundStyle(WanxiangColors.textSecondary)
                .lineLimit(1)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ExploreShowViewModel: ObservableObject {
    @Published var books: [SearchBook] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var hasMore = true
    @Published var error: String? = nil
    private var page = 1
    private var seenKeys = Set<String>()

    func loadFirst(source: BookSource, kind: ExploreParser.Kind) async {
        isLoading = true
        defer { isLoading = false }
        page = 1
        books = []
        seenKeys.removeAll()
        hasMore = true
        await loadPage(source: source, kind: kind)
    }

    func loadMore(source: BookSource, kind: ExploreParser.Kind) async {
        guard !isLoadingMore, hasMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        page += 1
        await loadPage(source: source, kind: kind)
    }

    private func loadPage(source: BookSource, kind: ExploreParser.Kind) async {
        do {
            let result = try await BookSourceEngine.shared.fetchExplore(of: source, kind: kind, page: page)
            // dedup
            var newBooks: [SearchBook] = []
            for b in result {
                if seenKeys.insert(b.dedupeKey).inserted {
                    newBooks.append(b)
                }
            }
            books.append(contentsOf: newBooks)
            // 万象书屋: 本页空 / 太少 = 没下一页了
            if result.isEmpty || newBooks.isEmpty {
                hasMore = false
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
            hasMore = false
        }
    }
}
