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
                // 万象书屋: 最新章节 — 跟 Android `ChangeBookSourceDialog` 行为一致.
                // SearchBook 大多数源不带 lastChapter, 由 ViewModel 异步 fetchInfo 补全后回填.
                // 在补全前显示占位"加载最新章节…", 拿到后切到正式标题.
                lastChapterRow(item: item)
            }
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(WanxiangColors.accent)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func lastChapterRow(item: ChangeSourceViewModel.Candidate) -> some View {
        if let last = item.book.lastChapter?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
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
        } else if item.isLoadingInfo {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.55)
                Text("加载最新章节…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if item.infoFailed {
            Text("最新章节: ——")
                .font(.caption2)
                .foregroundStyle(.secondary.opacity(0.5))
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ChangeSourceViewModel: ObservableObject {

    struct Candidate: Sendable {
        var book: SearchBook
        /// 最新章节是否在加载中 (UI 显示 spinner).
        var isLoadingInfo: Bool = false
        /// fetchInfo 失败 (UI 显示占位"——").
        var infoFailed: Bool = false
        var bookUrl: String { book.bookUrl }
    }

    @Published var candidates: [Candidate] = []
    @Published var isSearching = false

    /// 异步 fetchInfo 任务管控 (取消用); sheet dismiss 时 cancel 全停.
    private var infoFillTasks: [Task<Void, Never>] = []
    /// 信号量限制 fetchInfo 并发. 跟 Android `loadBookInfo` 单源串行 + 多源并行 类似:
    /// 这里 4 个 slot, 8 个候选源时 2 批跑完, 跟搜索池保持隔离避免抢资源.
    private let fetchInfoConcurrency = 4

    /// 多源 search, name + author 完全匹配的留下.
    /// 当前源排在第一位, 其它候选按各源回包顺序保持 (与 Android `ChangeBookSource` 行为对齐).
    func refresh(target: ChangeSourceView.Target) async {
        cancelInfoFill()
        candidates = []
        isSearching = true
        defer { isSearching = false }
        let sources = BookSourceRegistry.shared.enabledSources
        let stream = await BookSourceEngine.shared.searchAll(in: sources, key: target.name)
        var seen = Set<String>()
        // 信号量计数 (使用 actor-isolated state 避免锁; 简单计数即可).
        var inflightCount = 0
        var pendingQueue: [Int] = []  // 等待获得 slot 的 candidate index
        for await (_, result) in stream {
            if Task.isCancelled { break }
            switch result {
            case .success(let books):
                for b in books where matches(target: target, candidate: b) {
                    let key = "\(b.origin)::\(b.bookUrl)"
                    if seen.insert(key).inserted {
                        // 入列 + UI 即时显示 row + spinner
                        var cand = Candidate(book: b)
                        // 如果搜索阶段已经带了 lastChapter (少数源会), 直接用, 不重新拉.
                        let alreadyHasLast = (b.lastChapter?
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                        cand.isLoadingInfo = !alreadyHasLast
                        let insertIdx: Int
                        if let cur = target.currentOrigin, b.origin == cur {
                            candidates.insert(cand, at: 0)
                            insertIdx = 0
                        } else {
                            candidates.append(cand)
                            insertIdx = candidates.count - 1
                        }
                        if !alreadyHasLast {
                            // 调度 fetchInfo: 用 dedupe key (origin+bookUrl) 跟踪, 不用 index
                            // (列表插入会让 index 变, 必须按 key 找回).
                            scheduleInfoFill(for: key, inflight: &inflightCount, pending: &pendingQueue)
                        }
                        _ = insertIdx
                    }
                }
            case .failure:
                continue
            }
        }
    }

    /// 启动一个 fetchInfo 任务, 限 4 并发. 任务 finish 后递归处理 pending queue.
    private func scheduleInfoFill(for key: String,
                                  inflight: inout Int,
                                  pending: inout [Int]) {
        // 简化: 不真做信号量, 直接全部 launch 但每个内部限 concurrency
        // — Swift 5.9+ 简洁写法是 TaskGroup, 但这里候选可能持续到来, 用单独 Task + actor 计数.
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.acquireSlot()
            defer { Task { await self.releaseSlot() } }
            await self.performInfoFill(forKey: key)
        }
        infoFillTasks.append(task)
    }

    /// fetchInfo 一个候选的 BookInfo, 拿到 lastChapter 后回填 candidates.
    private func performInfoFill(forKey key: String) async {
        guard let cand = candidates.first(where: { "\($0.book.origin)::\($0.book.bookUrl)" == key }) else { return }
        guard let source = sourceFor(origin: cand.book.origin) else {
            updateCandidate(forKey: key) { $0.isLoadingInfo = false; $0.infoFailed = true }
            return
        }
        do {
            // 加 8 秒超时, 慢源不要拖死整个 sheet 体验
            let info: BookInfo = try await withThrowingTaskGroup(of: BookInfo.self) { group in
                group.addTask {
                    return try await BookSourceEngine.shared.fetchInfo(of: cand.book, in: source)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    throw CancellationError()
                }
                guard let first = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return first
            }
            if Task.isCancelled { return }
            updateCandidate(forKey: key) { c in
                c.isLoadingInfo = false
                c.infoFailed = false
                if let last = info.lastChapter?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
                    c.book.lastChapter = last
                }
                if c.book.intro?.isEmpty != false, let intro = info.intro { c.book.intro = intro }
                if c.book.coverUrl?.isEmpty != false, let cv = info.coverUrl { c.book.coverUrl = cv }
            }
        } catch {
            updateCandidate(forKey: key) { c in
                c.isLoadingInfo = false
                c.infoFailed = true
            }
        }
    }

    private func updateCandidate(forKey key: String, _ mut: (inout Candidate) -> Void) {
        guard let idx = candidates.firstIndex(where: { "\($0.book.origin)::\($0.book.bookUrl)" == key }) else { return }
        mut(&candidates[idx])
    }

    // 简陋信号量: 用一个 actor-isolated counter 限并发. (MainActor 上跑 await sleep 让出 thread).
    private var infoFillInflight = 0
    private func acquireSlot() async {
        while infoFillInflight >= fetchInfoConcurrency {
            try? await Task.sleep(nanoseconds: 80_000_000)  // 80ms 轮询
            if Task.isCancelled { return }
        }
        infoFillInflight += 1
    }
    private func releaseSlot() {
        infoFillInflight = max(0, infoFillInflight - 1)
    }

    private func cancelInfoFill() {
        for t in infoFillTasks { t.cancel() }
        infoFillTasks.removeAll()
        infoFillInflight = 0
    }

    private func matches(target: ChangeSourceView.Target, candidate: SearchBook) -> Bool {
        let n1 = target.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let n2 = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n1 == n2 else { return false }
        let a1 = target.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let a2 = candidate.author.trimmingCharacters(in: .whitespacesAndNewlines)
        return a1.isEmpty || a2.isEmpty || a1 == a2
    }

    func sourceFor(origin: String) -> BookSource? {
        BookSourceRegistry.shared.find(origin: origin)
    }

    deinit {
        for t in infoFillTasks { t.cancel() }
    }
}
