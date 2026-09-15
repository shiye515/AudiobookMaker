import Foundation

/// Compact number normalizer standing in for the WeTextProcessing pass
/// (`tn.chinese` / `tn.english`) that upstream IndexTTS2 runs before
/// `char_rep_map` and CJK pre-tokenization. The vocabulary has no digit
/// pieces, so anything left as digits tokenizes to `<unk>`.
///
/// Covers the readings that show up in ordinary prose — cardinals, years,
/// dates, times, decimals, percentages, fractions, money, ordinals,
/// negatives, thousands separators, mobile numbers — and leaves everything
/// else untouched. It is not a port of the upstream FST grammars.
struct IndexTTS2TextNormalizer {
    static func normalize(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: Self.isDigit) else { return text }
        let folded = foldFullwidthDigits(text)
        return usesChineseFrontEnd(folded) ? normalizeChinese(folded) : normalizeEnglish(folded)
    }

    /// Upstream `use_chinese`: Han text, or text with no Latin letters at all.
    static func usesChineseFrontEnd(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let hasHan = scalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let hasLatinLetter = scalars.contains { isLatinLetter($0) }
        return hasHan || !hasLatinLetter
    }

    // MARK: - Chinese

    private static func normalizeChinese(_ text: String) -> String {
        var s = stripThousandsSeparators(text)
        s = Self.zhPercent.replace(in: s) { "百分之" + zhNumber($0[1]) }
        s = Self.fraction.replace(in: s) { zhCardinal($0[2]) + "分之" + zhCardinal($0[1]) }
        s = Self.zhDollars.replace(in: s) { zhNumber($0[1]) + "美元" }
        s = Self.zhYuan.replace(in: s) { zhNumber($0[1]) + "元" }
        s = Self.clockTime.replace(in: s) { groups in
            let minute = groups[2]
            var reading = zhCardinal(groups[1]) + "点"
            if minute != "00" {
                reading += (minute.hasPrefix("0") ? "零" + zhDigits(String(minute.dropFirst())) : zhCardinal(minute)) + "分"
            }
            return reading
        }
        s = Self.zhYear.replace(in: s) { zhDigits($0[1]) + "年" }
        s = Self.zhMobileNumber.replace(in: s) { zhDigits($0[1]) }
        s = Self.negative.replace(in: s) { "负" + zhNumber($0[1]) }
        s = Self.decimal.replace(in: s) { zhCardinal($0[1]) + "点" + zhDigits($0[2]) }
        s = Self.integer.replace(in: s) { zhInteger($0[0]) }
        return s
    }

    private static let zhNumerals = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
    private static let zhUnits = ["", "十", "百", "千"]
    private static let zhSections = ["", "万", "亿"]

    private static func zhNumber(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return zhInteger(s) }
        return zhCardinal(String(s[..<dot])) + "点" + zhDigits(String(s[s.index(after: dot)...]))
    }

    private static func zhInteger(_ digits: String) -> String {
        if (digits.hasPrefix("0") && digits.count > 1) || digits.count > 12 {
            return zhDigits(digits)
        }
        return zhCardinal(digits)
    }

    private static func zhDigits(_ digits: String) -> String {
        digits.compactMap { $0.wholeNumberValue.map { zhNumerals[$0] } }.joined()
    }

    /// Standard cardinal reading with 万/亿 sections and single 零 for zero gaps.
    private static func zhCardinal(_ digitString: String) -> String {
        let all = digitString.compactMap(\.wholeNumberValue)
        guard let first = all.firstIndex(where: { $0 != 0 }), all.count <= 12 else {
            return all.isEmpty ? "" : (all.allSatisfy { $0 == 0 } ? "零" : zhDigits(digitString))
        }
        let digits = Array(all[first...])
        var result = ""
        var pendingZero = false
        var sectionHasValue = false
        for (index, digit) in digits.enumerated() {
            let position = digits.count - 1 - index
            let unit = position % 4
            let section = position / 4
            if digit == 0 {
                pendingZero = !result.isEmpty
            } else {
                if pendingZero { result += "零" }
                pendingZero = false
                sectionHasValue = true
                result += zhNumerals[digit] + zhUnits[unit]
            }
            if unit == 0 && section > 0 {
                if sectionHasValue {
                    result += zhSections[section]
                    pendingZero = false
                }
                sectionHasValue = false
            }
        }
        if result.hasPrefix("一十") { result.removeFirst() }
        return result
    }

    // MARK: - English

    private static func normalizeEnglish(_ text: String) -> String {
        var s = stripThousandsSeparators(text)
        s = Self.enOrdinal.replace(in: s, padLetters: true) { enOrdinal($0[1]) }
        s = Self.enPercent.replace(in: s, padLetters: true) { enNumber($0[1]) + " percent" }
        s = Self.enDollars.replace(in: s, padLetters: true) { enMoney(dollars: $0[1], cents: $0[2]) }
        s = Self.clockTime.replace(in: s, padLetters: true) { enTime(hour: $0[1], minute: $0[2]) }
        s = Self.negative.replace(in: s, padLetters: true) { "minus " + enNumber($0[1]) }
        s = Self.decimal.replace(in: s, padLetters: true) { enCardinal($0[1]) + " point " + enDigits($0[2]) }
        s = Self.enYear.replace(in: s, padLetters: true) { enYear($0[1]) }
        s = Self.integer.replace(in: s, padLetters: true) { enInteger($0[0]) }
        return s
    }

    private static let enOnes = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let enTens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let enScales = ["", "thousand", "million", "billion", "trillion"]
    private static let enIrregularOrdinals = [
        "one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
        "nine": "ninth", "twelve": "twelfth",
    ]

    private static func enNumber(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return enInteger(s) }
        return enCardinal(String(s[..<dot])) + " point " + enDigits(String(s[s.index(after: dot)...]))
    }

    private static func enInteger(_ digits: String) -> String {
        if (digits.hasPrefix("0") && digits.count > 1) || digits.count > 15 {
            return enDigits(digits)
        }
        return enCardinal(digits)
    }

    private static func enDigits(_ digits: String) -> String {
        digits.compactMap { $0.wholeNumberValue.map { enOnes[$0] } }.joined(separator: " ")
    }

    private static func enCardinal(_ digitString: String) -> String {
        guard let value = Int(digitString) else { return digitString }
        return enCardinal(value)
    }

    private static func enCardinal(_ value: Int) -> String {
        if value < 20 { return enOnes[value] }
        if value < 100 {
            return enTens[value / 10] + (value % 10 == 0 ? "" : " " + enOnes[value % 10])
        }
        if value < 1_000 {
            return enOnes[value / 100] + " hundred" + (value % 100 == 0 ? "" : " " + enCardinal(value % 100))
        }
        var remainder = value
        var scale = 0
        var parts: [String] = []
        while remainder > 0 && scale < enScales.count {
            let chunk = remainder % 1_000
            if chunk > 0 {
                parts.insert(enCardinal(chunk) + (scale == 0 ? "" : " " + enScales[scale]), at: 0)
            }
            remainder /= 1_000
            scale += 1
        }
        return parts.joined(separator: " ")
    }

    private static func enOrdinal(_ digits: String) -> String {
        var words = enCardinal(digits).split(separator: " ").map(String.init)
        guard let last = words.popLast() else { return digits }
        let ordinal: String
        if let irregular = enIrregularOrdinals[last] {
            ordinal = irregular
        } else if last.hasSuffix("y") {
            ordinal = String(last.dropLast()) + "ieth"
        } else {
            ordinal = last + "th"
        }
        return (words + [ordinal]).joined(separator: " ")
    }

    private static func enYear(_ digits: String) -> String {
        guard let year = Int(digits), (1_100...2_099).contains(year) else { return enCardinal(digits) }
        let high = year / 100
        let low = year % 100
        if (2_000...2_009).contains(year) {
            return "two thousand" + (low == 0 ? "" : " " + enCardinal(low))
        }
        if low == 0 { return enCardinal(high) + " hundred" }
        if low < 10 { return enCardinal(high) + " oh " + enOnes[low] }
        return enCardinal(high) + " " + enCardinal(low)
    }

    private static func enMoney(dollars: String, cents: String) -> String {
        let dollarValue = Int(dollars) ?? 0
        let centValue = cents.isEmpty ? 0 : Int(cents.count == 1 ? cents + "0" : cents) ?? 0
        var parts: [String] = []
        if dollarValue > 0 || centValue == 0 {
            parts.append(enCardinal(dollarValue) + (dollarValue == 1 ? " dollar" : " dollars"))
        }
        if centValue > 0 {
            parts.append(enCardinal(centValue) + (centValue == 1 ? " cent" : " cents"))
        }
        return parts.joined(separator: " ")
    }

    private static func enTime(hour: String, minute: String) -> String {
        let hourWords = enCardinal(hour)
        guard let minuteValue = Int(minute) else { return hourWords }
        if minuteValue == 0 { return hourWords + " o'clock" }
        if minuteValue < 10 { return hourWords + " oh " + enOnes[minuteValue] }
        return hourWords + " " + enCardinal(minuteValue)
    }

    // MARK: - Shared patterns

    private static let thousandsSeparator = Pattern("(?<=[0-9])[,，](?=[0-9]{3}(?![0-9]))")
    private static let fraction = Pattern("(?<![0-9])([0-9]+)/([0-9]+)(?![0-9])")
    private static let clockTime = Pattern("(?<![0-9])([0-9]{1,2}):([0-9]{2})(?![0-9:])")
    private static let negative = Pattern("(?<![0-9A-Za-z])-([0-9]+(?:\\.[0-9]+)?)")
    private static let decimal = Pattern("([0-9]+)\\.([0-9]+)")
    private static let integer = Pattern("[0-9]+")
    private static let zhPercent = Pattern("([0-9]+(?:\\.[0-9]+)?)\\s*[%％]")
    private static let zhDollars = Pattern("[$＄]([0-9]+(?:\\.[0-9]+)?)")
    private static let zhYuan = Pattern("[¥￥]([0-9]+(?:\\.[0-9]+)?)")
    private static let zhYear = Pattern("(?<![0-9])([0-9]{2,4})年")
    private static let zhMobileNumber = Pattern("(?<![0-9])(1[3-9][0-9]{9})(?![0-9])")
    private static let enOrdinal = Pattern("(?<![0-9])([0-9]+)(?:st|nd|rd|th)\\b", options: [.caseInsensitive])
    private static let enPercent = Pattern("([0-9]+(?:\\.[0-9]+)?)\\s*%")
    private static let enDollars = Pattern("\\$([0-9]+)(?:\\.([0-9]{1,2}))?(?![0-9])")
    private static let enYear = Pattern("(?<![0-9A-Za-z])([1-9][0-9]{3})(?![0-9A-Za-z])")

    private static func stripThousandsSeparators(_ text: String) -> String {
        thousandsSeparator.replace(in: text) { _ in "" }
    }

    private static func foldFullwidthDigits(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0xFF10...0xFF19).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0xFF10 + 0x30)! : scalar
        }))
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0xFF10...0xFF19).contains(scalar.value)
    }

    private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private struct Pattern: @unchecked Sendable {
        let regex: NSRegularExpression

        init(_ pattern: String, options: NSRegularExpression.Options = []) {
            // Patterns are static literals; a malformed one is a programming error.
            regex = try! NSRegularExpression(pattern: pattern, options: options)
        }

        /// Replaces every match with `transform(groups)`, where `groups[0]` is
        /// the whole match. With `padLetters`, a replacement that touches a
        /// Latin letter gets a space on that side so number words stay separate.
        func replace(in text: String, padLetters: Bool = false, _ transform: ([String]) -> String) -> String {
            let source = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            guard !matches.isEmpty else { return text }
            var result = source
            for match in matches.reversed() {
                let groups = (0..<match.numberOfRanges).map { index -> String in
                    let range = match.range(at: index)
                    return range.location == NSNotFound ? "" : source.substring(with: range)
                }
                var replacement = transform(groups)
                if padLetters {
                    if match.range.location > 0,
                       Self.isLetter(source.character(at: match.range.location - 1)) {
                        replacement = " " + replacement
                    }
                    let end = match.range.location + match.range.length
                    if end < source.length, Self.isLetter(source.character(at: end)) {
                        replacement += " "
                    }
                }
                result = result.replacingCharacters(in: match.range, with: replacement) as NSString
            }
            return result as String
        }

        private static func isLetter(_ unit: unichar) -> Bool {
            (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
        }
    }
}
