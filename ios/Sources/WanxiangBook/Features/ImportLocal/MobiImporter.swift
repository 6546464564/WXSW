//
//  MobiImporter.swift
//  万象书屋 iOS · MOBI/AZW 文件解析 (M2.8.1.3)
//
//  MOBI 格式:
//   - PDB 容器 (Palm DataBase) 包 PalmDoc 压缩流
//   - 78 字节 PDB header → records 表 → 第 0 条是 MOBI header
//   - 文本压缩格式: PalmDoc (LZ77 变体, type=2) 或不压缩 (type=1)
//   - HTML 内容里 <mbp:pagebreak> 是章节分隔符
//
//  AZW = MOBI + DRM (我们只解未加密的, AZW3 后续考虑)
//
//  实现策略:
//   1. 读 PDB records
//   2. record 0 拿 textLength + recordCount + compression
//   3. records 1..N 解压拼成完整 HTML
//   4. SwiftSoup 解析 → 用 <mbp:pagebreak> / <h1-3> 切章
//
//  参考: https://wiki.mobileread.com/wiki/MOBI
//

import Foundation
import SwiftSoup

enum MobiImporter {

    struct MobiBook {
        let title: String
        let author: String
        let chapters: [(title: String, content: String)]
    }

    static func parse(url: URL) throws -> MobiBook {
        let data = try Data(contentsOf: url)
        guard data.count >= 78 else {
            throw NSError(domain: "MOBI", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件太小"])
        }

        // 1. PDB header (78 bytes)
        let pdbName = String(data: data[0..<32], encoding: .ascii)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) ?? "MOBI"
        let recordCount = Int(UInt16(bigEndian: data[76..<78].withUnsafeBytes { $0.load(as: UInt16.self) }))
        guard recordCount > 0 else {
            throw NSError(domain: "MOBI", code: 2, userInfo: [NSLocalizedDescriptionKey: "无 records"])
        }

        // 2. Records 表 (8 bytes per record, starting at offset 78)
        var recordOffsets: [Int] = []
        for i in 0..<recordCount {
            let off = 78 + i * 8
            guard off + 4 <= data.count else { break }
            let recordOffset = Int(UInt32(bigEndian: data[off..<(off+4)].withUnsafeBytes { $0.load(as: UInt32.self) }))
            recordOffsets.append(recordOffset)
        }
        recordOffsets.append(data.count)  // sentinel for last record end

        // 3. record 0 = PalmDoc + MOBI header
        guard recordOffsets.count >= 2 else {
            throw NSError(domain: "MOBI", code: 3, userInfo: [NSLocalizedDescriptionKey: "无 record 0"])
        }
        let rec0 = data[recordOffsets[0]..<recordOffsets[1]]
        // PalmDoc header (16 bytes)
        let compression = Int(UInt16(bigEndian: rec0[0..<2].withUnsafeBytes { $0.load(as: UInt16.self) }))
        let textRecordCount = Int(UInt16(bigEndian: rec0[8..<10].withUnsafeBytes { $0.load(as: UInt16.self) }))

        // MOBI header at offset 16
        var bookTitle = pdbName
        var bookAuthor = "本地"
        if rec0.count >= 24, let ident = String(data: rec0[16..<20], encoding: .ascii), ident == "MOBI" {
            // 万象书屋: Title 在 EXTH 后面, fullNameOffset 在 MOBI header 偏移 84 (即 rec0[16+84..])
            if rec0.count >= 16 + 92 {
                let fnOff = Int(UInt32(bigEndian: rec0[(16+84)..<(16+88)].withUnsafeBytes { $0.load(as: UInt32.self) }))
                let fnLen = Int(UInt32(bigEndian: rec0[(16+88)..<(16+92)].withUnsafeBytes { $0.load(as: UInt32.self) }))
                let fnAbs = recordOffsets[0] + fnOff
                if fnAbs + fnLen <= data.count, fnLen > 0, fnLen < 256 {
                    bookTitle = String(data: data[fnAbs..<(fnAbs + fnLen)], encoding: .utf8) ?? pdbName
                }
            }
            // 作者从 EXTH (MOBI header 偏移 +16) 暂略, 用 PDB name fallback
        }

        // 4. 解压 text records (1..textRecordCount)
        var rawHtml = Data()
        for i in 1...min(textRecordCount, recordOffsets.count - 2) {
            let segment = data[recordOffsets[i]..<recordOffsets[i + 1]]
            switch compression {
            case 1:    // 不压缩
                rawHtml.append(segment)
            case 2:    // PalmDoc LZ77
                rawHtml.append(decompressPalmDoc(Data(segment)))
            case 17480: // HUFF/CDIC, 太复杂, 跳过
                continue
            default:
                rawHtml.append(segment)
            }
        }

        let html = String(data: rawHtml, encoding: .utf8)
            ?? String(decoding: rawHtml, as: UTF8.self)

        // 5. 用 SwiftSoup 切章
        let chapters = splitChapters(html: html)

        return MobiBook(
            title: bookTitle,
            author: bookAuthor,
            chapters: chapters.isEmpty ? [(bookTitle, html)] : chapters
        )
    }

