//
//  GroupManageView.swift
//  万象书屋 iOS · 分组管理 sheet
//
//  对应 Android: io.legado.app.ui.book.group.GroupManageDialog
//
//  功能 (与 Android 1:1 对齐):
//   - 列出所有用户自定义分组 (id > 0)
//   - 新建分组 (输入名字)
//   - 重命名分组 (点行打开 alert)
//   - 删除分组 (滑动 / contextMenu, 删除时书自动归入"未分组")
//
//  系统分组 (-1 全部 / 0 未分组) 不可编辑.
//

import SwiftUI

struct GroupManageView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var groups: [BookGroup] = []
    @State private var newGroupName = ""
    @State private var showCreate = false

    /// 重命名时承载当前选中分组
    @State private var renamingGroup: BookGroup?
    @State private var renameInput: String = ""

    /// 删除二次确认
    @State private var deleteConfirm: BookGroup?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if userGroups.isEmpty {
                        Text("还没有自定义分组")
                            .font(.subheadline)
                            .foregroundStyle(WanxiangColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(userGroups, id: \.id) { g in
                            Button {
                                renameInput = g.name
                                renamingGroup = g
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(WanxiangColors.primary)
                                    Text(g.name)
                                        .foregroundStyle(WanxiangColors.textPrimary)
                                    Spacer()
                                    Text("\(g.bookCount) 本")
                                        .font(.caption)
                                        .foregroundStyle(WanxiangColors.textSecondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    deleteConfirm = g
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("自定义分组")
                } footer: {
                    Text("点击重命名;左滑删除。删除分组后,该分组下的书将归入「未分组」。")
                        .font(.caption2)
                }
            }
            .scrollContentBackground(.hidden)
            .background(WanxiangColors.background.ignoresSafeArea())
            .navigationTitle("分组管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newGroupName = ""
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .task { await reload() }
            // 新建分组
            .alert("新建分组", isPresented: $showCreate) {
                TextField("分组名", text: $newGroupName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task {
                        _ = try? await BookGroupRepository.shared.create(name: name)
                        await reload()
                    }
                }
            }
            // 重命名 — 跟 Android `GroupEditDialog` 等价
            .alert("重命名分组", isPresented: Binding(
                get: { renamingGroup != nil },
                set: { if !$0 { renamingGroup = nil } }
            )) {
                TextField("分组名", text: $renameInput)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    guard let g = renamingGroup else { return }
                    let name = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, name != g.name else { return }
                    Task {
                        try? await BookGroupRepository.shared.rename(id: g.id, newName: name)
                        await reload()
                    }
                }
            }
            // 删除二次确认
            .confirmationDialog(
                "确认删除「\(deleteConfirm?.name ?? "")」吗?该分组下的书将归入「未分组」。",
                isPresented: Binding(
                    get: { deleteConfirm != nil },
                    set: { if !$0 { deleteConfirm = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let g = deleteConfirm {
                    Button("删除分组", role: .destructive) {
                        Task {
                            try? await BookGroupRepository.shared.delete(id: g.id)
                            await reload()
                        }
                    }
                    Button("取消", role: .cancel) {}
                }
            }
        }
    }

    /// 仅展示用户自定义分组 (id > 0). 系统分组 -1 全部 / 0 未分组不可编辑.
    private var userGroups: [BookGroup] {
        groups.filter { $0.id > 0 }
    }

    private func reload() async {
        groups = (try? await BookGroupRepository.shared.listAll()) ?? []
    }
}

#Preview {
    GroupManageView()
}
