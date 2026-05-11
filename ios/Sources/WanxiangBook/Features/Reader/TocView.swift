//
//  TocView.swift
//  万象书屋 iOS · 目录 (M2.5.5.1 + M2.5.6.x)
//
//  对应 Android: io.legado.app.ui.book.toc.TocActivity + ChapterListAdapter.upHasCache
//

import SwiftUI

struct TocView: View {
    let chapters: [BookChapter]
    let currentIndex: Int
    /// 非空时右侧显示缓存状态（对齐安卓：当前章 ✓ 主题色 / 已缓存 ✓ 绿色 / 未缓存 ☁︎）
    var bookUrl: String? = nil
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloader = BookDownloader.shared
    @State private var keyword: String = ""
    @State private var cachedIndexes: Set<Int> = []

    /// 已缓存章节主题色（对齐 Android `success`）
    private let cachedTint = Color(red: 0x43/255.0, green: 0xA0/255.0, blue: 0x47/255.0)

    private var filtered: [BookChapter] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        if kw.isEmpty { return chapters }
        return chapters.filter { $0.title.localizedCaseInsensitiveContains(kw) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("章节内搜索", text: $keyword)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding()

                ScrollViewReader { proxy in
                    List {
                        ForEach(filtered, id: \.chapterIndex) { ch in
                            Button {
                                onSelect(ch.chapterIndex)
                            } label: {
                                HStack(spacing: 8) {
                                    if ch.isVolume {
                                        Image(systemName: "books.vertical")
                                            .foregroundStyle(WanxiangColors.primary)
                                    }
                                    Text(ch.title)
                                        .foregroundStyle(ch.chapterIndex == currentIndex
                                                         ? WanxiangColors.primary
                                                         : WanxiangColors.textPrimary)
                                        .fontWeight(ch.isVolume ? .semibold : .regular)
                                    Spacer()
                                    if ch.isVip || ch.isPay {
                                        Image(systemName: "lock.fill")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    if let bookUrl, !bookUrl.isEmpty, !ch.isVolume {
                                        cacheTrailingIcon(chapterIndex: ch.chapterIndex)
                                    }
                                }
                            }
                            .id(ch.chapterIndex)
                        }
                    }
                    .listStyle(.plain)
                    .onAppear {
                        proxy.scrollTo(currentIndex, anchor: .center)
                    }
                }
            }
            .navigationTitle("目录(\(chapters.count) 章)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .task(id: bookUrl) {
                await refreshCachedIndexes()
            }
            .onReceive(downloader.$jobs) { _ in
                guard bookUrl != nil else { return }
                Task { await refreshCachedIndexes() }
            }
        }
    }

    @ViewBuilder
    private func cacheTrailingIcon(chapterIndex: Int) -> some View {
        if chapterIndex == currentIndex {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(WanxiangColors.primary)
                .accessibilityLabel("当前章节")
        } else if cachedIndexes.contains(chapterIndex) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(cachedTint)
                .accessibilityLabel("已缓存")
        } else {
            Image(systemName: "icloud")
                .font(.body)
                .foregroundStyle(WanxiangColors.textSecondary)
                .accessibilityLabel("未缓存")
        }
    }

    private func refreshCachedIndexes() async {
        guard let bookUrl, !bookUrl.isEmpty else {
            await MainActor.run { cachedIndexes = [] }
            return
        }
        let set = (try? await ChapterRepository.shared.cachedContentIndexes(bookUrl: bookUrl)) ?? []
        await MainActor.run { cachedIndexes = set }
    }
}
