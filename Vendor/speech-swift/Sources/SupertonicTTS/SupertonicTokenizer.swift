import Foundation

/// SupertonicTTS G2P-free text front-end: **NFKD + regex cleanup + `<lang>…</lang>` wrap +
/// codepoint→token-id table lookup**. No phonemizer, no IPA, no espeak.
///
/// Faithful Swift port of `Supertone/supertonic` `py/helper.py::UnicodeProcessor` (validated in
/// `speech-models/stmodels/infer.py`) and the C++ `SupertonicTokenizer`. NFKD — the keystone that
/// decomposes ä → a +◌̈ and Hangul into in-vocab jamo — is Foundation's
/// `decomposedStringWithCompatibilityMapping`.
public struct SupertonicTokenizer: Sendable {
    /// Token id for codepoints absent from the indexer table.
    public static let unknownId: Int32 = -1

    /// `Supertone/supertonic` AVAILABLE_LANGS (32 entries; includes "na", excludes "zh").
    public static let availableLangs: Set<String> = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es",
        "et", "fi", "fr", "hi", "hr", "hu", "id", "it", "lt", "lv",
        "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk",
        "vi", "na",
    ]

    /// `indexer[codepoint] = id`, -1 if unsupported. Flat array of 65536 ints.
    private let indexer: [Int32]

    public init(indexer: [Int32]) { self.indexer = indexer }

    /// Load `unicode_indexer.json` — a flat JSON array of 65536 ints.
    public static func load(from url: URL) throws -> SupertonicTokenizer {
        let data = try Data(contentsOf: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw SupertonicError.badAsset("unicode_indexer.json must be a flat JSON array")
        }
        var indexer = [Int32](); indexer.reserveCapacity(raw.count)
        for v in raw { indexer.append(Int32(truncatingIfNeeded: (v as? NSNumber)?.intValue ?? -1)) }
        return SupertonicTokenizer(indexer: indexer)
    }

    public func supports(_ lang: String) -> Bool { Self.availableLangs.contains(lang) }

    @inline(__always)
    private func lookup(_ cp: UInt32) -> Int32 {
        cp < UInt32(indexer.count) ? indexer[Int(cp)] : Self.unknownId
    }

    // MARK: - cleanup

    private static let emojiRanges: [ClosedRange<UInt32>] = [
        0x1F600...0x1F64F, 0x1F300...0x1F5FF, 0x1F680...0x1F6FF, 0x1F700...0x1F77F,
        0x1F780...0x1F7FF, 0x1F800...0x1F8FF, 0x1F900...0x1F9FF, 0x1FA00...0x1FA6F,
        0x1FA70...0x1FAFF, 0x2600...0x26FF, 0x2700...0x27BF, 0x1F1E6...0x1F1FF,
    ]

    private static func isEmoji(_ v: UInt32) -> Bool { emojiRanges.contains { $0.contains(v) } }

    /// helper.py::_char_repl + the `[♥☆♡©\]` strip, on a single scalar. Returns the replacement
    /// scalar(s), or nil to drop it.
    private static func charRepl(_ s: Unicode.Scalar) -> Unicode.Scalar? {
        switch s.value {
        case 0x2013, 0x2011, 0x2014: return "-"            // – ‑ —
        case 0x5F:                   return " "            // _
        case 0x201C, 0x201D:         return "\""           // “ ”
        case 0x2018, 0x2019:         return "'"            // ‘ ’
        case 0x00B4, 0x60:           return "'"            // ´ `
        case 0x5B, 0x5D, 0x7C, 0x2F, 0x23: return " "      // [ ] | / #
        case 0x2192, 0x2190:         return " "            // → ←
        case 0x2665, 0x2606, 0x2661, 0x00A9, 0x5C: return nil  // ♥ ☆ ♡ © backslash
        default:                     return s
        }
    }

    // helper.py terminal set: [.!?;:,'")\]}…。」』】〉》›»]
    private static let terminalSet: Set<UInt32> = Set(
        ".!?;:,'\")]}".unicodeScalars.map { $0.value } +
        [0x2026, 0x3002, 0x300D, 0x300F, 0x3011, 0x3009, 0x300B, 0x203A, 0x00BB])

    /// NFKD + cleanup + `<lang>` wrap. Throws on unsupported language.
    func preprocess(_ text: String, lang: String) throws -> String {
        // 1) NFKD.
        let nfkd = text.decomposedStringWithCompatibilityMapping

        // 2) emoji removal + char-level map/strip.
        var scalars = String.UnicodeScalarView()
        for s in nfkd.unicodeScalars {
            if Self.isEmoji(s.value) { continue }
            if let r = Self.charRepl(s) { scalars.append(r) }
        }
        var out = String(scalars)

        // 3) expression replacements.
        out = out.replacingOccurrences(of: "@", with: " at ")
        out = out.replacingOccurrences(of: "e.g.,", with: "for example, ")
        out = out.replacingOccurrences(of: "i.e.,", with: "that is, ")

        // 4) drop a space before punctuation.
        for p in [",", ".", "!", "?", ";", ":", "'"] {
            out = out.replacingOccurrences(of: " " + p, with: p)
        }

        // 5) collapse repeated quotes.
        while out.contains("\"\"") { out = out.replacingOccurrences(of: "\"\"", with: "\"") }
        while out.contains("''")   { out = out.replacingOccurrences(of: "''", with: "'") }
        while out.contains("``")   { out = out.replacingOccurrences(of: "``", with: "`") }

        // 6) collapse whitespace + trim.
        var collapsed = String.UnicodeScalarView()
        var prevWs = false
        for s in out.unicodeScalars {
            let ws = s == " " || s == "\t" || s == "\n" || s == "\r"
                || s.value == 0x0B || s.value == 0x0C
            if ws { if !prevWs { collapsed.append(" ") }; prevWs = true }
            else { collapsed.append(s); prevWs = false }
        }
        var trimmed = Array(collapsed)
        while trimmed.first == " " { trimmed.removeFirst() }
        while trimmed.last == " " { trimmed.removeLast() }

        // 7) ensure terminal punctuation.
        if let last = trimmed.last, !Self.terminalSet.contains(last.value) {
            trimmed.append(".")
        } else if trimmed.isEmpty {
            trimmed.append(".")
        }
        let cleaned = String(String.UnicodeScalarView(trimmed))

        // 8) validate + wrap.
        guard supports(lang) else { throw SupertonicError.unsupportedLanguage(lang) }
        return "<\(lang)>\(cleaned)</\(lang)>"
    }

    // MARK: - tokenize

    public struct Tokens: Sendable {
        public let ids: [Int32]    // length == textLength (zero-padded)
        public let mask: [Float]   // length == textLength (1.0 real, 0.0 pad)
    }

    /// Full front-end for one chunk: preprocess → per-codepoint lookup → right-pad to `textLength`.
    func process(_ text: String, lang: String, textLength: Int) throws -> Tokens {
        let wrapped = try preprocess(text, lang: lang)
        var ids = [Int32](repeating: 0, count: textLength)
        var mask = [Float](repeating: 0, count: textLength)
        var i = 0
        for s in wrapped.unicodeScalars {
            if i >= textLength { break }
            ids[i] = lookup(s.value)
            mask[i] = 1.0
            i += 1
        }
        return Tokens(ids: ids, mask: mask)
    }

    // MARK: - chunking

    /// Token count of the wrapped, preprocessed form of `text` — what `process()` emits before
    /// padding. Past `textLength`, `process()` truncates silently; NFKD adds a scalar per accented
    /// letter, so a raw-scalar budget alone cannot guarantee the fit.
    func wrappedLength(_ text: String, lang: String) throws -> Int {
        try preprocess(text, lang: lang).unicodeScalars.count
    }

    /// Smallest piece the balanced splitter may produce (scalars); also the packing-budget floor.
    static let minPieceScalars = 8

    /// Split free-form text into per-synthesis chunks that fit the fixed text length after the
    /// `<lang>` wrap. CoreML latent length L is dynamic (RangeDim), so only the text axis bounds
    /// us. Mirrors `helper.py::_chunk_text` and the C++ `SupertonicTokenizer::chunk()`: sentences
    /// (terminal punctuation followed by whitespace) are packed greedily up to a raw-scalar
    /// budget; a longer sentence is bisected at its best boundary in balanced halves rather than
    /// word-packed at the budget (which strands its last word or two in a tiny chunk — speech-core
    /// #140). Every chunk is guaranteed to fit `textLength` after NFKD (`wrappedLength`).
    func chunk(_ text: String, lang: String, textLength: Int) -> [String] {
        var budget = textLength - (2 * lang.count + 5) - 1
        if budget < Self.minPieceScalars { budget = Self.minPieceScalars }

        let cps = Array(text.unicodeScalars)

        // sentence-ish split at terminal punctuation + following whitespace; trim each sentence.
        var sentences: [[Unicode.Scalar]] = []
        var cur: [Unicode.Scalar] = []
        func pushSentence() {
            var a = 0, b = cur.count
            while a < b, Self.isWs(cur[a]) { a += 1 }
            while b > a, Self.isWs(cur[b - 1]) { b -= 1 }
            if b > a { sentences.append(Array(cur[a..<b])) }
            cur.removeAll(keepingCapacity: true)
        }
        for (i, s) in cps.enumerated() {
            cur.append(s)
            if Self.sentenceEnd.contains(s.value), i + 1 < cps.count, Self.isWs(cps[i + 1]) {
                pushSentence()
            }
        }
        pushSentence()

        var out: [String] = []
        var chunk: [Unicode.Scalar] = []
        func flush() {
            if !chunk.isEmpty {
                emitWithinCapacity(String(String.UnicodeScalarView(chunk)), lang: lang,
                                   textLength: textLength, into: &out)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        func fits(_ n: Int) -> Bool { chunk.count + (chunk.isEmpty ? 0 : 1) + n <= budget }

        for sent in sentences {
            if sent.count <= budget {
                if !fits(sent.count) { flush() }
                if !chunk.isEmpty { chunk.append(" ") }
                chunk.append(contentsOf: sent)
                continue
            }
            // Longer than the packing budget: keep it in one piece where the capacity allows,
            // otherwise cut it in balanced halves at the best boundary — never at the budget.
            flush()
            emitWithinCapacity(String(String.UnicodeScalarView(sent)), lang: lang,
                               textLength: textLength, into: &out)
        }
        flush()
        return out.isEmpty ? [""] : out
    }

    /// Append `text` as one chunk when its wrapped form fits `textLength`; otherwise bisect at the
    /// best sentence/clause/word boundary until every piece fits.
    private func emitWithinCapacity(_ text: String, lang: String, textLength: Int,
                                    into out: inout [String]) {
        // An unsupported language throws in process() anyway; treat it as fitting here.
        let wrapped = (try? wrappedLength(text, lang: lang)) ?? 0
        if wrapped <= textLength { out.append(text); return }
        guard let (left, right) = Self.bisect(text, minScalars: Self.minPieceScalars) else {
            out.append(text)  // nothing to cut on; process() truncates this one
            return
        }
        emitWithinCapacity(left, lang: lang, textLength: textLength, into: &out)
        emitWithinCapacity(right, lang: lang, textLength: textLength, into: &out)
    }

    static let sentenceEnd: Set<UInt32> = [0x2E, 0x21, 0x3F, 0x2026, 0x3002, 0xFF01, 0xFF1F]
    static let clauseEnd: Set<UInt32> = [0x2C, 0x3B, 0x3A]  // , ; :

    @inline(__always)
    static func isWs(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\n" || s == "\t" || s == "\r" || s.value == 0x0B || s.value == 0x0C
    }

    /// Split `text` in two at the best boundary — sentence end > clause end (`,;:`) > whitespace >
    /// any scalar — and, within a class, the most balanced cut. Both halves are trimmed. Returns
    /// nil when no cut leaves both halves at least `minScalars` long.
    static func bisect(_ text: String, minScalars: Int) -> (String, String)? {
        let s = Array(text.unicodeScalars)
        let n = s.count
        guard minScalars > 0, n >= 2 * minScalars else { return nil }
        var best: (rank: Int, largest: Int, imbalance: Int, l: Int, r: Int)?
        for cut in minScalars...(n - minScalars) {
            var l = cut, r = cut
            while l > 0, isWs(s[l - 1]) { l -= 1 }
            while r < n, isWs(s[r]) { r += 1 }
            let leftCount = l, rightCount = n - r
            if leftCount < minScalars || rightCount < minScalars { continue }
            let before = s[l - 1].value, after = s[r].value
            var rank = 3
            if sentenceEnd.contains(before) || clauseEnd.contains(before) {
                // never split inside a punctuation run
                if sentenceEnd.contains(after) || clauseEnd.contains(after) { continue }
                rank = sentenceEnd.contains(before) ? 0 : 1
            } else if r > l {
                rank = 2
            }
            let largest = max(leftCount, rightCount)
            let imbalance = abs(leftCount - rightCount)
            if let b = best, (b.rank, b.largest, b.imbalance) <= (rank, largest, imbalance) { continue }
            best = (rank, largest, imbalance, l, r)
        }
        guard let b = best else { return nil }
        return (String(String.UnicodeScalarView(s[0..<b.l])), String(String.UnicodeScalarView(s[b.r..<n])))
    }
}
