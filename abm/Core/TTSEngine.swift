//
//  TTSEngine.swift
//  abm
//
//  引擎隔离层：所有对 soniqo/speech-swift (CosyVoiceTTS) 的调用收敛在实现类里，
//  UI 与状态机只面向本协议。升级/更换引擎（如云 API）只动实现。
//

import Foundation

/// 一次合成请求使用的音色（内置参考音频库的一条记录）。
struct VoiceSample: Identifiable, Decodable, Sendable, Equatable {
    let name: String
    let trait: String
    let audioFile: String
    let text: String
    var age: String? = nil

    var id: String { audioFile }

    enum CodingKeys: String, CodingKey {
        case name, trait, text, age
        case audioFile = "audio_file"
    }
}

enum EngineError: LocalizedError {
    case notReady
    case busy
    case voiceAudioMissing(String)

    var errorDescription: String? {
        switch self {
        case .notReady: return "模型尚未就绪，请先初始化"
        case .busy: return "已有合成任务进行中"
        case .voiceAudioMissing(let file): return "找不到音色参考音频: \(file)"
        }
    }
}

/// 一次合成的输出：24 kHz 采样 + 各阶段耗时（用于日志与耗时展示）。
struct SynthesisOutput: Sendable {
    let samples: [Float]
    let profileFromCache: Bool
    /// 参考音频解码耗时（秒）
    let decodeSeconds: Double
    /// 音色档案提取耗时（秒；缓存命中时为 0）
    let profileSeconds: Double
    /// 模型合成耗时（秒，不含解码与档案提取）
    let synthSeconds: Double
}

/// 合成中断错误（用户暂停/停止时抛出，段间安全退出并保留已有断点）
struct SynthesisInterruptedError: Error, LocalizedError {
    var errorDescription: String? { "合成已在分段边界暂停或停止" }
}

/// 线程安全的取消/中断令牌，可在 MainActor 与后台合成任务之间安全传递
public final class SynthesisCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

/// 分段合成进度与最新单段性能指标（用于实时分段进度、实时 RTF 与剩余时间估算）
public struct SegmentProgress: Sendable {
    public let done: Int
    public let total: Int
    public let rtf: Double?
    public let wordsPerSecond: Double?

    public init(done: Int, total: Int, rtf: Double? = nil, wordsPerSecond: Double? = nil) {
        self.done = done
        self.total = total
        self.rtf = rtf
        self.wordsPerSecond = wordsPerSecond
    }
}

protocol TTSEngine: AnyObject {
    /// 加载本地权重 → 说话人编码器 → 预热。长任务，通过 progress 持续回报 (0…1, 消息)。
    /// 目录文件齐全时不发起网络请求。
    func initialize(progress: @escaping @Sendable (Double, String) -> Void) async throws

    /// 分段合成（长文本自动按句切分、逐段合成拼接，24 kHz 单声道）。
    /// 中文文本内部显式指定 language；同一时刻只执行一个任务。
    /// checkpointDir: 断点缓存目录（支持断点续接与逐段落盘；nil 表示纯内存合成）；
    /// cancellationToken: 线程安全取消令牌（用于分段边界检查中断；nil 表示不检查外部中断）；
    /// onSegment: 分段进度回调（已完成段数、总段数、最新完成分段的 RTF 与字数生成速率）；log: 阶段事件回调（实时）。
    func synthesize(text: String, voice: VoiceSample,
                    checkpointDir: URL?,
                    cancellationToken: SynthesisCancellationToken?,
                    onSegment: @escaping @Sendable (SegmentProgress) -> Void,
                    log: @escaping @Sendable (String) -> Void) async throws -> SynthesisOutput
}

extension TTSEngine {
    func synthesize(text: String, voice: VoiceSample,
                    onSegment: @escaping @Sendable (SegmentProgress) -> Void,
                    log: @escaping @Sendable (String) -> Void) async throws -> SynthesisOutput {
        try await synthesize(text: text, voice: voice,
                             checkpointDir: nil, cancellationToken: nil,
                             onSegment: onSegment, log: log)
    }
}

