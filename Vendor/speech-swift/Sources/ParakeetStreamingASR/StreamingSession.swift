import CoreML
import Foundation
import AudioCommon

/// A streaming ASR session that processes audio chunks incrementally.
///
/// Maintains encoder cache state and LSTM decoder state between chunks.
/// Emits partial transcripts as tokens are decoded, and detects end-of-utterance
/// via the `<EOU>` token from the RNNT joint network.
public class StreamingSession {
    private let config: ParakeetEOUConfig
    private let encoder: MLModel
    private let decoder: MLModel
    private let joint: MLModel
    private let vocabulary: ParakeetEOUVocabulary
    private let melPreprocessor: StreamingMelPreprocessor
    private let rnntDecoder: RNNTGreedyDecoder

    // Encoder cache state
    private var cacheLastChannel: MLMultiArray
    private var cacheLastTime: MLMultiArray
    private var cacheLastChannelLen: MLMultiArray
    // Pre-encode mel cache as separate model I/O (loopback architecture)
    private var preCache: MLMultiArray

    // Decoder LSTM state
    private var h: MLMultiArray
    private var c: MLMultiArray
    private var decoderOutput: MLMultiArray

    // Pre-allocated buffers
    private let tokenArray: MLMultiArray
    private let encSlice: MLMultiArray
    private let argmaxBuf: UnsafeMutablePointer<Float>
    private let decoderProvider: ReusableFeatureProvider
    private let jointProvider: ReusableFeatureProvider

    // Accumulated state
    private var allTokens: [Int] = []
    private var allLogProbs: [Float] = []
    private var segmentIndex: Int = 0
    private var eouDetected = false
    private var sampleBuffer: [Float] = []
    private var eouTokenOffset: Int = 0  // Token index where last EOU fired
    private var lastEmittedFinalText: String = ""

    // EOU debouncing — match FluidAudio: require sustained EOU before firing
    public var eouDebounceMs: Int = 1280
    private var eouFirstDetectedAtSamples: Int? = nil
    private var totalSamplesProcessed: Int = 0

    init(
        config: ParakeetEOUConfig,
        encoder: MLModel,
        decoder: MLModel,
        joint: MLModel,
        vocabulary: ParakeetEOUVocabulary,
        melPreprocessor: StreamingMelPreprocessor
    ) throws {
        self.config = config
        self.encoder = encoder
        self.decoder = decoder
        self.joint = joint
        self.vocabulary = vocabulary
        self.melPreprocessor = melPreprocessor
        self.rnntDecoder = RNNTGreedyDecoder(config: config, decoder: decoder, joint: joint)

        // Initialize encoder caches to zero
        let layers = config.encoderLayers
        let hidden = config.encoderHidden
        let attCtx = config.attentionContext
        let convCache = config.convCacheSize
        let preCacheSize = config.streaming.preCacheSize
        let numMelBins = config.numMelBins

        // Pre-encode mel cache as MLMultiArray (loopback model I/O)
        preCache = try MLMultiArray(
            shape: [1, numMelBins as NSNumber, preCacheSize as NSNumber], dataType: .float32)
        memset(preCache.dataPointer, 0, numMelBins * preCacheSize * MemoryLayout<Float>.stride)

        cacheLastChannel = try MLMultiArray(
            shape: [layers, 1, attCtx, hidden] as [NSNumber], dataType: .float32)
        cacheLastTime = try MLMultiArray(
            shape: [layers, 1, hidden, convCache] as [NSNumber], dataType: .float32)
        cacheLastChannelLen = try MLMultiArray(shape: [1], dataType: .int32)
        memset(cacheLastChannel.dataPointer, 0,
               layers * 1 * attCtx * hidden * MemoryLayout<Float>.stride)
        memset(cacheLastTime.dataPointer, 0,
               layers * 1 * hidden * convCache * MemoryLayout<Float>.stride)
        cacheLastChannelLen[0] = NSNumber(value: Int32(0))

        // Initialize LSTM state. New model uses fp32 inputs but fp16 outputs.
        // We allocate fp32 for inputs; outputs come back as fp16 MLMultiArrays
        // and we re-cast to fp32 buffers before the next decoder call.
        let decLayers = config.decoderLayers
        let decHidden = config.decoderHidden

        h = try MLMultiArray(shape: [decLayers, 1, decHidden] as [NSNumber], dataType: .float32)
        c = try MLMultiArray(shape: [decLayers, 1, decHidden] as [NSNumber], dataType: .float32)
        memset(h.dataPointer, 0, decLayers * decHidden * MemoryLayout<Float>.stride)
        memset(c.dataPointer, 0, decLayers * decHidden * MemoryLayout<Float>.stride)

        // Decoder output buffer (fp32, will be filled from fp16 model output)
        decoderOutput = try MLMultiArray(
            shape: [1, 1, decHidden as NSNumber], dataType: .float32)
        memset(decoderOutput.dataPointer, 0, decHidden * MemoryLayout<Float>.stride)

        // Prime decoder with blank token
        tokenArray = try MLMultiArray(shape: [1, 1], dataType: .int32)
        let tokenPtr = tokenArray.dataPointer.assumingMemoryBound(to: Int32.self)
        tokenPtr.pointee = Int32(config.blankTokenId)

        decoderProvider = ReusableFeatureProvider(["token": tokenArray, "h": h, "c": c])
        let initOut = try decoder.prediction(from: decoderProvider)
        Self.copyCastFP16ToFP32(initOut.featureValue(for: "decoder_output")!.multiArrayValue!,
                                into: decoderOutput)
        Self.copyCastFP16ToFP32(initOut.featureValue(for: "h_out")!.multiArrayValue!, into: h)
        Self.copyCastFP16ToFP32(initOut.featureValue(for: "c_out")!.multiArrayValue!, into: c)

        // Encoder slice for joint input — fp32 [1, 1, encoderHidden]
        encSlice = try MLMultiArray(shape: [1, 1, hidden as NSNumber], dataType: .float32)
        jointProvider = ReusableFeatureProvider([
            "encoder_output": encSlice, "decoder_output": decoderOutput,
        ])

        // Argmax buffer
        argmaxBuf = .allocate(capacity: config.vocabSize + 1)
    }

