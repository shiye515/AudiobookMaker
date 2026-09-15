//
//  AppStore.swift
//  abm
//
//  应用唯一状态源：引擎状态机、书籍库、导入、批量生成队列（严格串行——引擎 actor
//  保证同一时刻只有一个合成在跑，队列在段间暂停/恢复）、快速单文本、播放、导出。
//

import AppKit
import AudioCommon
import AVFoundation
import Foundation
import Observation

enum AppRoute: Hashable {
    case library
    case quickTTS
    case voiceCenter
    case model
    case bookDetail(String)
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, generating, finished
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .all: return "全部图书"
        case .generating: return "正在生成"
        case .finished: return "已完成"
        }
    }
}

struct QueueItem: Equatable, Sendable {
    let bookID: String
    let chapterID: String
}

@MainActor
@Observable
final class AppStore {

    enum EngineState {
        case uninitialized
        case loading(progress: Double, message: String)
        case ready
        case failed(String)
    }

    // MARK: - 引擎与快速单文本

    let engine = SoniqoCosyVoiceEngine()
    let voiceLibrary = VoiceLibrary()
    let player = AudioPlaybackService()

    var engineState: EngineState = .uninitialized
    var quickText = ""
    var quickVoiceID: String?
    var isQuickSynthesizing = false
    var quickHint: String?
    var quickLastOutput: String?

    // MARK: - 导航与书库

    var route: AppRoute = .library
    var libraryFilter: LibraryFilter = .all
    var searchText = ""
    var books: [BookProject] = []
    /// 解码失败（章节结构升级等）的书目录 ID，书库 UI 提示重新导入
    private(set) var failedManifestBookIDs: [String] = []
    var importStatus: String?
    var isImporting = false
    var defaultNarratorName: String {
        didSet {
            if oldValue != defaultNarratorName {
                UserDefaults.standard.set(defaultNarratorName, forKey: "abm.defaultNarrator")
            }
        }
    }

    // MARK: - 生成队列

    private(set) var pendingQueue: [QueueItem] = []
    private(set) var activeItem: QueueItem?
    var isQueuePaused = false
    var activeChapterProgress: String?          // "分段 3/12"
    private(set) var activeSegmentDone: Int?
    private(set) var activeSegmentTotal: Int?
    var queueElapsedSeconds: Double = 0
    var memoryMB: Int = 0
    private var rollingRTF = RollingRTF()
    private(set) var latestSegmentRTF: Double?
    private(set) var recentWordsPerSecond: Double = 0
    private var elapsedTimer: Task<Void, Never>?
    private var generationRunID = ""            // 当前在跑任务的 run id（停止时用于丢弃）
    private var activeSynthesisTask: Task<Void, Never>?
    private var activeCancellationToken: SynthesisCancellationToken?

    var activeBook: BookProject? {
        guard let item = activeItem else { return nil }
        return books.first { $0.id == item.bookID }
    }

    var generatingBookCount: Int {
        books.filter { isBookGeneratingOrQueued($0) }.count
    }

    func isBookGeneratingOrQueued(_ book: BookProject) -> Bool {
        book.isGenerating || activeItem?.bookID == book.id || pendingQueue.contains { $0.bookID == book.id }
    }

    func isBookQueuedOnly(_ book: BookProject) -> Bool {
        !book.isGenerating && activeItem?.bookID != book.id && pendingQueue.contains { $0.bookID == book.id }
    }

    var activeTaskCount: Int {
        (activeItem != nil ? 1 : 0) + pendingQueue.count
    }

    // MARK: - 导出

    var exportBookID: String?
    var exportSettings = ExportSettings(destinationDirectory: URL(fileURLWithPath: NSString(string: "~/Music/Audiobooks").expandingTildeInPath))
    var isExporting = false
    var exportProgress: Double = 0
    private var exportTask: Task<Void, Never>?
    private var exportRunID = ""
    var exportResultText: String?
    var exportResultURLs: [URL] = []
    var exportHint: String?

