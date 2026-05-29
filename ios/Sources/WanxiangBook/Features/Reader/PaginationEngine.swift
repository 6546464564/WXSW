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
    /// 本页在 attrString (含标题) 中的起始字符位置
    /// 对应 Android ReadBook.durChapterPos — 字体/屏幕变化后重新分页仍能精确还原到同段落
    public let charOffset: Int
    /// 本页包含的字符数
    public let charLength: Int
    /// CoreText 分页用的画布尺寸 (用于渲染时保持一致)
    public let canvasSize: CGSize
    /// CoreText 计算的底部浪费高度 (渲染时通过垂直分散消除)
    public let ctWasteH: CGFloat
    /// CoreText 计算的行数
    public let ctLineCount: Int
    /// 本页是否从段落边界开始 (非续行), 用于渲染时决定是否加 paragraphSpacingBefore
    public let startsNewParagraph: Bool

    /// 最后一章读完后的占位页（显示"作者努力更新中"）
    public var isFinishedPlaceholder: Bool = false

    public var isFirstPage: Bool { pageIndex == 0 }
    public var isLastPage: Bool { pageIndex == totalPages - 1 }

    /// 判断 durChapterPos 是否落在本页 (对应 Android TextPage.containPos)
    public func containsPos(_ pos: Int) -> Bool {
        charLength > 0
            ? (pos >= charOffset && pos < charOffset + charLength)
            : pos >= charOffset
    }
}

public struct PaginationEngine {

    /// 计算一章的分页结果
    /// - Parameters:
    ///   - text: 章节正文 (含段落, 用 \n 或 \n\n 分隔)
    ///   - chapterIndex: 章节序号
    ///   - chapterTitle: 章节标题 (会自动加在第 1 页头)
    ///   - canvasSize: 文字区域可用尺寸 (扣除 padding 后的)
    ///   - config: 阅读偏好
    /// Build the canonical NSAttributedString for a chapter (title + body).
    /// Rendering must use this exact string with page.charOffset to match pagination.
    /// textColor does not affect metrics — safe to differ between pagination and rendering.
    public static func buildChapterAttrString(
        text: String,
        chapterTitle: String,
        config: ReadConfigSnapshot,
        textColor: UIColor = .label
    ) -> NSAttributedString {
        var cleanedText = text
        if !chapterTitle.isEmpty {
            let firstLines = cleanedText.components(separatedBy: "\n")
            if let first = firstLines.first {
                let t = first.trimmingCharacters(in: .whitespaces)
                let looksLikeHeader = t.contains(chapterTitle) ||
                    (t.hasPrefix("第") && t.contains("章") && t.count < 40)
                if looksLikeHeader {
                    cleanedText = firstLines.dropFirst().joined(separator: "\n")
                }
            }
        }
        let processedText = applyParagraphLayout(cleanedText, config: config)
        return makeAttributedString(chapterTitle: chapterTitle, body: processedText, config: config,
                                    textColor: textColor)
    }

