//
//  ImportLocalView.swift
//  万象书屋 iOS · 本地导入 (M2.8.1)
//
//  M2.8.1 v1 实现:
//   - TXT 文件 (UTF-8 / GBK / Big5 自动探测)
//   - 用 TxtTocRule 切章, 写进 SQLite
//   - 加入书架 (origin = "local://", originName = "本地")
//
//  待补:
//   - EPUB / MOBI / PDF (M2.8.1.2-4 后续做)
//   - iOS 文件 App "用万象书屋打开" (Info.plist UTI 已在 Document Types 配)
//

import SwiftUI
import UniformTypeIdentifiers

struct ImportLocalView: View {

    @State private var importing = false
    @State private var progress: String? = nil
    @State private var imported: [ShelfBook] = []

    // 万象书屋: 拆出来不然 SwiftUI 编译器 9 个 UTType 一次推不过来
    private static let allowedTypes: [UTType] = {
        var arr: [UTType] = [.plainText, .pdf]
        let exts = ["txt", "epub", "mobi", "azw", "azw3", "umd", "rar", "cbr"]
        for ext in exts {
            if let t = UTType(filenameExtension: ext) { arr.append(t) }
        }
        return arr
    }()

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 64))
                .foregroundStyle(WanxiangColors.primary)
            Text("从本地导入书籍")
                .font(.title3.weight(.semibold))
            Text("支持 TXT / EPUB / PDF / MOBI / UMD (自动识别编码 + 切章)")
                .font(.subheadline)
                .foregroundStyle(WanxiangColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                importing = true
            } label: {
                Label("选择文件", systemImage: "doc.badge.plus")
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(WanxiangColors.primary)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)

            if let p = progress {
                Text(p)
                    .font(.caption)
                    .foregroundStyle(WanxiangColors.textSecondary)
            }

            if !imported.isEmpty {
                List {
                    Section("最近导入(\(imported.count))") {
                        ForEach(imported) { b in
                            VStack(alignment: .leading) {
                                Text(b.name).font(.subheadline)
                                Text("\(b.totalChapterNum) 章 · 来自本地")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 200)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("本地导入")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: false
        ) { result in
            Task { await handleFile(result: result) }
        }
    }

    private func handleFile(result: Result<[URL], Error>) async {
        switch result {
        case .failure(let err):
            progress = "失败:\(err.localizedDescription)"
        case .success(let urls):
            for url in urls {
                let ext = url.pathExtension.lowercased()
                switch ext {
                case "epub":                       await importEpub(at: url)
                case "pdf":                        await importPdf(at: url)
                case "mobi", "azw", "azw3":        await importMobi(at: url)
                case "umd":                        await importUmd(at: url)
                case "rar", "cbr":                 await importRar(at: url)
                default:                           await importTxt(at: url)
                }
            }
        }
    }

    /// 导入 EPUB
    private func importEpub(at url: URL) async {
        progress = "正在导入 \(url.lastPathComponent)..."
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let epub = try EpubImporter.parse(url: url)
            let bookUrl = "local://\(url.lastPathComponent)"
            var book = ShelfBook(
                bookUrl: bookUrl,
                name: epub.title.isEmpty ? url.deletingPathExtension().lastPathComponent : epub.title,
                author: epub.author.isEmpty ? "本地" : epub.author,
                origin: "local://",
                originName: "本地"
            )
            book.totalChapterNum = epub.chapters.count
            try await BookshelfRepository.shared.add(book)

            let chapters = epub.chapters.enumerated().map { (i, c) in
                BookChapter(chapterIndex: i, chapterUrl: nil, title: c.title)
            }
            try await ChapterRepository.shared.saveToc(bookUrl: bookUrl, chapters: chapters)
            for (i, c) in epub.chapters.enumerated() {
                try? await ChapterRepository.shared.saveContent(bookUrl: bookUrl, chapterIndex: i, content: c.content)
            }
            imported.insert(book, at: 0)
            progress = "✓ 已导入 EPUB「\(book.name)」共 \(epub.chapters.count) 章"
        } catch {
            progress = "EPUB 解析失败:\(error.localizedDescription)"
        }
    }

    /// 导入 PDF
    private func importPdf(at url: URL) async {
        progress = "正在导入 \(url.lastPathComponent)..."
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let pdf = try PdfImporter.parse(url: url)
            let bookUrl = "local://\(url.lastPathComponent)"
            var book = ShelfBook(
                bookUrl: bookUrl,
                name: pdf.title.isEmpty ? url.deletingPathExtension().lastPathComponent : pdf.title,
                author: pdf.author,
                origin: "local://",
                originName: "本地"
            )
            book.totalChapterNum = pdf.chapters.count
            try await BookshelfRepository.shared.add(book)

            let chapters = pdf.chapters.enumerated().map { (i, c) in
                BookChapter(chapterIndex: i, chapterUrl: nil, title: c.title)
            }
            try await ChapterRepository.shared.saveToc(bookUrl: bookUrl, chapters: chapters)
            for (i, c) in pdf.chapters.enumerated() {
                try? await ChapterRepository.shared.saveContent(bookUrl: bookUrl, chapterIndex: i, content: c.content)
            }
            imported.insert(book, at: 0)
            progress = "✓ 已导入 PDF「\(book.name)」共 \(pdf.chapters.count) 章/页"
        } catch {
            progress = "PDF 解析失败:\(error.localizedDescription)"
        }
    }

    /// 导入 MOBI / AZW / AZW3
    private func importMobi(at url: URL) async {
        progress = "正在导入 \(url.lastPathComponent)..."
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let mobi = try MobiImporter.parse(url: url)
            let bookUrl = "local://\(url.lastPathComponent)"
            var book = ShelfBook(
                bookUrl: bookUrl,
                name: mobi.title.isEmpty ? url.deletingPathExtension().lastPathComponent : mobi.title,
                author: mobi.author,
                origin: "local://",
                originName: "本地"
            )
            book.totalChapterNum = mobi.chapters.count
            try await BookshelfRepository.shared.add(book)

            let chapters = mobi.chapters.enumerated().map { (i, c) in
                BookChapter(chapterIndex: i, chapterUrl: nil, title: c.title)
            }
            try await ChapterRepository.shared.saveToc(bookUrl: bookUrl, chapters: chapters)
            for (i, c) in mobi.chapters.enumerated() {
                try? await ChapterRepository.shared.saveContent(bookUrl: bookUrl, chapterIndex: i, content: c.content)
            }
            imported.insert(book, at: 0)
            progress = "✓ 已导入 MOBI「\(book.name)」共 \(mobi.chapters.count) 章"
        } catch {
            progress = "MOBI 解析失败:\(error.localizedDescription)"
        }
    }

    /// 导入 UMD
    private func importUmd(at url: URL) async {
        progress = "正在导入 \(url.lastPathComponent)..."
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let umd = try UmdImporter.parse(url: url)
            let bookUrl = "local://\(url.lastPathComponent)"
            var book = ShelfBook(
                bookUrl: bookUrl,
                name: umd.title,
                author: umd.author,
                origin: "local://",
                originName: "本地"
            )
            book.totalChapterNum = umd.chapters.count
            try await BookshelfRepository.shared.add(book)

            let chapters = umd.chapters.enumerated().map { (i, c) in
                BookChapter(chapterIndex: i, chapterUrl: nil, title: c.title)
            }
            try await ChapterRepository.shared.saveToc(bookUrl: bookUrl, chapters: chapters)
            for (i, c) in umd.chapters.enumerated() {
                try? await ChapterRepository.shared.saveContent(bookUrl: bookUrl, chapterIndex: i, content: c.content)
            }
            imported.insert(book, at: 0)
            progress = "✓ 已导入 UMD「\(book.name)」共 \(umd.chapters.count) 章"
        } catch {
            progress = "UMD 解析失败:\(error.localizedDescription)"
        }
    }

    /// 导入 RAR / CBR (引导走文件 App 解压)
    private func importRar(at url: URL) async {
        let result = RarImporter.handle(url: url)
        switch result {
        case .unsupported(let reason):
            progress = reason
        }
    }

    private func importTxt(at url: URL) async {
        progress = "正在导入 \(url.lastPathComponent)..."
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let encoding = LocalImporter.detectEncoding(data: data)
            guard let text = LocalImporter.decode(data: data, encoding: encoding) else {
                progress = "无法解码:\(url.lastPathComponent)"
                return
            }
            let name = url.deletingPathExtension().lastPathComponent
            let bookUrl = "local://\(url.lastPathComponent)"

            // 用启用的 TxtTocRule 切章
            let rules = (try? await TxtTocRuleRepository.shared.listAll().filter { $0.enabled }) ?? []
            let chapters = LocalImporter.splitChapters(text: text, rules: rules)

            // 写书架
            var book = ShelfBook(
                bookUrl: bookUrl,
                name: name,
                author: "本地",
                origin: "local://",
                originName: "本地"
            )
            book.totalChapterNum = chapters.count
            try await BookshelfRepository.shared.add(book)

            // 写章节
            try await ChapterRepository.shared.saveToc(bookUrl: bookUrl, chapters: chapters)
            // 把每章正文也写进 cache (TXT 一次切完, 不依赖网络)
            for c in chapters {
                if let body = LocalImporter.bodyFor(chapter: c, in: text, allChapters: chapters) {
                    try? await ChapterRepository.shared.saveContent(
                        bookUrl: bookUrl, chapterIndex: c.chapterIndex, content: body)
                }
            }

            imported.insert(book, at: 0)
            progress = "✓ 已导入「\(name)」共 \(chapters.count) 章"
        } catch {
            progress = "失败:\(error.localizedDescription)"
        }
    }
}