    var exportSheetBook: BookProject? {
        guard let id = exportBookID else { return nil }
        return books.first { $0.id == id }
    }

    private let exporter = AudiobookExporter.self

    init() {
        defaultNarratorName = UserDefaults.standard.string(forKey: "abm.defaultNarrator")
            ?? voiceLibrary.voices.first?.name ?? ""
        let loaded = LibraryStore.loadAll()
        books = loaded.books
        failedManifestBookIDs = loaded.failedBookIDs
        if !failedManifestBookIDs.isEmpty {
            OutputManager.appendLog("[library] \(failedManifestBookIDs.count) 本书清单无法加载（可能因章节结构升级），请重新导入")
        }
        OutputManager.appendLog("应用启动（有声书版）")
    }

    // MARK: - 模型下载（步骤①）

    enum ModelDownloadState {
        case unknown                                        // 未检查
        case checking                                       // 检查缓存中
        case missing                                        // 未下载 / 不可用
        case cached                                         // 缓存可用，可离线初始化
        case downloading(progress: Double, message: String)
        case failed(String)
    }

    var modelDownloadState: ModelDownloadState = .unknown

    var isDownloadingModel: Bool {
        if case .downloading = modelDownloadState { return true }
        return false
    }

    /// 离线检查缓存可用性（不动网络）。
    func checkModelCache() {
        guard !isDownloadingModel else { return }
        modelDownloadState = .checking
        Task {
            let usable = SoniqoCosyVoiceEngine.isModelCacheUsable()
            modelDownloadState = usable ? .cached : .missing
            OutputManager.appendLog("模型缓存检查: \(usable ? "可用" : "未下载")")
        }
    }

    func downloadModel() {
        guard !isDownloadingModel else { return }
        modelDownloadState = .downloading(progress: 0, message: "连接 HuggingFace…")
        OutputManager.appendLog("模型下载开始")
        let runID = Self.newRunID()
        Task {
            do {
                try await SoniqoCosyVoiceEngine.downloadModelFiles { [weak self] fraction, message in
                    Task { @MainActor in
                        self?.modelDownloadState = .downloading(progress: fraction, message: message)
                    }
                }
                let usable = SoniqoCosyVoiceEngine.isModelCacheUsable()
                modelDownloadState = usable ? .cached : .failed("下载完成但缓存校验不通过，请重试")
                OutputManager.appendLog("[run=\(runID)] 模型下载完成（缓存可用: \(usable)）")
            } catch {
                modelDownloadState = .failed("下载失败: \(error.localizedDescription)")
                OutputManager.appendLog("[run=\(runID)] 模型下载失败: \(error)")
            }
        }
    }

    // MARK: - 引擎初始化

    var isInitializing: Bool {
        if case .loading = engineState { return true }
        return false
    }

    var isReady: Bool {
        if case .ready = engineState { return true }
        return false
    }

    var engineStatusLabel: String {
        switch engineState {
        case .uninitialized: return "未初始化"
        case .loading(_, let message): return message
        case .ready: return "就绪 (CosyVoice3-0.5B · 本地)"
        case .failed: return "出错"
        }
    }

    var loadProgress: Double? {
        if case .loading(let progress, _) = engineState { return progress }
        return nil
    }

    var engineErrorMessage: String? {
        if case .failed(let message) = engineState { return message }
        return nil
    }

    // MARK: - 遥测展示

    var queueRecentRTF: Double {
        if let latest = latestSegmentRTF, latest > 0 {
            return latest
        }
        return rollingRTF.value
    }

    func recordSegmentMetrics(rtf: Double?, wordsPerSecond: Double?) {
        if let rtf, rtf > 0, rtf.isFinite {
            latestSegmentRTF = rtf
            rollingRTF.record(rtf: rtf)
        }
        if let wps = wordsPerSecond, wps > 0, wps.isFinite {
            recentWordsPerSecond = wps
        }
    }

