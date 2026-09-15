import Foundation

/// A single keyword emission from the streaming decoder.
public struct KeywordDetection: Sendable, Equatable {
    /// Human-readable phrase (e.g. "hey soniqo").
    public let phrase: String
    /// BPE token ids that matched the phrase.
    public let tokenIds: [Int]
    /// Encoder frame indices the tokens were emitted at (40 ms / frame).
    public let timestamps: [Int]
    /// Encoder frame index at which the emission fired.
    ///
    /// This index is local to the decoder's current search epoch and can
    /// restart after an automatic reset or a keyword emission. Use
    /// ``streamFrameIndex`` for a position in a ``WakeWordSession`` stream.
    public let frameIndex: Int
    /// Monotonic encoder-frame index in the enclosing ``WakeWordSession``.
    ///
    /// Direct ``StreamingKwsDecoder`` use has no session clock and leaves this
    /// value nil.
    public let streamFrameIndex: Int?
    /// Session-relative encoder-frame indices for the matched BPE tokens.
    /// Direct ``StreamingKwsDecoder`` use leaves this value nil.
    public let streamTimestamps: [Int]?

    public init(
        phrase: String,
        tokenIds: [Int],
        timestamps: [Int],
        frameIndex: Int,
        streamFrameIndex: Int? = nil,
        streamTimestamps: [Int]? = nil
    ) {
        self.phrase = phrase
        self.tokenIds = tokenIds
        self.timestamps = timestamps
        self.frameIndex = frameIndex
        self.streamFrameIndex = streamFrameIndex
        self.streamTimestamps = streamTimestamps
    }

    /// Decoder-local detection time in seconds, given a ``frameShiftSeconds``.
    public func time(frameShiftSeconds: Double) -> Double {
        Double(frameIndex) * frameShiftSeconds
    }

    /// Detection time relative to the start of the enclosing session.
    public func streamTime(frameShiftSeconds: Double) -> Double? {
        streamFrameIndex.map { Double($0) * frameShiftSeconds }
    }
}

/// Port of ``kws_decoder.StreamingKwsDecoder`` — single-stream modified beam
/// search over a stateless transducer, with an Aho-Corasick ``ContextGraph``
/// boosting registered keywords.
///
/// The backend is abstract: the caller supplies ``decoderFn`` and ``joinerFn``
/// closures so the same decoder can drive CoreML, PyTorch reference, or a
/// stubbed backend in tests.
public final class StreamingKwsDecoder {
    public typealias DecoderFn = ([Int]) -> [Float]
    public typealias JoinerFn = ([Float], [Float]) -> [Float]

    /// One acoustic expansion considered for the next beam. ``insertionOrder``
    /// freezes the old full-sort behavior for equal scores: candidates were
    /// enumerated by hypothesis and then token, so an earlier candidate wins a
    /// boundary tie deterministically.
    struct Candidate: Equatable {
        let totalLogProb: Double
        let hypIndex: Int
        let token: Int
        let tokenProb: Double
        let insertionOrder: Int
    }

    public let contextGraph: ContextGraph
    public let blankId: Int
    public let unkId: Int
    public let contextSize: Int
    public let beam: Int
    public let numTrailingBlanks: Int
    public let blankPenalty: Float
    public let frameShiftSeconds: Double
    public let autoResetFrames: Int

    private let decoderFn: DecoderFn
    private let joinerFn: JoinerFn

    private var decCache: [[Int]: [Float]] = [:]
    private(set) var beamList: [Hypothesis] = []
    private var t: Int = 0
    private var framesSinceEmission: Int = 0

    public init(
        decoderFn: @escaping DecoderFn,
        joinerFn: @escaping JoinerFn,
        contextGraph: ContextGraph,
        blankId: Int = 0,
        unkId: Int? = nil,
        contextSize: Int = 2,
        beam: Int = 4,
        numTrailingBlanks: Int = 1,
        blankPenalty: Float = 0,
        frameShiftSeconds: Double = 0.04,
        autoResetSeconds: Double = 1.5
    ) {
        self.decoderFn = decoderFn
        self.joinerFn = joinerFn
        self.contextGraph = contextGraph
        self.blankId = blankId
        self.unkId = unkId ?? blankId
        self.contextSize = contextSize
        // WakeWordDecodingOptions rejects out-of-range values before this
        // lower-level decoder is built. Clamp direct construction as a final
        // guard against pathological allocations or model-call counts.
        self.beam = min(
            max(beam, WakeWordDecodingOptions.supportedBeamRange.lowerBound),
            WakeWordDecodingOptions.supportedBeamRange.upperBound
        )
        self.numTrailingBlanks = numTrailingBlanks
        self.blankPenalty = blankPenalty
        self.frameShiftSeconds = frameShiftSeconds
        self.autoResetFrames = Self.safeAutoResetFrameCount(
            seconds: autoResetSeconds,
            frameShiftSeconds: frameShiftSeconds
        )
        reset()
    }

