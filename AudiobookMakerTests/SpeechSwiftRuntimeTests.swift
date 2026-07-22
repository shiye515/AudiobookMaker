import AVFoundation
import Foundation
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
@MainActor
struct SpeechSwiftRuntimeTests {
    @Test("Both speech-swift adapters expose pinned capabilities and stable voices")
    func capabilities() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()

        let cosy = try await runtime.capabilities(for: TTSModelCatalog.cosyVoiceID)
        #expect(cosy.voices == TTSModelCatalog.cosyVoiceVoices)
        #expect(cosy.memoryTier == .high)
        #expect(cosy.recommendedConcurrency == 1)
        #expect(cosy.cancellationBoundary == .safeChunkBoundary)

        let qwen = try await runtime.capabilities(for: TTSModelCatalog.qwen3TTSID)
        #expect(qwen.voices == TTSModelCatalog.qwen3TTSVoices)
        #expect(qwen.maximumTokenBudget == 240)
        #expect(await fixture.cosySession.unloadCount == 1)
    }

    @Test("Long Qwen input is split at sentence boundaries and merged into valid CAF")
    func chunkAndMerge() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        let output = fixture.directories.root.appending(path: "qwen-long.caf")
        let text = String(repeating: "这是一个用于验证安全切片的中文句子。", count: 24)
        let result = try await runtime.synthesize(.init(
            text: text,
            languageCode: "zh-CN",
            voiceIdentifier: "vivian",
            outputURL: output,
            modelID: TTSModelCatalog.qwen3TTSID,
            modelVersion: TTSModelCatalog.qwen3TTS.version
        ))

        let calls = await fixture.qwenSession.calls
        #expect(calls.count > 1)
        #expect(calls.allSatisfy { $0.text.count <= 120 })
        #expect(calls.allSatisfy { $0.voiceID == "vivian" && $0.language == "chinese" })
        #expect(result.sampleRate == 24_000)
        #expect(result.channelCount == 1)
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).count == 1)
    }

    @Test("Cancellation discards a late safe-chunk result and leaves no output")
    func lateCancellation() async throws {
        let fixture = try Fixture(delay: .milliseconds(150))
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        let requestID = UUID()
        let output = fixture.directories.root.appending(path: "cancelled.caf")
        let task = Task {
            try await runtime.synthesize(.init(
                requestID: requestID,
                text: "这是一个取消测试。",
                languageCode: "zh-CN",
                voiceIdentifier: "default",
                outputURL: output,
                modelID: TTSModelCatalog.cosyVoiceID,
                modelVersion: TTSModelCatalog.cosyVoice.version
            ))
        }
        try await Task.sleep(for: .milliseconds(25))
        await runtime.cancel(requestID: requestID)
        await #expect(throws: RuntimeError.cancelled) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("Missing local files fail before a session factory can load or network")
    func missingFilesStayOffline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = try fixture.directories.modelVersionDirectory(
            id: TTSModelCatalog.cosyVoiceID,
            version: TTSModelCatalog.cosyVoice.version
        ).appending(path: "config.json")
        try FileManager.default.removeItem(at: missing)
        await #expect(throws: RuntimeError.modelUnavailable) {
            _ = try await fixture.runtime().capabilities(for: TTSModelCatalog.cosyVoiceID)
        }
        #expect(await fixture.cosySession.calls.isEmpty)
    }

    @Test("The second-level chunker never exceeds its declared character budget")
    func deterministicChunker() {
        let text = "第一句很短。第二句也很短！" + String(repeating: "长", count: 31) + "。最后一句。"
        let chunks = SpeechSwiftTextChunker.chunks(text, maximumLength: 20)
        #expect(chunks.count > 2)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 20 })
        #expect(chunks.joined() == text)
    }

    @Test("Version, voice and text limits fail before generation")
    func invalidRequestContract() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime()
        let output = fixture.directories.root.appending(path: "invalid.caf")
        await #expect(throws: RuntimeError.modelUnavailable) {
            _ = try await runtime.synthesize(.init(
                text: "测试", outputURL: output, modelID: TTSModelCatalog.cosyVoiceID,
                modelVersion: "wrong-version"
            ))
        }
        await #expect(throws: RepositoryError.invalidVoice) {
            _ = try await runtime.synthesize(.init(
                text: "测试", voiceIdentifier: "unknown", outputURL: output,
                modelID: TTSModelCatalog.cosyVoiceID, modelVersion: TTSModelCatalog.cosyVoice.version
            ))
        }
        await #expect(throws: RuntimeError.textTooLong(maximum: 500)) {
            _ = try await runtime.synthesize(.init(
                text: String(repeating: "长", count: 501), outputURL: output,
                modelID: TTSModelCatalog.cosyVoiceID, modelVersion: TTSModelCatalog.cosyVoice.version
            ))
        }
        #expect(await fixture.cosySession.calls.isEmpty)
    }

    @Test("Load failures, timeouts and invalid PCM are stable and leave no output")
    func failuresDiscardOutput() async throws {
        let outputName = "failed.caf"

        let loadFixture = try Fixture(loadError: .incompatibleRuntime)
        let loadOutput = loadFixture.directories.root.appending(path: outputName)
        await #expect(throws: RuntimeError.incompatibleRuntime) {
            _ = try await loadFixture.runtime().capabilities(for: TTSModelCatalog.cosyVoiceID)
        }
        #expect(!FileManager.default.fileExists(atPath: loadOutput.path))
        loadFixture.remove()

        let timeoutFixture = try Fixture(delay: .milliseconds(150))
        let timeoutOutput = timeoutFixture.directories.root.appending(path: outputName)
        await #expect(throws: RuntimeError.timedOut) {
            _ = try await timeoutFixture.runtime(timeout: .milliseconds(20)).synthesize(.init(
                text: "超时测试", outputURL: timeoutOutput,
                modelID: TTSModelCatalog.cosyVoiceID, modelVersion: TTSModelCatalog.cosyVoice.version
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: timeoutOutput.path))
        timeoutFixture.remove()

        let audioFixture = try Fixture(samples: [])
        let audioOutput = audioFixture.directories.root.appending(path: outputName)
        await #expect(throws: RuntimeError.invalidAudio) {
            _ = try await audioFixture.runtime().synthesize(.init(
                text: "无效音频", outputURL: audioOutput,
                modelID: TTSModelCatalog.cosyVoiceID, modelVersion: TTSModelCatalog.cosyVoice.version
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: audioOutput.path))
        audioFixture.remove()
    }

    @Test("The unified router dispatches both stable speech-swift IDs and rejects unknown or incompatible IDs")
    func routing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let router = fixture.router(platformSupported: true)
        #expect(try await router.capabilities(for: TTSModelCatalog.cosyVoiceID).runtimeID == TTSModelCatalog.cosyVoiceID)
        #expect(try await router.capabilities(for: TTSModelCatalog.qwen3TTSID).runtimeID == TTSModelCatalog.qwen3TTSID)
        await #expect(throws: RuntimeError.modelUnavailable) {
            _ = try await router.capabilities(for: "unknown/runtime")
        }
        await #expect(throws: RuntimeError.incompatibleRuntime) {
            _ = try await fixture.router(platformSupported: false)
                .capabilities(for: TTSModelCatalog.cosyVoiceID)
        }
    }
}