    var queueElapsedText: String { Self.durationTextDHMS(queueElapsedSeconds) }

    /// 时长中文格式：日时分秒（高位为零的单位省略）
    static func durationTextDHMS(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        let secs = total % 60
        if days > 0 { return "\(days)日\(hours)时\(minutes)分\(secs)秒" }
        if hours > 0 { return "\(hours)时\(minutes)分\(secs)秒" }
        return "\(minutes)分\(secs)秒"
    }

    /// ETA：剩余未完成字数 / 近期吞吐（结合最新完成分段速率，无历史吞吐时按经验速率 42000 字/小时）
    func etaText(for book: BookProject) -> String {
        var remaining = 0
        for ch in book.chapters {
            if ch.status == .done { continue }
            if ch.status == .generating, let done = ch.completedSegments, let total = ch.totalSegments, total > 0 {
                let remainingFraction = max(0, 1.0 - Double(done) / Double(total))
                remaining += Int(Double(ch.wordCount) * remainingFraction)
            } else {
                remaining += ch.wordCount
            }
        }
        guard remaining > 0 else { return "00:00" }
        let wordsPerSecond = recentWordsPerSecond > 0 ? recentWordsPerSecond : 42_000.0 / 3600.0
        let seconds = Double(remaining) / max(wordsPerSecond, 0.1)
        return Self.durationTextDHMS(seconds)
    }

    func initializeEngine() {
        guard !isInitializing, !isReady else { return }
        guard SoniqoCosyVoiceEngine.isModelCacheUsable() else {
            engineState = .failed("模型尚未下载，请先在「模型」页完成「① 下载模型」")
            modelDownloadState = .missing
            return
        }
        engineState = .loading(progress: 0, message: "准备加载…")
        OutputManager.appendLog("初始化开始")
        Task {
            do {
                try await engine.initialize(progress: { [weak self] progress, message in
                    OutputManager.appendLog(String(format: "初始化[%3.0f%%] %@", progress * 100, message))
                    Task { @MainActor in
                        self?.engineState = .loading(progress: progress, message: message)
                    }
                })
                engineState = .ready
                OutputManager.appendLog("初始化完成")
            } catch {
                engineState = .failed("初始化失败: \(error.localizedDescription)")
                OutputManager.appendLog("初始化失败: \(error)")
            }
        }
    }

    private func ensureEngineReady() async throws {
        guard !isReady else { return }
        try await engine.initialize(progress: { [weak self] progress, message in
            Task { @MainActor in
                self?.engineState = .loading(progress: progress, message: message)
            }
        })
        engineState = .ready
    }

    // MARK: - 快速单文本（原 MVP 行为）

    func quickSynthesize() {
        let text = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isReady, !isQuickSynthesizing else { return }
        guard !text.isEmpty else {
            quickHint = "请先输入要合成的文本"
            return
        }
        guard let voice = voiceLibrary.voices.first(where: { $0.id == quickVoiceID })
            ?? voiceLibrary.voices.first else { return }
        quickVoiceID = voice.id
        quickHint = nil
        isQuickSynthesizing = true

        let runID = Self.newRunID()
        OutputManager.appendLog(
            "[run=\(runID)] 快速合成开始 | 音色: \(voice.name)(\(voice.audioFile)) | 文本 \(text.count) 字")
        let startedAt = Date()
        Task {
            do {
                let output = try await engine.synthesize(text: text, voice: voice) { [weak self] progress in
                    Task { @MainActor in
                        if let rtf = progress.rtf {
                            self?.recordSegmentMetrics(rtf: rtf, wordsPerSecond: progress.wordsPerSecond)
                        }
                    }
                } log: { message in
                    OutputManager.appendLog("[run=\(runID)] \(message)")
                }
                let duration = Double(output.samples.count) / 24_000.0
                let exportDir = exportSettings.destinationDirectory
                let wavURL = try OutputManager.writeWav(samples: output.samples,
                                                        voiceName: voice.name, runID: runID,
                                                        destinationDirectory: exportDir)
                quickLastOutput = "\(wavURL.lastPathComponent)（\(String(format: "%.1f", duration))s）"
                quickHint = "已生成 \(wavURL.lastPathComponent)，存放在导出目录"
                OutputManager.appendLog(String(
                    format: "[run=%@] 快速合成完成 | 音频 %.2fs | 墙钟 %.2fs | RTF %.3f | 输出: %@",
                    runID, duration, Date().timeIntervalSince(startedAt),
                    duration > 0 ? Date().timeIntervalSince(startedAt) / duration : 0, wavURL.path))
            } catch {
                quickHint = "合成失败: \(error.localizedDescription)"
                OutputManager.appendLog("[run=\(runID)] 快速合成失败: \(error)")
            }
            isQuickSynthesizing = false
        }
    }

