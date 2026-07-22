import AVFoundation
import Foundation
import SherpaOnnx

nonisolated private enum KokoroStopReason: Sendable {
    case cancelled
    case timedOut
}

nonisolated private final class KokoroCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var reason: KokoroStopReason?

    nonisolated func stop(_ reason: KokoroStopReason) {
        lock.withLock {
            if self.reason == nil { self.reason = reason }
        }
    }

    nonisolated func shouldContinue() -> Int32 { lock.withLock { reason == nil ? 1 : 0 } }

    nonisolated func throwIfStopped() throws {
        switch lock.withLock({ reason }) {
        case .cancelled: throw RuntimeError.cancelled
        case .timedOut: throw RuntimeError.timedOut
        case nil: return
        }
    }
}

nonisolated private func kokoroProgressCallback(
    _ samples: UnsafePointer<Float>?,
    _ count: Int32,
    _ progress: Float,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 1 }
    return Unmanaged<KokoroCancellationBox>.fromOpaque(context).takeUnretainedValue().shouldContinue()
}

nonisolated private struct KokoroGeneratedAudioMetadata: Sendable {
    let sampleCount: Int
    let sampleRate: Double
}

nonisolated private final class KokoroGenerationWork: @unchecked Sendable {
    let tts: OpaquePointer
    let text: String
    let speakerID: Int32
    let outputURL: URL
    let cancellation: KokoroCancellationBox

    init(
        tts: OpaquePointer,
        text: String,
        speakerID: Int32,
        outputURL: URL,
        cancellation: KokoroCancellationBox
    ) {
        self.tts = tts
        self.text = text
        self.speakerID = speakerID
        self.outputURL = outputURL
        self.cancellation = cancellation
    }

    func run() throws -> KokoroGeneratedAudioMetadata {
        try cancellation.throwIfStopped()
        var generation = SherpaOnnxGenerationConfig()
        generation.sid = speakerID
        generation.speed = 1
        generation.silence_scale = 0.2
        let context = Unmanaged.passUnretained(cancellation).toOpaque()
        let generated = text.withCString { text in
            SherpaOnnxOfflineTtsGenerateWithConfig(
                tts,
                text,
                &generation,
                kokoroProgressCallback,
                context
            )
        }
        try cancellation.throwIfStopped()
        guard let generated else { throw RuntimeError.synthesisFailed("sherpa-onnx returned no audio") }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(generated) }
        guard generated.pointee.n > 0, generated.pointee.sample_rate == 24_000,
              let samples = generated.pointee.samples else { throw RuntimeError.invalidAudio }
        try writeKokoroCAF(
            samples: samples,
            count: Int(generated.pointee.n),
            sampleRate: Double(generated.pointee.sample_rate),
            to: outputURL
        )
        try cancellation.throwIfStopped()
        return KokoroGeneratedAudioMetadata(
            sampleCount: Int(generated.pointee.n),
            sampleRate: Double(generated.pointee.sample_rate)
        )
    }
}

private nonisolated func writeKokoroCAF(
    samples: UnsafePointer<Float>,
    count: Int,
    sampleRate: Double,
    to url: URL
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ), let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(count)
    ), let destination = buffer.floatChannelData?.pointee else { throw RuntimeError.invalidAudio }
    buffer.frameLength = AVAudioFrameCount(count)
    destination.update(from: samples, count: count)
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
}