    // MARK: - Hypothesis

    public struct Hypothesis {
        public var ys: [Int]
        public var logProb: Double
        public var acProbs: [Double]
        public var timestamps: [Int]
        public var contextState: ContextGraph.State
        public var numTailingBlanks: Int

        public var key: String {
            // Reuse the same dict-key scheme as upstream: join ys with `_`.
            return ys.map(String.init).joined(separator: "_")
        }
    }

    // MARK: - state management

    public func reset() {
        t = 0
        framesSinceEmission = 0
        decCache.removeAll(keepingCapacity: true)
        let initYs = Array(repeating: -1, count: max(contextSize - 1, 0)) + [blankId]
        beamList = [
            Hypothesis(
                ys: initYs,
                logProb: 0,
                acProbs: [],
                timestamps: [],
                contextState: contextGraph.root,
                numTailingBlanks: 0
            )
        ]
    }

    /// Advance one encoder output frame (already in joiner space).
    public func step(encoderFrame: [Float]) -> [KeywordDetection] {
        var emissions: [KeywordDetection] = []

        // Expand the beam while retaining only the global top B candidates.
        // The former implementation materialized beam*vocab candidates and
        // fully sorted them even though only B were consumed. With the shipped
        // vocabulary that meant sorting up to 8,000 values per encoder frame
        // at beam 16. This bounded list has identical ranking semantics and
        // stores at most B values.
        var topCandidates: [Candidate] = []
        topCandidates.reserveCapacity(beam)
        var insertionOrder = 0

        for (i, hyp) in beamList.enumerated() {
            let decOut = decoderFor(hyp.ys)
            var logits = joinerFn(encoderFrame, decOut)
            if blankPenalty != 0, blankId < logits.count {
                logits[blankId] -= blankPenalty
            }
            let (logProbs, probs) = Self.logSoftmax(logits)
            for token in 0..<logProbs.count {
                Self.retainTopCandidate(
                    Candidate(
                        totalLogProb: hyp.logProb + Double(logProbs[token]),
                        hypIndex: i,
                        token: token,
                        tokenProb: Double(probs[token]),
                        insertionOrder: insertionOrder
                    ),
                    in: &topCandidates,
                    limit: beam
                )
                insertionOrder += 1
            }
        }

        var nextBeam: [String: Hypothesis] = [:]
        for cand in topCandidates {
            var hyp = beamList[cand.hypIndex]
            hyp.numTailingBlanks += 1

            var contextScore: Double = 0
            if cand.token != blankId && cand.token != unkId {
                hyp.ys.append(cand.token)
                hyp.timestamps.append(t)
                hyp.acProbs.append(cand.tokenProb)
                let (boost, next, _) = contextGraph.forwardOneStep(
                    from: hyp.contextState, token: cand.token
                )
                contextScore = boost
                hyp.contextState = next
                hyp.numTailingBlanks = 0
                if next.token == -1 {
                    // Rewind BPE prefix back to initial when we drop back to root.
                    let tail = hyp.ys.suffix(contextSize)
                    let replacement =
                        Array(repeating: -1, count: max(contextSize - 1, 0)) + [blankId]
                    hyp.ys.removeLast(tail.count)
                    hyp.ys.append(contentsOf: replacement)
                }
            }
            hyp.logProb = cand.totalLogProb + contextScore

            let key = hyp.key
            if var existing = nextBeam[key] {
                existing.logProb = Self.logAddExp(existing.logProb, hyp.logProb)
                nextBeam[key] = existing
            } else {
                nextBeam[key] = hyp
            }
        }
        beamList = Array(nextBeam.values)

        // Check emission on most-probable hypothesis (length-normalized).
        let top = beamList.max { a, b in
            let an = a.logProb / Double(max(a.ys.count, 1))
            let bn = b.logProb / Double(max(b.ys.count, 1))
            return an < bn
        }

        if let top, let matched = contextGraph.isMatched(top.contextState).state {
            let level = matched.level
            if level > 0 && top.acProbs.count >= level {
                let window = top.acProbs.suffix(level)
                let acProb = window.reduce(0, +) / Double(level)
                if top.numTailingBlanks > numTrailingBlanks && acProb >= matched.acThreshold {
                    let tokens = Array(top.ys.suffix(level))
                    let timestamps = Array(top.timestamps.suffix(level))
                    emissions.append(
                        KeywordDetection(
                            phrase: matched.phrase,
                            tokenIds: tokens,
                            timestamps: timestamps,
                            frameIndex: t
                        )
                    )
                    reset()
                    t += 1
                    framesSinceEmission = 0
                    return emissions
                }
            }
        }

        t += 1
        if emissions.isEmpty {
            framesSinceEmission += 1
            if framesSinceEmission >= autoResetFrames {
                reset()
            }
        } else {
            framesSinceEmission = 0
        }
        return emissions
    }

