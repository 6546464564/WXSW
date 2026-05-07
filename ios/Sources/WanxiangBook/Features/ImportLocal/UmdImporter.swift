//
//  UmdImporter.swift
//  万象书屋 iOS · UMD 文件解析 (M2.8.1.5)
//
//  UMD 是早期手机阅读器格式 (北大方正/掌上书院 时代).
//  完整规范见: https://blog.csdn.net/lizhuo_2008/article/details/6263420
//
//  结构:
//   - File header: 4 bytes magic 0x89 9B BE A4
//   - 一系列 chunk, 每个: 1 byte separator 0x23 + 1 byte type + 1 byte 0x1B + 1 byte unknown + 2 bytes length + data
//   - 关键 chunk:
//     0x01 = title
//     0x02 = author
//     0x03 = year
//     0x04 = month
//     0x05 = day
//     0x06 = book type
//     0x07 = publisher
//     0x09 = vendor
//     0x0A = content type (1=text 2=comic 3=audio)
//     0x0B = encoding (中文 1=GBK 2=UTF-16LE)
//     0x0F = chapter offsets
//     0x83 = chapter titles
//     0xE1 = end-of-content marker
//
//  内容是 UTF-16LE 编码 LZSS 压缩, 章节用 offset 切.
//

import Foundation

enum UmdImporter {

    struct UmdBook {
        let title: String
        let author: String
        let chapters: [(title: String, content: String)]
    }

    static func parse(url: URL) throws -> UmdBook {
        let data = try Data(contentsOf: url)
        guard data.count >= 4 else {
            throw NSError(domain: "UMD", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件太小"])
        }
        // Magic
        guard data[0] == 0x89 && data[1] == 0x9B && data[2] == 0xBE && data[3] == 0xA4 else {
            throw NSError(domain: "UMD", code: 2, userInfo: [NSLocalizedDescriptionKey: "不是 UMD 文件 (magic 不匹配)"])
        }

        var title = url.deletingPathExtension().lastPathComponent
        var author = "本地"
        var chapterOffsets: [UInt32] = []
        var chapterTitles: [String] = []
        var contentBlocks: [(blockId: UInt32, payload: Data)] = []
        var contentType: UInt8 = 1
        var encoding: UInt8 = 2  // default UTF-16LE

        var i = 4
        while i < data.count {
            // 万象书屋: chunk 头开头是 0x23
            guard data[i] == 0x23 else { i += 1; continue }
            guard i + 6 <= data.count else { break }
            let type = data[i + 1]
            // i+2 = 0x1B (separator), i+3 = unknown
            let len = Int(UInt16(littleEndian: data[(i+4)..<(i+6)].withUnsafeBytes { $0.load(as: UInt16.self) }))
            // 万象书屋: len 包含 chunk 头 6 字节; payload 是后面 len-6 字节
            let payloadStart = i + 6
            let payloadEnd = i + max(len, 6)
            guard payloadEnd <= data.count else { break }
            let payload = data.subdata(in: payloadStart..<payloadEnd)

            switch type {
            case 0x01:
                title = decodeUtf16Le(payload).trimmingCharacters(in: .whitespacesAndNewlines)
            case 0x02:
                author = decodeUtf16Le(payload).trimmingCharacters(in: .whitespacesAndNewlines)
            case 0x0A:
                if !payload.isEmpty { contentType = payload[0] }
            case 0x0B:
                if !payload.isEmpty { encoding = payload[0] }
            case 0x0F:
                // 4 字节 offset 列表
                var k = 0
                while k + 4 <= payload.count {
                    let off = UInt32(littleEndian: payload[k..<(k+4)].withUnsafeBytes { $0.load(as: UInt32.self) })
                    chapterOffsets.append(off)
                    k += 4
                }
            case 0x83:
                // 章节标题: [1B 长度][UTF-16LE 标题]...
                var k = 0
                while k < payload.count {
                    let tLen = Int(payload[k])
                    k += 1
                    let end = min(k + tLen, payload.count)
                    let titleData = payload.subdata(in: k..<end)
                    chapterTitles.append(decodeUtf16Le(titleData))
                    k = end
                }
            case 0x81:
                // 内容块 ID 表 (4 bytes per id)
                break
            case 0x82:
                // 内容块: [4B blockId][...content (LZSS 或 UTF-16LE 直存)]
                if payload.count >= 4 {
                    let blockId = UInt32(littleEndian: payload[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) })
                    contentBlocks.append((blockId, payload.subdata(in: 4..<payload.count)))
                }
            case 0xF1:
                // checksum, 跳
                break
            case 0x24:  // 0x24 = chunk 后跟单字节
                break
            default:
                break
            }
            i = payloadEnd
        }

        // 简化: 把所有 content block 拼起来当全文 (大部分 UMD 内容直接 UTF-16LE 不压缩)
        var allContent = Data()
        for blk in contentBlocks {
            allContent.append(blk.payload)
        }

        let fullText: String
        switch encoding {
        case 1:
            fullText = String(data: allContent, encoding: .gb_18030_2000) ?? ""
        default:
            fullText = decodeUtf16Le(allContent)
        }

        // 用 chapter offsets 切章节 (offset 是 UTF-16 字符序号 * 2)
        var chapters: [(String, String)] = []
        let utf16 = fullText.unicodeScalars.map { Character($0) }
        if !chapterOffsets.isEmpty && !chapterTitles.isEmpty {
            for (idx, off) in chapterOffsets.enumerated() {
                let charStart = Int(off) / 2
                let charEnd: Int
                if idx + 1 < chapterOffsets.count {
                    charEnd = Int(chapterOffsets[idx + 1]) / 2
                } else {
                    charEnd = utf16.count
                }
                guard charStart < utf16.count else { continue }
                let realEnd = min(charEnd, utf16.count)
                let body = String(utf16[charStart..<realEnd])
                let chTitle = idx < chapterTitles.count ? chapterTitles[idx] : "第 \(idx + 1) 章"
                chapters.append((chTitle, body))
            }
        }
        if chapters.isEmpty {
            chapters = TxtChapterSplitter.split(fullText, fallbackTitle: title)
        }

        _ = contentType  // 1=text 已支持, 2=comic 3=audio 不支持

        return UmdBook(
            title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
            author: author,
            chapters: chapters
        )
    }

    private static func decodeUtf16Le(_ data: Data) -> String {
        return String(data: data, encoding: .utf16LittleEndian) ?? ""
    }
}

// 万象书屋: GB18030 别名 (Swift 没暴露这枚 enum, 用 CFString 转)
extension String.Encoding {
    static var gb_18030_2000: String.Encoding {
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(cf)
        return String.Encoding(rawValue: nsEnc)
    }
}

// 万象书屋: 通用 TXT 章节切分 (UMD/MOBI/TXT 都可用)
enum TxtChapterSplitter {
    static func split(_ text: String, fallbackTitle: String) -> [(String, String)] {
        // 中文章节正则: 第X章/卷/节/回 + 任意标题字符
        let pattern = #"(第[零一二三四五六七八九十百千万0-9]+[章节回卷集部篇][^\n]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [(fallbackTitle, text)]
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else {
            return [(fallbackTitle, text)]
        }
        var out: [(String, String)] = []
        for (idx, m) in matches.enumerated() {
            let titleRange = m.range(at: 1)
            let title = nsText.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let bodyStart = m.range.location + m.range.length
            let bodyEnd = idx + 1 < matches.count ? matches[idx + 1].range.location : nsText.length
            let body = nsText.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append((title, body))
        }
        return out
    }
}
