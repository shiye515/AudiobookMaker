import AVFoundation
import CosyVoiceTTS
import Foundation
import Qwen3TTS

nonisolated private final class SpeechSwiftContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            defer { continuation = nil }
            return continuation
        }?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.withLock { () -> CheckedContinuation<Value, any Error>? in
            defer { continuation = nil }
            return continuation
        }?.resume(throwing: error)
    }
}

nonisolated protocol SpeechSwiftSession: Actor {
    func availableSpeakers() async throws -> [String]
    func synthesize(text: String, language: String, voiceID: String) async throws -> [Float]
    func unload() async
}

nonisolated protocol SpeechSwiftSessionFactory: Sendable {
    func makeSession(modelID: String, modelRoot: URL) throws -> any SpeechSwiftSession
}

nonisolated struct LiveSpeechSwiftSessionFactory: SpeechSwiftSessionFactory {
    func makeSession(modelID: String, modelRoot: URL) throws -> any SpeechSwiftSession {
        switch modelID {
        case TTSModelCatalog.cosyVoiceID:
            CosyVoiceSpeechSwiftSession(modelRoot: modelRoot)
        case TTSModelCatalog.qwen3TTSID:
            Qwen3SpeechSwiftSession(modelRoot: modelRoot)
        default:
            throw RuntimeError.modelUnavailable
        }
    }
}

private actor CosyVoiceSpeechSwiftSession: SpeechSwiftSession {
    private let modelRoot: URL
    private var model: CosyVoiceTTSModel?

    init(modelRoot: URL) { self.modelRoot = modelRoot }

    func availableSpeakers() async throws -> [String] {
        _ = try await load()
        return ["default"]
    }

    func synthesize(text: String, language: String, voiceID: String) async throws -> [Float] {
        guard voiceID == "default" else { throw RepositoryError.invalidVoice }
        let loaded = try await load()
        return loaded.synthesize(text: text, language: language)
    }

    func unload() {
        model?.unload()
        model = nil
    }

    private func load() async throws -> CosyVoiceTTSModel {
        if let model { return model }
        let loaded = try await CosyVoiceTTSModel.fromPretrained(
            modelId: TTSModelCatalog.cosyVoiceRepositoryID,
            cacheDir: modelRoot,
            offlineMode: true
        )
        model = loaded
        return loaded
    }
}

private actor Qwen3SpeechSwiftSession: SpeechSwiftSession {
    private let modelRoot: URL
    private var model: Qwen3TTSModel?

    init(modelRoot: URL) { self.modelRoot = modelRoot }

    func availableSpeakers() async throws -> [String] {
        try await load().availableSpeakers
    }

    func synthesize(text: String, language: String, voiceID: String) async throws -> [Float] {
        let loaded = try await load()
        guard loaded.availableSpeakers.contains(voiceID) else { throw RepositoryError.invalidVoice }
        return loaded.synthesize(
            text: text,
            language: language,
            speaker: voiceID,
            languageExplicit: true
        )
    }

    func unload() {
        model?.unload()
        model = nil
    }

    private func load() async throws -> Qwen3TTSModel {
        if let model { return model }
        let runtimeCache = modelRoot.appending(path: "runtime-cache", directoryHint: .isDirectory)
        guard setenv("QWEN3_CACHE_DIR", runtimeCache.path, 1) == 0 else {
            throw RuntimeError.incompatibleRuntime
        }
        let loaded = try await Qwen3TTSModel.fromPretrained(
            modelId: TTSModelCatalog.qwen3TTSRepositoryID,
            tokenizerModelId: "Qwen/Qwen3-TTS-Tokenizer-12Hz",
            cacheDir: modelRoot,
            offlineMode: true
        )
        model = loaded
        return loaded
    }
}

