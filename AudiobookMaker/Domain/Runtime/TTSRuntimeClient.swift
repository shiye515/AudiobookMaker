import AVFoundation
import Foundation

nonisolated enum RuntimePlatformRequirement: String, Codable, Equatable, Sendable {
    case anyMac
    case nativeAppleSilicon
}

nonisolated enum RuntimeMemoryTier: String, Codable, Equatable, Sendable {
    case low
    case medium
    case high
}

nonisolated enum RuntimeCancellationBoundary: String, Codable, Equatable, Sendable {
    case immediate
    case safeChunkBoundary
}

nonisolated struct RuntimeCapabilities: Codable, Equatable, Sendable {
    let runtimeID: String
    let displayName: String
    let version: String
    let maximumTextLength: Int
    let recommendedConcurrency: Int
    let supportsImmediateCancellation: Bool
    let outputFileType: String
    let supportedLanguages: [String]
    let voices: [TTSVoiceDescriptor]
    let platformRequirement: RuntimePlatformRequirement
    let maximumTokenBudget: Int?
    let memoryTier: RuntimeMemoryTier
    let cancellationBoundary: RuntimeCancellationBoundary

    init(
        runtimeID: String,
        displayName: String,
        version: String,
        maximumTextLength: Int,
        recommendedConcurrency: Int = 1,
        supportsImmediateCancellation: Bool,
        outputFileType: String = "caf",
        supportedLanguages: [String] = [],
        voices: [TTSVoiceDescriptor] = [],
        platformRequirement: RuntimePlatformRequirement = .anyMac,
        maximumTokenBudget: Int? = nil,
        memoryTier: RuntimeMemoryTier = .low,
        cancellationBoundary: RuntimeCancellationBoundary? = nil
    ) {
        self.runtimeID = runtimeID
        self.displayName = displayName
        self.version = version
        self.maximumTextLength = maximumTextLength
        self.recommendedConcurrency = recommendedConcurrency
        self.supportsImmediateCancellation = supportsImmediateCancellation
        self.outputFileType = outputFileType
        self.supportedLanguages = supportedLanguages
        self.voices = voices
        self.platformRequirement = platformRequirement
        self.maximumTokenBudget = maximumTokenBudget
        self.memoryTier = memoryTier
        self.cancellationBoundary = cancellationBoundary
            ?? (supportsImmediateCancellation ? .immediate : .safeChunkBoundary)
    }
}

nonisolated enum SynthesisPurpose: String, Codable, Equatable, Sendable {
    case conversion
    case preview
}

nonisolated struct SynthesisRequest: Equatable, Sendable {
    let requestID: UUID
    let text: String
    let languageCode: String?
    let voiceIdentifier: String?
    let outputURL: URL
    let modelID: String
    let modelVersion: String
    let purpose: SynthesisPurpose

    init(
        requestID: UUID = UUID(),
        text: String,
        languageCode: String? = nil,
        voiceIdentifier: String? = nil,
        outputURL: URL,
        modelID: String = "com.audiobookmaker.apple-system-speech",
        modelVersion: String = "system",
        purpose: SynthesisPurpose = .conversion
    ) {
        self.requestID = requestID
        self.text = text
        self.languageCode = languageCode
        self.voiceIdentifier = voiceIdentifier
        self.outputURL = outputURL
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.purpose = purpose
    }
}

nonisolated struct SynthesisResult: Equatable, Sendable {
    let requestID: UUID
    let audioURL: URL
    let durationSeconds: Double
    let sampleRate: Double
    let channelCount: Int
}

nonisolated enum RuntimeError: Error, StableAppError, Equatable, Sendable {
    case incompatibleRuntime
    case modelUnavailable
    case invalidText
    case textTooLong(maximum: Int)
    case invalidOutputPath
    case synthesisFailed(String)
    case invalidAudio
    case timedOut
    case cancelled
    case connectionInvalidated

    var errorDescription: String? {
        switch self {
        case .incompatibleRuntime: String(localized: "语音运行时与当前设备不兼容。")
        case .modelUnavailable: String(localized: "所选语音模型当前不可用。")
        case .invalidText: String(localized: "章节没有可转换的正文。")
        case let .textTooLong(maximum): String(
            format: String(localized: "文本片段超过运行时上限（%lld 个字符）。"), maximum
        )
        case .invalidOutputPath: String(localized: "音频输出位置无效。")
        case let .synthesisFailed(message): String(
            format: String(localized: "语音生成失败：%@"), message
        )
        case .invalidAudio: String(localized: "运行时返回了无效音频。")
        case .timedOut: String(localized: "语音生成超时。")
        case .cancelled: String(localized: "语音生成已取消。")
        case .connectionInvalidated: String(localized: "语音服务连接已中断。")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .modelUnavailable, .incompatibleRuntime:
            String(localized: "请在模型设置中选择一个可用的本机语音。")
        case .timedOut, .connectionInvalidated, .synthesisFailed:
            String(localized: "请稍后重试；已完成的章节不会丢失。")
        case .invalidText, .textTooLong:
            String(localized: "请重新解析该章节或减小语音片段长度。")
        case .invalidOutputPath:
            String(localized: "请重新开始任务，系统会创建新的安全输出位置。")
        case .invalidAudio:
            String(localized: "请重试该章节；无效音频不会进入 M4B 封装。")
        case .cancelled:
            String(localized: "可以从已保存的进度继续转换。")
        }
    }

    var code: String {
        switch self {
        case .incompatibleRuntime: "runtime.incompatible"
        case .modelUnavailable: "runtime.modelUnavailable"
        case .invalidText: "runtime.invalidText"
        case .textTooLong: "runtime.textTooLong"
        case .invalidOutputPath: "runtime.invalidOutputPath"
        case .synthesisFailed: "runtime.synthesisFailed"
        case .invalidAudio: "runtime.invalidAudio"
        case .timedOut: "runtime.timedOut"
        case .cancelled: "runtime.cancelled"
        case .connectionInvalidated: "runtime.connectionInvalidated"
        }
    }

    var isTransient: Bool {
        switch self {
        case .synthesisFailed, .timedOut, .connectionInvalidated:
            true
        default:
            false
        }
    }
}

protocol TTSRuntimeClient: Sendable {
    func capabilities() async throws -> RuntimeCapabilities
    func capabilities(for modelID: String) async throws -> RuntimeCapabilities
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult
    func cancel(requestID: UUID) async
}

extension TTSRuntimeClient {
    func capabilities(for modelID: String) async throws -> RuntimeCapabilities {
        // Single-runtime adapters and deterministic test doubles do not route by
        // catalog ID. Multi-model routers override this method and validate IDs.
        try await capabilities()
    }
}
