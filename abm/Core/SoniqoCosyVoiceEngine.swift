//
//  SoniqoCosyVoiceEngine.swift
//  abm
//
//  TTSEngine 唯一实现：CosyVoiceTTS 框架调用的唯一接触点。
//  speech-swift @ d655076badd143f99c9ce19642fbea8b643ccc0b（无 release，已锁 commit）。
//  用 actor 串行化：CosyVoiceTTSModel 非线程安全，且整段合成是同步阻塞调用。
//

import AVFoundation
import AudioCommon
import CosyVoiceTTS
import Foundation
import MLX

actor SoniqoCosyVoiceEngine: TTSEngine {

    /// 8bit 量化版（LLM int8 + DiT bf16）。注意：框架已下线 4bit（fromPretrained 强校验
    /// bits ∈ {8,16}，CLI 变体也只有 bf16/8bit/8bit-full；soniqo 指南的 4bit 表格已过时）。
    nonisolated static let modelID = "aufklarer/CosyVoice3-0.5B-MLX-8bit"

    private var model: CosyVoiceTTSModel?
    private var campp: CamPlusPlusSpeaker?
    private var tokenizer: SpeechTokenizerModel?

    /// 音色档案缓存（懒提取，进程内复用；单个提取实测 ~0.73s）
    private var profiles: [String: CosyVoiceVoiceProfile] = [:]
    private(set) var isBusy = false

    func initialize(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        // ① 预下载（自管进度：文件名 + 字节级 MB 计数，每 MB 上报一次）。
        //    "*.safetensors" 通配覆盖 llm/flow/hifigan/speech_tokenizer，
        //    其余小文件（vocab/merges/tokenizer_config/flow_noise）显式列出。
        let cacheDir = try HuggingFaceDownloader.getCacheDirectory(for: Self.modelID)
        progress(0.02, "连接 HuggingFace…")
        let totalMB = try await Self.fetchRepoTotalMB(modelID: Self.modelID)
        try await HuggingFaceDownloader.downloadWeights(
            modelId: Self.modelID,
            to: cacheDir,
            additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json",
                              "flow_noise.bin", "speech_tokenizer.safetensors"],
            progressHandler: { fraction in
                let doneMB = Int(fraction * Double(totalMB))
                progress(0.02 + fraction * 0.58,
                         "下载模型 \(doneMB)/\(totalMB) MB（\(Int(fraction * 100))%）")
            }
        )

        // ② 缓存已完整，fromPretrained 直接离线加载（不再下载）
        progress(0.60, "加载模型权重…")
        let model = try await CosyVoiceTTSModel.fromPretrained(
            modelId: Self.modelID,
            progressHandler: { p, msg in
                progress(0.60 + p * 0.22, "加载 \(msg)")
            }
        )
        self.model = model

        // ③ CAM++（~14 MB，首用自动下载）
        progress(0.85, "下载/加载 CAM++ 说话人编码器…")
        let campp = try await CamPlusPlusSpeaker.fromPretrained(
            modelId: "aufklarer/CamPlusPlus-Speaker-CoreML",
            progressHandler: { p, _ in
                progress(0.85 + p * 0.07, "CAM++ \(Int(p * 100))%")
            }
        )
        self.campp = campp

        // ④ 预热 + 语音 tokenizer（已在 ① 中下载）
        progress(0.93, "预热 MLX 计算图…")
        model.warmUp()

        progress(0.96, "加载语音 tokenizer…")
        let tokenizer = SpeechTokenizerModel()
        try CosyVoiceWeightLoader.loadSpeechTokenizer(
            tokenizer,
            from: cacheDir.appendingPathComponent("speech_tokenizer.safetensors"))
        self.tokenizer = tokenizer

        progress(1.0, "就绪")
    }

    func synthesize(text: String, voice: VoiceSample,
                    checkpointDir: URL? = nil,
                    cancellationToken: SynthesisCancellationToken? = nil,
                    onSegment: @escaping @Sendable (SegmentProgress) -> Void,
                    log: @escaping @Sendable (String) -> Void) async throws -> SynthesisOutput {
        guard let model, let campp, let tokenizer else { throw EngineError.notReady }
        guard !isBusy else { throw EngineError.busy }
        isBusy = true
        defer {
            isBusy = false
            MLX.Memory.clearCache()
        }

        var profileFromCache = true
        var decodeSeconds: Double = 0
        var profileSeconds: Double = 0
        let profile: CosyVoiceVoiceProfile
        if let cached = profiles[voice.id] {
            profile = cached
            log("音色档案缓存命中")
        } else {
            profileFromCache = false
            guard let audioURL = VoiceLibrary.audioURL(for: voice) else {
                throw EngineError.voiceAudioMissing(voice.audioFile)
            }
            log("音色档案缓存未命中，开始提取")
            let t0 = CFAbsoluteTimeGetCurrent()
            let (samples, sampleRate) = try Self.decodeMono(url: audioURL)
            decodeSeconds = CFAbsoluteTimeGetCurrent() - t0
            log(String(format: "参考音频解码完成: %.1fs @ %d Hz（耗时 %.2fs）",
                       Double(samples.count) / Double(sampleRate), sampleRate, decodeSeconds))

            let t1 = CFAbsoluteTimeGetCurrent()
            profile = try autoreleasepool {
                try model.extractVoiceProfile(
                    audio: samples,
                    sampleRate: sampleRate,
                    speechTokenizer: tokenizer,
                    camppSpeaker: campp,
                    referenceTranscript: voice.text
                )
            }
            profileSeconds = CFAbsoluteTimeGetCurrent() - t1
            profiles[voice.id] = profile
            log(String(format: "音色档案提取完成: %.2fs", profileSeconds))
            MLX.Memory.clearCache()
        }

        // 长文本分段：自适应目标字数与硬上限（根据系统显存规模动态调整）
        let (adaptiveTarget, adaptiveHardMax) = TextChunker.adaptiveRange
        let segments = TextChunker.split(text, target: adaptiveTarget, hardMax: adaptiveHardMax)
        let total = segments.count
        log(String(format: "文本切分为 %d 段（自适应: target=%d 字/段，硬上限 %d 字 | 系统总显存 %d MB，高水位阈值 %d MB）",
                   total, adaptiveTarget, adaptiveHardMax,
                   Telemetry.totalPhysicalMemoryMB, Telemetry.adaptiveMemoryThresholdMB))

        // 段间短静音（150ms @ 24kHz）
        let gap = [Float](repeating: 0, count: Int(0.15 * 24_000))
        var segmentSamples = [[Float]?](repeating: nil, count: total)
        var synthSeconds: Double = 0
        var emptySegments: [Int] = []

        // ① 断点检查与加载：转换开始前预先将全部分段与待合成状态写入 meta.json，或恢复既有断点
        let textHash = ChapterCheckpointManager.textHash(for: text)
        var checkpoint: ChapterCheckpoint
        if let dir = checkpointDir {
            checkpoint = ChapterCheckpointManager.initializeOrResumeCheckpoint(
                dir: dir,
                voiceName: voice.name,
                textHash: textHash,
                segments: segments
            )
            for idx in checkpoint.completedIndices where idx < total {
                if let cached = ChapterCheckpointManager.loadSegmentSamples(from: dir, index: idx) {
                    segmentSamples[idx] = cached
                }
            }
            let cachedCount = segmentSamples.compactMap { $0 }.count
            if cachedCount > 0 {
                log("命中断点缓存：已恢复 \(cachedCount)/\(total) 段，跳过已生成分段")
                onSegment(SegmentProgress(done: cachedCount, total: total, rtf: nil, wordsPerSecond: nil))
            }
        } else {
            let items = segments.enumerated().map { i, seg in
                SegmentCheckpointItem(
                    index: i,
                    text: seg,
                    characterCount: seg.count,
                    isCompleted: false,
                    sampleCount: nil,
                    audioSeconds: nil
                )
            }
            checkpoint = ChapterCheckpoint(
                voiceName: voice.name,
                textHash: textHash,
                totalSegments: total,
                completedIndices: [],
                segments: items
            )
        }

        // ② 分段合成循环
        for (index, segment) in segments.enumerated() {
            // 已有缓存分段直接跳过模型推理
            if segmentSamples[index] != nil {
                continue
            }

            let t = CFAbsoluteTimeGetCurrent()
            // 方案 A：单段合成包裹在 autoreleasepool 中，每一段结束立即排空临时 Metal/CoreML 引用
            let samples: [Float] = autoreleasepool {
                model.synthesize(
                    text: segment,
                    language: "chinese",
                    speakerEmbedding: profile.speakerEmbedding,
                    promptToken: profile.promptToken,
                    promptFeat: profile.promptFeat,
                    promptText: profile.promptText,
                    verbose: false
                )
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - t
            synthSeconds += elapsed

            var segmentRTF: Double? = nil
            var segmentWordsPerSecond: Double? = nil

            if samples.isEmpty {
                // 对齐上游 issue #1654 的段尾丢失现象：记录并跳过，不中断整体
                emptySegments.append(index + 1)
                log("[seg \(index + 1)/\(total)] ⚠️ 该段生成 0 采样，已跳过: “\(segment)”")
            } else {
                segmentSamples[index] = samples
                let segmentAudioSeconds = Double(samples.count) / 24_000.0
                if segmentAudioSeconds > 0, elapsed > 0 {
                    let rtf = elapsed / segmentAudioSeconds
                    segmentRTF = rtf
                    if !segment.isEmpty {
                        segmentWordsPerSecond = Double(segment.count) / elapsed
                    }
                }
                // 逐段原子落盘
                if let dir = checkpointDir {
                    try? ChapterCheckpointManager.saveSegmentSamples(
                        to: dir,
                        index: index,
                        samples: samples,
                        checkpoint: &checkpoint
                    )
                }
                let rtfText = segmentRTF.map { String(format: "，RTF %.2fx", $0) } ?? ""
                log(String(format: "[seg %d/%d] %.2fs，%d 采样（%.2fs 音频%@）: “%@”",
                           index + 1, total, elapsed, samples.count,
                           segmentAudioSeconds, rtfText, segment))
            }

            let doneCount = segmentSamples.compactMap { $0 }.count
            onSegment(SegmentProgress(
                done: doneCount,
                total: total,
                rtf: segmentRTF,
                wordsPerSecond: segmentWordsPerSecond
            ))

            // 方案 B：显存水位自适应治理（最大为系统总显存的一半，最小 5GB）
            let currentFootprint = Telemetry.physFootprintMB()
            let thresholdMB = Telemetry.adaptiveMemoryThresholdMB
            if currentFootprint >= thresholdMB {
                MLX.Memory.clearCache()
                let afterFootprint = Telemetry.physFootprintMB()
                log(String(format: "[seg %d/%d] 显存达到自适应高水位阈值 (%d MB >= %d MB)，已触发 MLX 缓存清理 -> %d MB",
                           index + 1, total, currentFootprint, thresholdMB, afterFootprint))
            }

            // ③ 段间中断检查：秒级响应暂停与停止
            if Task.isCancelled || cancellationToken?.isCancelled == true {
                log("[seg \(index + 1)/\(total)] 响应暂停/停止请求，已落盘断点，安全挂起")
                throw SynthesisInterruptedError()
            }
        }

        if !emptySegments.isEmpty {
            log("⚠️ 共 \(emptySegments.count) 段生成失败被跳过: \(emptySegments)")
        }

        // ③ 拼装所有分段采样
        var all: [Float] = []
        for i in 0..<total {
            if let s = segmentSamples[i] {
                all.append(contentsOf: s)
                if i < total - 1 { all.append(contentsOf: gap) }
            }
        }

        return SynthesisOutput(
            samples: all,
            profileFromCache: profileFromCache,
            decodeSeconds: decodeSeconds,
            profileSeconds: profileSeconds,
            synthSeconds: synthSeconds
        )
    }

    /// 下载模型全量文件（缓存已存在的文件自动跳过/续传）。
    nonisolated static func downloadModelFiles(
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let cacheDir = try HuggingFaceDownloader.getCacheDirectory(for: modelID)
        progress(0, "连接 HuggingFace…")
        let totalMB = await fetchRepoTotalMB(modelID: modelID)
        try await HuggingFaceDownloader.downloadWeights(
            modelId: modelID,
            to: cacheDir,
            additionalFiles: ["vocab.json", "merges.txt", "tokenizer_config.json",
                              "flow_noise.bin", "speech_tokenizer.safetensors"],
            progressHandler: { fraction in
                let doneMB = Int(fraction * Double(totalMB))
                progress(fraction,
                         "下载模型 \(doneMB)/\(totalMB) MB（\(Int(fraction * 100))%）")
            }
        )
        progress(1.0, "模型文件已就绪")
    }

    /// 缓存可用性检查（纯离线）：权重齐全 + 分词器就位。
    nonisolated static func isModelCacheUsable() -> Bool {
        guard let dir = try? HuggingFaceDownloader.getCacheDirectory(for: modelID) else { return false }
        let fm = FileManager.default
        return HuggingFaceDownloader.weightsExist(in: dir)
            && fm.fileExists(atPath: dir.appendingPathComponent("vocab.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("speech_tokenizer.safetensors").path)
    }

    /// 从 HF tree API 汇总所需文件总大小（MB），用于下载进度显示；失败返回估算值。
    nonisolated static func fetchRepoTotalMB(modelID: String) async -> Int {
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelID)/tree/main"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return 2_100 }
        var total = 0
        for entry in entries {
            guard entry["type"] as? String == "file" else { continue }
            total += entry["size"] as? Int ?? 0
        }
        return max(1, total / 1_000_000)
    }

    // MARK: - 参考音频解码

    /// 解码为单声道 Float32（任意通道数下混），保留原采样率由框架内部重采样。
    nonisolated static func decodeMono(url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(max(0, file.length)))
        else {
            throw NSError(domain: "TTSEngine", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法分配 PCM buffer: \(url.path)"])
        }
        try file.read(into: buffer)

        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: frames)
        guard let channelData = buffer.floatChannelData else {
            throw NSError(domain: "TTSEngine", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "非 Float PCM 格式: \(url.path)"])
        }
        for c in 0..<channels {
            let ptr = channelData[c]
            for i in 0..<frames { mono[i] += ptr[i] }
        }
        if channels > 1 {
            let scale = Float(1) / Float(channels)
            for i in 0..<frames { mono[i] *= scale }
        }
        return (mono, Int(format.sampleRate))
    }
}
