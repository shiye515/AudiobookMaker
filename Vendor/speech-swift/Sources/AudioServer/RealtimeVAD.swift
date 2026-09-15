import AudioCommon
import AVFoundation
import Foundation
import SpeechVAD

/// OpenAI-compatible server VAD controls plus a hard safety bound for a
/// continuously voiced turn.
struct RealtimeTurnDetectionConfig: Sendable, Equatable {
    var threshold: Float = 0.5
    var prefixPaddingMilliseconds: Int = 300
    var silenceDurationMilliseconds: Int = 500
    var maxTurnDurationMilliseconds: Int = 120_000

    var vadConfig: VADConfig {
        VADConfig(
            onset: threshold,
            offset: max(0, threshold - 0.15),
            minSpeechDuration: 0.25,
            minSilenceDuration: Float(silenceDurationMilliseconds) / 1_000,
            windowDuration: 0.032,
            stepRatio: 1)
    }
}

enum RealtimeVADEvent: Sendable, Equatable {
    case speechStarted(audioStartMilliseconds: Int)
    case speechEnded(
        audioEndMilliseconds: Int,
        audio: [Float],
        forcedByDurationLimit: Bool)
}

/// Converts protocol-rate audio into fixed VAD frames and retains only bounded
/// pre-roll while idle. Speech audio is returned when the configured silence
/// closes a turn, so ASR is never invoked for silence-only input.
final class RealtimeVADController {
    private let provider: any StreamingVADProvider
    private let processor: StreamingVADProcessor
    private let config: RealtimeTurnDetectionConfig
    private let inputSampleRate: Int
    private let inputFramesPerVADChunk: Int
    private let historySampleCapacity: Int
    private let maxTurnSampleCount: Int
    private let resampler: AVAudioConverter?
    private let resamplerInputFormat: AVAudioFormat?
    private let resamplerOutputFormat: AVAudioFormat?

    private var pendingInput: [Float] = []
    private var retainedAudio: [Float] = []
    private var retainedStartSample: Int64 = 0
    private var processedInputSamples: Int64 = 0
    /// Absolute input position corresponding to processor time zero. This
    /// advances when a duration-limited turn resets the VAD state mid-stream.
    private var processorStartSample: Int64 = 0
    private var speechActive = false

