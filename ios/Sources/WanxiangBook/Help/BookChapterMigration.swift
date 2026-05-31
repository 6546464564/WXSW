//
//  BookChapterMigration.swift
//  万象书屋 iOS · 换源章节索引映射
//
//  对齐 Android: io.legado.app.help.book.BookHelp.getDurChapter
//  + StringUtils.fullToHalf / stringToInt / chineseNumToInt (节选).
//

import Foundation

/// 换源后把「旧目录进度」映射到新目录章节下标 (Legado 同款启发式).
enum BookChapterMigration {

    /// `BookHelp.getDurChapter(oldDurChapterIndex, oldDurChapterName, newChapterList, oldChapterListSize)`
    static func mappedDurChapterIndex(
        oldDurChapterIndex: Int,
        oldDurChapterTitle: String?,
        newChapters: [BookChapter],
        oldChapterListSize: Int
    ) -> Int {
        if oldDurChapterIndex <= 0 { return 0 }
        if newChapters.isEmpty { return oldDurChapterIndex }

        let oldChapterNum = chapterNum(from: oldDurChapterTitle)
        let oldName = pureChapterName(oldDurChapterTitle)
        let newChapterSize = newChapters.count

        let durIndex: Int = {
            if oldChapterListSize == 0 { return oldDurChapterIndex }
            return oldDurChapterIndex * oldChapterListSize / max(newChapterSize, 1)
        }()

        let minBound = max(0, min(oldDurChapterIndex, durIndex) - 10)
        let maxBound = min(newChapterSize - 1, max(oldDurChapterIndex, durIndex) + 10)

        // 万象书屋 (crash fix): 新目录比旧进度短很多时 minBound > maxBound,
        // `minBound...maxBound` 会 Fatal error: Range requires lowerBound <= upperBound.
        guard minBound <= maxBound else {
            // #region agent log
            DebugSessionLog.log(
                location: "BookChapterMigration.mappedDurChapterIndex",
                message: "illegal range guard",
                hypothesisId: "H3",
                data: [
                    "oldIdx": oldDurChapterIndex,
                    "newSize": newChapterSize,
                    "minBound": minBound,
                    "maxBound": maxBound,
                ]
            )
            // #endregion
            return min(max(0, newChapterSize - 1), oldDurChapterIndex)
        }

        var nameSim = 0.0
        var newIndex = 0
        var newNum = 0

        if !oldName.isEmpty {
            for i in minBound...maxBound {
                let newTitle = newChapters[i].title
                let pureNew = pureChapterName(newTitle)
                let temp = jaccardBigramSimilarity(oldName, pureNew)
                if temp > nameSim {
                    nameSim = temp
                    newIndex = i
                }
            }
        }

        if nameSim < 0.96 && oldChapterNum > 0 {
            var bestDist = Int.max
            for i in minBound...maxBound {
                let temp = chapterNum(from: newChapters[i].title)
                if temp == oldChapterNum {
                    newNum = temp
                    newIndex = i
                    break
                } else if temp >= 0 {
                    let dist = abs(temp - oldChapterNum)
                    if dist < bestDist {
                        bestDist = dist
                        newNum = temp
                        newIndex = i
                    }
                }
            }
        }

        if nameSim > 0.96 || abs(newNum - oldChapterNum) < 1 {
            return newIndex
        }
        return min(max(0, newChapterSize - 1), oldDurChapterIndex)
    }

    // MARK: - Apache commons-text 风格 bigram Jaccard (与 Legado 引用一致)

    private static func bigramCounts(_ s: String) -> [String: Int] {
        var m: [String: Int] = [:]
        let chars = Array(s)
        guard chars.count >= 2 else {
            if chars.count == 1 {
                let k = String(chars[0])
                m[k, default: 0] += 1
            }
            return m
        }
        for i in 0..<(chars.count - 1) {
            let bg = String(chars[i]) + String(chars[i + 1])
            m[bg, default: 0] += 1
        }
        return m
    }

    private static func jaccardBigramSimilarity(_ a: String, _ b: String) -> Double {
        let fa = bigramCounts(a), fb = bigramCounts(b)
        let keys = Set(fa.keys).union(fb.keys)
        if keys.isEmpty { return 0 }
        var inter = 0
        var uni = 0
        for k in keys {
            let ca = fa[k] ?? 0
            let cb = fb[k] ?? 0
            inter += min(ca, cb)
            uni += max(ca, cb)
        }
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }

