//
//  OutputManager.swift
//  abm
//
//  合成输出：WAV 唯一命名落盘（原子写入）、运行日志追加、访达打开目录。
//

import AppKit
import Foundation

enum OutputManager {

    private static let logTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static let fileTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    /// 本次进程标识（多实例排查用）。
    static let pid = ProcessInfo.processInfo.processIdentifier

    /// 把合成结果写成 WAV（16-bit PCM mono）到指定目录。
    /// 文件名含毫秒时间戳 + run ID，绝不与既有文件重名；原子写入不留残缺文件。
    static func writeWav(samples: [Float], sampleRate: Int = 24_000,
                         voiceName: String, runID: String,
                         destinationDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let name = "\(fileTimestampFormatter.string(from: Date()))-\(runID)-\(voiceName).wav"
        let url = destinationDirectory.appendingPathComponent(name)
        try writeWav16(samples: samples, sampleRate: sampleRate, to: url)
        return url
    }

    /// 追加一行带毫秒时间戳与 pid 的日志到 abm.log。
    static func appendLog(_ message: String) {
        let line = "[\(logTimestampFormatter.string(from: Date()))] [pid=\(pid)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: AppPaths.logFile.path) {
                if let handle = try? FileHandle(forWritingTo: AppPaths.logFile) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    return
                }
            }
            try? line.write(to: AppPaths.logFile, atomically: true, encoding: .utf8)
        }
    }

    /// 在访达中打开目录。
    static func reveal(directory: URL) {
        try? AppPaths.ensureOutputDirectories()
        NSWorkspace.shared.open(directory)
    }

    /// 文件字节数（取不到返回 -1）。
    static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
    }

    // MARK: - WAV 写出（44 字节 header）

    static func writeWav16(samples: [Float], sampleRate: Int, to url: URL) throws {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            var v = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }

        var header = Data()
        func ascii(_ s: String) { header.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { header.append(contentsOf: $0) } }

        let dataLen = UInt32(pcm.count)
        ascii("RIFF"); u32(36 + dataLen); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(dataLen)

        try (header + pcm).write(to: url, options: [.atomic])
    }
}
