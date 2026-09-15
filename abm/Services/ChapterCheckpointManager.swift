//
//  ChapterCheckpointManager.swift
//  abm
//
//  章节分段断点管理：全分段信息与进度预写 meta.json、逐段原始采样落盘、断点有效性校验与恢复。
//

import CryptoKit
import Foundation

/// 单个分段元数据与进度
struct SegmentCheckpointItem: Codable, Sendable {
    let index: Int                  // 0-based 序号
    let text: String                // 分段文本内容
    let characterCount: Int         // 分段字数
    var isCompleted: Bool           // 是否已合成完成
    var sampleCount: Int?           // 采样点数
    var audioSeconds: Double?       // 音频时长（秒）
}

/// 章节断点总览清单（落盘至 segments/<chapterID>/meta.json）
struct ChapterCheckpoint: Codable, Sendable {
    let voiceName: String
    let textHash: String
    let totalSegments: Int
    var completedIndices: [Int]
    var segments: [SegmentCheckpointItem]
    var createdAt: Date?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case voiceName, textHash, totalSegments, completedIndices, segments, createdAt, updatedAt
    }

    init(
        voiceName: String,
        textHash: String,
        totalSegments: Int,
        completedIndices: [Int],
        segments: [SegmentCheckpointItem] = [],
        createdAt: Date? = Date(),
        updatedAt: Date? = Date()
    ) {
        self.voiceName = voiceName
        self.textHash = textHash
        self.totalSegments = totalSegments
        self.completedIndices = completedIndices
        self.segments = segments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        voiceName = try container.decode(String.self, forKey: .voiceName)
        totalSegments = try container.decode(Int.self, forKey: .totalSegments)
        completedIndices = (try? container.decode([Int].self, forKey: .completedIndices)) ?? []
        segments = (try? container.decode([SegmentCheckpointItem].self, forKey: .segments)) ?? []
        createdAt = try? container.decode(Date.self, forKey: .createdAt)
        updatedAt = try? container.decode(Date.self, forKey: .updatedAt)

        if let str = try? container.decode(String.self, forKey: .textHash) {
            textHash = str
        } else if let intVal = try? container.decode(Int.self, forKey: .textHash) {
            textHash = String(intVal)
        } else {
            textHash = ""
        }
    }
}

enum ChapterCheckpointManager {

    private static let metaFileName = "meta.json"

