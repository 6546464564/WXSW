//
//  BookExporter.swift
//  万象书屋 iOS · 导出 TXT/EPUB (M2.8.x)
//
//  对应 Android: io.legado.app.service.ExportBookService
//
//  - TXT: 把所有已 cache 的章节正文按顺序拼成单一 .txt
//   - EPUB: ZIPFoundation 打包标准 EPUB 3 (mimetype + container.xml + OPF + nav + 章节 xhtml)
//

import Foundation
import ZIPFoundation
import SwiftUI

@MainActor
public final class BookExporter: ObservableObject {

    public static let shared = BookExporter()

    @Published public private(set) var progress: Double = 0
    @Published public private(set) var isExporting: Bool = false

    private init() {}

    // MARK: - TXT

    /// 导出整本 TXT, 返回 file URL (在 tmp 目录)
    /// bug #9 fix: 用 FileHandle 流式写, 不一次性 String concat (千章书会爆内存)
    public func exportTxt(book: ShelfBook, chapters: [BookChapter]) async throws -> URL {
        isExporting = true
        defer { isExporting = false }
        progress = 0

        let safeName = sanitizeFileName(book.name)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(safeName).txt")
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw NSError(domain: "Export", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法打开 TXT 输出文件"])
        }
        defer { try? handle.close() }

        // 头部
        var header = "\(book.name)\n"
        if !book.author.isEmpty { header += "作者: \(book.author)\n" }
        if let intro = book.intro, !intro.isEmpty { header += "简介: \(intro)\n" }
        header += "\n" + String(repeating: "=", count: 30) + "\n\n"
        try? handle.write(contentsOf: Data(header.utf8))

        // 章节流式写
        for (i, c) in chapters.enumerated() {
            let content = (try? await ChapterRepository.shared.loadContent(
                bookUrl: book.bookUrl, chapterIndex: c.chapterIndex)) ?? ""
            let chunk = "\(c.title)\n\n\(content)\n\n\n"
            try? handle.write(contentsOf: Data(chunk.utf8))
            self.progress = Double(i + 1) / Double(max(chapters.count, 1))
        }
        return url
    }

    // MARK: - EPUB

    /// 导出 EPUB. 标准 EPUB 3 结构, 通过 ZIPFoundation 写包.
    public func exportEpub(book: ShelfBook, chapters: [BookChapter]) async throws -> URL {
        isExporting = true
        defer { isExporting = false }
        progress = 0

        let safeName = sanitizeFileName(book.name)
        let outUrl = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(safeName).epub")
        try? FileManager.default.removeItem(at: outUrl)

        guard let archive = try? Archive(url: outUrl, accessMode: .create) else {
            throw NSError(domain: "Export", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 EPUB 文件"])
        }

        // 1. mimetype 必须第一个写入, 不压缩 (EPUB 标准要求)
        let mimeData = "application/epub+zip".data(using: .utf8)!
        try archive.addEntry(with: "mimetype", type: .file, uncompressedSize: Int64(mimeData.count),
                              compressionMethod: .none) { pos, size in
            mimeData.subdata(in: Int(pos)..<Int(pos) + size)
        }

        // 2. META-INF/container.xml
        let containerXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try addText(to: archive, path: "META-INF/container.xml", content: containerXml)

        // 3. OPF (manifest + spine)
        let opfXml = makeOpf(book: book, chapters: chapters)
        try addText(to: archive, path: "OEBPS/content.opf", content: opfXml)

        // 4. nav.xhtml (EPUB 3 目录)
        let navXml = makeNav(chapters: chapters)
        try addText(to: archive, path: "OEBPS/nav.xhtml", content: navXml)

        // 5. 每章 xhtml
        for (i, c) in chapters.enumerated() {
            let content = (try? await ChapterRepository.shared.loadContent(
                bookUrl: book.bookUrl, chapterIndex: c.chapterIndex)) ?? ""
            let chapXml = makeChapterXhtml(title: c.title, content: content)
            try addText(to: archive, path: "OEBPS/chapter_\(i).xhtml", content: chapXml)
            self.progress = Double(i + 1) / Double(max(chapters.count, 1))
        }

        return outUrl
    }

    // MARK: - 工具

    private func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    private func addText(to archive: Archive, path: String, content: String) throws {
        let data = content.data(using: .utf8)!
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { pos, size in
            data.subdata(in: Int(pos)..<Int(pos) + size)
        }
    }

    private func makeOpf(book: ShelfBook, chapters: [BookChapter]) -> String {
        let manifest = chapters.enumerated().map { i, _ in
            "    <item id=\"chap\(i)\" href=\"chapter_\(i).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spine = chapters.enumerated().map { i, _ in
            "    <itemref idref=\"chap\(i)\"/>"
        }.joined(separator: "\n")
        let bookId = "wanxiang-\(abs(book.bookUrl.hashValue))"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(escapeXml(book.name))</dc:title>
            <dc:creator>\(escapeXml(book.author))</dc:creator>
            <dc:identifier id="bookid">\(bookId)</dc:identifier>
            <dc:language>zh-CN</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        \(manifest)
          </manifest>
          <spine>
        \(spine)
          </spine>
        </package>
        """
    }

    private func makeNav(chapters: [BookChapter]) -> String {
        let lis = chapters.enumerated().map { i, c in
            "    <li><a href=\"chapter_\(i).xhtml\">\(escapeXml(c.title))</a></li>"
        }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>目录</title></head>
        <body>
          <nav epub:type="toc" id="toc"><h1>目录</h1><ol>
        \(lis)
          </ol></nav>
        </body>
        </html>
        """
    }

    private func makeChapterXhtml(title: String, content: String) -> String {
        let paras = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { "<p>\(escapeXml($0))</p>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(escapeXml(title))</title>
          <style>body{font-family:serif;line-height:1.6;} h1{text-align:center;}</style>
        </head>
        <body>
          <h1>\(escapeXml(title))</h1>
        \(paras)
        </body>
        </html>
        """
    }

    private func escapeXml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
