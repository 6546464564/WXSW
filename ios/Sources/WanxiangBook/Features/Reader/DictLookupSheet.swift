//
//  DictLookupSheet.swift
//  万象书屋 iOS · 长按选词 → 词典查询 (M2.7.5)
//
//  打开后:
//   1. 拉所有启用的词典 (DictRuleRepository)
//   2. tab 切换不同词典
//   3. 内嵌 InAppBrowserView 显示 URL 渲染结果
//

import SwiftUI

struct DictLookupSheet: View {
    let keyword: String
    @Environment(\.dismiss) private var dismiss

    @State private var dicts: [DictRuleEntity] = []
    @State private var current: DictRuleEntity? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if dicts.count > 1 {
                    Picker("", selection: Binding(
                        get: { current?.id ?? 0 },
                        set: { newId in current = dicts.first { $0.id == newId } }
                    )) {
                        ForEach(dicts) { d in
                            Text(d.name).tag(d.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding()
                }

                if let d = current,
                   let url = URL(string: d.urlTemplate.replacingOccurrences(of: "{{key}}",
                       with: keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword)) {
                    InAppBrowserView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("未配置词典",
                        systemImage: "character.book.closed",
                        description: Text("我的→词典规则 添加"))
                }
            }
            .navigationTitle("查词:「\(keyword)」")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            try? await DictRuleRepository.shared.seedDefaultsIfNeeded()
            dicts = ((try? await DictRuleRepository.shared.listAll()) ?? []).filter { $0.enabled }
            current = dicts.first
        }
    }
}