    deinit {
        argmaxBuf.deallocate()
    }

    /// Sample rate accepted by the incremental session.
    public var inputSampleRate: Int { config.sampleRate }

    // MARK: - Push Audio

    /// Push a chunk of audio samples and get any new partial transcripts.
    ///
    /// Samples are buffered internally. When enough samples accumulate for a
    /// full mel chunk, the encoder and decoder run and partial results are returned.
    public func pushAudio(_ samples: [Float]) throws -> [ParakeetStreamingASRModel.PartialTranscript] {

        sampleBuffer.append(contentsOf: samples)

        // Cache-aware streaming with audio overlap.
        // The encoder consumes melFrames mel frames per chunk but only the first
        // outputFrames output frames (after subsampling) correspond to NEW audio.
        // The shift between chunks must equal `outputFrames * subsamplingFactor`
        // mel frames (in samples) to avoid duplication and gaps.
        let samplesPerChunk = config.streaming.melFrames * config.hopLength
        let shiftMelFrames = config.streaming.outputFrames * config.subsamplingFactor
        let shiftSamples = shiftMelFrames * config.hopLength
        var results: [ParakeetStreamingASRModel.PartialTranscript] = []

        while sampleBuffer.count >= samplesPerChunk {
            let chunk = Array(sampleBuffer.prefix(samplesPerChunk))
            let drop = min(shiftSamples, sampleBuffer.count)
            sampleBuffer.removeFirst(drop)

            let partial = try processChunk(chunk)
            if let partial { results.append(partial) }

            if eouDetected { break }
        }

        return results
    }

