import Foundation
import OSLog

actor ConversionCoordinator {
    private struct PendingJob: Sendable {
        let bookID: UUID
        let jobID: UUID
    }

    private let repository: LibraryRepository
    private let directories: AppDirectories
    private let runtime: any TTSRuntimeClient
    private let packager: any M4BPackaging
    private let logger: any ApplicationLogging
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var activeRequests: [UUID: UUID] = [:]
    private var pending: [PendingJob] = []
    private var activeBookIDs: Set<UUID> = []
    private var cachedCapabilities: RuntimeCapabilities?
    private var pauseRequested: Set<UUID> = []

    init(
        repository: LibraryRepository,
        directories: AppDirectories,
        runtime: any TTSRuntimeClient,
        packager: any M4BPackaging = SystemM4BPackaging(),
        logger: any ApplicationLogging = PrivacyPreservingApplicationLogger()
    ) {
        self.repository = repository
        self.directories = directories
        self.runtime = runtime
        self.packager = packager
        self.logger = logger
    }

    func start(bookID: UUID) async {
        guard tasks[bookID] == nil,
              !activeBookIDs.contains(bookID),
              !pending.contains(where: { $0.bookID == bookID }) else { return }
        do {
            let capabilities = try await runtime.capabilities()
            cachedCapabilities = capabilities
            let jobID = try await repository.enqueueConversion(
                bookID: bookID,
                modelID: capabilities.runtimeID
            )
            pending.append(PendingJob(bookID: bookID, jobID: jobID))
            await scheduleIfPossible()
        } catch {
            try? await repository.failConversion(
                bookID: bookID,
                jobID: nil,
                chapterID: nil,
                code: String(describing: type(of: error)),
                message: error.localizedDescription
            )
        }
    }

    func pause(bookID: UUID) async {
        let supportsImmediate = cachedCapabilities?.supportsImmediateCancellation ?? true
        if supportsImmediate {
            tasks[bookID]?.cancel()
            if let requestID = activeRequests[bookID] {
                await runtime.cancel(requestID: requestID)
            }
        } else {
            pauseRequested.insert(bookID)
        }
    }

    func cancelQueued(bookID: UUID) async {
        guard let index = pending.firstIndex(where: { $0.bookID == bookID }) else { return }
        let job = pending.remove(at: index)
        try? await repository.cancelQueuedConversion(bookID: bookID, jobID: job.jobID)
    }

    func isActive(bookID: UUID) -> Bool {
        tasks[bookID] != nil || pending.contains { $0.bookID == bookID }
    }

    private func scheduleIfPossible() async {
        let capabilities: RuntimeCapabilities
        do {
            capabilities = if let cachedCapabilities {
                cachedCapabilities
            } else {
                try await runtime.capabilities()
            }
        } catch { return }
        let configured = UserDefaults.standard.integer(forKey: "maxConcurrentJobs")
        let userLimit = configured == 2 ? 2 : 1
        let limit = max(1, min(userLimit, capabilities.recommendedConcurrency))
        while activeBookIDs.count < limit, !pending.isEmpty {
            let job = pending.removeFirst()
            activeBookIDs.insert(job.bookID)
            tasks[job.bookID] = Task {
                await run(bookID: job.bookID, jobID: job.jobID)
                await slotFinished(bookID: job.bookID)
            }
        }
    }

    private func slotFinished(bookID: UUID) async {
        tasks[bookID] = nil
        activeBookIDs.remove(bookID)
        await scheduleIfPossible()
    }

    private func run(bookID: UUID, jobID: UUID) async {
        let interval = AppLog.conversionSignposter.beginInterval("Book Conversion")
        var chapterID: UUID?
        defer {
            AppLog.conversionSignposter.endInterval("Book Conversion", interval)
            activeRequests[bookID] = nil
            pauseRequested.remove(bookID)
        }
        do {
            AppLog.conversion.info("Starting book id=\(bookID.uuidString, privacy: .public) job=\(jobID.uuidString, privacy: .public)")
            logger.event("conversion.started", id: bookID, count: nil, errorCode: nil)
            let draft = try await repository.conversionDraft(bookID: bookID)
            let capabilities = try await runtime.capabilities()
            try await repository.startConversion(bookID: bookID, jobID: jobID)
            let audioDirectory = directories.bookDirectory(id: bookID)
                .appending(path: "audio", directoryHint: .isDirectory)
            let largestChapter = draft.chapters.map(\.characterCount).max() ?? 0
            try SystemDiskSpaceChecker().requireAvailable(
                at: directories.root,
                requiredBytes: max(128 * 1_024 * 1_024, Int64(largestChapter) * 20_000)
            )
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let coverData = try draft.coverRelativePath.map {
                try Data(contentsOf: directories.resolve(relativePath: $0), options: .mappedIfSafe)
            }
            var completedUnits = Int64(draft.chapters
                .filter { $0.status == .completed }
                .reduce(0) { $0 + $1.characterCount })
            try await repository.updateJobProgress(id: jobID, completedUnits: completedUnits)

            for chapter in draft.chapters where chapter.status != .completed {
                try Task.checkCancellation()
                try checkPauseRequested(bookID: bookID)
                chapterID = chapter.id
                try await repository.markChapter(id: chapter.id, status: .synthesizing)
                let textURL = try directories.resolve(relativePath: chapter.textRelativePath)
                let text = try String(contentsOf: textURL, encoding: .utf8)
                guard SHA256Hasher.hash(Data(text.utf8)) == chapter.textSHA256 else {
                    throw RuntimeError.invalidText
                }
                let chunks = try TextChunker.chunks(
                    text: text,
                    maximumLength: capabilities.maximumTextLength
                )
                let segmentDirectory = audioDirectory
                    .appending(path: chapter.id.uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(
                    at: segmentDirectory,
                    withIntermediateDirectories: true
                )
                var segments: [URL] = []
                for (index, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    try checkPauseRequested(bookID: bookID)
                    let segmentURL = segmentDirectory.appending(path: String(format: "%04d.caf", index))
                    if !FileManager.default.fileExists(atPath: segmentURL.path) {
                        let requestID = UUID()
                        activeRequests[bookID] = requestID
                        _ = try await synthesizeWithRetry(SynthesisRequest(
                            requestID: requestID,
                            text: chunk,
                            languageCode: draft.languageCode,
                            outputURL: segmentURL
                        ))
                    }
                    segments.append(segmentURL)
                    completedUnits += Int64(chunk.count)
                    try await repository.updateJobProgress(
                        id: jobID,
                        completedUnits: completedUnits
                    )
                    // A runtime without immediate cancellation must checkpoint the
                    // fragment it just finished before honoring the pause request.
                    try checkPauseRequested(bookID: bookID)
                }

                try Task.checkCancellation()
                try await repository.markChapter(id: chapter.id, status: .packaging)
                let safeTitle = FileNameSanitizer.visibleName(chapter.title, fallback: "章节")
                let outputURL = audioDirectory.appending(
                    path: String(format: "%04d-%@.m4b", chapter.index + 1, safeTitle)
                )
                let result = try await packager.package(M4BPackageRequest(
                    audioSegments: segments,
                    outputURL: outputURL,
                    title: draft.title,
                    author: draft.author,
                    chapterTitle: chapter.title,
                    chapterIndex: chapter.index,
                    languageCode: draft.languageCode,
                    fullText: text,
                    coverData: coverData
                ))
                let relativePath = try directories.relativePath(for: result.url)
                try await repository.completeChapter(
                    id: chapter.id,
                    artifactRelativePath: relativePath,
                    durationSeconds: result.durationSeconds
                )
                try? FileManager.default.removeItem(at: segmentDirectory)
            }
            try await repository.finishConversion(bookID: bookID, jobID: jobID)
            AppLog.conversion.info("Completed book id=\(bookID.uuidString, privacy: .public) job=\(jobID.uuidString, privacy: .public)")
            logger.event("conversion.completed", id: bookID, count: draft.chapters.count, errorCode: nil)
        } catch is CancellationError {
            try? await repository.pauseConversion(bookID: bookID, jobID: jobID)
        } catch RuntimeError.cancelled {
            try? await repository.pauseConversion(bookID: bookID, jobID: jobID)
        } catch {
            let code = (error as? any StableAppError)?.code ?? "conversion.unknown"
            AppLog.conversion.error("Conversion failed book=\(bookID.uuidString, privacy: .public) code=\(code, privacy: .public)")
            logger.event("conversion.failed", id: bookID, count: nil, errorCode: code)
            try? await repository.failConversion(
                bookID: bookID,
                jobID: jobID,
                chapterID: chapterID,
                code: code,
                message: error.localizedDescription
            )
        }
    }

    private func synthesizeWithRetry(
        _ request: SynthesisRequest
    ) async throws -> SynthesisResult {
        var retryCount = 0
        while true {
            do {
                return try await runtime.synthesize(request)
            } catch let error as RuntimeError where error.isTransient && retryCount < 2 {
                let delay = retryCount == 0 ? 250 : 500
                retryCount += 1
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
    }

    private func checkPauseRequested(bookID: UUID) throws {
        if pauseRequested.contains(bookID) { throw CancellationError() }
    }
}
