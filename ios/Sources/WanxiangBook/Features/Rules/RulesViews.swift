//
//  RulesViews.swift
//  万象书屋 iOS · 三种规则系统 UI (M2.7)
//
//  - ReplaceRuleListView / EditView (M2.7.1+2)
//  - DictRuleListView / EditView (M2.7.4)
//  - TxtTocRuleListView / EditView (M2.7.6)
//
//  统一通过 ReplaceRuleRepository / DictRuleRepository / TxtTocRuleRepository 操作 SQLite
//

import SwiftUI

// MARK: - Replace Rule

struct ReplaceRuleListView: View {
    @State private var rules: [ReplaceRuleEntity] = []
    @State private var editing: ReplaceRuleEntity? = nil
    @State private var showAdd = false

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView("还没有替换规则", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("点右上 + 添加,可用正则去广告 / 替换错别字"))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(rules) { r in
                    Button { editing = r } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.name).foregroundStyle(WanxiangColors.textPrimary)
                                    if !r.isRegex {
                                        Text("纯文本").font(.caption2)
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(WanxiangColors.divider)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text("\(r.pattern) → \(r.replacement.isEmpty ? "(删)" : r.replacement)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(WanxiangColors.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { r.enabled },
                                set: { newVal in
                                    Task {
                                        var copy = r
                                        copy.enabled = newVal
                                        try? await ReplaceRuleRepository.shared.upsert(copy)
                                        await load()
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task {
                                try? await ReplaceRuleRepository.shared.delete(id: r.id)
                                await load()
                            }
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background)
        .navigationTitle("替换净化")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = ReplaceRuleEntity(name: "", pattern: "")
                    showAdd = true
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { r in
            ReplaceRuleEditView(rule: r) { updated in
                Task {
                    try? await ReplaceRuleRepository.shared.upsert(updated)
                    editing = nil
                    await load()
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        rules = (try? await ReplaceRuleRepository.shared.listAll()) ?? []
    }
}

struct ReplaceRuleEditView: View {
    @State var rule: ReplaceRuleEntity
    let onSave: (ReplaceRuleEntity) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("规则名", text: $rule.name)
                }
                Section("匹配") {
                    TextField("模式 (正则或文本)", text: $rule.pattern, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...5)
                    Toggle("使用正则", isOn: $rule.isRegex)
                }
                Section("替换为(空 = 删除)") {
                    TextField("替换字符串", text: $rule.replacement, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1...5)
                }
                Section("作用域(选填,空 = 全局应用)") {
                    TextField("书源 URL 或书 URL,多个用逗号", text: $rule.scope)
                        .font(.system(.caption, design: .monospaced))
                }
                Section {
                    Toggle("启用", isOn: $rule.enabled)
                }
            }
            .navigationTitle(rule.id == 0 ? "新建规则" : "编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard !rule.name.isEmpty, !rule.pattern.isEmpty else { return }
                        onSave(rule)
                    }
                    .fontWeight(.semibold)
                    .disabled(rule.name.isEmpty || rule.pattern.isEmpty)
                }
            }
        }
    }
}

// MARK: - Dict Rule

struct DictRuleListView: View {
    @State private var rules: [DictRuleEntity] = []
    @State private var editing: DictRuleEntity? = nil

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView("没有词典", systemImage: "character.book.closed",
                                       description: Text("点右上 + 添加,可在选词时弹出查词"))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(rules) { r in
                    Button { editing = r } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).foregroundStyle(WanxiangColors.textPrimary)
                            Text(r.urlTemplate)
                                .font(.caption2.monospaced())
                                .foregroundStyle(WanxiangColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                try? await DictRuleRepository.shared.delete(id: r.id)
                                await load()
                            }
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background)
        .navigationTitle("词典规则")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = DictRuleEntity(name: "", urlTemplate: "https://example.com?q={{key}}")
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { r in
            DictRuleEditView(rule: r) { updated in
                Task {
                    try? await DictRuleRepository.shared.upsert(updated)
                    editing = nil
                    await load()
                }
            }
        }
        .task {
            try? await DictRuleRepository.shared.seedDefaultsIfNeeded()
            await load()
        }
    }

    private func load() async {
        rules = (try? await DictRuleRepository.shared.listAll()) ?? []
    }
}

struct DictRuleEditView: View {
    @State var rule: DictRuleEntity
    let onSave: (DictRuleEntity) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("词典名", text: $rule.name) }
                Section("URL 模板") {
                    TextField("https://example.com?q={{key}}", text: $rule.urlTemplate)
                        .font(.system(.body, design: .monospaced))
                    Text("用 {{key}} 占位查询词")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("提取规则(选填,留空则用 WebView 显示)") {
                    TextField("CSS / XPath / @js: 规则", text: Binding(
                        get: { rule.rule ?? "" },
                        set: { rule.rule = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.system(.caption, design: .monospaced))
                }
                Section { Toggle("启用", isOn: $rule.enabled) }
            }
            .navigationTitle(rule.id == 0 ? "新建词典" : "编辑词典")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard !rule.name.isEmpty, !rule.urlTemplate.isEmpty else { return }
                        onSave(rule)
                    }
                    .fontWeight(.semibold)
                    .disabled(rule.name.isEmpty || rule.urlTemplate.isEmpty)
                }
            }
        }
    }
}

// MARK: - TXT Toc Rule

struct TxtTocRuleListView: View {
    @State private var rules: [TxtTocRuleEntity] = []
    @State private var editing: TxtTocRuleEntity? = nil

    var body: some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView("没有规则", systemImage: "list.bullet.rectangle",
                                       description: Text("打开本地 TXT 时用来识别章节"))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(rules) { r in
                    Button { editing = r } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name).foregroundStyle(WanxiangColors.textPrimary)
                            Text(r.pattern)
                                .font(.caption.monospaced())
                                .foregroundStyle(WanxiangColors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task {
                                try? await TxtTocRuleRepository.shared.delete(id: r.id)
                                await load()
                            }
                        } label: { Label("删除", systemImage: "trash") }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(WanxiangColors.background)
        .navigationTitle("TXT 目录规则")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = TxtTocRuleEntity(name: "", pattern: "")
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { r in
            TxtTocEditView(rule: r) { updated in
                Task {
                    try? await TxtTocRuleRepository.shared.upsert(updated)
                    editing = nil
                    await load()
                }
            }
        }
        .task {
            try? await TxtTocRuleRepository.shared.seedDefaultsIfNeeded()
            await load()
        }
    }

    private func load() async {
        rules = (try? await TxtTocRuleRepository.shared.listAll()) ?? []
    }
}

struct TxtTocEditView: View {
    @State var rule: TxtTocRuleEntity
    let onSave: (TxtTocRuleEntity) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") { TextField("规则名", text: $rule.name) }
                Section("正则模式") {
                    TextField(#"^\s*第[一二三0-9]+章"#, text: $rule.pattern)
                        .font(.system(.body, design: .monospaced))
                }
                Section("示例文本(选填,可用来测试)") {
                    TextField("示例", text: Binding(
                        get: { rule.example ?? "" },
                        set: { rule.example = $0.isEmpty ? nil : $0 }
                    ), axis: .vertical)
                    .lineLimit(2...5)
                }
                Section { Toggle("启用", isOn: $rule.enabled) }
            }
            .navigationTitle(rule.id == 0 ? "新建规则" : "编辑规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        guard !rule.name.isEmpty, !rule.pattern.isEmpty else { return }
                        onSave(rule)
                    }
                    .fontWeight(.semibold)
                    .disabled(rule.name.isEmpty || rule.pattern.isEmpty)
                }
            }
        }
    }
}
