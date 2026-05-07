//
//  TocView.swift
//  万象书屋 iOS · 目录 (M2.5.5.1 + M2.5.6.x)
//
//  对应 Android: io.legado.app.ui.book.toc.TocActivity
//

import SwiftUI

struct TocView: View {
    let chapters: [BookChapter]
    let currentIndex: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyword: String = ""

    private var filtered: [BookChapter] {
        let kw = keyword.trimmingCharacters(in: .whitespaces)
        if kw.isEmpty { return chapters }
        return chapters.filter { $0.title.localizedCaseInsensitiveContains(kw) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索框
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("章节内搜索", text: $keyword)
                }
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding()

                // 列表
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
        }
    }
}