actor SpeechSwiftTTSRuntimeClient: TTSRuntimeClient {
    private let directories: AppDirectories
    private let platformSupport: SpeechSwiftPlatformSupport
    private let sessionFactory: any SpeechSwiftSessionFactory
    private let synthesisTimeout: Duration
    private var loadedModelID: String?
    private var session: (any SpeechSwiftSession)?
    private var activeRequests: Set<UUID> = []
    private var cancelledRequests: Set<UUID> = []
    private var generationIsActive = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        directories: AppDirectories,
        platformSupport: SpeechSwiftPlatformSupport = SpeechSwiftPlatformSupport(),
        sessionFactory: any SpeechSwiftSessionFactory = LiveSpeechSwiftSessionFactory(),
        synthesisTimeout: Duration = .seconds(90)
    ) {
        self.directories = directories
        self.platformSupport = platformSupport
        self.sessionFactory = sessionFactory
        self.synthesisTimeout = synthesisTimeout
    }

    func capabilities() async throws -> RuntimeCapabilities {
        try await capabilities(for: TTSModelCatalog.cosyVoiceID)
    }

    func capabilities(for modelID: String) async throws -> RuntimeCapabilities {
        guard platformSupport.status().isSupported else { throw RuntimeError.incompatibleRuntime }
        let manifest = try manifest(for: modelID)
        let session = try await session(for: manifest)
        let speakers = try await session.availableSpeakers()
        let voices = voices(for: modelID)
        guard Set(voices.map(\.id)).isSubset(of: Set(speakers)) else {
            throw RuntimeError.incompatibleRuntime
        }
        return RuntimeCapabilities(
            runtimeID: modelID,
            displayName: manifest.displayName,
            version: manifest.version,
            maximumTextLength: 500,
            recommendedConcurrency: 1,
            supportsImmediateCancellation: false,
            outputFileType: "caf",
            supportedLanguages: ["zh-CN", "en-US", "ja-JP", "ko-KR"],
            voices: voices,
            platformRequirement: .nativeAppleSilicon,
            maximumTokenBudget: modelID == TTSModelCatalog.qwen3TTSID ? 240 : 320,
            memoryTier: .high,
            cancellationBoundary: .safeChunkBoundary
        )
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        guard platformSupport.status().isSupported else { throw RuntimeError.incompatibleRuntime }
        let manifest = try manifest(for: request.modelID)
        guard request.modelVersion == manifest.version else { throw RuntimeError.modelUnavailable }
        let normalized = normalize(request.text)
        guard !normalized.isEmpty else { throw RuntimeError.invalidText }
        guard normalized.count <= 500 else { throw RuntimeError.textTooLong(maximum: 500) }
        let outputComponents = request.outputURL.standardizedFileURL.pathComponents
        guard request.outputURL.isFileURL,
              outputComponents.starts(with: directories.root.standardizedFileURL.pathComponents)
                || outputComponents.starts(with: directories.cacheRoot.standardizedFileURL.pathComponents)
        else { throw RuntimeError.invalidOutputPath }
        let voiceID = request.voiceIdentifier ?? defaultVoiceID(for: request.modelID)
        guard voices(for: request.modelID).contains(where: { $0.id == voiceID }) else {
            throw RepositoryError.invalidVoice
        }

        await acquireGenerationSlot()
        defer { releaseGenerationSlot() }
        activeRequests.insert(request.requestID)
        cancelledRequests.remove(request.requestID)
        defer {
            activeRequests.remove(request.requestID)
            cancelledRequests.remove(request.requestID)
        }

        let session = try await session(for: manifest)
        let maximumChunkLength = request.modelID == TTSModelCatalog.qwen3TTSID ? 120 : 180
        let chunks = SpeechSwiftTextChunker.chunks(normalized, maximumLength: maximumChunkLength)
        var samples: [Float] = []
        do {
            for chunk in chunks {
                try throwIfCancelled(request.requestID)
                let language = languageName(for: request.languageCode)
                let timeout = synthesisTimeout
                let generated: [Float] = try await withCheckedThrowingContinuation { continuation in
                    let gate = SpeechSwiftContinuationGate(continuation)
                    Task {
                        do {
                            gate.resume(returning: try await session.synthesize(
                                text: chunk,
                                language: language,
                                voiceID: voiceID
                            ))
                        } catch {
                            gate.resume(throwing: error)
                        }
                    }
                    Task {
                        do {
                            try await Task.sleep(for: timeout)
                            gate.resume(throwing: RuntimeError.timedOut)
                        } catch is CancellationError {
                            return
                        } catch {
                            gate.resume(throwing: error)
                        }
                    }
                }
                try throwIfCancelled(request.requestID)
                guard !generated.isEmpty,
                      generated.allSatisfy(\.isFinite),
                      generated.count < 24_000 * 60 else {
                    throw RuntimeError.invalidAudio
                }
                samples.append(contentsOf: generated)
            }
            try throwIfCancelled(request.requestID)
            try writeCAF(samples: samples, to: request.outputURL)
            let duration = Double(samples.count) / 24_000
            guard duration.isFinite, duration > 0 else { throw RuntimeError.invalidAudio }
            return SynthesisResult(
                requestID: request.requestID,
                audioURL: request.outputURL,
                durationSeconds: duration,
                sampleRate: 24_000,
                channelCount: 1
            )
        } catch {
            try? FileManager.default.removeItem(at: request.outputURL)
            throw error
        }
    }

    func cancel(requestID: UUID) {
        guard activeRequests.contains(requestID) else { return }
        cancelledRequests.insert(requestID)
    }

    func unload() async {
        await session?.unload()
        session = nil
        loadedModelID = nil
    }

    private func session(for manifest: DownloadableModelManifest) async throws -> any SpeechSwiftSession {
        if loadedModelID == manifest.id, let session { return session }
        await session?.unload()
        session = nil
        loadedModelID = nil
        let root = try verifiedLocalRoot(for: manifest)
        let created = try sessionFactory.makeSession(modelID: manifest.id, modelRoot: root)
        session = created
        loadedModelID = manifest.id
        return created
    }

    private func verifiedLocalRoot(for manifest: DownloadableModelManifest) throws -> URL {
        let root = try directories.modelVersionDirectory(id: manifest.id, version: manifest.version)
            .standardizedFileURL
        guard root.pathComponents.starts(with: directories.models.standardizedFileURL.pathComponents),
              !root.pathComponents.starts(with: Bundle.main.bundleURL.standardizedFileURL.pathComponents) else {
            throw RuntimeError.modelUnavailable
        }
        for path in manifest.requiredPaths {
            let file = root.appending(path: path)
            guard FileManager.default.fileExists(atPath: file.path),
                  file.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(
                    with: root.pathComponents
                  ) else { throw RuntimeError.modelUnavailable }
        }
        return root
    }

    private func manifest(for modelID: String) throws -> DownloadableModelManifest {
        guard modelID == TTSModelCatalog.cosyVoiceID || modelID == TTSModelCatalog.qwen3TTSID,
              let manifest = TTSModelCatalog.manifestsByID[modelID] else {
            throw RuntimeError.modelUnavailable
        }
        return manifest
    }

    private func voices(for modelID: String) -> [TTSVoiceDescriptor] {
        modelID == TTSModelCatalog.cosyVoiceID
            ? TTSModelCatalog.cosyVoiceVoices
            : TTSModelCatalog.qwen3TTSVoices
    }

    private func defaultVoiceID(for modelID: String) -> String {
        modelID == TTSModelCatalog.cosyVoiceID ? "default" : "vivian"
    }

    private func languageName(for code: String?) -> String {
        switch code?.lowercased().prefix(2) {
        case "zh": "chinese"
        case "ja": "japanese"
        case "ko": "korean"
        case "de": "german"
        case "es": "spanish"
        case "fr": "french"
        case "ru": "russian"
        default: "english"
        }
    }

    private func throwIfCancelled(_ requestID: UUID) throws {
        if cancelledRequests.contains(requestID) || Task.isCancelled {
            throw RuntimeError.cancelled
        }
    }

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

    private nonisolated func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func writeCAF(samples: [Float], to url: URL) throws {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 24_000,
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let destination = buffer.floatChannelData?.pointee else {
            throw RuntimeError.invalidAudio
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: url)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                destination.update(from: baseAddress, count: source.count)
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}

nonisolated enum SpeechSwiftTextChunker {
    static func chunks(_ text: String, maximumLength: Int) -> [String] {
        guard text.count > maximumLength else { return [text] }
        let boundaries = Set<Character>("。！？!?；;\n")
        var sentences: [String] = []
        var sentenceBuffer = ""
        for character in text {
            sentenceBuffer.append(character)
            if boundaries.contains(character) {
                let sentence = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                sentenceBuffer = ""
            }
        }
        let tail = sentenceBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        var result: [String] = []
        var current = ""
        for sentence in sentences {
            if sentence.count > maximumLength {
                if !current.isEmpty { result.append(current); current = "" }
                var remainder = sentence[...]
                while remainder.count > maximumLength {
                    let end = remainder.index(remainder.startIndex, offsetBy: maximumLength)
                    result.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
                if !remainder.isEmpty { current = String(remainder) }
            } else if current.isEmpty {
                current = sentence
            } else if current.count + sentence.count <= maximumLength {
                current += sentence
            } else {
                result.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [text] : result
    }
}