    /// Force-emit a final transcript for the current utterance and continue
    /// the session. Used when an external signal (e.g. VAD silence) indicates
    /// end-of-utterance before the joint's EOU head has fired.
    ///
    /// Keeps encoder cache and decoder LSTM state intact so the next utterance
    /// continues streaming without reinitialization.
    public func forceEndOfUtterance() -> ParakeetStreamingASRModel.PartialTranscript? {
        let pendingTokens = Array(allTokens[eouTokenOffset...])
        let pendingLogProbs = Array(allLogProbs[eouTokenOffset...])

        // Advance segment/offset regardless so stale EOU state is cleared.
        eouTokenOffset = allTokens.count
        eouDetected = false
        eouFirstDetectedAtSamples = nil

        guard !pendingTokens.isEmpty else { return nil }
        let text = vocabulary.decode(pendingTokens)
        if text.isEmpty { return nil }
        // Don't dedupe against lastEmittedFinalText here — the caller has
        // signaled a new utterance boundary (e.g. via VAD), so identical
        // text across different utterances is legitimate and must be emitted.
        // Still update the field so subsequent same-chunk duplicates in the
        // normal EOU path don't re-emit.

        let confidence: Float
        if !pendingLogProbs.isEmpty {
            let mean = pendingLogProbs.reduce(0, +) / Float(pendingLogProbs.count)
            confidence = min(1.0, exp(mean))
        } else {
            confidence = 0
        }
        let emittedSegment = segmentIndex
        segmentIndex += 1
        lastEmittedFinalText = text
        return ParakeetStreamingASRModel.PartialTranscript(
            text: text,
            isFinal: true,
            confidence: confidence,
            eouDetected: true,
            segmentIndex: emittedSegment
        )
    }

    /// Signal end of audio stream and return any remaining transcription.
    public func finalize() throws -> [ParakeetStreamingASRModel.PartialTranscript] {
        // Process remaining buffered samples (a single trailing chunk).
        if !sampleBuffer.isEmpty && !eouDetected {
            let samplesPerChunk = config.streaming.melFrames * config.hopLength
            let padded = sampleBuffer + [Float](repeating: 0, count: max(0, samplesPerChunk - sampleBuffer.count))
            sampleBuffer.removeAll()
            _ = try processChunk(Array(padded.prefix(samplesPerChunk)))
        }

        // Emit a single final transcript covering everything since the last EOU.
        // Tokens before eouTokenOffset were already returned in a prior final partial.
        let pendingTokens = Array(allTokens[eouTokenOffset...])
        let pendingLogProbs = Array(allLogProbs[eouTokenOffset...])
        guard !pendingTokens.isEmpty else { return [] }

        let text = vocabulary.decode(pendingTokens)
        let confidence: Float
        if !pendingLogProbs.isEmpty {
            let mean = pendingLogProbs.reduce(0, +) / Float(pendingLogProbs.count)
            confidence = min(1.0, exp(mean))
        } else {
            confidence = 0
        }
        return [ParakeetStreamingASRModel.PartialTranscript(
            text: text,
            isFinal: true,
            confidence: confidence,
            eouDetected: eouDetected,
            segmentIndex: segmentIndex
        )]
    }

    // MARK: - Internal

    /// Whether to use running normalization (true for streaming, false for batch).
    public var useRunningNormalization = true

    /// Number of mel frames accumulated for running normalization.
    public var melRunningCount: Int { melPreprocessor.runningCount }

