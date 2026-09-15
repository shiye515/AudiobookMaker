//
//  AudiobookExporter.swift
//  abm
//
//  导出：M4B（整书转码由内置 ffmpeg 单命令完成：concat 拼接 + AAC 编码 + FFMETADATA 章节 +
//  封面 attached_pic + 元数据）、分章节 M4A（系统 AAC 编码器；macOS 无系统 MP3 编码器，
//  不引入第三方编码依赖）、WAV（直接复制章节文件）。
//  背景：macOS 26 的 AVAssetWriter 音频编码管线在长会话下内部队列膨胀、速度崩塌（80×→1.3×），
//  且其章节写回 API 已失效——故整书转码整体切换到内置 ffmpeg（构建见 scripts/build-ffmpeg.sh）。
//

import AVFoundation
import Foundation

enum AudiobookExporter {

    struct ExportOutcome: Sendable {
        let productURLs: [URL]
    }

    static func export(book: BookProject, settings: ExportSettings,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> ExportOutcome {
        let doneChapters = book.chapters.filter { $0.status == .done }
        guard !doneChapters.isEmpty else {
            throw ExportError.noCompletedChapters
        }
        try FileManager.default.createDirectory(at: settings.destinationDirectory,
                                                withIntermediateDirectories: true)
        switch settings.format {
        case .m4b:
            OutputManager.appendLog("[export] M4B 导出开始 | 完成章节 \(doneChapters.count) 个 | 目标 \(settings.destinationDirectory.path)")
            return try await exportM4B(book: book, chapters: doneChapters,
                                       settings: settings, progress: progress)
        case .mp3:
            OutputManager.appendLog("[export] 分章节 M4A 导出开始 | 完成章节 \(doneChapters.count) 个 | 目标 \(settings.destinationDirectory.path)")
            return try await exportPerChapter(book: book, chapters: doneChapters,
                                              settings: settings, progress: progress)
        case .wav:
            OutputManager.appendLog("[export] WAV 导出开始 | 完成章节 \(doneChapters.count) 个 | 目标 \(settings.destinationDirectory.path)")
            return try exportWAV(book: book, chapters: doneChapters, settings: settings, progress: progress)
        }
    }

    enum ExportError: LocalizedError {
        case noCompletedChapters
        case missingAudio(String)
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noCompletedChapters: return "书内没有已完成的章节可导出"
            case .missingAudio(let ch): return "找不到章节音频：\(ch)"
            case .exportFailed(let why): return "导出失败：\(why)"
            }
        }
    }

    // MARK: - M4B（整书转码，内置 ffmpeg 单命令）

    private static func exportM4B(book: BookProject, chapters: [Chapter], settings: ExportSettings,
                                  progress: @escaping @Sendable (Double) -> Void) async throws -> ExportOutcome {
        // 扫描各章时长，得到章节起点与总时长（0–5%）
        var cursor = CMTime.zero
        var chapterURLs: [URL] = []
        var chapterStartSeconds: [Double] = []
        for (i, chapter) in chapters.enumerated() {
            try Task.checkCancellation()
            guard let url = LibraryStore.audioURL(book: book, chapter: chapter) else {
                throw ExportError.missingAudio(chapter.fullTitle)
            }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard (try await asset.loadTracks(withMediaType: .audio).first) != nil else {
                throw ExportError.missingAudio(chapter.fullTitle)
            }
            chapterURLs.append(url)
            chapterStartSeconds.append(CMTimeGetSeconds(cursor))
            cursor = cursor + duration
            OutputManager.appendLog("[export] 章节扫描 \(i + 1)/\(chapters.count): \(chapter.fullTitle) | 时长 \(String(format: "%.1f", CMTimeGetSeconds(duration)))s")
            progress(Double(i + 1) / Double(chapters.count + 1) * 0.05)
        }
        let totalSeconds = CMTimeGetSeconds(cursor)

        let outputURL = settings.destinationDirectory
            .appendingPathComponent("\(safeFileName(book.title)).m4b")
        try? FileManager.default.removeItem(at: outputURL)

        do {
            try await transcodeBookViaFFmpeg(chapterURLs: chapterURLs,
                                             chapterStartSeconds: chapterStartSeconds,
                                             chapterTitles: chapters.map(\.fullTitle),
                                             totalSeconds: totalSeconds,
                                             settings: settings,
                                             book: book,
                                             outputURL: outputURL,
                                             progressBase: 0.05, progressSpan: 0.94,
                                             progress: progress)
        } catch is CancellationError {
            // 取消 = 完全取消：不遗留半成品文件
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }

        progress(1.0)
        return ExportOutcome(productURLs: [outputURL])
    }

    // MARK: - 分章节 M4A

    private static func exportPerChapter(book: BookProject, chapters: [Chapter], settings: ExportSettings,
                                         progress: @escaping @Sendable (Double) -> Void) async throws -> ExportOutcome {
        var outputs: [URL] = []
        let bookDir = settings.destinationDirectory.appendingPathComponent(safeFileName(book.title),
                                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        do {
            for (i, chapter) in chapters.enumerated() {
                try Task.checkCancellation()
                guard let sourceURL = LibraryStore.audioURL(book: book, chapter: chapter) else {
                    throw ExportError.missingAudio(chapter.fullTitle)
                }
                let outputURL = bookDir.appendingPathComponent(
                    "\(String(format: "%03d", chapter.index))-\(safeFileName(chapter.fullTitle)).m4a")
                try? FileManager.default.removeItem(at: outputURL)
                let asset = AVURLAsset(url: sourceURL)
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw ExportError.exportFailed("无法创建导出会话")
                }
                var metadata: [AVMetadataItem] = [
                    makeItem(.commonIdentifierTitle, chapter.fullTitle as NSString),
                    makeItem(.commonIdentifierArtist, book.author as NSString),
                    makeItem(.commonIdentifierAlbumName, book.title as NSString)
                ]
                if settings.embedCoverAndMetadata,
                   let coverURL = LibraryStore.coverURL(for: book),
                   let data = try? Data(contentsOf: coverURL) {
                    metadata.append(makeItem(.commonIdentifierArtwork, data as NSData))
                }
                session.metadata = metadata
                session.outputURL = outputURL
                session.outputFileType = .m4a
                // 每章占 1/N 进度段，段内用会话真实进度填充
                let base = Double(i) / Double(chapters.count)
                let span = 1.0 / Double(chapters.count)
                guard await runSession(session, stage: "转码章节 \(i + 1)/\(chapters.count): \(chapter.fullTitle)",
                                       progressBase: base, progressSpan: span, progress: progress) else {
                    throw ExportError.exportFailed(session.error?.localizedDescription ?? "未知错误")
                }
                outputs.append(outputURL)
            }
        } catch is CancellationError {
            // 取消 = 完全取消：清理已产出的分章节文件
            outputs.forEach { try? FileManager.default.removeItem(at: $0) }
            throw CancellationError()
        }
        return ExportOutcome(productURLs: outputs)
    }

    // MARK: - WAV（复制章节文件）

    private static func exportWAV(book: BookProject, chapters: [Chapter], settings: ExportSettings,
                                  progress: @escaping @Sendable (Double) -> Void) throws -> ExportOutcome {
        let bookDir = settings.destinationDirectory.appendingPathComponent(safeFileName(book.title),
                                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
        var outputs: [URL] = []
        do {
            for (i, chapter) in chapters.enumerated() {
                try Task.checkCancellation()
                guard let sourceURL = LibraryStore.audioURL(book: book, chapter: chapter) else {
                    throw ExportError.missingAudio(chapter.fullTitle)
                }
                let outputURL = bookDir.appendingPathComponent(
                    "\(String(format: "%03d", chapter.index))-\(safeFileName(chapter.fullTitle)).wav")
                try? FileManager.default.removeItem(at: outputURL)
                try FileManager.default.copyItem(at: sourceURL, to: outputURL)
                outputs.append(outputURL)
                OutputManager.appendLog("[export] 复制章节 \(i + 1)/\(chapters.count): \(chapter.fullTitle)")
                progress(Double(i + 1) / Double(chapters.count))
            }
        } catch is CancellationError {
            outputs.forEach { try? FileManager.default.removeItem(at: $0) }
            throw CancellationError()
        }
        return ExportOutcome(productURLs: outputs)
    }

    // MARK: - 整书转码（内置 ffmpeg 单命令：concat + AAC + 章节 + 封面 + 元数据）

    /// 应用内置的极简静态 ffmpeg（随包分发，见 scripts/build-ffmpeg.sh）；不存在时回退 Homebrew 路径
    private nonisolated static func locateFFmpeg() -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("ffmpeg").path)
            candidates.append(res.appendingPathComponent("Tools/ffmpeg").path)
        }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("ffmpeg").path)
        }
        candidates.append(contentsOf: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// FFMETADATA 值转义：= ; # \ 与换行需反斜杠转义
    private nonisolated static func escapeFFMetadataValue(_ value: String) -> String {
        var v = value
        for (raw, escaped) in [("\\", "\\\\"), ("=", "\\="), (";", "\\;"), ("#", "\\#"), ("\n", "\\n")] {
            v = v.replacingOccurrences(of: raw, with: escaped)
        }
        return v
    }

    /// 单条 ffmpeg 命令完成整书导出：concat 拼接章节 WAV → AAC 编码 → FFMETADATA 章节 +
    /// 标题/作者元数据 + 封面 attached_pic。
    /// 进度与 stderr 均落临时文件由本侧轮询读取（不用管道/handler——GUI 应用内曾出现
    /// stdout 管道零输出的未知停滞，文件轮询行为可预期）；取消经 withTaskCancellationHandler
    /// 即时 terminate 进程。`nonisolated` 使轮询与等待运行在后台执行器。
    private nonisolated static func transcodeBookViaFFmpeg(chapterURLs: [URL],
                                                           chapterStartSeconds: [Double],
                                                           chapterTitles: [String],
                                                           totalSeconds: Double,
                                                           settings: ExportSettings,
                                                           book: BookProject,
                                                           outputURL: URL,
                                                           progressBase: Double,
                                                           progressSpan: Double,
                                                           progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let ffmpegPath = locateFFmpeg() else {
            throw ExportError.exportFailed("未找到内置 ffmpeg 组件，无法导出 M4B")
        }
        try Task.checkCancellation()

        func escapeSingleQuoted(_ path: String) -> String {
            path.replacingOccurrences(of: "'", with: "'\\''")
        }

        // concat 解复用列表（逐章 WAV，同源 TTS 管线保证参数一致）
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("abm_concat_\(UUID().uuidString).txt")
        let listContent = chapterURLs
            .map { "file 'file:\(escapeSingleQuoted($0.path))'" }
            .joined(separator: "\n")
        try listContent.write(to: listURL, atomically: true, encoding: .utf8)

        // FFMETADATA：头部全局元数据 + 毫秒时间基章节表（元数据走文件，避开命令行转义问题）
        var meta = ";FFMETADATA1\n"
        meta += "title=\(escapeFFMetadataValue(book.title))\n"
        meta += "artist=\(escapeFFMetadataValue(book.author))\n"
        for (i, start) in chapterStartSeconds.enumerated() {
            let end = i + 1 < chapterStartSeconds.count ? chapterStartSeconds[i + 1] : totalSeconds
            meta += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(start * 1000))\nEND=\(Int(end * 1000))\n"
            meta += "title=\(escapeFFMetadataValue(chapterTitles[i]))\n"
        }
        let metaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("abm_meta_\(UUID().uuidString).txt")
        try meta.write(to: metaURL, atomically: true, encoding: .utf8)

        // 进度与 stderr 落临时文件（轮询读取，零管道依赖）
        let progressURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("abm_progress_\(UUID().uuidString).txt")
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("abm_stderr_\(UUID().uuidString).txt")
        try "".write(to: stderrURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: listURL)
            try? FileManager.default.removeItem(at: metaURL)
            try? FileManager.default.removeItem(at: progressURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        var arguments = ["-nostdin", "-y", "-v", "error",
                         "-f", "concat", "-safe", "0", "-i", listURL.path,
                         "-i", metaURL.path]
        // 封面参数动态拼接：仅在勾选且封面存在时映射第三输入，否则不得出现 -map 2:v
        if settings.embedCoverAndMetadata, let coverURL = LibraryStore.coverURL(for: book) {
            arguments += ["-i", coverURL.path,
                          "-map", "0:a", "-map", "2:v",
                          "-disposition:v:0", "attached_pic", "-c:v", "copy"]
        } else {
            arguments += ["-map", "0:a"]
        }
        arguments += ["-map_metadata", "1", "-map_chapters", "1",
                      "-c:a", "aac", "-b:a", "\(settings.bitrateKbps)k",
                      "-progress", progressURL.path,
                      outputURL.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        // stdin 显式接 /dev/null（子进程卫生，杜绝交互读取的可能）

        await OutputManager.appendLog("[export] 整书转码开始 | ffmpeg AAC \(settings.bitrateKbps)kbps | 章节表 \(chapterStartSeconds.count) 项 | 总时长 \(String(format: "%.1f", totalSeconds))s")
        let startedAt = Date()

        try process.run()

        // 轮询进度文件（250ms）+ 10% 里程碑日志；取消钩子即时 terminate 进程
        var lastTenth = -1
        do {
            try await withTaskCancellationHandler {
                while process.isRunning {
                    if let data = try? Data(contentsOf: progressURL),
                       let text = String(data: data, encoding: .utf8) {
                        var encoded: Double?
                        for line in text.split(separator: "\n").reversed() {
                            let key = "out_time_ms="
                            if line.hasPrefix(key), let micro = Double(line.dropFirst(key.count)) {
                                encoded = micro / 1_000_000
                                break
                            }
                        }
                        if let encoded {
                            let frac = totalSeconds > 0 ? min(1, encoded / totalSeconds) : 1
                            progress(progressBase + frac * progressSpan)
                            let tenth = Int(frac * 10)
                            if tenth > lastTenth {
                                lastTenth = tenth
                                await OutputManager.appendLog("[export] 整书转码 | 已编码 \(String(format: "%.1f", encoded))s / \(String(format: "%.1f", totalSeconds))s (\(tenth * 10)%)")
                            }
                        }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } onCancel: {
                process.terminate()
            }
        } catch is CancellationError {
            // 进程已被 terminate，等待其退出后走统一取消路径
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: stderrURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await OutputManager.appendLog("[export] ❌ 整书转码失败 | exit=\(process.terminationStatus) | \(String(detail.suffix(500)))")
            throw ExportError.exportFailed("ffmpeg 转码失败: \(detail.isEmpty ? "exit \(process.terminationStatus)" : String(detail.suffix(300)))")
        }
        await OutputManager.appendLog("[export] ✅ 整书转码完成 | 耗时 \(elapsed)s | 输出 \(outputURL.path)")
    }

    // MARK: - 工具

    /// 线程安全的进度快照（KVO 回调/管道解析在任意队列写入，轮询任务读取）
    private final class SessionProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        func set(_ v: Double) { lock.lock(); value = min(1, max(0, v)); lock.unlock() }
        func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// 等待导出会话完成。期间轮询 `session.progress` 映射到 [progressBase, progressBase+progressSpan)
    /// 驱动 UI，每 30 秒输出存活日志（区分"慢"与"卡死"）。返回是否成功完成。
    private static func runSession(_ session: AVAssetExportSession,
                                   stage: String,
                                   progressBase: Double,
                                   progressSpan: Double,
                                   progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        let startedAt = Date()
        OutputManager.appendLog("[export] \(stage) 开始 | preset=\(session.presetName)")
        let box = SessionProgressBox()
        let observer = session.observe(\.progress, options: [.initial]) { observed, _ in
            box.set(Double(observed.progress))
        }
        let poller = Task {
            var lastLoggedInterval = -1
            while !Task.isCancelled {
                progress(progressBase + box.get() * progressSpan)
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                if elapsed / 30 > lastLoggedInterval {
                    lastLoggedInterval = elapsed / 30
                    OutputManager.appendLog("[export] \(stage) 进行中 | 会话进度 \(Int(box.get() * 100))% | 已耗时 \(elapsed)s")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        poller.cancel()
        observer.invalidate()
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))
        guard session.status == .completed else {
            OutputManager.appendLog("[export] ❌ \(stage) 失败 | status=\(session.status.rawValue) | 耗时 \(elapsed)s | error=\(session.error.map(String.init(describing:)) ?? "nil")")
            return false
        }
        progress(progressBase + progressSpan)
        OutputManager.appendLog("[export] ✅ \(stage) 完成 | 耗时 \(elapsed)s | 输出 \(session.outputURL?.path ?? "-")")
        return true
    }

    private static func makeItem(_ identifier: AVMetadataIdentifier,
                                 _ value: any NSCopying & NSObjectProtocol) -> AVMutableMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }

    static func safeFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: forbidden).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : String(cleaned.prefix(80))
    }
}
