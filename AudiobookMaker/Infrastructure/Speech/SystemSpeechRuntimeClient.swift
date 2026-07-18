import AVFoundation
import Foundation

@MainActor
final class SystemSpeechRuntimeClient: NSObject, TTSRuntimeClient {
    private let synthesizer = AVSpeechSynthesizer()
    private var activeRequestID: UUID?

    nonisolated func capabilities() async throws -> RuntimeCapabilities {
        RuntimeCapabilities(
            runtimeID: "com.audiobookmaker.apple-system-speech",
            displayName: "Apple 系统语音",
            version: ProcessInfo.processInfo.operatingSystemVersionString,
            maximumTextLength: 2_000,
            supportsImmediateCancellation: true,
            outputFileType: "caf"
        )
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RuntimeError.invalidText }
        guard text.count <= 2_000 else { throw RuntimeError.textTooLong(maximum: 2_000) }
        guard request.outputURL.isFileURL else { throw RuntimeError.invalidOutputPath }

        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: request.outputURL)

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        if let identifier = request.voiceIdentifier {
            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
        } else if let languageCode = request.languageCode {
            utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        }

        let writer = SpeechBufferWriter(url: request.outputURL)
        activeRequestID = request.requestID
        defer { activeRequestID = nil }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                writer.install(continuation: continuation, requestID: request.requestID)
                synthesizer.write(utterance) { buffer in
                    writer.consume(buffer)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.synthesizer.stopSpeaking(at: .immediate)
                writer.cancel()
            }
        }

        let asset = AVURLAsset(url: request.outputURL)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isNumeric, duration.seconds > 0, let track = tracks.first else {
            throw RuntimeError.invalidAudio
        }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw RuntimeError.invalidAudio
        }
        return SynthesisResult(
            requestID: request.requestID,
            audioURL: request.outputURL,
            durationSeconds: duration.seconds,
            sampleRate: basic.pointee.mSampleRate,
            channelCount: Int(basic.pointee.mChannelsPerFrame)
        )
    }

    func cancel(requestID: UUID) async {
        guard activeRequestID == requestID else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }
}

private final class SpeechBufferWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var audioFile: AVAudioFile?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var requestID: UUID?
    private var isFinished = false

    init(url: URL) {
        self.url = url
    }

    func install(
        continuation: CheckedContinuation<Void, any Error>,
        requestID: UUID
    ) {
        lock.withLock {
            self.continuation = continuation
            self.requestID = requestID
        }
    }

    func consume(_ buffer: AVAudioBuffer) {
        lock.withLock {
            guard !isFinished else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                finish(throwing: RuntimeError.invalidAudio)
                return
            }
            if pcm.frameLength == 0 {
                finish()
                return
            }
            do {
                if audioFile == nil {
                    audioFile = try AVAudioFile(
                        forWriting: url,
                        settings: pcm.format.settings,
                        commonFormat: pcm.format.commonFormat,
                        interleaved: pcm.format.isInterleaved
                    )
                }
                try audioFile?.write(from: pcm)
            } catch {
                finish(throwing: RuntimeError.synthesisFailed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        lock.withLock {
            guard !isFinished else { return }
            finish(throwing: RuntimeError.cancelled)
        }
    }

    private func finish(throwing error: (any Error)? = nil) {
        isFinished = true
        audioFile = nil
        let continuation = continuation
        self.continuation = nil
        requestID = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