    // MARK: - EPUB 导入

    func importEPUBs(urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        importStatus = "导入中…"
        Task {
            var imported = 0
            var skipped = 0
            var lastError: String?
            for url in urls {
                do {
                    // 重复判断：内容指纹一致（同文件重复导入会在解析后按 id 命中）
                    let book = try await EPUBImportService.import(
                        fileURL: url, defaultVoiceName: defaultNarratorName)
                    if books.contains(where: { $0.id == book.id }) {
                        skipped += 1
                        continue
                    }
                    books.append(book)
                    books.sort { $0.createdAt < $1.createdAt }
                    try? LibraryStore.save(book)
                    failedManifestBookIDs.removeAll { $0 == book.id }
                    imported += 1
                    importStatus = "已导入《\(book.title)》"
                } catch {
                    lastError = error.localizedDescription
                    OutputManager.appendLog("导入失败 \(url.lastPathComponent): \(error)")
                }
            }
            if imported == 0 && skipped == 0 {
                importStatus = "导入失败: \(lastError ?? "未知错误")"
            } else if skipped > 0 {
                importStatus = "导入 \(imported) 本，跳过重复 \(skipped) 本"
            } else if imported > 1 {
                importStatus = "已导入 \(imported) 本"
            }
            isImporting = false
        }
    }

    // MARK: - 批量生成队列

    func generateBook(_ bookID: String) {
        guard let book = books.first(where: { $0.id == bookID }) else { return }

        // 若当前该书队列处于暂停挂起状态，点击一键生成等同于恢复生成
        if isQueuePaused && pendingQueue.contains(where: { $0.bookID == bookID }) {
            resumeQueue()
            return
        }

        let waiting = book.chapters.filter { $0.status == .waiting || $0.status == .failed }
        guard !waiting.isEmpty else { return }

        // 清理当前书籍在待处理队列中的既有项（防重复堆叠），严格按章节原本顺序入队
        pendingQueue.removeAll { $0.bookID == bookID }
        pendingQueue.append(contentsOf: waiting.map { QueueItem(bookID: bookID, chapterID: $0.id) })
        isQueuePaused = false
        queueElapsedSeconds = 0   // 新的生成会话重新累计
        OutputManager.appendLog("[queue] 全书入队《\(book.title)》共 \(waiting.count) 章")
        startNextIfIdle()
    }

    func pauseQueue() {
        isQueuePaused = true
        activeCancellationToken?.cancel()
        activeSynthesisTask?.cancel()
        OutputManager.appendLog("[queue] 队列暂停（当前分段完成后挂起）")
    }

    func resumeQueue() {
        isQueuePaused = false
        OutputManager.appendLog("[queue] 队列恢复")
        startNextIfIdle()
    }