// MARK: - 本地 TXT 导入器 (静态工具)

enum LocalImporter {

    /// 编码探测 (跟 HTTPFetcher.detectEncoding 同款顺序)
    static func detectEncoding(data: Data) -> String.Encoding {
        // 1. BOM
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return .utf8
        }
        if data.count >= 2 {
            if data[0] == 0xFF, data[1] == 0xFE { return .utf16LittleEndian }
            if data[0] == 0xFE, data[1] == 0xFF { return .utf16BigEndian }
        }
        // 2. 试 UTF-8
        if String(data: data.prefix(4096), encoding: .utf8) != nil {
            return .utf8
        }
        // 3. fallback GBK
        let cfEnc = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEnc))
    }

    static func decode(data: Data, encoding: String.Encoding) -> String? {
        if let s = String(data: data, encoding: encoding) { return s }
        // 万象书屋: GBK 失败再试 UTF-8 lossy
        return String(decoding: data, as: UTF8.self)
    }

    /// 用规则切章. 没规则匹配时, 把整本书当一章
    static func splitChapters(text: String, rules: [TxtTocRuleEntity]) -> [BookChapter] {
        if rules.isEmpty {
            return [BookChapter(chapterIndex: 0, chapterUrl: nil, title: "全文")]
        }
        // 把所有规则合成一个大 OR 正则
        let combined = rules.compactMap { $0.pattern }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: "(?m)\(combined)", options: []) else {
            return [BookChapter(chapterIndex: 0, chapterUrl: nil, title: "全文")]
        }
        let nsstr = text as NSString
        let matches = regex.matches(in: text, range: NSRange(0..<nsstr.length))
        if matches.isEmpty {
            return [BookChapter(chapterIndex: 0, chapterUrl: nil, title: "全文")]
        }
        var out: [BookChapter] = []
        for (i, m) in matches.enumerated() {
            let lineEnd = (text as NSString).range(of: "\n", range: NSRange(m.range.location..<nsstr.length))
            let titleEnd = lineEnd.location == NSNotFound ? nsstr.length : lineEnd.location
            let title = nsstr.substring(with: NSRange(m.range.location..<titleEnd))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(BookChapter(
                chapterIndex: i,
                chapterUrl: "offset://\(m.range.location)",
                title: title
            ))
        }
        return out
    }

    /// 取某一章的正文 (从 chapter.chapterUrl 解析 offset, 切到下一章 offset)
    static func bodyFor(chapter: BookChapter, in text: String, allChapters: [BookChapter]) -> String? {
        guard let urlStr = chapter.chapterUrl, urlStr.hasPrefix("offset://"),
              let start = Int(urlStr.dropFirst("offset://".count)) else {
            return text
        }
        let nsstr = text as NSString
        var end = nsstr.length
        if chapter.chapterIndex + 1 < allChapters.count,
           let nextUrl = allChapters[chapter.chapterIndex + 1].chapterUrl,
           nextUrl.hasPrefix("offset://"),
           let nextStart = Int(nextUrl.dropFirst("offset://".count)) {
            end = nextStart
        }
        guard start < end, end <= nsstr.length else { return nil }
        return nsstr.substring(with: NSRange(start..<end))
    }
}
