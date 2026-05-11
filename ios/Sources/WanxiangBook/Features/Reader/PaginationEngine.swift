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

        // 万象书屋 (排版): 段首缩进 + 段间距用"修改原始文本 + 空行"表达 (与 SwiftUI Text 渲染一致).
        //   - 每段开头加 indentChars 个 U+3000 全角空格 → 视觉首行缩进
        //   - 段间额外加空行数量 = round(paragraphSpacing / lineHeight) (1-3 行)
        //   - CoreText 分页和 SwiftUI Text 渲染看到同一份字符串, 避免分页错位
        let processedText = applyParagraphLayout(text, config: config)
        let attrString = makeAttributedString(
            chapterTitle: chapterTitle,
            body: processedText,
            config: config
        )
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
            // 容错: paginate 完没切到任何 slice (canvas 太小或全空 text), 把 attrString 整体作 1 页
            return [ReaderPage(id: "\(chapterIndex)-0", chapterIndex: chapterIndex,
                               pageIndex: 0, totalPages: 1, text: attrString.string,
                               chapterTitle: chapterTitle)]
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

    /// 万象书屋 (排版): 章节标题字号倍率 (相对正文). 1.4× = 18pt 正文时标题 ~25pt.
    public static let chapterTitleScale: CGFloat = 1.4
    /// 万象书屋 (排版): 章节标题段后留白 (pt). 让标题跟正文有呼吸距.
    public static let chapterTitleTrailingPadding: CGFloat = 18

    /// 万象书屋 (排版): 按 indentChars / paragraphSpacing 把原始文本转成带"全角空格首行缩进 +
    /// 段间空行"的字符串. CoreText 和 SwiftUI Text 都用这份字符串, 渲染视觉自然一致.
    static func applyParagraphLayout(_ raw: String, config: ReadConfigSnapshot) -> String {
        // 1. 用单 \n 切段; 多个连续 \n 合成一个段间分隔
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let indent = String(repeating: "\u{3000}", count: max(0, config.indentChars))

        // 段间空行数: paragraphSpacing 折成行数 (一行高 = textSize × lineSpacing).
        // paragraphSpacing=12, textSize=18, lineSpacing=1.5 → lineH=27 → blank≈12/27≈0.44 → 1 行
        // paragraphSpacing=24 → blank≈0.89 → 1 行
        // paragraphSpacing=30 → blank≈1.11 → 2 行
        let lineH = config.textSize * max(config.lineSpacing, 1.0)
        let extraBlanks = max(0, Int((config.paragraphSpacing / max(lineH, 1)).rounded()))

        var out: [String] = []
        var prevWasBlank = true   // 首段前不需要插额外空行
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !prevWasBlank {
                    out.append("")
                    for _ in 0..<extraBlanks { out.append("") }
                    prevWasBlank = true
                }
                continue
            }
            // 段首加全角空格 (除非段本身已经以全角空格或英文段落 indentChars 为 0 开头)
            if indent.isEmpty || trimmed.hasPrefix("\u{3000}") {
                out.append(trimmed)
            } else {
                out.append(indent + trimmed)
            }
            prevWasBlank = false
        }
        return out.joined(separator: "\n")
    }

    /// 构造 NSAttributedString — 标题段大字号 + 居中, 正文段普通字号. 都用 ReadConfigSnapshot.
    private static func makeAttributedString(chapterTitle: String, body: String, config: ReadConfigSnapshot) -> NSAttributedString {
        let bodyFont = resolveFont(family: config.fontFamily, size: config.textSize, bold: false)
        let titleSize = (config.textSize * Self.chapterTitleScale).rounded()
        let titleFont = resolveFont(family: config.fontFamily, size: titleSize, bold: true)

        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineSpacing = config.textSize * (config.lineSpacing - 1.0)
        bodyPara.paragraphSpacing = 0
        bodyPara.firstLineHeadIndent = 0
        bodyPara.alignment = .natural
        bodyPara.lineBreakMode = .byCharWrapping

        let titlePara = NSMutableParagraphStyle()
        titlePara.lineSpacing = titleSize * 0.15
        titlePara.paragraphSpacing = Self.chapterTitleTrailingPadding
        titlePara.alignment = .center
        titlePara.lineBreakMode = .byCharWrapping

        let result = NSMutableAttributedString()
        let trimmedTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            result.append(NSAttributedString(string: trimmedTitle, attributes: [
                .font: titleFont,
                .paragraphStyle: titlePara,
                .foregroundColor: UIColor.label,
            ]))
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: bodyFont,
                .paragraphStyle: bodyPara,
            ]))
        }
        result.append(NSAttributedString(string: body, attributes: [
            .font: bodyFont,
            .paragraphStyle: bodyPara,
            .kern: config.letterSpacing,
            .foregroundColor: UIColor.label,
        ]))
        return result
    }

    private static func resolveFont(family: String, size: CGFloat, bold: Bool) -> UIFont {
        if family.isEmpty {
            return bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        }
        let base = UIFont(name: family, size: size) ?? UIFont(descriptor: UIFontDescriptor(name: family, size: size), size: size)
        if !bold { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor
        return UIFont(descriptor: desc, size: size)
    }
}

/// 万象书屋: 不可变快照, 在 PaginationEngine.paginate 调用时复制一份避免线程问题
public struct ReadConfigSnapshot: Hashable, Sendable {
    public let textSize: CGFloat
    public let lineSpacing: CGFloat
    public let paragraphSpacing: CGFloat
    public let letterSpacing: CGFloat
    public let indentChars: Int
    public let fontFamily: String

    @MainActor
    public static func current(from c: ReadConfig = .shared) -> ReadConfigSnapshot {
        ReadConfigSnapshot(
            textSize: c.textSize,
            lineSpacing: c.lineSpacing,
            paragraphSpacing: c.paragraphSpacing,
            letterSpacing: c.letterSpacing,
            indentChars: c.indentChars,
            fontFamily: c.fontFamily
        )
    }
}