actor KokoroTTSRuntimeClient: TTSRuntimeClient {
    private let directories: AppDirectories
    private let synthesisTimeout: Duration
    nonisolated(unsafe) private var handle: OpaquePointer?
    private var active: [UUID: KokoroCancellationBox] = [:]
    private var generationIsActive = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []

    init(directories: AppDirectories, synthesisTimeout: Duration = .seconds(600)) {
        self.directories = directories
        self.synthesisTimeout = synthesisTimeout
    }

    deinit {
        if let handle { SherpaOnnxDestroyOfflineTts(handle) }
    }

    func capabilities() async throws -> RuntimeCapabilities {
        try await capabilities(for: TTSModelCatalog.kokoroID)
    }

    func capabilities(for modelID: String) async throws -> RuntimeCapabilities {
        guard modelID == TTSModelCatalog.kokoroID else { throw RuntimeError.modelUnavailable }
        let tts = try load(version: TTSModelCatalog.kokoro.version)
        guard SherpaOnnxOfflineTtsNumSpeakers(tts) == TTSModelCatalog.kokoroVoices.count,
              SherpaOnnxOfflineTtsSampleRate(tts) == 24_000 else { throw RuntimeError.incompatibleRuntime }
        return RuntimeCapabilities(
            runtimeID: TTSModelCatalog.kokoroID,
            displayName: TTSModelCatalog.kokoro.displayName,
            version: TTSModelCatalog.kokoro.version,
            maximumTextLength: 500,
            recommendedConcurrency: 1,
            supportsImmediateCancellation: true,
            outputFileType: "caf",
            supportedLanguages: ["zh-CN", "en-US"],
            voices: TTSModelCatalog.kokoroVoices
        )
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        guard request.modelID == TTSModelCatalog.kokoroID,
              request.modelVersion == TTSModelCatalog.kokoro.version else { throw RuntimeError.modelUnavailable }
        let normalized = Self.normalize(request.text)
        guard !normalized.isEmpty else { throw RuntimeError.invalidText }
        guard normalized.count <= 500 else { throw RuntimeError.textTooLong(maximum: 500) }
        guard request.outputURL.isFileURL else { throw RuntimeError.invalidOutputPath }
        guard let voiceID = request.voiceIdentifier,
              let voice = TTSModelCatalog.kokoroVoices.first(where: { $0.id == voiceID }),
              voice.speakerID >= 0, voice.speakerID < TTSModelCatalog.kokoroVoices.count else {
            throw RepositoryError.invalidVoice
        }
        let tts = try load(version: request.modelVersion)
        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }
        let cancellation = KokoroCancellationBox()
        active[request.requestID] = cancellation
        defer { active[request.requestID] = nil }
        let work = KokoroGenerationWork(
            tts: tts,
            text: normalized,
            speakerID: voice.speakerID,
            outputURL: request.outputURL,
            cancellation: cancellation
        )
        let timeout = synthesisTimeout
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: timeout)
                cancellation.stop(.timedOut)
            } catch {
                return
            }
        }
        defer { timeoutTask.cancel() }
        do {
            let metadata = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) { try work.run() }.value
            } onCancel: {
                cancellation.stop(.cancelled)
            }
            let duration = Double(metadata.sampleCount) / metadata.sampleRate
            guard duration.isFinite, duration > 0 else { throw RuntimeError.invalidAudio }
            return SynthesisResult(
                requestID: request.requestID,
                audioURL: request.outputURL,
                durationSeconds: duration,
                sampleRate: metadata.sampleRate,
                channelCount: 1
            )
        } catch {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw error
        }
    }

    func cancel(requestID: UUID) async { active[requestID]?.stop(.cancelled) }

    private func acquireGenerationSlot() async {
        if !generationIsActive {
            generationIsActive = true
            return
        }
        await withCheckedContinuation { generationWaiters.append($0) }
    }

    private func releaseGenerationSlot() {
        if generationWaiters.isEmpty {
            generationIsActive = false
        } else {
            generationWaiters.removeFirst().resume()
        }
    }

    private func load(version: String) throws -> OpaquePointer {
        if let handle { return handle }
        guard version == TTSModelCatalog.kokoro.version else { throw RuntimeError.modelUnavailable }
        let root = try directories.modelVersionDirectory(id: TTSModelCatalog.kokoroID, version: version).standardizedFileURL
        guard root.pathComponents.starts(with: directories.models.standardizedFileURL.pathComponents),
              !root.pathComponents.starts(with: Bundle.main.bundleURL.standardizedFileURL.pathComponents) else {
            throw RuntimeError.modelUnavailable
        }
        for path in TTSModelCatalog.kokoro.requiredPaths {
            let url = root.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path),
                  url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(with: root.pathComponents) else {
                throw RuntimeError.modelUnavailable
            }
        }
        let modelPath = root.appending(path: "model.int8.onnx").path
        let voicesPath = root.appending(path: "voices.bin").path
        let tokensPath = root.appending(path: "tokens.txt").path
        let dataPath = root.appending(path: "espeak-ng-data").path
        let lexiconPath = root.appending(path: "lexicon-us-en.txt").path + "," + root.appending(path: "lexicon-zh.txt").path
        let values = [modelPath, voicesPath, tokensPath, dataPath, lexiconPath, "cpu"]
        let allocated: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.kokoro.model = UnsafePointer(allocated[0])
        config.model.kokoro.voices = UnsafePointer(allocated[1])
        config.model.kokoro.tokens = UnsafePointer(allocated[2])
        config.model.kokoro.data_dir = UnsafePointer(allocated[3])
        config.model.kokoro.lexicon = UnsafePointer(allocated[4])
        config.model.kokoro.length_scale = 1
        config.model.provider = UnsafePointer(allocated[5])
        config.model.num_threads = 2
        // Kokoro only accepts 1 here; higher values are ignored by sherpa-onnx
        // and emit one warning for every fragment.
        config.max_num_sentences = 1
        guard let created = SherpaOnnxCreateOfflineTts(&config) else { throw RuntimeError.incompatibleRuntime }
        handle = created
        return created
    }

    private nonisolated static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