    init(
        provider: any StreamingVADProvider,
        config: RealtimeTurnDetectionConfig,
        inputSampleRate: Int = 24_000
    ) throws {
        guard provider.inputSampleRate > 0, provider.chunkSize > 0,
              inputSampleRate > 0 else {
            throw RealtimeVADError.invalidSampleRate
        }

        self.provider = provider
        self.config = config
        self.inputSampleRate = inputSampleRate
        self.inputFramesPerVADChunk = max(1, Int(ceil(
            Double(provider.chunkSize) * Double(inputSampleRate)
                / Double(provider.inputSampleRate))))
        self.historySampleCapacity = max(
            inputFramesPerVADChunk,
            Int((Double(config.prefixPaddingMilliseconds) / 1_000
                + Double(config.vadConfig.minSpeechDuration))
                * Double(inputSampleRate)) + inputFramesPerVADChunk)
        self.maxTurnSampleCount = max(
            inputFramesPerVADChunk,
            config.maxTurnDurationMilliseconds * inputSampleRate / 1_000)
        if inputSampleRate == provider.inputSampleRate {
            self.resampler = nil
            self.resamplerInputFormat = nil
            self.resamplerOutputFormat = nil
        } else {
            guard let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(inputSampleRate),
                channels: 1,
                interleaved: false),
                  let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(provider.inputSampleRate),
                    channels: 1,
                    interleaved: false),
                  let converter = AVAudioConverter(
                    from: inputFormat,
                    to: outputFormat) else {
                throw RealtimeVADError.resamplerUnavailable(
                    inputSampleRate: inputSampleRate,
                    vadSampleRate: provider.inputSampleRate)
            }
            self.resampler = converter
            self.resamplerInputFormat = inputFormat
            self.resamplerOutputFormat = outputFormat
        }
        self.processor = StreamingVADProcessor(
            provider: provider,
            config: config.vadConfig)
    }

    /// Number of original-rate samples retained by the controller.
    var retainedSampleCount: Int { retainedAudio.count + pendingInput.count }

    /// Feed arbitrary-size mono chunks at the configured input rate.
    func push(_ samples: [Float]) throws -> [RealtimeVADEvent] {
        guard !samples.isEmpty else { return [] }
        pendingInput.append(contentsOf: samples)
        var emitted: [RealtimeVADEvent] = []
        var consumed = 0
        defer {
            if consumed > 0 {
                pendingInput.removeFirst(consumed)
            }
        }

        while pendingInput.count - consumed >= inputFramesPerVADChunk {
            let end = consumed + inputFramesPerVADChunk
            let sourceChunk = Array(pendingInput[consumed..<end])
            let vadSamples = try samplesForVAD(sourceChunk)
            consumed = end
            retainedAudio.append(contentsOf: sourceChunk)
            processedInputSamples += Int64(sourceChunk.count)

            let events = processor.process(samples: vadSamples)
            for event in events {
                emitted.append(contentsOf: handle(event))
            }

            if speechActive, retainedAudio.count >= maxTurnSampleCount {
                let endMilliseconds = milliseconds(forInputSample: processedInputSamples)
                let audio = retainedAudio
                keepTrailingHistory()
                speechActive = false
                processor.reset()
                processorStartSample = processedInputSamples
                emitted.append(.speechEnded(
                    audioEndMilliseconds: endMilliseconds,
                    audio: audio,
                    forcedByDurationLimit: true))
            } else if !speechActive {
                capIdleHistory()
            }
        }
        return emitted
    }

    /// Return currently buffered protocol audio for an explicit client commit.
    /// In server-VAD mode idle silence is intentionally limited to the pre-roll
    /// window; an active speech turn is returned in full.
    func takeBufferedAudio() -> [Float] {
        var audio = retainedAudio
        audio.append(contentsOf: pendingInput)
        reset()
        return audio
    }

    func reset() {
        pendingInput.removeAll(keepingCapacity: false)
        retainedAudio.removeAll(keepingCapacity: false)
        retainedStartSample = 0
        processedInputSamples = 0
        processorStartSample = 0
        speechActive = false
        processor.reset()
        resampler?.reset()
    }

    private func handle(_ event: VADEvent) -> [RealtimeVADEvent] {
        switch event {
        case .speechStarted(let time):
            let onsetSample = processorStartSample
                + Int64(Double(time) * Double(inputSampleRate))
            let prefixSamples = Int64(
                config.prefixPaddingMilliseconds * inputSampleRate / 1_000)
            let audioStart = max(0, onsetSample - prefixSamples)
            trimRetained(before: audioStart)
            speechActive = true
            return [.speechStarted(
                audioStartMilliseconds: milliseconds(forInputSample: audioStart))]

        case .speechEnded(let segment):
            guard speechActive else { return [] }
            let speechEndSample = processorStartSample
                + Int64(Double(segment.endTime) * Double(inputSampleRate))
            let availableEnd = retainedStartSample + Int64(retainedAudio.count)
            let utteranceEnd = min(max(speechEndSample, retainedStartSample), availableEnd)
            let utteranceCount = Int(utteranceEnd - retainedStartSample)
            let audio = Array(retainedAudio.prefix(utteranceCount))
            keepTrailingHistory()
            speechActive = false
            return [.speechEnded(
                audioEndMilliseconds: milliseconds(forInputSample: speechEndSample),
                audio: audio,
                forcedByDurationLimit: false)]
        }
    }

    private func trimRetained(before absoluteSample: Int64) {
        let drop = min(
            retainedAudio.count,
            max(0, Int(absoluteSample - retainedStartSample)))
        if drop > 0 {
            retainedAudio.removeFirst(drop)
            retainedStartSample += Int64(drop)
        }
    }

    private func capIdleHistory() {
        guard retainedAudio.count > historySampleCapacity else { return }
        let drop = retainedAudio.count - historySampleCapacity
        retainedAudio.removeFirst(drop)
        retainedStartSample += Int64(drop)
    }

    private func keepTrailingHistory() {
        if retainedAudio.count > historySampleCapacity {
            retainedAudio = Array(retainedAudio.suffix(historySampleCapacity))
        }
        retainedStartSample = processedInputSamples - Int64(retainedAudio.count)
    }

    private func milliseconds(forInputSample sample: Int64) -> Int {
        Int((Double(sample) / Double(inputSampleRate) * 1_000).rounded())
    }

    /// Resample without resetting filter/carry state between protocol chunks.
    private func samplesForVAD(_ samples: [Float]) throws -> [Float] {
        guard let resampler,
              let inputFormat = resamplerInputFormat,
              let outputFormat = resamplerOutputFormat else {
            return samples
        }
        guard let input = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw RealtimeVADError.resamplingFailed("Cannot allocate input buffer")
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(
                from: source.baseAddress!, count: samples.count)
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(
            (Double(samples.count) * ratio).rounded(.up) + 16)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity) else {
            throw RealtimeVADError.resamplingFailed("Cannot allocate output buffer")
        }

        var consumed = false
        var conversionError: NSError?
        let status = resampler.convert(to: output, error: &conversionError) {
            _, outputStatus in
            if consumed {
                outputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outputStatus.pointee = .haveData
            return input
        }
        if let conversionError {
            throw RealtimeVADError.resamplingFailed(
                conversionError.localizedDescription)
        }
        guard status != .error else {
            throw RealtimeVADError.resamplingFailed(
                "AVAudioConverter returned an error")
        }
        let count = Int(output.frameLength)
        guard count > 0, let channel = output.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }
}

enum RealtimeVADError: Error, LocalizedError, Equatable {
    case invalidSampleRate
    case resamplerUnavailable(inputSampleRate: Int, vadSampleRate: Int)
    case resamplingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            return "Realtime VAD sample rates and chunk size must be positive"
        case .resamplerUnavailable(let input, let vad):
            return "Cannot create realtime VAD resampler from \(input) Hz to \(vad) Hz"
        case .resamplingFailed(let reason):
            return "Realtime VAD resampling failed: \(reason)"
        }
    }
}