    // MARK: - fullToHalf (对齐 StringUtils.fullToHalf)

    private static func fullWidthToHalfWidth(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        for ch in input {
            guard let scalar = ch.unicodeScalars.first else { continue }
            let code = Int(scalar.value)
            if code == 0x3000 {
                out.append(" ")
                continue
            }
            if (65281...65374).contains(code) {
                out.append(Character(UnicodeScalar(code - 65248)!))
                continue
            }
            out.append(ch)
        }
        return out
    }

    // MARK: - 章节号解析 (对齐 BookHelp.getChapterNum + StringUtils.stringToInt)

    private static func chapterNum(from chapterName: String?) -> Int {
        guard let chapterName, !chapterName.isEmpty else { return -1 }
        let chapterName1 = fullWidthToHalfWidth(chapterName).replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

        if let r = firstCapture(pattern:
            ".*?第([\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)[章节篇回集话]",
                                in: chapterName1) {
            let n = stringToInt(r)
            if n >= 0 { return n }
        }

        if let r = firstCapture(pattern:
            #"^(?:[\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+[:：,，、])*([\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)(?:[:：,，、]|\.[^\d])"#,
                                in: chapterName1) {
            let n = stringToInt(r)
            if n >= 0 { return n }
        }

        return -1
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range),
              m.numberOfRanges >= 2,
              let sr = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[sr])
    }

    private static func stringToInt(_ str: String?) -> Int {
        guard let str, !str.isEmpty else { return -1 }
        let num = fullWidthToHalfWidth(str).replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        if let v = Int(num) { return v }
        return chineseNumToInt(num)
    }

    /// 对齐 StringUtils.chineseNumToInt (核心分支)
    private static func chineseNumToInt(_ chNum: String) -> Int {
        let cn = Array(chNum)
        guard !cn.isEmpty else { return -1 }

        let pattern = "^[〇零一二三四五六七八九壹贰叁肆伍陆柒捌玖]$"
        if cn.count > 1,
           cn.allSatisfy({ String($0).range(of: pattern, options: .regularExpression) != nil }) {
            var digits = ""
            for c in cn {
                if let d = chnDigitMap[c] {
                    digits.append(Character(UnicodeScalar(48 + d)!))
                }
            }
            return Int(digits) ?? -1
        }

        var result = 0
        var tmp = 0
        var billion = 0
        for (i, char) in cn.enumerated() {
            guard let tmpNum = chnMap[char] else { return -1 }
            switch tmpNum {
            case 100_000_000:
                result += tmp
                result *= tmpNum
                billion = billion * 100_000_000 + result
                result = 0
                tmp = 0
            case 10_000:
                result += tmp
                result *= tmpNum
                tmp = 0
            case let x where x >= 10:
                if tmp == 0 { tmp = 1 }
                result += x * tmp
                tmp = 0
            default:
                if i >= 2, i == cn.count - 1, let prev = chnMap[cn[i - 1]], prev > 10 {
                    tmp = tmpNum * prev / 10
                } else {
                    tmp = tmp * 10 + tmpNum
                }
            }
        }
        result += tmp + billion
        return result
    }

    private static let chnDigitMap: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        "壹": 1, "贰": 2, "叁": 3, "肆": 4, "伍": 5,
        "陆": 6, "柒": 7, "捌": 8, "玖": 9,
    ]

    private static let chnMap: [Character: Int] = {
        var map: [Character: Int] = [:]
        let s1 = Array("零一二三四五六七八九十")
        for i in 0...10 { map[s1[i]] = i }
        let s2 = Array("〇壹贰叁肆伍陆柒捌玖拾")
        for i in 0...10 { map[s2[i]] = i }
        map["两"] = 2
        map["百"] = 100; map["佰"] = 100
        map["千"] = 1000; map["仟"] = 1000
        map["万"] = 10_000
        map["亿"] = 100_000_000
        return map
    }()

    // MARK: - pureChapterName (对齐 BookHelp.getPureChapterName)

    private static func pureChapterName(_ chapterName: String?) -> String {
        guard var s = chapterName else { return "" }
        s = fullWidthToHalfWidth(s)
        s = s.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

        let regexB = "^.*?第(?:[\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)[章节篇回集话](?!$)|^(?:[\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+[:：,，、])*([\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)(?:[:：,，、](?!$)|\\.(?=[^\\d]))"

        /// BMP 汉字 + 字母数字下划线保留, 其余剔除 (Legado regexOther 主平面子集).
        let regexOther = "[^\\w\\x{4e00}-\\x{9fef}〇\\x{3400}-\\x{4dbf}]"

        if let re = try? NSRegularExpression(pattern: regexB, options: []) {
            let r = NSRange(s.startIndex..., in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: "")
        }
        if let re = try? NSRegularExpression(pattern: regexOther, options: []) {
            let r = NSRange(s.startIndex..., in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: r, withTemplate: "")
        }
        return s
    }
}

