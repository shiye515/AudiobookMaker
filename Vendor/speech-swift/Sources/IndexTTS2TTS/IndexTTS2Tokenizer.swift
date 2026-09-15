import AudioCommon
import Foundation

public struct IndexTTS2Token: Equatable, Sendable {
    public let id: Int
    public let piece: String

    public init(id: Int, piece: String) {
        self.id = id
        self.piece = piece
    }
}

public enum IndexTTS2TokenizerError: Error, LocalizedError, Equatable {
    case emptyVocabulary
    case textTooLong(maxScalars: Int)
    /// Only thrown for models without an `<unk>` piece; the published
    /// `bpe.model` has one, so unsupported scalars degrade to it instead.
    case unencodableText(String)

    public var errorDescription: String? {
        switch self {
        case .emptyVocabulary:
            return "IndexTTS2 tokenizer vocabulary is empty."
        case .textTooLong(let maxScalars):
            return "IndexTTS2 tokenizer input is too long; max \(maxScalars) Unicode scalars."
        case .unencodableText(let text):
            return "IndexTTS2 tokenizer could not encode text: \(text)"
        }
    }
}

/// SentencePiece Unigram tokenizer for IndexTTS2's `bpe.model`.
///
/// Mirrors the upstream text front end (`indextts/utils/front.py`) ahead of
/// the SentencePiece lattice:
///
/// 1. `char_rep_map` punctuation rewriting (`。` → `.`, `，` → `,`, quotes and
///    brackets → `'`, `:`/`;` → `,`, …). The vocabulary has pieces for none
///    of the originals.
/// 2. `tokenize_by_CJK_char`: a word boundary before every CJK scalar, so the
///    lattice emits a standalone `▁` ahead of each character — the shape the
///    GPT was trained on. The vocabulary has no `▁`-prefixed CJK pieces.
/// 3. Uppercasing of the non-CJK text.
///
/// `IndexTTS2TextNormalizer` reads numbers out ahead of these steps, standing
/// in for upstream's WeTextProcessing pass; glossary handling is not ported.
/// Scalars without a piece become `<unk>`, with consecutive runs merged, as
/// SentencePiece does.
public struct IndexTTS2Tokenizer: Sendable {
    public static let maxInputScalars = 2_048

    /// SentencePiece's `kUnkPenalty`: `<unk>` nodes score `minScore - 10`.
    private static let unknownPenalty: Float = 10

    private let pieces: [SentencePieceModel.Piece]
    private let tokenToId: [String: Int]
    private let singleScalarPieces: Set<Unicode.Scalar>
    private let maxPieceScalars: Int
    private let unknownScore: Float

    /// Id of the `<unk>` piece, or nil when the model has none.
    public let unknownTokenId: Int?

    public init(modelURL: URL) throws {
        let model = try SentencePieceModel(contentsOf: modelURL)
        try self.init(pieces: model.pieces)
    }

    init(pieces: [SentencePieceModel.Piece]) throws {
        guard !pieces.isEmpty else {
            throw IndexTTS2TokenizerError.emptyVocabulary
        }
        self.pieces = pieces
        self.tokenToId = Dictionary(
            uniqueKeysWithValues: pieces.enumerated().map { ($0.element.text, $0.offset) }
        )
        let lattice = pieces.filter { !$0.isControlOrUnknown }
        self.singleScalarPieces = Set(lattice.compactMap { piece in
            let scalars = piece.text.unicodeScalars
            return scalars.count == 1 ? scalars.first : nil
        })
        self.maxPieceScalars = lattice.map { $0.text.unicodeScalars.count }.max() ?? 1
        self.unknownScore = (lattice.map(\.score).min() ?? 0) - Self.unknownPenalty
        self.unknownTokenId = pieces.firstIndex { $0.pieceType == .unknown }
    }

    public func tokenize(_ text: String) throws -> [IndexTTS2Token] {
        try encode(text).map { id in
            IndexTTS2Token(id: id, piece: pieces[id].text)
        }
    }

    public func encode(_ text: String) throws -> [Int] {
        let normalized = normalizedPieceText(for: text)
        guard !normalized.isEmpty else { return [] }

        let scalars = Array(normalized.unicodeScalars)
        guard scalars.count <= Self.maxInputScalars else {
            throw IndexTTS2TokenizerError.textTooLong(maxScalars: Self.maxInputScalars)
        }

        var bestScores = [Float](repeating: -.infinity, count: scalars.count + 1)
        var backPointer = [(start: Int, id: Int)?](repeating: nil, count: scalars.count + 1)
        bestScores[0] = 0

        for start in 0..<scalars.count where bestScores[start].isFinite {
            for end in (start + 1)...min(scalars.count, start + maxPieceScalars) {
                let piece = String(String.UnicodeScalarView(scalars[start..<end]))
                guard let id = tokenToId[piece] else { continue }
                guard !pieces[id].isControlOrUnknown else { continue }

                let score = bestScores[start] + pieces[id].score
                if score > bestScores[end] || (score == bestScores[end] && isTieBreakBetter(id, start, than: backPointer[end])) {
                    bestScores[end] = score
                    backPointer[end] = (start, id)
                }
            }

            // SentencePiece adds a one-scalar `<unk>` node wherever no
            // single-scalar piece covers the position.
            if let unknownTokenId, !singleScalarPieces.contains(scalars[start]) {
                let score = bestScores[start] + unknownScore
                if score > bestScores[start + 1] {
                    bestScores[start + 1] = score
                    backPointer[start + 1] = (start, unknownTokenId)
                }
            }
        }

        guard bestScores[scalars.count].isFinite else {
            throw IndexTTS2TokenizerError.unencodableText(text)
        }

        var ids: [Int] = []
        var cursor = scalars.count
        while cursor > 0, let pointer = backPointer[cursor] {
            // Consecutive `<unk>` nodes collapse into one, as in SentencePiece.
            if pointer.id != unknownTokenId || ids.last != unknownTokenId {
                ids.append(pointer.id)
            }
            cursor = pointer.start
        }
        ids.reverse()

        if let unknownTokenId {
            let unknownCount = ids.filter { $0 == unknownTokenId }.count
            if unknownCount > 0 {
                AudioLog.inference.warning(
                    "IndexTTS2 tokenizer mapped \(unknownCount) span(s) to <unk>; unsupported symbols have no vocabulary pieces.")
            }
        }
        return ids
    }

