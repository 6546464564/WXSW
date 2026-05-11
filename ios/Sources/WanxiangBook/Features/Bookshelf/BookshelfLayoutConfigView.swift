//
//  BookshelfLayoutConfigView.swift
//  万象书屋 iOS · 书架布局配置 sheet
//
//  对应 Android: io.legado.app.ui.main.bookshelf.BaseBookshelfFragment.configBookshelf
//  (DialogBookshelfConfigBinding 内嵌 spinner + RadioGroup + Switch)
//
//  字段对齐:
//   - rgLayout      → bookshelfStyle  (列表 / 网格)  + cols (3/4/5)
//   - rgSort        → bookshelfSort   (6 种, 跟 ShelfSort.allCases 对齐)
//   - swShowUnread             → showUnread
//   - swShowLastUpdateTime     → showLastUpdateTime
//   - swShowBookshelfFastScroller → showBookshelfFastScroller
//   - swShowWaitUpBooks        → showWaitUpCount  (我们 iOS 默认 true, 没有可视开关意义,
//                                                   暂不放; 跟 Android `swShowWaitUpBooks` 对应)
//
//  保存方式: 直接写 @AppStorage, 关闭 sheet 后 BookshelfView .onChange 即时刷新.
//

import SwiftUI

struct BookshelfLayoutConfigView: View {

    @Environment(\.dismiss) private var dismiss

    @AppStorage("wanxiang.shelf.style")
    private var styleRaw: Int = 1   // 0 列表, 1 网格 — 默认网格 3 列 (跟 Android bookshelfLayout 含义对齐)
    @AppStorage("wanxiang.shelf.cols")
    private var cols: Int = 3
    @AppStorage("wanxiang.shelf.sort")
    private var sortRaw: Int = ShelfSort.latestRead.rawValue
    @AppStorage("wanxiang.shelf.show_unread")
    private var showUnread: Bool = true
    @AppStorage("wanxiang.shelf.show_last_update")
    private var showLastUpdateTime: Bool = true
    @AppStorage("wanxiang.shelf.show_fast_scroller")
    private var showFastScroller: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                // 万象书屋: 视图样式 — 跟 Android rgLayout (列表 / 3 列 / 4 列 / 5 列) 对齐.
                // iOS 拆成两层: 先选 列表/网格, 网格时再选列数, 比安卓 4 个并排单选清晰.
                Section("视图") {
                    Picker("样式", selection: $styleRaw) {
                        Label("列表", systemImage: "list.bullet").tag(0)
                        Label("网格", systemImage: "square.grid.3x2").tag(1)
                    }
                    .pickerStyle(.segmented)

                    if styleRaw == 1 {
                        Picker("每行列数", selection: $cols) {
                            ForEach(3...5, id: \.self) { n in
                                Text("\(n) 列").tag(n)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                // 万象书屋: 排序 — 6 种, 完全跟 Android bookshelfSort 数字对应.
                Section("排序") {
                    Picker("排序方式", selection: $sortRaw) {
                        ForEach(ShelfSort.allCases, id: \.rawValue) { s in
                            Text(s.displayName).tag(s.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                // 万象书屋: 显示设置 — Android `swShowUnread` / `swShowLastUpdateTime` /
                // `swShowBookshelfFastScroller`. swShowWaitUpBooks 暂不实现 (iOS 没有等待更新计数 UI).
                Section("显示") {
                    Toggle("显示未读章节数", isOn: $showUnread)
                        .tint(WanxiangColors.primary)
                    Toggle("显示最后更新时间", isOn: $showLastUpdateTime)
                        .tint(WanxiangColors.primary)
                    Toggle("启用快速滚动条", isOn: $showFastScroller)
                        .tint(WanxiangColors.primary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(WanxiangColors.background.ignoresSafeArea())
            .navigationTitle("书架布局")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

#Preview {
    BookshelfLayoutConfigView()
}