private struct Fixture {
    let root: URL
    let directories: AppDirectories
    let cosySession: FakeSpeechSwiftSession
    let qwenSession: FakeSpeechSwiftSession

    init(
        delay: Duration = .zero,
        samples: [Float] = Array(repeating: 0.1, count: 2_400),
        loadError: RuntimeError? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "SpeechSwiftTests-\(UUID().uuidString)")
        directories = AppDirectories(
            root: root.appending(path: "ApplicationSupport"),
            cacheRoot: root.appending(path: "Caches")
        )
        try directories.createIfNeeded()
        cosySession = FakeSpeechSwiftSession(
            speakers: ["default"], delay: delay, samples: samples, loadError: loadError
        )
        qwenSession = FakeSpeechSwiftSession(
            speakers: TTSModelCatalog.qwen3TTSVoices.map(\.id),
            delay: delay,
            samples: samples,
            loadError: loadError
        )
        try installPlaceholderFiles(for: TTSModelCatalog.cosyVoice)
        try installPlaceholderFiles(for: TTSModelCatalog.qwen3TTS)
    }

    @MainActor
    func runtime(timeout: Duration = .seconds(90)) -> SpeechSwiftTTSRuntimeClient {
        SpeechSwiftTTSRuntimeClient(
            directories: directories,
            platformSupport: .init(snapshotProvider: {
                .init(
                    architecture: .arm64,
                    isRosettaTranslated: false,
                    operatingSystemVersion: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                    hasMetalDevice: true
                )
            }),
            sessionFactory: FakeSpeechSwiftSessionFactory(
                cosy: cosySession,
                qwen: qwenSession
            ),
            synthesisTimeout: timeout
        )
    }

    @MainActor
    func router(platformSupported: Bool) -> RoutingTTSRuntimeClient {
        RoutingTTSRuntimeClient(
            directories: directories,
            platformSupport: support(platformSupported: platformSupported),
            speechSwiftSessionFactory: FakeSpeechSwiftSessionFactory(
                cosy: cosySession,
                qwen: qwenSession
            )
        )
    }

    private func support(platformSupported: Bool) -> SpeechSwiftPlatformSupport {
        .init(snapshotProvider: {
            .init(
                architecture: platformSupported ? .arm64 : .x86_64,
                isRosettaTranslated: false,
                operatingSystemVersion: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                hasMetalDevice: platformSupported
            )
        })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private func installPlaceholderFiles(for manifest: DownloadableModelManifest) throws {
        let modelRoot = try directories.modelVersionDirectory(id: manifest.id, version: manifest.version)
        for path in manifest.requiredPaths {
            let file = modelRoot.appending(path: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: file)
        }
    }
}

private nonisolated struct FakeSpeechSwiftSessionFactory: SpeechSwiftSessionFactory {
    let cosy: FakeSpeechSwiftSession
    let qwen: FakeSpeechSwiftSession

    func makeSession(modelID: String, modelRoot: URL) throws -> any SpeechSwiftSession {
        switch modelID {
        case TTSModelCatalog.cosyVoiceID: cosy
        case TTSModelCatalog.qwen3TTSID: qwen
        default: throw RuntimeError.modelUnavailable
        }
    }
}

private actor FakeSpeechSwiftSession: SpeechSwiftSession {
    struct Call: Sendable {
        let text: String
        let language: String
        let voiceID: String
    }

    let speakers: [String]
    let delay: Duration
    let samples: [Float]
    let loadError: RuntimeError?
    private(set) var calls: [Call] = []
    private(set) var unloadCount = 0

    init(speakers: [String], delay: Duration, samples: [Float], loadError: RuntimeError?) {
        self.speakers = speakers
        self.delay = delay
        self.samples = samples
        self.loadError = loadError
    }

    func availableSpeakers() throws -> [String] {
        if let loadError { throw loadError }
        return speakers
    }

    func synthesize(text: String, language: String, voiceID: String) async throws -> [Float] {
        calls.append(.init(text: text, language: language, voiceID: voiceID))
        if delay != .zero { try await Task.sleep(for: delay) }
        return samples
    }

    func unload() { unloadCount += 1 }
}
