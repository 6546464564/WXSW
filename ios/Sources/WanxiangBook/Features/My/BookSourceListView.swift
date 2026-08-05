//
//  BookSourceListView.swift
//  万象书屋 iOS · 书源列表 (我的 → 书源管理)
//
//  展示后端下发的全部书源: 名称 / 分组 / URL + 启用开关.
//  - 数据来自 BookSourceRegistry (启动时从 /api/sources 拉, 内存持有)
//  - 开关只改内存 enabled, 重启后以后端下发为准 (iOS in-memory only 政策)
//  - 搜索为后端代理搜索, 本页开关影响"换源 / 详情找源"的候选范围
//

import SwiftUI

struct BookSourceListView: View {

    @StateObject private var registry = BookSourceRegistry.shared
    @State private var query = ""

    private var groups: [(name: String, sources: [BookSource])] {
        var byGroup: [String: [BookSource]] = [:]
        for s in registry.sources {
            let g = (s.bookSourceGroup?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
                ? String(localized: "source_list_ungrouped")
                : s.bookSourceGroup!
            byGroup[g, default: []].append(s)
        }
        var out = byGroup.map { (name: $0.key, sources: $0.value) }
        out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return out
    }

    private var filteredGroups: [(name: String, sources: [BookSource])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return groups }
        return groups.compactMap { group in
            let hit = group.sources.filter { s in
                s.bookSourceName.lowercased().contains(q)
                    || s.bookSourceUrl.lowercased().contains(q)
                    || (s.bookSourceGroup ?? "").lowercased().contains(q)
            }
            return hit.isEmpty ? nil : (name: group.name, sources: hit)
        }
    }

    var body: some View {
        List {
            if !registry.isLoaded, registry.sources.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("source_list_loading")
                            .font(.caption)
                            .foregroundStyle(WanxiangColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                }
                .listRowBackground(Color.clear)
            } else if registry.sources.isEmpty {
                Section {
                    Text("source_list_empty")
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredGroups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.sources, id: \.bookSourceUrl) { source in
                            BookSourceListRow(source: source) { enabled in
                                registry.setEnabled(source, enabled: enabled)
                            }
                        }
                    }
                }
                Section {
                    Text("source_list_footnote")
                        .font(.caption2)
                        .foregroundStyle(WanxiangColors.textSecondary)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "source_list_search")
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("source_list_title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(registry.sources.count)")
                    .font(.caption)
                    .foregroundStyle(WanxiangColors.textSecondary)
                    .accessibilityLabel("共 \(registry.sources.count) 个书源")
            }
        }
        .task {
            if !registry.isLoaded {
                await registry.refresh()
            }
        }
    }
}

// MARK: - 单行

private struct BookSourceListRow: View {

    let source: BookSource
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(source.bookSourceName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(WanxiangColors.textPrimary)
                        .lineLimit(1)
                    if let group = source.bookSourceGroup?.trimmingCharacters(in: .whitespaces),
                       !group.isEmpty {
                        Text(group)
                            .font(.caption2)
                            .foregroundStyle(WanxiangColors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(WanxiangColors.textSecondary.opacity(0.12))
                            .clipShape(Capsule())
                            .lineLimit(1)
                    }
                }
                Text(source.bookSourceUrl)
                    .font(.caption2)
                    .foregroundStyle(WanxiangColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { source.enabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .tint(WanxiangColors.primary)
            .accessibilityLabel("\(source.bookSourceName) 启用状态")
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        BookSourceListView()
    }
}
