//
//  BookDetailView.swift
//  万象书屋 iOS · 书籍详情页 (M2.4.8)
//
//  对应 Android: io.legado.app.ui.book.info.BookInfoActivity
//
//  M2.4.8 阶段交付:
//   - 封面 + 书名 + 作者 + 分类 + 简介 + 来源
//   - "加书架" / "已加书架" 按钮 (写入 BookshelfRepository)
//   - 占位的 "开始阅读" / "目录" 按钮 (M2.5 阅读器接)
//
//  待补 (M2 后续):
//   - 真实拉详情 (BookSourceEngine.fetchInfo) — 当前用 SearchBook 的字段就够展示
//   - 目录列表 (M2.4.x)
//   - 换源 ChangeBookSourceDialog (M2.5.5.1)
//

import SwiftUI

struct BookDetailView: View {

    let book: SearchBook
    /// 用于"加书架"时知道是哪个源 (源 URL = book.origin)
    let source: BookSource?

    @StateObject private var vm = BookDetailViewModel()
    @State private var addAlert: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionRow
                if let intro = book.intro?.trimmingCharacters(in: .whitespacesAndNewlines), !intro.isEmpty {
                    introBlock(intro)
                }
                metaBlock
                Spacer().frame(height: 40)
            }
            .padding()
        }
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle(book.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.refreshShelfStatus(bookUrl: book.bookUrl) }
        .alert(item: Binding(
            get: { addAlert.map { AlertText(text: $0) } },
            set: { _ in addAlert = nil })
        ) { item in
            Alert(title: Text(item.text))
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            // 万象书屋 (P0 fix): 真加载封面
            BookCover(url: book.coverUrl, width: 100, height: 140)

            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(WanxiangColors.textPrimary)
                Text(book.author)
                    .font(.subheadline)
                    .foregroundStyle(WanxiangColors.textSecondary)
                if let kind = book.kind, !kind.isEmpty {
                    Text(kind)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(WanxiangColors.primary.opacity(0.15))
                        .foregroundStyle(WanxiangColors.primary)
                        .clipShape(Capsule())
                }
                Spacer(minLength: 4)
                Text("来源:\(book.originName)")
                    .font(.caption2)
                    .foregroundStyle(WanxiangColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await onAddOrRemove() }
            } label: {
                HStack {
                    Image(systemName: vm.isInShelf ? "checkmark" : "plus")
                    Text(vm.isInShelf ? "已加书架" : "加书架")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(vm.isInShelf ? WanxiangColors.divider : WanxiangColors.primary)
                .foregroundStyle(vm.isInShelf ? WanxiangColors.textPrimary : .white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(vm.isWorking)

            NavigationLink {
                // 万象书屋: 进阅读器前先确保书在书架 (没在则隐式加)
                ReaderView(book: shelfBookFromSearch(), source: source)
            } label: {
                HStack {
                    Image(systemName: "book.fill")
                    Text("开始阅读")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(WanxiangColors.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// 从 SearchBook 构造一个 ShelfBook (用于阅读器入参)
    private func shelfBookFromSearch() -> ShelfBook {
        ShelfBook(
            bookUrl: book.bookUrl,
            name: book.name,
            author: book.author,
            origin: book.origin,
            originName: book.originName,
            coverUrl: book.coverUrl,
            intro: book.intro,
            kind: book.kind,
            tocUrl: book.bookUrl
        )
    }

    private func introBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("简介")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WanxiangColors.textPrimary)
            Text(text)
                .font(.body)
                .foregroundStyle(WanxiangColors.textPrimary)
                .lineSpacing(4)
        }
    }

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let last = book.lastChapter, !last.isEmpty {
                metaLine(label: "最新章节", value: last)
            }
            if let upd = book.updateTime, !upd.isEmpty {
                metaLine(label: "更新时间", value: upd)
            }
            if let wc = book.wordCount, !wc.isEmpty {
                metaLine(label: "字数", value: wc)
            }
        }
    }

    private func metaLine(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.caption).foregroundStyle(WanxiangColors.textSecondary)
            Text(value).font(.caption).foregroundStyle(WanxiangColors.textPrimary)
        }
    }

    // MARK: - 业务

    private func onAddOrRemove() async {
        if vm.isInShelf {
            await vm.remove(bookUrl: book.bookUrl)
            addAlert = "已从书架移除"
        } else {
            await vm.addToShelf(book: book)
            addAlert = "已加入书架"
        }
    }
}

private struct AlertText: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
final class BookDetailViewModel: ObservableObject {

    @Published var isInShelf = false
    @Published var isWorking = false

    func refreshShelfStatus(bookUrl: String) async {
        isInShelf = (try? await BookshelfRepository.shared.contains(bookUrl: bookUrl)) ?? false
    }

    func addToShelf(book: SearchBook) async {
        isWorking = true
        defer { isWorking = false }
        let shelf = ShelfBook(
            bookUrl: book.bookUrl,
            name: book.name,
            author: book.author,
            origin: book.origin,
            originName: book.originName,
            coverUrl: book.coverUrl,
            intro: book.intro,
            kind: book.kind
        )
        try? await BookshelfRepository.shared.add(shelf)
        isInShelf = true
    }

    func remove(bookUrl: String) async {
        isWorking = true
        defer { isWorking = false }
        try? await BookshelfRepository.shared.remove(bookUrl: bookUrl)
        isInShelf = false
    }
}