actor RoutingTTSRuntimeClient: TTSRuntimeClient {
    private var system: SystemSpeechRuntimeClient?
    private let kokoro: KokoroTTSRuntimeClient
    private let speechSwift: SpeechSwiftTTSRuntimeClient?

    init(
        directories: AppDirectories,
        platformSupport: SpeechSwiftPlatformSupport = SpeechSwiftPlatformSupport(),
        speechSwiftSessionFactory: any SpeechSwiftSessionFactory = LiveSpeechSwiftSessionFactory()
    ) {
        kokoro = KokoroTTSRuntimeClient(directories: directories)
        speechSwift = platformSupport.status().isSupported
            ? SpeechSwiftTTSRuntimeClient(
                directories: directories,
                platformSupport: platformSupport,
                sessionFactory: speechSwiftSessionFactory
            )
            : nil
    }

    func capabilities() async throws -> RuntimeCapabilities {
        try await systemRuntime().capabilities()
    }

    func capabilities(for modelID: String) async throws -> RuntimeCapabilities {
        switch modelID {
        case TTSModelCatalog.systemID: return try await systemRuntime().capabilities()
        case TTSModelCatalog.kokoroID: return try await kokoro.capabilities()
        case TTSModelCatalog.cosyVoiceID, TTSModelCatalog.qwen3TTSID:
            guard let speechSwift else { throw RuntimeError.incompatibleRuntime }
            return try await speechSwift.capabilities(for: modelID)
        default: throw RuntimeError.modelUnavailable
        }
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        switch request.modelID {
        case TTSModelCatalog.systemID: return try await systemRuntime().synthesize(request)
        case TTSModelCatalog.kokoroID: return try await kokoro.synthesize(request)
        case TTSModelCatalog.cosyVoiceID, TTSModelCatalog.qwen3TTSID:
            guard let speechSwift else { throw RuntimeError.incompatibleRuntime }
            return try await speechSwift.synthesize(request)
        default: throw RuntimeError.modelUnavailable
        }
    }

    func cancel(requestID: UUID) async {
        if let system { await system.cancel(requestID: requestID) }
        await kokoro.cancel(requestID: requestID)
        await speechSwift?.cancel(requestID: requestID)
    }

    private func systemRuntime() async -> SystemSpeechRuntimeClient {
        if let system { return system }
        let runtime = await SystemSpeechRuntimeClient()
        system = runtime
        return runtime
    }
}
