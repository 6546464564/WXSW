//
//  PdfImporter.swift
//  万象书屋 iOS · PDF 文件解析 (M2.8.1.4)
//
//  PDFKit (系统库) 自带 PDFDocument, 直接抽页文本
//  对应 Android: io.legado.app.model.localBook.PdfFile
//

import Foundation
import PDFKit

enum PdfImporter {

    struct PdfBook {
        let title: String
        let author: String
        let chapters: [(title: String, content: String)]   // 每页一章
    }

    /// PDF 拆章策略:
    ///   - v1: 一页 = 一章 (简单粗暴, 但对小说类 PDF 已经够用)
    ///   - v2 (留): 用 outline (目录) 切章
    static func parse(url: URL) throws -> PdfBook {
        guard let doc = PDFDocument(url: url) else {
            throw NSError(domain: "PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开 PDF"])
        }

        // 元数据
        let attrs = doc.documentAttributes ?? [:]
        let title = (attrs[PDFDocumentAttribute.titleAttribute] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let author = (attrs[PDFDocumentAttribute.authorAttribute] as? String) ?? "本地"

        // 优先 outline 切章
        if let outline = doc.outlineRoot, outline.numberOfChildren > 0 {
            return parseByOutline(doc: doc, outline: outline, title: title, author: author)
        }

        // fallback: 一页一章
        var chapters: [(String, String)] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i),
                  let body = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { continue }
            chapters.append(("第 \(i + 1) 页", body))
        }

        return PdfBook(title: title, author: author, chapters: chapters)
    }

    private static func parseByOutline(doc: PDFDocument, outline: PDFOutline, title: String, author: String) -> PdfBook {
        var chapters: [(String, String)] = []

        // 收集 outline 列表 (扁平化, 多级树取第 1-2 级)
        var outlineItems: [(label: String, pageIdx: Int)] = []
        collectOutline(outline, into: &outlineItems)

        // 按页码切, 范围 = 当前 → 下一个 -1
        for (i, item) in outlineItems.enumerated() {
            let endPage = (i + 1 < outlineItems.count) ? outlineItems[i + 1].pageIdx : doc.pageCount
            var body = ""
            for p in item.pageIdx..<endPage {
                if let page = doc.page(at: p), let s = page.string {
                    body += s + "\n\n"
                }
            }
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                chapters.append((item.label, body))
            }
        }

        return PdfBook(title: title, author: author, chapters: chapters)
    }

    private static func collectOutline(_ node: PDFOutline, into out: inout [(label: String, pageIdx: Int)]) {
        for i in 0..<node.numberOfChildren {
            guard let child = node.child(at: i) else { continue }
            let label = child.label ?? ""
            if let dest = child.destination, let page = dest.page,
               let doc = page.document {
                let idx = doc.index(for: page)
                if !label.isEmpty { out.append((label, idx)) }
            }
            // 递归子级 (但只取一层, 避免太碎)
            // collectOutline(child, into: &out)
        }
    }
}