    /// Convenience: iterate across a chunk of encoder frames ``[numFrames][joinerDim]``.
    public func stepChunk(_ frames: [[Float]]) -> [KeywordDetection] {
        var out: [KeywordDetection] = []
        for frame in frames {
            out.append(contentsOf: step(encoderFrame: frame))
        }
        return out
    }

    // MARK: - helpers

    /// Total ordering used by the bounded selector. Acoustic score remains the
    /// primary key. The secondary key only resolves exact ties and preserves
    /// the candidate enumeration order used by the previous full sort.
    static func candidateRanksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.totalLogProb != rhs.totalLogProb {
            return lhs.totalLogProb > rhs.totalLogProb
        }
        return lhs.insertionOrder < rhs.insertionOrder
    }

    /// Insert one value into an already-ranked bounded list. The list never
    /// grows beyond ``limit`` and therefore avoids allocating or sorting the
    /// discarded vocabulary expansions.
    static func retainTopCandidate(
        _ candidate: Candidate,
        in candidates: inout [Candidate],
        limit: Int
    ) {
        guard limit > 0 else { return }
        if candidates.count == limit,
           let last = candidates.last,
           !candidateRanksBefore(candidate, last) {
            return
        }

        var lower = 0
        var upper = candidates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if candidateRanksBefore(candidate, candidates[middle]) {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        candidates.insert(candidate, at: lower)
        if candidates.count > limit {
            candidates.removeLast()
        }
    }

    /// Testable convenience that exercises the same streaming retention path
    /// as ``step(encoderFrame:)`` without requiring Core ML models.
    static func boundedTopCandidates(_ input: [Candidate], limit: Int) -> [Candidate] {
        var result: [Candidate] = []
        result.reserveCapacity(max(0, limit))
        for candidate in input {
            retainTopCandidate(candidate, in: &result, limit: limit)
        }
        return result
    }

    private func decoderFor(_ ys: [Int]) -> [Float] {
        let ctx = Array(ys.suffix(contextSize))
        if let cached = decCache[ctx] { return cached }
        let value = decoderFn(ctx)
        decCache[ctx] = value
        return value
    }

    static func logAddExp(_ a: Double, _ b: Double) -> Double {
        if a == -Double.infinity { return b }
        if b == -Double.infinity { return a }
        let m = max(a, b)
        return m + log1p(exp(-abs(a - b)))
    }

    /// Convert a duration to frames without allowing a finite but enormous
    /// Double to trap during Int conversion. Session-facing options are
    /// rejected above the documented maximum; this saturation protects direct
    /// construction of the lower-level decoder as well.
    static func safeAutoResetFrameCount(
        seconds: Double,
        frameShiftSeconds: Double
    ) -> Int {
        guard seconds.isFinite, seconds > 0,
              frameShiftSeconds.isFinite, frameShiftSeconds > 0 else {
            return 1
        }
        let rounded = (seconds / frameShiftSeconds).rounded()
        guard rounded.isFinite, rounded < Double(Int.max) else {
            return Int.max
        }
        return max(1, Int(rounded))
    }

    static func logSoftmax(_ logits: [Float]) -> (log: [Float], prob: [Float]) {
        guard !logits.isEmpty else { return ([], []) }
        let m = logits.max() ?? 0
        var exps = [Float](repeating: 0, count: logits.count)
        var s: Float = 0
        for i in 0..<logits.count {
            let e = Foundation.exp(logits[i] - m)
            exps[i] = e
            s += e
        }
        var logs = [Float](repeating: 0, count: logits.count)
        var probs = [Float](repeating: 0, count: logits.count)
        for i in 0..<logits.count {
            let p = exps[i] / s
            probs[i] = p
            logs[i] = p > 0 ? Foundation.log(p) : -.infinity
        }
        return (logs, probs)
    }
}
