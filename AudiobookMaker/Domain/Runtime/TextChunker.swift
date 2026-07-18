import Foundation

nonisolated enum TextChunker {
    static func chunks(text: String, maximumLength: Int) throws -> [String] {
        guard maximumLength > 0 else { throw RuntimeError.incompatibleRuntime }

        let normalized = text
            .precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw RuntimeError.invalidText }

        var result: [String] = []
        var remainder = normalized
        let preferredBreaks = CharacterSet(charactersIn: "。！？!?；;：:\n")
        let secondaryBreaks = CharacterSet(charactersIn: "，,、 ")

        while remainder.count > maximumLength {
            let limit = remainder.index(remainder.startIndex, offsetBy: maximumLength)
            let window = remainder[..<limit]
            let split = lastBreak(in: window, characters: preferredBreaks)
                ?? lastBreak(in: window, characters: secondaryBreaks)
                ?? limit
            let piece = remainder[..<split].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(String(piece)) }
            remainder = String(remainder[split...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(String(tail)) }
        return result
    }

    private static func lastBreak(
        in text: Substring,
        characters: CharacterSet
    ) -> String.Index? {
        for index in text.indices.reversed() {
            guard let scalar = text[index].unicodeScalars.first,
                  characters.contains(scalar) else { continue }
            return text.index(after: index)
        }
        return nil
    }
}
