import Foundation

/// Splits a tokenized sentence into synthesis segments the way upstream
/// `TextTokenizer.split_segments` does: cut after sentence-final punctuation,
/// commas and hyphens, then merge neighbouring runs back together while they
/// still fit in `maxTokens`. Each segment is generated on its own so long
/// inputs never exceed the GPT's text window or its mel budget.
///
/// One deliberate difference: upstream chops a punctuation-free run at the
/// limit and leaves the remainder as its own segment, which can be a single
/// token (even a lone `▁`) and synthesizes as noise. Such runs are cut into
/// even chunks here, preferring word boundaries.
struct IndexTTS2TextSegmenter {
    static let defaultMaxTokens = 120

    private static let sentenceEndPieces: Set<String> = [".", "!", "?", "▁.", "▁?", "▁..."]
    private static let commaPieces: Set<String> = [",", "▁,"]
    private static let hyphenPieces: Set<String> = ["-"]
    private static let apostrophePieces: Set<String> = ["'", "▁'"]

    static func split(_ tokens: [IndexTTS2Token], maxTokens: Int = defaultMaxTokens) -> [[IndexTTS2Token]] {
        guard !tokens.isEmpty else { return [] }
        let limit = max(1, maxTokens)

        var runs: [[IndexTTS2Token]] = []
        var current: [IndexTTS2Token] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            current.append(token)
            index += 1

            if commaPieces.contains(token.piece) || hyphenPieces.contains(token.piece) {
                runs.append(current)
                current = []
            } else if sentenceEndPieces.contains(token.piece), current.count > 2 {
                // Keep a trailing apostrophe with the sentence it closes.
                if index < tokens.count, apostrophePieces.contains(tokens[index].piece) {
                    current.append(tokens[index])
                    index += 1
                }
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }

        let bounded = runs.flatMap { chunkEvenly($0, limit: limit) }

        var merged: [[IndexTTS2Token]] = []
        for run in bounded {
            if let last = merged.last, last.count + run.count <= limit {
                merged[merged.count - 1] = last + run
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// Cuts a run longer than `limit` into near-equal chunks, moving each cut
    /// back to the nearest word start (a `▁`-prefixed piece) when that keeps
    /// the chunk at least half the target size.
    private static func chunkEvenly(_ run: [IndexTTS2Token], limit: Int) -> [[IndexTTS2Token]] {
        guard run.count > limit else { return [run] }
        let chunkCount = (run.count + limit - 1) / limit
        let target = (run.count + chunkCount - 1) / chunkCount

        var chunks: [[IndexTTS2Token]] = []
        var start = 0
        while start < run.count {
            var end = min(start + target, run.count)
            if end < run.count {
                var boundary = end
                while boundary > start + target / 2, !run[boundary].piece.hasPrefix("▁") {
                    boundary -= 1
                }
                if boundary > start { end = boundary }
            }
            chunks.append(Array(run[start..<end]))
            start = end
        }
        return chunks
    }
}
