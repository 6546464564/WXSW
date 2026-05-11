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
