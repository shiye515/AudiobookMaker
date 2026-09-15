//
//  ExportPreset.swift
//  abm
//
//  导出配置模型。
//

import Foundation

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// 单文件 + 章节标记（Apple Books / 播客兼容）
    case m4b
    /// 分章节独立文件（系统 AAC 编码器输出 .m4a；macOS 无系统 MP3 编码器）
    case mp3
    case wav

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .m4b: return "M4B (带章节标记 · 推荐)"
        case .mp3: return "分章节 M4A"
        case .wav: return "WAV (无损)"
        }
    }

    var fileExtension: String {
        switch self {
        case .m4b: return "m4b"
        case .mp3: return "m4a"
        case .wav: return "wav"
        }
    }
}

struct ExportSettings: Sendable {
    var format: ExportFormat = .m4b
    var embedCoverAndMetadata = true
    /// TTS 源音频为 24kHz 单声道，Apple AAC 编码器上限约 采样率×8/3 ≈ 64kbps，超限会被拒绝
    var bitrateKbps: Int = 64
    var destinationDirectory: URL
}
