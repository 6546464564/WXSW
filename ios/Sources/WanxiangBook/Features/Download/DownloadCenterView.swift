//
//  DownloadCenterView.swift
//  万象书屋 iOS · 下载管理中心 (M2.8 C 档)
//
//  对应 Android: io.legado.app.ui.book.cache.CacheActivity
//
//  功能:
//   - 列出所有下载任务 (running / finished / error / cancelled), 按状态分组
//   - 每行显示书名 + 进度条 + 章节计数 + 图片张数 + 状态图标
//   - 点击行: 取消(running) / 重试(error) / 重新下载(finished)
//

import SwiftUI

public struct DownloadCenterView: View {

    @StateObject private var downloader = BookDownloader.shared
    @State private var confirmCancel: BookDownloader.Job? = nil

    public init() {}

    public var body: some View {
        let allJobs = sortedJobs()
        Group {
            if allJobs.isEmpty {
                emptyState
            } else {
                List {
                    let running = allJobs.filter { $0.status == .running }
                    let finished = allJobs.filter { $0.status == .finished }
                    let failed = allJobs.filter { $0.status == .error || $0.status == .cancelled }
                    if !running.isEmpty {
                        Section("正在下载 (\(running.count))") {
                            ForEach(running, id: \.bookUrl) { jobRow($0) }
                        }
                    }
                    if !finished.isEmpty {
                        Section("已完成 (\(finished.count))") {
                            ForEach(finished, id: \.bookUrl) { jobRow($0) }
                        }
                    }
                    if !failed.isEmpty {
                        Section("失败 / 已取消 (\(failed.count))") {
                            ForEach(failed, id: \.bookUrl) { jobRow($0) }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(WanxiangColors.background)
            }
        }
        .navigationTitle("下载管理")
        .navigationBarTitleDisplayMode(.inline)
        .background(WanxiangColors.background.ignoresSafeArea())
        .confirmationDialog(
            "取消下载",
            isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }),
            titleVisibility: .visible
        ) {
            Button("取消下载", role: .destructive) {
                if let j = confirmCancel { downloader.cancel(bookUrl: j.bookUrl) }
                confirmCancel = nil
            }
            Button("继续下载", role: .cancel) { confirmCancel = nil }
        } message: {
            Text("已下载的章节会保留, 仍可离线阅读")
        }
    }

    private func sortedJobs() -> [BookDownloader.Job] {
        // 排序: running 在前, 然后按 bookName 字典序
        downloader.jobs.values.sorted { a, b in
            if a.status == b.status { return a.bookName < b.bookName }
            return statusOrder(a.status) < statusOrder(b.status)
        }
    }

    private func statusOrder(_ s: BookDownloader.Job.Status) -> Int {
        switch s {
        case .running: return 0
        case .paused: return 1
        case .error: return 2
        case .finished: return 3
        case .cancelled: return 4
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 64))
                .foregroundStyle(WanxiangColors.textSecondary.opacity(0.5))
            Text("暂无下载任务")
                .font(.headline)
                .foregroundStyle(WanxiangColors.textPrimary)
            Text("在书籍详情页或阅读器内点「下载本书」即可加入下载")
                .font(.caption)
                .foregroundStyle(WanxiangColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WanxiangColors.background)
    }

    @ViewBuilder
    private func jobRow(_ job: BookDownloader.Job) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusIcon(job.status)
                Text(job.bookName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(WanxiangColors.textPrimary)
                    .lineLimit(1)
                Spacer()
                actionButton(for: job)
            }
            if job.status == .running {
                ProgressView(value: job.progress)
                    .tint(WanxiangColors.primary)
            }
            HStack(spacing: 6) {
                Text(detailText(for: job))
                    .font(.caption)
                    .foregroundStyle(WanxiangColors.textSecondary)
                if job.imagesDownloaded > 0 {
                    Text("· \(job.imagesDownloaded) 张图")
                        .font(.caption2)
                        .foregroundStyle(WanxiangColors.textSecondary.opacity(0.7))
                }
                Spacer()
                if job.status == .running {
                    Text("\(Int(job.progress * 100))%")
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(WanxiangColors.primary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func detailText(for job: BookDownloader.Job) -> String {
        switch job.status {
        case .running:    return "下载中 \(job.completed + job.failed) / \(job.total)"
        case .finished:   return "已完成 \(job.completed) 章" + (job.failed > 0 ? " · \(job.failed) 失败" : "")
        case .error:      return "下载失败"
        case .cancelled:  return "已取消 (已下 \(job.completed) / \(job.total))"
        case .paused:     return "已暂停 \(job.completed) / \(job.total)"
        }
    }

    @ViewBuilder
    private func statusIcon(_ s: BookDownloader.Job.Status) -> some View {
        switch s {
        case .running:    Image(systemName: "arrow.down.circle.fill").foregroundStyle(WanxiangColors.primary)
        case .finished:   Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:  Image(systemName: "xmark.circle.fill").foregroundStyle(.gray)
        case .paused:     Image(systemName: "pause.circle.fill").foregroundStyle(.gray)
        }
    }

    @ViewBuilder
    private func actionButton(for job: BookDownloader.Job) -> some View {
        switch job.status {
        case .running:
            Button { confirmCancel = job } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        case .error, .cancelled:
            // 重新下载需要 source — 从 BookSourceRegistry 找回, 没有就 disabled
            Button("重试") {
                retryDownload(job: job)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(WanxiangColors.primary)
            .buttonStyle(.borderless)
        case .finished:
            Button("重下") {
                retryDownload(job: job)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(WanxiangColors.textSecondary)
            .buttonStyle(.borderless)
        case .paused:
            EmptyView()
        }
    }

    private func retryDownload(job: BookDownloader.Job) {
        Task {
            // 万象书屋 (M2.8 fix): 优先用 Job 缓存的 originalBook (没加书架的书也能重试),
            // 没缓存才从 BookshelfRepository 兜底.
            let book: ShelfBook?
            if let cached = job.originalBook {
                book = cached
            } else {
                book = try? await BookshelfRepository.shared.get(bookUrl: job.bookUrl)
            }
            guard let book = book else { return }
            let source = BookSourceRegistry.shared.find(origin: book.origin)
            await MainActor.run {
                downloader.startDownload(book: book, source: source, range: job.lastRange)
            }
        }
    }
}
