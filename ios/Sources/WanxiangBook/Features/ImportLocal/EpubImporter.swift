//
//  EpubImporter.swift
//  万象书屋 iOS · EPUB 文件解析 (M2.8.1.2)
//
//  EPUB 格式核心:
//   - 本质是 zip 包 → ZIPFoundation 解压
//   - META-INF/container.xml 指向 OPF 文件
//   - OPF 文件 (manifest + spine) 列出所有章节 XHTML
//   - SwiftSoup 解析 XHTML 抽 text
//
//  M2.8.1.2 v1: 简单实现, 把所有 XHTML 按 spine 顺序拼成章节
//  对应 Android: io.legado.app.model.localBook.EpubFile
//

import Foundation
import ZIPFoundation
import SwiftSoup

enum EpubImporter {

    struct EpubBook {
        let title: String
        let author: String
        let chapters: [(title: String, content: String)]
    }

    /// 解析 EPUB 文件
    /// - Parameter url: 本地文件 URL
    /// - Returns: 拆好的章节
    static func parse(url: URL) throws -> EpubBook {
        let fm = FileManager.default
        // 临时解压目录
        let tmp = fm.temporaryDirectory.appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 1. 解压
        try fm.unzipItem(at: url, to: tmp)

        // 2. 读 container.xml 找 OPF
        let containerUrl = tmp.appendingPathComponent("META-INF/container.xml")
        guard fm.fileExists(atPath: containerUrl.path) else {
            throw NSError(domain: "EPUB", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺 META-INF/container.xml"])
        }
        let containerXml = try String(contentsOf: containerUrl, encoding: .utf8)
        let opfPath = try extractOpfPath(from: containerXml)
        let opfUrl = tmp.appendingPathComponent(opfPath)
        let opfDir = opfUrl.deletingLastPathComponent()

        // 3. 解析 OPF 拿 manifest + spine
        let opfXml = try String(contentsOf: opfUrl, encoding: .utf8)
        let (title, author, manifest, spine) = try parseOPF(opfXml)

        // 4. 按 spine 顺序拼章节
        var chapters: [(String, String)] = []
        for itemId in spine {
            guard let href = manifest[itemId] else { continue }
            let chapUrl = opfDir.appendingPathComponent(href)
            guard fm.fileExists(atPath: chapUrl.path),
                  let xhtml = try? String(contentsOf: chapUrl, encoding: .utf8) else { continue }
            let (chTitle, chBody) = extractTextFromXHTML(xhtml, fallbackTitle: itemId)
            if !chBody.isEmpty {
                chapters.append((chTitle, chBody))
            }
        }

        return EpubBook(title: title, author: author, chapters: chapters)
    }

    // MARK: - container.xml

    private static func extractOpfPath(from xml: String) throws -> String {
        // <rootfile full-path="OEBPS/content.opf" .../>
        let pattern = #"<rootfile[^>]*full-path=['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: xml, range: NSRange(0..<(xml as NSString).length)),
              m.numberOfRanges > 1 else {
            throw NSError(domain: "EPUB", code: 2, userInfo: [NSLocalizedDescriptionKey: "container.xml 缺 rootfile"])
        }
        return (xml as NSString).substring(with: m.range(at: 1))
    }

    // MARK: - OPF

    private static func parseOPF(_ xml: String) throws -> (title: String, author: String, manifest: [String: String], spine: [String]) {
        let doc = try SwiftSoup.parse(xml, "")
        let title = (try? doc.select("metadata title").first()?.text()) ?? ""
        let author = (try? doc.select("metadata creator").first()?.text()) ?? ""

        // manifest: id → href
        var manifest: [String: String] = [:]
        for item in (try? doc.select("manifest item").array()) ?? [] {
            let id = (try? item.attr("id")) ?? ""
            let href = (try? item.attr("href")) ?? ""
            if !id.isEmpty, !href.isEmpty {
                manifest[id] = href
            }
        }

        // spine: itemref idref
        var spine: [String] = []
        for ref in (try? doc.select("spine itemref").array()) ?? [] {
            let id = (try? ref.attr("idref")) ?? ""
            if !id.isEmpty { spine.append(id) }
        }

        return (title, author, manifest, spine)
    }

    // MARK: - XHTML 章节文本提取

    private static func extractTextFromXHTML(_ xhtml: String, fallbackTitle: String) -> (title: String, body: String) {
        guard let doc = try? SwiftSoup.parse(xhtml) else {
            return (fallbackTitle, xhtml)
        }
        let title = (try? doc.select("title").first()?.text())
            ?? (try? doc.select("h1, h2, h3").first()?.text())
            ?? fallbackTitle

        // 取 body 文本, 段落用 \n\n 分隔
        var paragraphs: [String] = []
        if let bodyEl = try? doc.select("body").first() {
            for p in (try? bodyEl.select("p, h1, h2, h3, h4, div").array()) ?? [] {
                let text = (try? p.text())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !text.isEmpty { paragraphs.append(text) }
            }
        }
        let body = paragraphs.joined(separator: "\n\n")
        return (title, body)
    }
}