    /// Joins pieces back into text, undoing the per-character CJK spacing.
    /// Spaces stay between Latin words and are dropped next to CJK scalars.
    public func decode(_ ids: [Int]) -> String {
        let surface = ids.compactMap { id -> String? in
            guard id >= 0, id < pieces.count else { return nil }
            let piece = pieces[id]
            return piece.isControlOrUnknown ? nil : piece.text
        }
        .joined()
        .replacingOccurrences(of: "▁", with: " ")

        let scalars = Array(surface.unicodeScalars)
        var output = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            if scalar == " ",
               let previous = output.last,
               let next = scalars[(index + 1)...].first(where: { $0 != " " }),
               Self.isCJK(previous) || Self.isCJK(next),
               !Self.isLatinAlphanumeric(previous), !Self.isLatinAlphanumeric(next) {
                continue
            }
            output.append(scalar)
        }
        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Upstream text front end

    private func normalizedPieceText(for text: String) -> String {
        let rewritten = Self.rewritePunctuation(in: IndexTTS2TextNormalizer.normalize(text))
        let spaced = Self.separateCJKCharacters(in: rewritten).uppercased()
        let normalized = (spaced as NSString)
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return "" }
        return "▁" + normalized.replacingOccurrences(of: " ", with: "▁")
    }

    private struct Rewrite: Sendable {
        let from: [Unicode.Scalar]
        let to: [Unicode.Scalar]

        init(_ from: String, _ to: String) {
            self.from = Array(from.unicodeScalars)
            self.to = Array(to.unicodeScalars)
        }
    }

    /// Upstream `char_rep_map`, in its original order: entries are tried in
    /// sequence at each position and the first match wins, which is how the
    /// upstream regex alternation behaves.
    private static let punctuationRewrites: [Rewrite] = [
        Rewrite("：", ","), Rewrite("；", ","), Rewrite(";", ","), Rewrite("，", ","), Rewrite("。", "."),
        Rewrite("！", "!"), Rewrite("？", "?"), Rewrite("\n", " "), Rewrite("·", "-"), Rewrite("、", ","),
        Rewrite("...", "…"), Rewrite(",,,", "…"), Rewrite("，，，", "…"), Rewrite("……", "…"),
        Rewrite("“", "'"), Rewrite("”", "'"), Rewrite("\"", "'"), Rewrite("‘", "'"), Rewrite("’", "'"),
        Rewrite("（", "'"), Rewrite("）", "'"), Rewrite("(", "'"), Rewrite(")", "'"),
        Rewrite("《", "'"), Rewrite("》", "'"), Rewrite("【", "'"), Rewrite("】", "'"),
        Rewrite("[", "'"), Rewrite("]", "'"), Rewrite("—", "-"), Rewrite("～", "-"), Rewrite("~", "-"),
        Rewrite("「", "'"), Rewrite("」", "'"), Rewrite(":", ","),
    ]

    /// Upstream `zh_char_rep_map`: the Chinese path additionally reads `$` as `.`.
    private static let chinesePunctuationRewrites: [Rewrite] = [Rewrite("$", ".")] + punctuationRewrites

    private static func rewritePunctuation(in text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let rules = IndexTTS2TextNormalizer.usesChineseFrontEnd(text) ? chinesePunctuationRewrites : punctuationRewrites
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            if let rule = rules.first(where: { scalars[index...].starts(with: $0.from) }) {
                output.append(contentsOf: rule.to)
                index += rule.from.count
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return String(output)
    }

    /// Upstream `tokenize_by_CJK_char`: every CJK scalar becomes its own
    /// whitespace-delimited word.
    private static func separateCJKCharacters(in text: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                output.append(" ")
                output.append(scalar)
                output.append(" ")
            } else {
                output.append(scalar)
            }
        }
        return String(output)
    }

    /// The CJK ranges upstream splits on (`CJK_RANGE_PATTERN`).
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF, 0x2E80...0xA4CF, 0xA840...0xD7AF, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF65...0xFFDC, 0x20000...0x2FFFF:
            return true
        default:
            return false
        }
    }

    private static func isLatinAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value) || (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private func isTieBreakBetter(
        _ candidateId: Int,
        _ candidateStart: Int,
        than existing: (start: Int, id: Int)?
    ) -> Bool {
        guard let existing else { return true }
        return candidateId < existing.id ||
            (candidateId == existing.id && candidateStart > existing.start)
    }
}
