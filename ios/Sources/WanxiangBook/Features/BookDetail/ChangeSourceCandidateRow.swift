//
//  ChangeSourceCandidateRow.swift
//  万象书屋 iOS · 换源候选行 (整书换源 / 本章换源共用)
//
//  对应 Android: item_change_source.xml + ChangeBookSourceAdapter.convert
//  - 源名 / 当前源 ✓ / 作者
//  - 书名 + 最新章节 (异步 fetchInfo 后回填)
//  - 字数 + 响应时间 (load_word_count toggle 打开时显示)
//  - 👍 / 👎 评分 (UserDefaults 持久化)
//  - 长按 → 置顶 / 置底
//

import SwiftUI

struct ChangeSourceCandidateRow: View {

    let candidate: ChangeSourceViewModel.Candidate
    /// 高亮当前正在用的源 + 行尾 ✓
    let isCurrent: Bool
    /// load_word_count toggle 是否打开 (Android `menu_load_word_count`)
    let showWordCountAndRespond: Bool
    /// 用户操作回调
    let onTop: () -> Void
    let onBottom: () -> Void
    let onScoreChanged: (Int) -> Void
    /// 当前评分 (-1 / 0 / 1); 从 SourceScoreStore 取
    let score: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(candidate.book.originName)
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
                    Text(candidate.book.author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(candidate.book.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                lastChapterRow
                if showWordCountAndRespond {
                    metaRow
                }
            }

            // 评分按钮: 👍 / 👎. 跟 Android `ChangeBookSourceAdapter.ivGood/ivBad` 等价.
            scoreButtons

            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(WanxiangColors.accent)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onTop()
            } label: {
                Label("置顶", systemImage: "arrow.up.to.line")
            }
            Button {
                onBottom()
            } label: {
                Label("置底", systemImage: "arrow.down.to.line")
            }
            Divider()
            Button {
                onScoreChanged(score == 1 ? 0 : 1)
            } label: {
                Label(score == 1 ? "取消推荐" : "推荐此源", systemImage: "hand.thumbsup")
            }
            Button {
                onScoreChanged(score == -1 ? 0 : -1)
            } label: {
                Label(score == -1 ? "取消屏蔽" : "屏蔽此源", systemImage: "hand.thumbsdown")
            }
        }
    }

    // MARK: - subviews

    @ViewBuilder
    private var lastChapterRow: some View {
        if let last = candidate.book.lastChapter?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "book.closed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("最新章节: \(last)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if candidate.isLoadingInfo {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.55)
                Text("加载最新章节…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if candidate.infoFailed {
            Text("最新章节: ——")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }

    /// 字数 + 响应时间一行 (Android `tvCurrentChapterWordCount` + `tvRespondTime`)
    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 8) {
            if let wc = candidate.book.wordCount?.trimmingCharacters(in: .whitespacesAndNewlines), !wc.isEmpty {
                Label(wc, systemImage: "textformat.size")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if candidate.respondTimeMs >= 0 {
                Label("\(candidate.respondTimeMs)ms", systemImage: "bolt.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(
                        candidate.respondTimeMs < 1500
                            ? Color.green.opacity(0.85)
                            : candidate.respondTimeMs < 5000
                                ? Color.orange.opacity(0.85)
                                : Color.red.opacity(0.85)
                    )
            }
        }
    }

    private var scoreButtons: some View {
        VStack(spacing: 6) {
            Button {
                onScoreChanged(score == 1 ? 0 : 1)
            } label: {
                Image(systemName: score == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.caption)
                    .foregroundStyle(score == 1 ? Color.red.opacity(0.85) : Color.secondary.opacity(0.5))
                    // 万象书屋 (UX 2026-05-11): 限制评分按钮命中区到 28×26.
                    // 之前 Image 自动撑满外层 VStack 高度, 整行右侧 1/3 被这两个按钮吃掉,
                    // 用户点行右侧"没反应"误以为是 row 不能点.
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            Button {
                onScoreChanged(score == -1 ? 0 : -1)
            } label: {
                Image(systemName: score == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.caption)
                    .foregroundStyle(score == -1 ? Color.blue.opacity(0.85) : Color.secondary.opacity(0.5))
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.top, 2)
    }
}