    // MARK: - PalmDoc LZ77 解压

    private static func decompressPalmDoc(_ data: Data) -> Data {
        var out = Data()
        var i = 0
        while i < data.count {
            let byte = data[i]
            i += 1
            switch byte {
            case 0:                 // 0x00 → 字面 NULL
                out.append(0)
            case 1...8:             // 1..8 → 后面 N 字节字面
                let count = Int(byte)
                let end = min(i + count, data.count)
                out.append(data[i..<end])
                i = end
            case 9...0x7F:          // 9..0x7F → ASCII 字面
                out.append(byte)
            case 0x80...0xBF:       // 0x80..0xBF → LZ77 反向引用 (2 bytes total)
                guard i < data.count else { break }
                let next = data[i]; i += 1
                let pair = (UInt16(byte) << 8) | UInt16(next)
                let length = Int(pair & 0x0007) + 3
                let distance = Int((pair >> 3) & 0x07FF)
                let start = out.count - distance
                if start >= 0 {
                    for k in 0..<length {
                        out.append(out[start + k])
                    }
                }
            case 0xC0...0xFF:       // 0xC0..0xFF → 空格 + (byte ^ 0x80) 字符
                out.append(0x20)
                out.append(byte ^ 0x80)
            default:
                break
            }
        }
        return out
    }

    private static func splitChapters(html: String) -> [(String, String)] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        // mbp:pagebreak 是 MOBI 章节分隔
        let body = (try? doc.body()?.html()) ?? html
        let parts = body.components(separatedBy: "<mbp:pagebreak")
        if parts.count < 2 {
            // fallback: 用 h1/h2/h3 切
            return splitByHeading(html: body)
        }
        var out: [(String, String)] = []
        for (i, part) in parts.enumerated() {
            let cleaned = stripHtml(part)
            if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            // 第一行当章名
            let firstLine = cleaned.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "第 \(i + 1) 章"
            let title = firstLine.count <= 40 ? firstLine : "第 \(i + 1) 章"
            out.append((title.trimmingCharacters(in: .whitespacesAndNewlines), cleaned))
        }
        return out
    }

    private static func splitByHeading(html: String) -> [(String, String)] {
        guard let doc = try? SwiftSoup.parse(html) else { return [] }
        var out: [(String, String)] = []
        var currentTitle = "正文"
        var currentBuf = ""
        for child in (try? doc.body()?.children().array()) ?? [] {
            let tag = child.tagName().lowercased()
            if ["h1", "h2", "h3"].contains(tag) {
                let t = (try? child.text()) ?? ""
                if !currentBuf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append((currentTitle, currentBuf))
                }
                currentTitle = t
                currentBuf = ""
            } else {
                currentBuf += ((try? child.text()) ?? "") + "\n\n"
            }
        }
        if !currentBuf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append((currentTitle, currentBuf))
        }
        return out.isEmpty ? [(currentTitle, currentBuf)] : out
    }

    private static func stripHtml(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: #"</?p[^>]*>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&#39;", with: "'")
        out = out.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
