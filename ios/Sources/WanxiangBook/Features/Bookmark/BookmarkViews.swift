//
//  BookmarkViews.swift
//  万象书屋 iOS · 书签 + 阅读记录 (M2.9.1-4)
//

import SwiftUI

// MARK: - 全部书签

struct AllBookmarkView: View {
    @State private var bookmarks: [BookmarkEntity] = []

    var body: some View {
        Group {
            if bookmarks.isEmpty {
                ContentUnavailableView("没有书签", systemImage: "bookmark",
                    description: Text("阅读时长按选中文本可添加书签"))
            } else {
                List {
                    ForEach(bookmarks) { b in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(b.bookName).font(.headline).foregroundStyle(WanxiangColors.textPrimary)
                            if let title = b.chapterTitle {
                                Text("\(title) · 第 \(b.chapterIndex + 1) 章")
                                    .font(.caption).foregroundStyle(WanxiangColors.textSecondary)
                            }
                            if let content = b.content {
                                Text(content).font(.subheadline).foregroundStyle(WanxiangColors.textPrimary)
                                    .lineLimit(3).padding(.top, 2)
                            }
                            if let note = b.note, !note.isEmpty {
                                Text("📝 \(note)").font(.caption).foregroundStyle(WanxiangColors.primary)
                            }
                            Text(formatDate(b.createdAt))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task {
                                    try? await BookmarkRepository.shared.delete(id: b.id)
                                    await load()
                                }
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("全部书签 (\(bookmarks.count))")
        .background(WanxiangColors.background.ignoresSafeArea())
        .scrollContentBackground(.hidden)
        .task { await load() }
    }

    private func load() async {
        bookmarks = (try? await BookmarkRepository.shared.listAll()) ?? []
    }

    private func formatDate(_ ts: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts) / 1000))
    }
}

// MARK: - 阅读记录

struct ReadRecordView: View {
    @State private var totalSec: Int = 0
    @State private var rows: [ReadRecordRow] = []

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Text(formatDuration(totalSec))
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(WanxiangColors.primary)
                    Text("累计阅读时长")
                        .font(.subheadline).foregroundStyle(WanxiangColors.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section("近 30 天") {
                if rows.isEmpty {
                    Text("还没有阅读记录").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { r in
                        HStack {
                            Text(r.day).font(.caption.monospacedDigit())
                                .foregroundStyle(WanxiangColors.textSecondary)
                            Spacer()
                            Text(formatDuration(r.seconds))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(WanxiangColors.textPrimary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("阅读记录")
        .task {
            totalSec = (try? await ReadRecordRepository.shared.totalSeconds()) ?? 0
            rows = (try? await ReadRecordRepository.shared.dailyLast30()) ?? []
        }
    }

    private func formatDuration(_ sec: Int) -> String {
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}
