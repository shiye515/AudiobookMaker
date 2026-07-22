import AVFoundation
import Foundation

/// Explicit Intel/Rosetta release-gate runner. Normal launches never enter this path.
/// The caller supplies an existing Application Support root containing the installed
/// Kokoro snapshot; the runner never downloads or mutates model artifacts.
@MainActor
enum KokoroCompatibilityAcceptanceRunner {
    static let launchArgument = "--kokoro-compatibility-acceptance"

    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let applicationSupportPath = environment["KOKORO_ACCEPTANCE_APPLICATION_SUPPORT"],
              let evidencePath = environment["KOKORO_ACCEPTANCE_EVIDENCE"] else {
            throw AcceptanceError.missingEnvironment
        }

        let platform = SpeechSwiftPlatformSupport.liveSnapshot()
        guard SpeechSwiftPlatformSupport().status() == .requiresNativeAppleSilicon else {
            throw AcceptanceError.expectedIncompatiblePlatform
        }

        let evidenceRoot = URL(filePath: evidencePath, directoryHint: .isDirectory)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        let directories = AppDirectories(
            root: URL(filePath: applicationSupportPath, directoryHint: .isDirectory)
                .standardizedFileURL,
            cacheRoot: evidenceRoot.appending(path: "Caches", directoryHint: .isDirectory)
        )
        let runtime = RoutingTTSRuntimeClient(directories: directories)

        do {
            _ = try await runtime.capabilities(for: TTSModelCatalog.cosyVoiceID)
            throw AcceptanceError.speechSwiftWasAvailable
        } catch RuntimeError.incompatibleRuntime {
            // Expected: an Intel/Rosetta process must not construct an MLX runtime.
        }

        let capabilities = try await runtime.capabilities(for: TTSModelCatalog.kokoroID)
        guard capabilities.version == TTSModelCatalog.kokoro.version,
              let voice = capabilities.voices.first else {
            throw AcceptanceError.invalidKokoroCapabilities
        }
        let output = evidenceRoot.appending(path: "kokoro-compatibility.caf")
        let result = try await runtime.synthesize(SynthesisRequest(
            text: "这是 Rosetta 与 Intel 兼容性验收。Kokoro 本地转换保持正常。",
            languageCode: "zh-CN",
            voiceIdentifier: voice.id,
            outputURL: output,
            modelID: TTSModelCatalog.kokoroID,
            modelVersion: TTSModelCatalog.kokoro.version,
            purpose: .conversion
        ))
        let asset = AVURLAsset(url: output)
        guard result.sampleRate == 24_000,
              result.channelCount == 1,
              result.durationSeconds > 0,
              try await asset.loadTracks(withMediaType: .audio).count == 1,
              try await asset.load(.duration).seconds > 0 else {
            throw RuntimeError.invalidAudio
        }

        let metrics: [String: Any] = [
            "architecture": platform.architecture.rawValue,
            "is_rosetta_translated": platform.isRosettaTranslated,
            "speech_swift_rejected": true,
            "kokoro_model_id": TTSModelCatalog.kokoroID,
            "kokoro_model_version": TTSModelCatalog.kokoro.version,
            "kokoro_voice_id": voice.id,
            "sample_rate": result.sampleRate,
            "channel_count": result.channelCount,
            "duration_seconds": result.durationSeconds,
            "output": output.lastPathComponent,
            "timestamp": Date().ISO8601Format()
        ]
        let data = try JSONSerialization.data(
            withJSONObject: metrics,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: evidenceRoot.appending(path: "metrics.json"), options: .atomic)
        FileHandle.standardOutput.write(Data(
            "Kokoro compatibility acceptance passed: \(platform.architecture.rawValue), Rosetta=\(platform.isRosettaTranslated), duration=\(result.durationSeconds)\n".utf8
        ))
    }

    private enum AcceptanceError: LocalizedError {
        case missingEnvironment
        case expectedIncompatiblePlatform
        case speechSwiftWasAvailable
        case invalidKokoroCapabilities

        var errorDescription: String? {
            switch self {
            case .missingEnvironment:
                "缺少 Kokoro 兼容性验收目录。"
            case .expectedIncompatiblePlatform:
                "此验收入口只能在 Intel 或 Rosetta 进程中运行。"
            case .speechSwiftWasAvailable:
                "speech-swift 在不兼容进程中错误地变为可用。"
            case .invalidKokoroCapabilities:
                "Kokoro 能力握手无效。"
            }
        }
    }
}