    public static func paginate(
        text: String,
        chapterIndex: Int,
        chapterTitle: String,
        canvasSize: CGSize,
        config: ReadConfigSnapshot
    ) -> [ReaderPage] {

        guard canvasSize.width > 50, canvasSize.height > 50 else { return [] }

        let attrString = buildChapterAttrString(text: text, chapterTitle: chapterTitle, config: config)
        let totalLength = attrString.length
        if totalLength == 0 {
            return [ReaderPage(id: "\(chapterIndex)-0", chapterIndex: chapterIndex,
                               pageIndex: 0, totalPages: 1, text: "", chapterTitle: chapterTitle,
                               charOffset: 0, charLength: 0,
                               canvasSize: canvasSize, ctWasteH: 0, ctLineCount: 0,
                               startsNewParagraph: true)]
        }

        // 2. CTFramesetter 反向算页面能装多少字符
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        var slices: [(text: String, charOffset: Int, wasteH: CGFloat, lineCount: Int, startsNewPara: Bool)] = []
        var startIdx: CFIndex = 0
        var safety = 0
        // 长章节能分上千页; 固定 1000 会截断后半段正文 (后面章节更容易触发)
        let maxPages = max(1000, totalLength / 30 + 200)

        // #region agent log
        _dbg63Log("paginate canvasW=\(String(format: "%.1f", canvasSize.width)) canvasH=\(String(format: "%.1f", canvasSize.height)) textSize=\(config.textSize) lineSpacing=\(config.lineSpacing) paraSpacing=\(config.paragraphSpacing) chIdx=\(chapterIndex) totalLen=\(totalLength)")
        // #endregion

        while startIdx < totalLength, safety < maxPages {
            safety += 1
            let path = CGPath(rect: CGRect(origin: .zero, size: canvasSize), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRangeMake(startIdx, 0),
                path,
                nil
            )
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            if visibleRange.length <= 0 {
                if startIdx < totalLength {
                    // CoreText 偶发返回 0 长度 — 用 SuggestFrameSize 推进, 避免逐字 +1 触发 maxPages 截断
                    var fitRange = CFRange()
                    _ = CTFramesetterSuggestFrameSizeWithConstraints(
                        framesetter,
                        CFRangeMake(startIdx, totalLength - startIdx),
                        nil,
                        canvasSize,
                        &fitRange
                    )
                    let advance = max(1, min(fitRange.length > 0 ? fitRange.length : 1, totalLength - startIdx))
                    if fitRange.length > 0 {
                        let fallbackFrame = CTFramesetterCreateFrame(
                            framesetter,
                            CFRangeMake(startIdx, advance),
                            path,
                            nil
                        )
                        let ctLines = CTFrameGetLines(fallbackFrame) as! [CTLine]
                        var wasteH: CGFloat = 0
                        if !ctLines.isEmpty {
                            var origins = [CGPoint](repeating: .zero, count: ctLines.count)
                            CTFrameGetLineOrigins(fallbackFrame, CFRangeMake(0, ctLines.count), &origins)
                            let lastOriginY = origins[ctLines.count - 1].y
                            var lastDesc: CGFloat = 0
                            CTLineGetTypographicBounds(ctLines.last!, nil, &lastDesc, nil)
                            wasteH = max(0, lastOriginY - lastDesc)
                        }
                        let pageRange = NSRange(location: startIdx, length: advance)
                        let pageText = (attrString.string as NSString).substring(with: pageRange)
                        let isNewPara = startIdx == 0 || (attrString.string as NSString).substring(with: NSRange(location: Int(startIdx) - 1, length: 1)) == "\n"
                        slices.append((text: pageText, charOffset: Int(startIdx), wasteH: wasteH, lineCount: ctLines.count, startsNewPara: isNewPara))
                    }
                    startIdx += advance
                    continue
                }
                break
            }

            let ctLines = CTFrameGetLines(frame) as! [CTLine]
            var wasteH: CGFloat = 0
            if !ctLines.isEmpty {
                var origins = [CGPoint](repeating: .zero, count: ctLines.count)
                CTFrameGetLineOrigins(frame, CFRangeMake(0, ctLines.count), &origins)
                let lastOriginY = origins[ctLines.count - 1].y
                var lastDesc: CGFloat = 0
                CTLineGetTypographicBounds(ctLines.last!, nil, &lastDesc, nil)
                wasteH = max(0, lastOriginY - lastDesc)
            }

            // #region agent log
            if safety <= 5 {
                _dbg63Log("page\(safety-1) lines=\(ctLines.count) visLen=\(visibleRange.length) wasteH=\(String(format: "%.1f", wasteH)) canvasH=\(String(format: "%.1f", canvasSize.height))")
            }
            // #endregion

            let pageRange = NSRange(location: visibleRange.location, length: visibleRange.length)
            let pageText = (attrString.string as NSString).substring(with: pageRange)
            let isNewPara = startIdx == 0 || (attrString.string as NSString).substring(with: NSRange(location: Int(startIdx) - 1, length: 1)) == "\n"
            slices.append((text: pageText, charOffset: Int(startIdx), wasteH: wasteH, lineCount: ctLines.count, startsNewPara: isNewPara))
            startIdx += visibleRange.length
        }
        // bug #10 fix: safety 触底是异常, 加日志方便用户上报
        if safety >= maxPages {
            print("[PaginationEngine] WARNING: page limit hit (\(maxPages) pages) at chapter \(chapterIndex), output truncated at char \(startIdx)/\(totalLength)")
        }

        if slices.isEmpty {
            return [ReaderPage(id: "\(chapterIndex)-0", chapterIndex: chapterIndex,
                               pageIndex: 0, totalPages: 1, text: attrString.string,
                               chapterTitle: chapterTitle, charOffset: 0, charLength: totalLength,
                               canvasSize: canvasSize, ctWasteH: 0, ctLineCount: 0,
                               startsNewParagraph: true)]
        }

        let total = slices.count
        return slices.enumerated().map { i, s in
            let nextOffset = i + 1 < total ? slices[i + 1].charOffset : totalLength
            return ReaderPage(
                id: "\(chapterIndex)-\(i)",
                chapterIndex: chapterIndex,
                pageIndex: i,
                totalPages: total,
                text: s.text,
                chapterTitle: chapterTitle,
                charOffset: s.charOffset,
                charLength: nextOffset - s.charOffset,
                canvasSize: canvasSize,
                ctWasteH: s.wasteH,
                ctLineCount: s.lineCount,
                startsNewParagraph: s.startsNewPara
            )
        }
    }

