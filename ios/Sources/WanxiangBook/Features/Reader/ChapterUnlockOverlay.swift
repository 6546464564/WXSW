//
//  ChapterUnlockOverlay.swift
//  万象书屋 iOS · 章节付费墙 + 顶部倒计时条 + 读完页 (M2.5.8)
//
//  对应 Android: ad/ + ReadBookActivity 内嵌 chapter_unlock_view + book_finished_view
//  ⚠️ 这套在 iOS 可能违反 3.1.1 In-App Purchase, M5 申诉时强调"激励留存"
//

import SwiftUI

// MARK: - 顶部纯净阅读倒计时条 (M2.5.8.3)

struct PurifiedTopBar: View {
    @StateObject private var state = PurifiedReadingState.shared

    var body: some View {
        if state.isActive {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                Text("纯净阅读 \(state.formattedRemaining)")
                    .font(.caption2.monospacedDigit())
                Spacer()
                Button("延长") {
                    Task { _ = await AdManager.shared.showRewardedToUnlock(minutes: 30) }
                }
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.white.opacity(0.25))
                .clipShape(Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(WanxiangColors.primary.opacity(0.85))
        }
    }
}

// MARK: - 章节付费墙 (M2.5.8.2)

struct ChapterUnlockOverlay: View {
    let chapterIndex: Int
    let onUnlock: () -> Void
    let onSkip: () -> Void
    let onAddToShelf: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(WanxiangColors.primary)
            Text("第 \(chapterIndex + 1) 章 · 解锁阅读")
                .font(.title3.weight(.semibold))
            Text("看一段 30 秒广告即可解锁\n后续 30 分钟纯净阅读不弹此墙")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 8) {
                Button {
                    Task {
                        let ok = await AdManager.shared.showRewardedToUnlock()
                        if ok { onUnlock() }
                    }
                } label: {
                    Label("看广告解锁", systemImage: "play.rectangle.fill")
                        .frame(maxWidth: 280)
                        .padding(.vertical, 12)
                        .background(WanxiangColors.primary)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                Button("加入书架") { onAddToShelf() }
                    .font(.subheadline)
                    .foregroundStyle(WanxiangColors.primary)
                Button("先跳过") { onSkip() }
                    .font(.caption)
                    .foregroundStyle(WanxiangColors.textSecondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WanxiangColors.background)
    }
}

// MARK: - 读完页 (M2.5.8.6)

struct BookFinishedView: View {
    let bookName: String
    let onGoBookshelf: () -> Void
    let onGoBookStore: () -> Void
    let onChangeSource: () -> Void
    let onWatchAdToContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 56))
                .foregroundStyle(WanxiangColors.primary)
            Text("作者努力更新中")
                .font(.title2.weight(.semibold))
            Text("「\(bookName)」最新章节已读完")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textSecondary)

            VStack(spacing: 10) {
                Button(action: onGoBookshelf) {
                    Label("去书架", systemImage: "books.vertical")
                        .frame(maxWidth: 280).padding(.vertical, 10)
                        .background(WanxiangColors.primary)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                Button(action: onGoBookStore) {
                    Label("去书城", systemImage: "storefront")
                        .frame(maxWidth: 280).padding(.vertical, 10)
                        .background(WanxiangColors.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                Button(action: onChangeSource) {
                    Label("看看其它源", systemImage: "arrow.triangle.swap")
                        .frame(maxWidth: 280).padding(.vertical, 10)
                        .background(WanxiangColors.divider)
                        .foregroundStyle(WanxiangColors.textPrimary)
                        .clipShape(Capsule())
                }
                Button(action: onWatchAdToContinue) {
                    Text("看广告续读 →")
                        .font(.caption)
                        .foregroundStyle(WanxiangColors.primary)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WanxiangColors.background.ignoresSafeArea())
    }
}

// MARK: - 选词菜单包装 (M2.5.6.1)
//
// SwiftUI 的 Text 默认自带 "复制" 长按菜单. 我们用 UIViewRepresentable 包 UITextView
// 注入 7 项 (替换 / 复制 / 书签 / 词典 / 正文搜索 / 浏览器 / 分享)

import UIKit

struct SelectableTextView: UIViewRepresentable {
    let text: String
    let textColor: UIColor
    let font: UIFont
    let onAction: (SelectionAction, String) -> Void

    enum SelectionAction {
        case replace, copyText, bookmark, dict, searchContent, browser, share
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = SelectionTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.dataDetectorTypes = []
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.actionHandler = onAction
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.text = text
        uiView.textColor = textColor
        uiView.font = font
        if let tv = uiView as? SelectionTextView {
            tv.actionHandler = onAction
        }
        // 万象书屋 (P1 fix): 触发 intrinsicContentSize 重算, SwiftUI 才会按真实文本高度布局
        uiView.invalidateIntrinsicContentSize()
    }

    /// 万象书屋 (P1 fix): 给 SwiftUI 提供精确尺寸. 没有这个 SelectableTextView 会被压成 1 行.
    /// iOS 16+ SwiftUI 的 sizeThatFits 协议
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        // 让 UITextView 按宽度自适应高度
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}

private final class SelectionTextView: UITextView {
    var actionHandler: ((SelectableTextView.SelectionAction, String) -> Void)?

    /// 万象书屋 (P1 fix): UITextView 的 intrinsicContentSize 默认基于 contentSize, 但 isScrollEnabled=false
    /// 时需要主动按 textContainer 算
    override var intrinsicContentSize: CGSize {
        let size = sizeThatFits(CGSize(width: bounds.width > 0 ? bounds.width : 320,
                                        height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let custom: [Selector] = [
            #selector(actReplace), #selector(actBookmark), #selector(actDict),
            #selector(actSearchContent), #selector(actBrowser), #selector(actShare)
        ]
        if custom.contains(action) { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        // iOS 16+ 自定义 menu (避免改 UIMenuController, 它在 iOS 17+ deprecated)
        let items: [UIMenuElement] = [
            UIAction(title: "替换") { [weak self] _ in self?.actReplace() },
            UIAction(title: "书签") { [weak self] _ in self?.actBookmark() },
            UIAction(title: "词典") { [weak self] _ in self?.actDict() },
            UIAction(title: "正文搜索") { [weak self] _ in self?.actSearchContent() },
            UIAction(title: "浏览器") { [weak self] _ in self?.actBrowser() },
            UIAction(title: "分享") { [weak self] _ in self?.actShare() },
        ]
        builder.insertSibling(UIMenu(title: "万象书屋", children: items), beforeMenu: .standardEdit)
    }

    private var selectedString: String {
        guard let r = selectedTextRange else { return "" }
        return text(in: r) ?? ""
    }

    @objc func actReplace() { actionHandler?(.replace, selectedString) }
    @objc func actBookmark() { actionHandler?(.bookmark, selectedString) }
    @objc func actDict() { actionHandler?(.dict, selectedString) }
    @objc func actSearchContent() { actionHandler?(.searchContent, selectedString) }
    @objc func actBrowser() { actionHandler?(.browser, selectedString) }
    @objc func actShare() { actionHandler?(.share, selectedString) }
}