    func stopQueue() {
        let count = pendingQueue.count
        pendingQueue.removeAll()
        isQueuePaused = false
        activeCancellationToken?.cancel()
        activeSynthesisTask?.cancel()
        // 当前章节在当前分段完成后安全挂起，断点进度自动保留在磁盘
        OutputManager.appendLog("[queue] 全部停止：清空待处理 \(count) 项（当前分段完成后保留断点安全挂起）")
        if activeItem == nil { cancelElapsedTimer() }
    }

    func retryChapter(bookID: String, chapterID: String) {
        pendingQueue.removeAll { $0.bookID == bookID && $0.chapterID == chapterID }
        pendingQueue.insert(QueueItem(bookID: bookID, chapterID: chapterID), at: 0)
        isQueuePaused = false
        startNextIfIdle()
    }

    func resetChapter(bookID: String, chapterID: String) {
        if activeItem?.bookID == bookID && activeItem?.chapterID == chapterID {
            activeCancellationToken?.cancel()
            activeSynthesisTask?.cancel()
        }
        guard let book = books.first(where: { $0.id == bookID }) else { return }
        updateChapter(bookID: bookID, chapterID: chapterID) { chapter in
            LibraryStore.removeChapterAudio(book: book, chapter: chapter)
            chapter.status = .waiting
            chapter.audioFileName = nil
            chapter.durationSeconds = nil
            chapter.errorMessage = nil
            chapter.completedSegments = nil
            chapter.totalSegments = nil
        }
    }

    func resetBook(_ bookID: String) {
        if player.contextID?.hasPrefix(bookID) == true {
            player.stop()
        }
        if activeItem?.bookID == bookID {
            activeCancellationToken?.cancel()
            activeSynthesisTask?.cancel()
            activeItem = nil
        }
        pendingQueue.removeAll { $0.bookID == bookID }
        guard let index = books.firstIndex(where: { $0.id == bookID }) else { return }

        var book = books[index]
        for cIndex in book.chapters.indices {
            let chapter = book.chapters[cIndex]
            LibraryStore.removeChapterAudio(book: book, chapter: chapter)
            book.chapters[cIndex].status = .waiting
            book.chapters[cIndex].audioFileName = nil
            book.chapters[cIndex].durationSeconds = nil
            book.chapters[cIndex].errorMessage = nil
            book.chapters[cIndex].completedSegments = nil
            book.chapters[cIndex].totalSegments = nil
        }
        book.completedAt = nil
        try? LibraryStore.save(book)
        books[index] = book
        if isQueuePaused && pendingQueue.isEmpty {
            isQueuePaused = false
        }
        OutputManager.appendLog("[queue] 《\(book.title)》已重置为初始状态")
    }

    func deleteBook(_ bookID: String) {
        if player.contextID?.hasPrefix(bookID) == true {
            player.stop()
        }
        if activeItem?.bookID == bookID {
            activeCancellationToken?.cancel()
            activeSynthesisTask?.cancel()
            activeItem = nil
        }
        pendingQueue.removeAll { $0.bookID == bookID }
        guard let book = books.first(where: { $0.id == bookID }) else { return }
        LibraryStore.deleteBook(book)
        books.removeAll { $0.id == bookID }
        if route == .bookDetail(bookID) { route = .library }
        OutputManager.appendLog("[library] 已删除书籍《\(book.title)》（ID: \(bookID)）及其所有本地数据")
    }

