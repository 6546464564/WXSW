//
//  PaginationEngine.swift
//  万象书屋 iOS · 分页算法 (M2.5.2, ⭐⭐⭐⭐⭐ 工程难点 #1)
//
//  对应 Android: io.legado.app.ui.book.read.page.entities.{TextChapter, TextPage}
//
//  原理: SwiftUI 没有等价 Android `StaticLayout` 的 API.
//   用 CoreText `CTFramesetter` 做精确分页:
//   1. 给 (text, font, paraStyle) 建一个 CTFramesetter
//   2. 用 `CTFramesetterSuggestFrameSizeWithConstraints` 反向算页面能装多少字符
//   3. 切片 → 下一页继续
//
//  当前实现 (M2.5.2 v1):
//   - 单 chapter 一次性分页 (不流式)
//   - 不做 hyphenation / 字号自适应
//   - 段落空行用 paragraphSpacing
//   - 首行缩进用 paragraphStyle.firstLineHeadIndent
//   - 不做横屏双页 (留 M2.5.2.4)
//
//  待补 (M2.5.2.x):
//   - 两端对齐 + 中文标点压缩 (CTLineGetTypographicBounds + 自定义)
//   - E-ink 模式 (灰阶 + 高对比)
//

import Foundation
import CoreText
import UIKit

/// 一页的内容 (字符串切片)
public struct ReaderPage: Identifiable, Hashable, Sendable {
    public let id: String  // chapterIndex-pageIndex
    public let chapterIndex: Int
    public let pageIndex: Int
    public let totalPages: Int
    public let text: String
    public let chapterTitle: String

    public var isFirstPage: Bool { pageIndex == 0 }
    public var isLastPage: Bool { pageIndex == totalPages - 1 }
}

public struct PaginationEngine {

    /// 计算一章的分页结果
    /// - Parameters:
    ///   - text: 章节正文 (含段落, 用 \n 或 \n\n 分隔)
    ///   - chapterIndex: 章节序号
    ///   - chapterTitle: 章节标题 (会自动加在第 1 页头)
    ///   - canvasSize: 文字区域可用尺寸 (扣除 padding 后的)
    ///   - config: 阅读偏好
    public static func paginate(
        text: String,
        chapterIndex: Int,
        chapterTitle: String,
        canvasSize: CGSize,
        config: ReadConfigSnapshot
    ) -> [ReaderPage] {

        guard canvasSize.width > 50, canvasSize.height > 50 else { return [] }

        // 1. 拼正文 (标题作为单独段落, 字号大一档, 居中通过自加换行实现简化版)
        let body = "\(chapterTitle)\n\n\(text)"
        let attrString = makeAttributedString(body: body, config: config)
        let totalLength = attrString.length
        if totalLength == 0 {
            return [ReaderPage(id: "\(chapterIndex)-0", chapterIndex: chapterIndex,
                               pageIndex: 0, totalPages: 1, text: "", chapterTitle: chapterTitle)]
        }

        // 2. CTFramesetter 反向算页面能装多少字符
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        var slices: [String] = []
        var startIdx: CFIndex = 0
        var safety = 0  // 防御性死循环计数

        while startIdx < totalLength, safety < 1000 {
            safety += 1
            let path = CGPath(rect: CGRect(origin: .zero, size: canvasSize), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRangeMake(startIdx, 0),
                path,
                nil
            )
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            // bug #10 fix: visibleRange.length == 0 时也步进 1 char, 避免空转 (canvas 太窄一行装不下 1 字符的极端 case)
            if visibleRange.length <= 0 {
                if startIdx < totalLength {
                    startIdx += 1
                    continue
                }
                break
            }
            let pageRange = NSRange(location: visibleRange.location, length: visibleRange.length)
            let pageText = (attrString.string as NSString).substring(with: pageRange)
            slices.append(pageText)
            startIdx += visibleRange.length
        }
        // bug #10 fix: safety 触底是异常, 加日志方便用户上报
        if safety >= 1000 {
            print("[PaginationEngine] WARNING: safety limit hit (>1000 pages) at chapter \(chapterIndex), output truncated")
        }

        if slices.isEmpty {
            return [ReaderPage(id: "\(chapterIndex)-0", chapterIndex: chapterIndex,
                               pageIndex: 0, totalPages: 1, text: body, chapterTitle: chapterTitle)]
        }

        let total = slices.count
        return slices.enumerated().map { i, s in
            ReaderPage(
                id: "\(chapterIndex)-\(i)",
                chapterIndex: chapterIndex,
                pageIndex: i,
                totalPages: total,
                text: s,
                chapterTitle: chapterTitle
            )
        }
    }

    /// 构造 NSAttributedString (字号 + 行距 + 段距 + 字距 + 缩进)
    private static func makeAttributedString(body: String, config: ReadConfigSnapshot) -> NSAttributedString {
        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineSpacing = config.textSize * (config.lineSpacing - 1.0)
        // 万象书屋: 分页算法必须和 ReaderPageView 实际 SwiftUI Text 渲染一致。
        // SwiftUI Text 当前只用了 `.lineSpacing` / `.kerning`, 没有逐段 paragraphSpacing /
        // firstLineHeadIndent。之前 CoreText 在分页时额外计算了段距和缩进,
        // 导致每页可见字符偏少, 用户看到每页底部一大片空白。
        // 先置 0 对齐实际渲染; 后续若改成 AttributedString 渲染, 再恢复这两项。
        paraStyle.paragraphSpacing = 0
        paraStyle.firstLineHeadIndent = 0
        paraStyle.alignment = .natural
        paraStyle.lineBreakMode = .byCharWrapping

        let font = UIFont.systemFont(ofSize: config.textSize)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paraStyle,
            .kern: config.letterSpacing,
            .foregroundColor: UIColor.label,  // 先用 system label, 渲染时按主题覆盖
        ]
        return NSAttributedString(string: body, attributes: attrs)
    }
}

/// 万象书屋: 不可变快照, 在 PaginationEngine.paginate 调用时复制一份避免线程问题
public struct ReadConfigSnapshot: Hashable, Sendable {
    public let textSize: CGFloat
    public let lineSpacing: CGFloat
    public let paragraphSpacing: CGFloat
    public let letterSpacing: CGFloat
    public let indentChars: Int

    @MainActor
    public static func current(from c: ReadConfig = .shared) -> ReadConfigSnapshot {
        ReadConfigSnapshot(
            textSize: c.textSize,
            lineSpacing: c.lineSpacing,
            paragraphSpacing: c.paragraphSpacing,
            letterSpacing: c.letterSpacing,
            indentChars: c.indentChars
        )
    }
}