// MARK: - Runtime string deobfuscation

enum Obf {
    private static let key: [UInt8] = [0x5A, 0x3C, 0x7E, 0x1B, 0x4D, 0x69, 0x22, 0xAF]

    static func d(_ data: [UInt8]) -> String {
        var out = [UInt8](repeating: 0, count: data.count)
        for i in data.indices { out[i] = data[i] ^ key[i % key.count] }
        return String(bytes: out, encoding: .utf8) ?? ""
    }
}

enum S {
    static let bookshelf = Obf.d([0xBE, 0x85, 0xD8, 0xFD, 0xD3, 0xDF])
    static let bookstore = Obf.d([0xBE, 0x85, 0xD8, 0xFE, 0xD2, 0xE7])
    static let mine = Obf.d([0xBC, 0xB4, 0xEF, 0xFC, 0xD7, 0xED])
    static let search = Obf.d([0xBC, 0xAC, 0xE2, 0xFC, 0xF9, 0xCB])
    static let titleAuthor = Obf.d([0xBE, 0x85, 0xD8, 0xFE, 0xDD, 0xE4, 0xC1, 0x2F, 0xDB, 0xD8, 0xC3, 0x87, 0xA5, 0xE9, 0xA7])
    static let read = Obf.d([0xB3, 0xA4, 0xFB, 0xF3, 0xE2, 0xD2])
    static let chapter = Obf.d([0xBD, 0x97, 0xDE, 0xF3, 0xC7, 0xEB])
    static let source = Obf.d([0xBE, 0x85, 0xD8, 0xFD, 0xF7, 0xF9])
    static let toc = Obf.d([0xBD, 0xA7, 0xD0, 0xFE, 0xF0, 0xFC])
    static let changeSource = Obf.d([0xBC, 0xB1, 0xDC, 0xFD, 0xF7, 0xF9])
    static let addToShelf = Obf.d([0xBF, 0xB6, 0xDE, 0xFE, 0xC8, 0xCC, 0xC6, 0x16, 0xFC, 0xDA, 0xE0, 0xAD])
    static let startRead = Obf.d([0xBF, 0x80, 0xFE, 0xFE, 0xEA, 0xE2, 0xCB, 0x37, 0xDF, 0xD4, 0xD1, 0xA0])
    static let emptyShelf = Obf.d([0xBE, 0x85, 0xD8, 0xFD, 0xD3, 0xDF, 0xC6, 0x17, 0xE0, 0xDB, 0xD7, 0xA1])
    static let browseStore = Obf.d([0xBF, 0xB2, 0xC5, 0xFF, 0xF4, 0xCF, 0xC7, 0x30, 0xD4, 0xD5, 0xFE, 0x80, 0xA4, 0xE9, 0xB9])
    static let download = Obf.d([0xBE, 0x84, 0xF5, 0xF3, 0xF0, 0xD4])
    static let cacheAll = Obf.d([0xBF, 0xB9, 0xD6, 0xF2, 0xCE, 0xC1, 0xC5, 0x13, 0xC9, 0xD9, 0xD3, 0x83])
    static let appName = Obf.d([0xBE, 0x84, 0xF9, 0xF3, 0xFC, 0xC8, 0xC6, 0x16, 0xFC, 0xD9, 0xCF, 0x90])
}