    private func startNextIfIdle() {
        guard activeItem == nil, !isQueuePaused, !pendingQueue.isEmpty else {
            if activeItem == nil, pendingQueue.isEmpty, !isQueuePaused { cancelElapsedTimer() }
            return
        }
        let item = pendingQueue.removeFirst()
        guard let book = books.first(where: { $0.id == item.bookID }),
              let chapterIndex = book.chapters.firstIndex(where: { $0.id == item.chapterID })
        else { startNextIfIdle(); return }

        let chapter = book.chapters[chapterIndex]
        let voiceName = chapter.voiceName ?? book.defaultVoiceName
        guard let voice = voiceLibrary.voices.first(where: { $0.name == voiceName })
            ?? voiceLibrary.voices.first else { return }

        activeItem = item
        activeChapterProgress = nil
        activeSegmentDone = nil
        activeSegmentTotal = nil
        generationRunID = Self.newRunID()
        startElapsedTimer()

        updateChapter(bookID: item.bookID, chapterID: item.chapterID) { $0.status = .generating }

        let runID = generationRunID
        let text = LibraryStore.loadChapterText(bookID: item.bookID, chapterID: item.chapterID) ?? ""
        OutputManager.appendLog(
            "[run=\(runID)] 章节合成开始 | 《\(book.title)》\(chapter.fullTitle) | \(chapter.wordCount) 字 | 音色: \(voice.name)")

        let startedAt = Date()
        let checkpointDir = LibraryStore.segmentsDirectory(bookID: item.bookID, chapterID: item.chapterID)
        let token = SynthesisCancellationToken()
        activeCancellationToken = token

        activeSynthesisTask = Task {
            do {
                try await ensureEngineReady()
                let output = try await engine.synthesize(
                    text: text,
                    voice: voice,
                    checkpointDir: checkpointDir,
                    cancellationToken: token,
                    onSegment: { [weak self] progress in
                        Task { @MainActor in
                            self?.activeSegmentDone = progress.done
                            self?.activeSegmentTotal = progress.total
                            self?.activeChapterProgress = progress.done >= progress.total ? nil : "分段 \(progress.done)/\(progress.total)"
                            self?.recordSegmentMetrics(rtf: progress.rtf, wordsPerSecond: progress.wordsPerSecond)
                            self?.updateChapter(bookID: item.bookID, chapterID: item.chapterID) { chapter in
                                chapter.completedSegments = progress.done
                                chapter.totalSegments = progress.total
                            }
                        }
                    },
                    log: { message in
                        OutputManager.appendLog("[run=\(runID)] \(message)")
                    }
                )
                let wallTime = Date().timeIntervalSince(startedAt)
                let duration = Double(output.samples.count) / 24_000.0
                let rtf = duration > 0 ? wallTime / duration : 0
                rollingRTF.record(rtf: rtf)
                if chapter.wordCount > 0, wallTime > 0 {
                    recentWordsPerSecond = Double(chapter.wordCount) / wallTime
                }

                let bookDir = LibraryStore.directory(for: item.bookID)
                    .appendingPathComponent("audio", isDirectory: true)
                try FileManager.default.createDirectory(at: bookDir, withIntermediateDirectories: true)
                let wavURL = bookDir.appendingPathComponent("\(item.chapterID).wav")
                try OutputManager.writeWav16(samples: output.samples, sampleRate: 24_000, to: wavURL)

                // 整章合成完毕，清理分段缓存目录
                LibraryStore.clearChapterSegments(bookID: item.bookID, chapterID: item.chapterID)

                updateChapter(bookID: item.bookID, chapterID: item.chapterID) { chapter in
                    chapter.status = .done
                    chapter.durationSeconds = duration
                    chapter.audioFileName = "audio/\(item.chapterID).wav"
                    chapter.errorMessage = nil
                    chapter.completedSegments = nil
                    chapter.totalSegments = nil
                }
                let total = book.chapters.count
                OutputManager.appendLog(String(
                    format: "[run=%@] 章节合成完成 | 音频 %.1fs | 墙钟 %.1fs | RTF %.3f | 进度 %d/%d | 输出: %@",
                    runID, duration, wallTime, rtf,
                    books.first(where: { $0.id == item.bookID })?.doneCount ?? 0, total, wavURL.path))
            } catch let error where error is SynthesisInterruptedError || error is CancellationError {
                updateChapter(bookID: item.bookID, chapterID: item.chapterID) { chapter in
                    chapter.status = .waiting
                }
                // 若属于暂停挂起，将当前未完成的章节插回待处理队首，以便继续时首先恢复本章断点
                if isQueuePaused {
                    if !pendingQueue.contains(where: { $0.bookID == item.bookID && $0.chapterID == item.chapterID }) {
                        pendingQueue.insert(item, at: 0)
                    }
                }
                OutputManager.appendLog("[run=\(runID)] 章节合成在分段断点处安全挂起，已保留断点并放回队首")
            } catch {
                updateChapter(bookID: item.bookID, chapterID: item.chapterID) { chapter in
                    chapter.status = .failed
                    chapter.errorMessage = error.localizedDescription
                }
                OutputManager.appendLog("[run=\(runID)] 章节合成失败: \(error)")
            }
            activeCancellationToken = nil
            activeSynthesisTask = nil
            activeItem = nil
            activeChapterProgress = nil
            activeSegmentDone = nil
            activeSegmentTotal = nil
            startNextIfIdle()
        }
    }

