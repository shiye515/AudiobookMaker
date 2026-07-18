import AVFoundation
import Foundation

actor MockTTSRuntimeClient: TTSRuntimeClient {
    nonisolated struct ProgressEvent: Sendable, Equatable {
        let requestID: UUID
        let fractionCompleted: Double
    }

    nonisolated struct Configuration: Sendable {
        var delay: Duration = .zero
        var error: RuntimeError?
        var maximumTextLength = 200
        var sampleRate = 22_050.0
        var supportsImmediateCancellation = true
        var progressStepCount = 4
        var recommendedConcurrency = 1
    }

    private let configuration: Configuration
    private var cancelled: Set<UUID> = []
    private var synthesizedTextLog: [String] = []
    private var progressLog: [ProgressEvent] = []
    private var activeSynthesisCount = 0
    private var maximumActiveSynthesisCount = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func capabilities() async throws -> RuntimeCapabilities {
        RuntimeCapabilities(
            runtimeID: "com.audiobookmaker.mock",
            displayName: "确定性测试语音",
            version: "1",
            maximumTextLength: configuration.maximumTextLength,
            recommendedConcurrency: configuration.recommendedConcurrency,
            supportsImmediateCancellation: configuration.supportsImmediateCancellation,
            outputFileType: "caf"
        )
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeError.invalidText
        }
        guard request.text.count <= configuration.maximumTextLength else {
            throw RuntimeError.textTooLong(maximum: configuration.maximumTextLength)
        }
        activeSynthesisCount += 1
        maximumActiveSynthesisCount = max(maximumActiveSynthesisCount, activeSynthesisCount)
        defer { activeSynthesisCount -= 1 }
        progressLog.append(ProgressEvent(requestID: request.requestID, fractionCompleted: 0))
        if configuration.delay > .zero {
            let steps = max(1, configuration.progressStepCount)
            do {
                for step in 1...steps {
                    try await Task.sleep(for: configuration.delay / steps)
                    progressLog.append(ProgressEvent(
                        requestID: request.requestID,
                        fractionCompleted: Double(step) / Double(steps)
                    ))
                }
            } catch is CancellationError {
                throw RuntimeError.cancelled
            }
        } else {
            progressLog.append(ProgressEvent(requestID: request.requestID, fractionCompleted: 1))
        }
        do {
            try Task.checkCancellation()
        } catch is CancellationError {
            throw RuntimeError.cancelled
        }
        if cancelled.contains(request.requestID) { throw RuntimeError.cancelled }
        synthesizedTextLog.append(request.text)
        if let error = configuration.error { throw error }

        try Self.writeTone(
            to: request.outputURL,
            sampleRate: configuration.sampleRate,
            duration: max(0.1, min(1.0, Double(request.text.count) / 100.0))
        )
        let asset = AVURLAsset(url: request.outputURL)
        let duration = try await asset.load(.duration).seconds
        return SynthesisResult(
            requestID: request.requestID,
            audioURL: request.outputURL,
            durationSeconds: duration,
            sampleRate: configuration.sampleRate,
            channelCount: 1
        )
    }

    func cancel(requestID: UUID) async {
        cancelled.insert(requestID)
    }

    func synthesizedTexts() -> [String] {
        synthesizedTextLog
    }

    func progressEvents() -> [ProgressEvent] {
        progressLog
    }

    func maximumObservedConcurrency() -> Int {
        maximumActiveSynthesisCount
    }

    private nonisolated static func writeTone(
        to url: URL,
        sampleRate: Double,
        duration: Double
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleRate * duration)
        ), let samples = buffer.floatChannelData?[0] else {
            throw RuntimeError.invalidAudio
        }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = sin(2 * .pi * 440 * Float(frame) / Float(sampleRate)) * 0.08
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