    private func processChunk(_ audio: [Float]) throws -> ParakeetStreamingASRModel.PartialTranscript? {
        // Extract mel — no normalization for streaming (model trained with normalize: "NA")
        let (rawMel, melLength): (MLMultiArray, Int)
        if useRunningNormalization {
            (rawMel, melLength) = try melPreprocessor.extractRaw(audio)
        } else {
            (rawMel, melLength) = try melPreprocessor.extract(audio)
        }
        guard melLength > 0 else { return nil }

        // Truncate/pad chunk mel to exact expected frame count
        let expectedFrames = config.streaming.melFrames
        let actualMelFrames = rawMel.shape[2].intValue
        let chunkMel: MLMultiArray
        if actualMelFrames > expectedFrames {
            chunkMel = try truncateMel(rawMel, to: expectedFrames)
        } else if actualMelFrames < expectedFrames {
            chunkMel = try padMel(rawMel, actualLength: actualMelFrames, targetLength: expectedFrames)
        } else {
            chunkMel = rawMel
        }

        // Run cache-aware encoder — loopback architecture takes pre_cache as a
        // separate input and returns new_pre_cache to feed back next chunk.
        let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: chunkMel),
            "audio_length": MLFeatureValue(multiArray: makeInt32Array(value: Int32(expectedFrames))),
            "pre_cache": MLFeatureValue(multiArray: preCache),
            "cache_last_channel": MLFeatureValue(multiArray: cacheLastChannel),
            "cache_last_time": MLFeatureValue(multiArray: cacheLastTime),
            "cache_last_channel_len": MLFeatureValue(multiArray: cacheLastChannelLen),
        ])

        let encoderOutput = try encoder.prediction(from: encoderInput)

        let encoded = encoderOutput.featureValue(for: "encoded_output")!.multiArrayValue!
        let reportedLength = encoderOutput.featureValue(for: "encoded_length")!.multiArrayValue![0].intValue
        // Encoder output is [B, T, D] — frame count is shape[1].
        // Take the first `outputFrames` frames; the rest are future-context overlap.
        let actualFrames = encoded.shape[1].intValue
        let totalFrames = min(reportedLength, actualFrames)
        let encodedLength = min(config.streaming.outputFrames, totalFrames)
        let frameOffset = 0

        // Update encoder caches (including new_pre_cache for next iteration)
        preCache = encoderOutput.featureValue(for: "new_pre_cache")!.multiArrayValue!
        cacheLastChannel = encoderOutput.featureValue(for: "new_cache_last_channel")!.multiArrayValue!
        cacheLastTime = encoderOutput.featureValue(for: "new_cache_last_time")!.multiArrayValue!
        cacheLastChannelLen = encoderOutput.featureValue(for: "new_cache_last_channel_len")!.multiArrayValue!

        AudioLog.inference.debug("EOU encoder: encodedLength=\(encodedLength), shape=\(encoded.shape)")

        guard encodedLength > 0 else { return nil }

        // RNNT greedy decode
        let result = try rnntDecoder.decode(
            encoded: encoded,
            encodedLength: encodedLength,
            frameOffset: frameOffset,
            h: &h,
            c: &c,
            decoderOutput: &decoderOutput,
            decoderProvider: decoderProvider,
            jointProvider: jointProvider,
            tokenArray: tokenArray,
            encSlice: encSlice,
            argmaxBuf: argmaxBuf
        )

        allTokens.append(contentsOf: result.tokens)
        allLogProbs.append(contentsOf: result.tokenLogProbs)

        // EOU debounce: require sustained EOU silence before firing.
        // If new tokens were emitted, speech is ongoing — reset the timer.
        // Otherwise, start the timer on first EOU and confirm after eouDebounceMs.
        totalSamplesProcessed += audio.count
        if result.eouDetected {
            if !result.tokens.isEmpty {
                eouFirstDetectedAtSamples = nil
            } else if eouFirstDetectedAtSamples == nil {
                eouFirstDetectedAtSamples = totalSamplesProcessed
            }
            if let firstAt = eouFirstDetectedAtSamples {
                let elapsedMs = ((totalSamplesProcessed - firstAt) * 1000) / config.sampleRate
                AudioLog.inference.debug("EOU candidate: elapsed=\(elapsedMs)ms (need \(self.eouDebounceMs)ms)")
                if elapsedMs >= eouDebounceMs {
                    eouDetected = true
                    AudioLog.inference.info("EOU CONFIRMED after \(elapsedMs)ms silence")
                }
            }
        } else {
            eouFirstDetectedAtSamples = nil
        }

        // Decode only tokens since last EOU boundary
        let currentTokens = Array(allTokens[eouTokenOffset...])
        let currentLogProbs = Array(allLogProbs[eouTokenOffset...])
        let text = vocabulary.decode(currentTokens)
        if text.isEmpty {
            // Nothing to emit. If EOU fired during silence with no pending text,
            // consume it here so a stale flag doesn't prematurely finalize the
            // next utterance's first tokens.
            if eouDetected {
                eouTokenOffset = allTokens.count
                segmentIndex += 1
                eouDetected = false
                eouFirstDetectedAtSamples = nil
            }
            return nil
        }

        let confidence: Float
        if !currentLogProbs.isEmpty {
            let mean = currentLogProbs.reduce(0, +) / Float(currentLogProbs.count)
            confidence = min(1.0, exp(mean))
        } else {
            confidence = 0
        }

        if eouDetected {
            // Always advance offset/segment so future partials are scoped to the
            // new utterance, but suppress consecutive duplicate finals (model
            // re-emitting the same content from overlapping audio chunks).
            eouTokenOffset = allTokens.count
            segmentIndex += 1
            eouDetected = false
            if text == lastEmittedFinalText { return nil }
            lastEmittedFinalText = text
            return ParakeetStreamingASRModel.PartialTranscript(
                text: text,
                isFinal: true,
                confidence: confidence,
                eouDetected: true,
                segmentIndex: segmentIndex - 1
            )
        }

        // Suppress duplicate partials — only emit if text changed
        // (avoids flooding UI with identical partials during silence)

        return ParakeetStreamingASRModel.PartialTranscript(
            text: text,
            isFinal: false,
            confidence: confidence,
            eouDetected: false,
            segmentIndex: segmentIndex
        )
    }

    private func makeInt32Array(value: Int32) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1], dataType: .int32)
        array[0] = NSNumber(value: value)
        return array
    }

    /// Copy fp16 model output into a fp32 input buffer (in place).
    static func copyCastFP16ToFP32(_ src: MLMultiArray, into dst: MLMultiArray) {
        let count = src.count
        let srcPtr = src.dataPointer.assumingMemoryBound(to: Float16.self)
        let dstPtr = dst.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<count { dstPtr[i] = Float(srcPtr[i]) }
    }

    /// Truncate mel to exactly `targetFrames` frames.
    private func truncateMel(_ mel: MLMultiArray, to targetFrames: Int) throws -> MLMultiArray {
        let numMelBins = config.numMelBins
        let stride = mel.dataType == .float16 ? MemoryLayout<Float16>.stride : MemoryLayout<Float>.stride
        let truncated = try MLMultiArray(
            shape: [1, numMelBins as NSNumber, targetFrames as NSNumber], dataType: mel.dataType)
        let actualFrames = mel.shape[2].intValue
        for bin in 0..<numMelBins {
            let srcOffset = bin * actualFrames * stride
            let dstOffset = bin * targetFrames * stride
            memcpy(truncated.dataPointer.advanced(by: dstOffset),
                   mel.dataPointer.advanced(by: srcOffset),
                   targetFrames * stride)
        }
        return truncated
    }

    /// Pad mel to `targetLength` frames with zeros.
    private func padMel(_ mel: MLMultiArray, actualLength: Int, targetLength: Int) throws -> MLMultiArray {
        let numMelBins = config.numMelBins
        let stride = mel.dataType == .float16 ? MemoryLayout<Float16>.stride : MemoryLayout<Float>.stride
        let padded = try MLMultiArray(
            shape: [1, numMelBins as NSNumber, targetLength as NSNumber], dataType: mel.dataType)
        for bin in 0..<numMelBins {
            let srcOffset = bin * actualLength * stride
            let dstOffset = bin * targetLength * stride
            memcpy(padded.dataPointer.advanced(by: dstOffset),
                   mel.dataPointer.advanced(by: srcOffset),
                   actualLength * stride)
            memset(padded.dataPointer.advanced(by: dstOffset + actualLength * stride), 0,
                   (targetLength - actualLength) * stride)
        }
        return padded
    }
}

extension StreamingSession: StreamingRecognitionSession {
    public func push(_ chunk: CapturedAudioChunk) throws -> [StreamingRecognitionUpdate] {
        guard chunk.sampleRate == inputSampleRate else {
            throw StreamingRecognitionError.sampleRateMismatch(
                expected: inputSampleRate, actual: chunk.sampleRate)
        }
        return try pushAudio(chunk.samples).map {
            StreamingRecognitionUpdate(
                text: $0.text,
                isFinal: $0.isFinal,
                endOfUtterance: $0.eouDetected,
                segmentIndex: $0.segmentIndex,
                confidence: $0.confidence)
        }
    }

    public func finish() throws -> [StreamingRecognitionUpdate] {
        try finalize().map {
            StreamingRecognitionUpdate(
                text: $0.text,
                isFinal: $0.isFinal,
                endOfUtterance: $0.eouDetected,
                segmentIndex: $0.segmentIndex,
                confidence: $0.confidence)
        }
    }
}