    private func updateChapter(bookID: String, chapterID: String, mutate: (inout Chapter) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == bookID }),
              let chapterIndex = books[index].chapters.firstIndex(where: { $0.id == chapterID })
        else { return }
        mutate(&books[index].chapters[chapterIndex])
        if books[index].isFinished, books[index].completedAt == nil {
            books[index].completedAt = Date()
            OutputManager.appendLog("[queue] 《\(books[index].title)》全部章节完成 🎉")
        }
        try? LibraryStore.save(books[index])
    }

    private func startElapsedTimer() {
        guard elapsedTimer == nil else { return }
        elapsedTimer = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.activeItem != nil {
                    self.queueElapsedSeconds += 1
                    self.memoryMB = Telemetry.physFootprintMB()
                }
                // 会话结束（全部完成/停止）或暂停挂起：停止计时，保留累计值
                if self.activeItem == nil,
                   self.pendingQueue.isEmpty || self.isQueuePaused {
                    break
                }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.cancelElapsedTimer()
        }
    }

    private func cancelElapsedTimer() {
        elapsedTimer?.cancel()
        elapsedTimer = nil
    }

    /// 章节进度：已完成 = 100%；生成中 = 分段完成数 / 预估分段数（TextChunker 目标
    /// ~50 字/段，封顶 98%）；非生成中若存在断点分段缓存，返回已保存分段比例；其余 = 0。
    func chapterProgress(book: BookProject, chapter: Chapter) -> Double {
        switch chapter.status {
        case .done: return 1
        case .generating:
            if let done = activeSegmentDone, let total = activeSegmentTotal, total > 0,
               activeItem?.chapterID == chapter.id {
                return min(0.98, Double(done) / Double(total))
            }
            if let done = chapter.completedSegments, let total = chapter.totalSegments, total > 0 {
                return min(0.98, Double(done) / Double(total))
            }
            let expected = max(1, Int(ceil(Double(chapter.wordCount) / Double(TextChunker.adaptiveRange.target))))
            return min(0.15, queueElapsedSeconds / Double(expected * 6))
        case .waiting, .failed:
            if let done = chapter.completedSegments, let total = chapter.totalSegments, total > 0 {
                return min(0.98, Double(done) / Double(total))
            }
            return 0
        }
    }

    // MARK: - 播放

    func playChapter(book: BookProject, chapter: Chapter) {
        let audioURL = LibraryStore.audioURL(book: book, chapter: chapter)
        OutputManager.appendLog("[player] 请求试听《\(book.title)》- \(chapter.fullTitle) | chapterID=\(chapter.id), status=\(chapter.status.rawValue), audioFileName=\(chapter.audioFileName ?? "nil"), resolvedURL=\(audioURL?.path ?? "nil")")
        guard let url = audioURL else {
            OutputManager.appendLog("[player] ⚠️ 无法获取章节音频路径（audioFileName 为空或文件在书库中不存在），放弃播放: 《\(book.title)》\(chapter.fullTitle)")
            return
        }
        // 播放条显示叶子标题，副标题为书名
        player.play(url: url, contextID: "\(book.id)/\(chapter.id)", title: chapter.title, subtitle: book.title, bookID: book.id)
    }

    // MARK: - 导出

    func beginExport(bookID: String) {
        exportBookID = bookID
        exportHint = nil
        exportResultText = nil
        exportProgress = 0
    }

    func runExport(book: BookProject, settings: ExportSettings) {
        guard !isExporting else { return }
        isExporting = true
        exportHint = nil
        exportProgress = 0
        exportTask?.cancel()
        let runID = Self.newRunID()
        exportRunID = runID
        OutputManager.appendLog("[run=\(runID)] 导出开始 | 《\(book.title)》格式 \(settings.format.rawValue) | 码率 \(settings.bitrateKbps) | 目标 \(settings.destinationDirectory.path)")
        exportTask = Task { [weak self] in
            // runID 门卫：被取消的旧任务迟到回调不得污染新导出的 UI 状态
            @MainActor func touch(_ body: @MainActor (AppStore) -> Void) async -> Bool {
                guard let self, !Task.isCancelled, self.exportRunID == runID else { return false }
                body(self)
                return true
            }
            do {
                let outcome = try await exporter.export(book: book, settings: settings) { [weak self] p in
                    Task { @MainActor in
                        guard let self, self.exportRunID == runID else { return }
                        self.exportProgress = p
                    }
                }
                guard await touch({ store in
                    store.exportProgress = 1
                    store.exportResultURLs = outcome.productURLs
                    let names = outcome.productURLs.map(\.lastPathComponent).prefix(3).joined(separator: ", ")
                    store.exportResultText = "已导出 \(outcome.productURLs.count) 个文件: \(names)"
                    store.isExporting = false
                }) else {
                    OutputManager.appendLog("[run=\(runID)] 导出已完成但任务已失效（被新导出/取消取代），丢弃结果 UI")
                    return
                }
                OutputManager.appendLog("[run=\(runID)] 导出完成 | \(outcome.productURLs.count) 个文件 | \(outcome.productURLs.first?.path ?? "")")
            } catch is CancellationError {
                guard await touch({ store in
                    store.exportHint = "已取消导出"
                    store.isExporting = false
                }) else { return }
                OutputManager.appendLog("[run=\(runID)] 导出已取消，部分产物已清理")
            } catch {
                guard await touch({ store in
                    store.exportHint = "导出失败: \(error.localizedDescription)"
                    store.isExporting = false
                }) else { return }
                OutputManager.appendLog("[run=\(runID)] 导出失败: \(error)")
            }
        }
    }

    /// 完全取消当前导出：协作式停止转码并清理部分产物。
    func cancelExport() {
        guard isExporting else { return }
        OutputManager.appendLog("[export] 用户请求取消导出")
        exportRunID = ""
        exportTask?.cancel()
        isExporting = false
        exportProgress = 0
        exportHint = "已取消导出"
        exportTask = nil
    }

    func revealExport(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openModelDirectory() {
        guard let url = try? HuggingFaceDownloader.getCacheDirectory(for: SoniqoCosyVoiceEngine.modelID) else { return }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        OutputManager.reveal(directory: url)
    }

    // MARK: - 书架辅助

    func book(id: String) -> BookProject? {
        books.first { $0.id == id }
    }

    func filteredBooks() -> [BookProject] {
        var list = books
        switch libraryFilter {
        case .all: break
        case .generating: list = list.filter { isBookGeneratingOrQueued($0) }
        case .finished: list = list.filter { $0.isFinished }
        }
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(keyword)
                || $0.author.localizedCaseInsensitiveContains(keyword) }
        }
        return list
    }

    func setDefaultNarrator(_ name: String) {
        defaultNarratorName = name
        OutputManager.appendLog("默认旁白设为: \(name)")
    }

    // MARK: - 工具

    static func newRunID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