    /// 万象书屋 (排版): 章节标题字号倍率 (相对正文). 1.5× = 18pt 正文时标题 ~27pt.
    public static let chapterTitleScale: CGFloat = 1.5
    /// 万象书屋 (排版): 章节标题段后留白 (pt). 让标题跟正文有呼吸距.
    public static let chapterTitleTrailingPadding: CGFloat = 24

    /// 万象书屋 (排版): 把原始文本转为"全角空格首行缩进 + 段间单个换行"格式.
    /// 段间距由 NSAttributedString.paragraphSpacing 控制, 不插入空行以避免双倍视觉间距.
    static func applyParagraphLayout(_ raw: String, config: ReadConfigSnapshot) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let indent = String(repeating: "\u{3000}", count: max(0, config.indentChars))

        var out: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if indent.isEmpty || trimmed.hasPrefix("\u{3000}") {
                out.append(trimmed)
            } else {
                out.append(indent + trimmed)
            }
        }
        return out.joined(separator: "\n")
    }

    /// 构造 NSAttributedString — 标题段大字号 + 居中, 正文段普通字号. 都用 ReadConfigSnapshot.
    static func makeAttributedString(chapterTitle: String, body: String, config: ReadConfigSnapshot,
                                     textColor: UIColor = .label) -> NSAttributedString {
        let bodyFont = resolveFont(family: config.fontFamily, size: config.textSize, bold: false)
        let titleSize = (config.textSize * Self.chapterTitleScale).rounded()
        let titleFont = resolveFont(family: config.fontFamily, size: titleSize, bold: true)

        let bodyPara = NSMutableParagraphStyle()
        bodyPara.lineSpacing = config.textSize * (config.lineSpacing - 1.0)
        bodyPara.paragraphSpacing = 0
        bodyPara.paragraphSpacingBefore = config.paragraphSpacing
        bodyPara.firstLineHeadIndent = 0
        bodyPara.alignment = .natural
        bodyPara.lineBreakMode = .byCharWrapping

        let titlePara = NSMutableParagraphStyle()
        titlePara.lineSpacing = titleSize * 0.15
        titlePara.paragraphSpacing = Self.chapterTitleTrailingPadding
        titlePara.alignment = .left
        titlePara.lineBreakMode = .byCharWrapping

        let result = NSMutableAttributedString()
        let trimmedTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            // "\n" 内嵌在 titlePara 中, 不再额外添加 bodyFont "\n".
            // 这样 CoreText 分配的标题块高度 = titleLineHeight + titlePara.paragraphSpacing
            // 与 ChapterPageBody.chapterTitleHeader 的 SwiftUI 渲染高度一致, 消除空白累积.
            result.append(NSAttributedString(string: trimmedTitle + "\n", attributes: [
                .font: titleFont,
                .paragraphStyle: titlePara,
                .foregroundColor: textColor,
            ]))
        }
        result.append(NSAttributedString(string: body, attributes: [
            .font: bodyFont,
            .paragraphStyle: bodyPara,
            .kern: config.letterSpacing,
            .foregroundColor: textColor,
        ]))
        return result
    }

    private static func resolveFont(family: String, size: CGFloat, bold: Bool) -> UIFont {
        ReadConfig.resolveUIFont(family: family, size: size, bold: bold)
    }
}

// #region agent log
func _b08f71Log(_ msg: String, hyp: String = "") {
    let logPath = "/Users/stark/Desktop/WXSW/.cursor/debug-b08f71.log"
    let ts = Int(Date().timeIntervalSince1970 * 1000)
    let json = "{\"sessionId\":\"b08f71\",\"timestamp\":\(ts),\"hypothesisId\":\"\(hyp)\",\"message\":\"\(msg.replacingOccurrences(of: "\"", with: "'"))\"}\n"
    if let d = json.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath) {
            if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) { fh.seekToEndOfFile(); fh.write(d); fh.closeFile() }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: d)
        }
    }
}
// #endregion

// #region agent log
// 万象书屋 (2026-05-25): 仅 DEBUG 构建写日志; RELEASE 空函数让分页热路径零开销.
// 之前 .first! 强制解包 + 每次分页写文件, 在 sandbox 异常时会崩在分页路径里,
// 比 RELEASE 构建直接不写盘要安全.
func _dbg63Log(_ msg: String) {
    #if DEBUG
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let path = docs.appendingPathComponent("debug-63be44.log")
    let line = "\(msg)\n"
    guard let d = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: path.path) {
        if let fh = try? FileHandle(forWritingTo: path) {
            fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
        }
    } else {
        try? d.write(to: path)
    }
    #endif
}
// #endregion

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