    /// 计算跨进程、重启稳定的确定性文本哈希（SHA256 前 16 字节十六进制）
    /// 严禁使用 String.hashValue（Swift 运行时每次启动随机 seed，会导致重启后校验全部失效）
    static func textHash(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// 在章节开始转换前初始化或恢复断点清单：
    /// 预先将章节全部分段及进度写入 meta.json，若存在合法的断点缓存则恢复并返回已完成分段。
    static func initializeOrResumeCheckpoint(
        dir: URL,
        voiceName: String,
        textHash: String,
        segments: [String]
    ) -> ChapterCheckpoint {
        let metaURL = dir.appendingPathComponent(metaFileName)
        let fm = FileManager.default

        // 尝试加载既有 meta.json
        if fm.fileExists(atPath: metaURL.path),
           let data = try? Data(contentsOf: metaURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let existing = (try? decoder.decode(ChapterCheckpoint.self, from: data))
                ?? (try? JSONDecoder().decode(ChapterCheckpoint.self, from: data)) {
                // 校验一致性：音色、文本哈希、总分段数必须一致
                if existing.voiceName == voiceName,
                   existing.textHash == textHash,
                   existing.totalSegments == segments.count {
                    // 校验磁盘上真实存在的分段采样文件
                    let validIndices = existing.completedIndices.filter { idx in
                        let segURL = segmentURL(in: dir, index: idx)
                        return fm.fileExists(atPath: segURL.path)
                    }

                    var verified = existing
                    verified.completedIndices = validIndices.sorted()

                    // 若 segments 列表为空（旧版本升级兼容），补充完整分段列表
                    if verified.segments.isEmpty || verified.segments.count != segments.count {
                        verified.segments = segments.enumerated().map { i, seg in
                            SegmentCheckpointItem(
                                index: i,
                                text: seg,
                                characterCount: seg.count,
                                isCompleted: validIndices.contains(i),
                                sampleCount: nil,
                                audioSeconds: nil
                            )
                        }
                    } else {
                        // 同步每个分段的 isCompleted 标记
                        for i in verified.segments.indices {
                            verified.segments[i].isCompleted = validIndices.contains(verified.segments[i].index)
                        }
                    }
                    verified.updatedAt = Date()
                    saveCheckpointMeta(verified, to: dir)
                    OutputManager.appendLog("[checkpoint] 发现有效断点清单，已恢复 \(validIndices.count)/\(segments.count) 段")
                    return verified
                } else {
                    OutputManager.appendLog("[checkpoint] 断点参数已变更 (voice: \(existing.voiceName)==\(voiceName), textHash: \(existing.textHash)==\(textHash), segments: \(existing.totalSegments)==\(segments.count))，重置清单")
                    try? fm.removeItem(at: dir)
                }
            } else {
                OutputManager.appendLog("[checkpoint] ⚠️ 发现断点目录但 meta.json 损坏，重置清单")
                try? fm.removeItem(at: dir)
            }
        }

        // 全新创建：在合成开始前预先将全部分段与待处理状态写入 meta.json
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
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
        let initial = ChapterCheckpoint(
            voiceName: voiceName,
            textHash: textHash,
            totalSegments: segments.count,
            completedIndices: [],
            segments: items,
            createdAt: Date(),
            updatedAt: Date()
        )
        saveCheckpointMeta(initial, to: dir)
        OutputManager.appendLog("[checkpoint] 章节预分段初始化完成（共 \(segments.count) 段），分段清单已全量落盘至 meta.json")
        return initial
    }

    /// 读取单个分段的原始 Float 采样数据
    static func loadSegmentSamples(from dir: URL, index: Int) -> [Float]? {
        let file = segmentURL(in: dir, index: index)
        guard let data = try? Data(contentsOf: file), data.count >= MemoryLayout<Float>.size else {
            return nil
        }
        let count = data.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return samples
    }

    /// 原子保存单个分段的采样数据，并实时更新 meta.json 中的分段进度
    static func saveSegmentSamples(
        to dir: URL,
        index: Int,
        samples: [Float],
        checkpoint: inout ChapterCheckpoint
    ) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // ① 写入分段二进制 Float 文件（零编解码损耗）
        let file = segmentURL(in: dir, index: index)
        var data = Data(capacity: samples.count * MemoryLayout<Float>.size)
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: file, options: [.atomic])

        // ② 更新 checkpoint 分段进度清单
        if !checkpoint.completedIndices.contains(index) {
            checkpoint.completedIndices.append(index)
            checkpoint.completedIndices.sort()
        }
        if index < checkpoint.segments.count {
            checkpoint.segments[index].isCompleted = true
            checkpoint.segments[index].sampleCount = samples.count
            checkpoint.segments[index].audioSeconds = Double(samples.count) / 24_000.0
        }
        checkpoint.updatedAt = Date()

        // ③ 原子回写 meta.json
        saveCheckpointMeta(checkpoint, to: dir)
    }

    /// 保存断点元数据至 meta.json
    static func saveCheckpointMeta(_ checkpoint: ChapterCheckpoint, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let metaData = try? encoder.encode(checkpoint) {
            let metaURL = dir.appendingPathComponent(metaFileName)
            try? metaData.write(to: metaURL, options: [.atomic])
        }
    }

    /// 清空分段目录
    static func clearCheckpoint(at dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private static func segmentURL(in dir: URL, index: Int) -> URL {
        dir.appendingPathComponent(String(format: "seg_%04d.raw", index))
    }
}
