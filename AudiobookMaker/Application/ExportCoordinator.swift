import Foundation
import OSLog

nonisolated struct ExportProgress: Sendable, Equatable {
    let fractionCompleted: Double
    let currentFile: String?
}

nonisolated enum ExportError: Error, StableAppError, Equatable, Sendable {
    case bookIncomplete
    case invalidDestination
    case validationFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .bookIncomplete: String(localized: "书籍尚未全部转换完成，不能导出。")
        case .invalidDestination: String(localized: "导出目标位置无效。")
        case .validationFailed: String(localized: "导出的 M4B 未通过完整性校验。")
        case let .writeFailed(message): String(
            format: String(localized: "导出失败：%@"), message
        )
        }
    }

    var code: String {
        switch self {
        case .bookIncomplete: "export.bookIncomplete"
        case .invalidDestination: "export.invalidDestination"
        case .validationFailed: "export.validationFailed"
        case .writeFailed: "export.writeFailed"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .bookIncomplete: String(localized: "请先完成所有章节转换。")
        case .invalidDestination: String(localized: "请在保存面板中重新选择可写位置。")
        case .validationFailed, .writeFailed: String(localized: "请检查磁盘空间和目录权限后重试。")
        }
    }
}

nonisolated struct ExportCoordinator: Sendable {
    let repository: LibraryRepository
    let directories: AppDirectories
    let diskSpaceChecker: any DiskSpaceChecking
    let logger: any ApplicationLogging

    init(
        repository: LibraryRepository,
        directories: AppDirectories,
        diskSpaceChecker: any DiskSpaceChecking = SystemDiskSpaceChecker(),
        logger: any ApplicationLogging = PrivacyPreservingApplicationLogger()
    ) {
        self.repository = repository
        self.directories = directories
        self.diskSpaceChecker = diskSpaceChecker
        self.logger = logger
    }

    func export(
        bookID: UUID,
        to destination: URL,
        progress: (@Sendable (ExportProgress) -> Void)? = nil
    ) async throws -> URL {
        guard destination.isFileURL else { throw ExportError.invalidDestination }
        progress?(ExportProgress(fractionCompleted: 0, currentFile: nil))
        let draft = try await repository.exportDraft(bookID: bookID)
        let operation = Task.detached(priority: .utility) {
            try await export(draft: draft, to: destination, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    private func export(
        draft: ExportBookDraft,
        to destination: URL,
        progress: (@Sendable (ExportProgress) -> Void)?
    ) async throws -> URL {
        let interval = AppLog.exportSignposter.beginInterval("Book Export")
        defer { AppLog.exportSignposter.endInterval("Book Export", interval) }
        AppLog.exporting.info("Starting export book=\(draft.id.uuidString, privacy: .public) chapters=\(draft.chapters.count)")
        logger.event("export.started", id: draft.id, count: draft.chapters.count, errorCode: nil)
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
        let parent = destination.deletingLastPathComponent()
        // NSSavePanel grants a sandbox extension for the selected file URL, not
        // general write access to its parent directory. Checking the parent with
        // isWritableFile therefore rejects valid user-selected destinations.
        // Let the final operation against the authorized file URL decide whether
        // the destination is writable.
        guard destination.isFileURL,
              destination.pathExtension.lowercased() == "m4b" else {
            throw ExportError.invalidDestination
        }
        let artifactBytes = try draft.chapters.reduce(Int64(0)) { total, chapter in
            let url = try directories.resolve(relativePath: chapter.artifactRelativePath)
            let size = Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            return total + size
        }
        do {
            try diskSpaceChecker.requireAvailable(
                at: parent,
                requiredBytes: max(64 * 1_024 * 1_024, artifactBytes + artifactBytes / 10)
            )
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        // The save panel grants access to the chosen file. Build and validate in
        // the app cache first, then atomically commit the finished audiobook.
        let hiddenTemporary = directories.cacheRoot.appending(
            path: "Export-\(UUID().uuidString).m4b"
        )
        let hiddenPartial = hiddenTemporary.deletingPathExtension()
            .appendingPathExtension("partial.m4b")
        defer {
            try? FileManager.default.removeItem(at: hiddenTemporary)
            try? FileManager.default.removeItem(at: hiddenPartial)
        }
        let chapters = try draft.chapters.map {
            M4BAudiobookChapter(
                title: $0.title,
                audioURL: try directories.resolve(relativePath: $0.artifactRelativePath)
            )
        }
        let coverData = try draft.coverRelativePath.map {
            try Data(contentsOf: directories.resolve(relativePath: $0))
        }
        let narrator = narratorName(modelID: draft.modelID, voiceID: draft.voiceID)

        do {
            _ = try await M4BPackager.packageAudiobook(M4BAudiobookPackageRequest(
                chapters: chapters,
                outputURL: hiddenTemporary,
                title: draft.title,
                author: draft.author,
                narrator: narrator,
                genre: String(localized: "有声书"),
                publicationDate: draft.publicationDate,
                languageCode: draft.languageCode,
                coverData: coverData
            )) { fraction, currentChapter in
                progress?(ExportProgress(
                    fractionCompleted: fraction,
                    currentFile: currentChapter
                ))
            }
            try Task.checkCancellation()
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(
                        destination,
                        withItemAt: hiddenTemporary
                    )
                } else {
                    try FileManager.default.copyItem(at: hiddenTemporary, to: destination)
                }
            } catch {
                throw ExportError.invalidDestination
            }
            progress?(ExportProgress(fractionCompleted: 1, currentFile: nil))
            AppLog.exporting.info("Completed export book=\(draft.id.uuidString, privacy: .public)")
            logger.event("export.completed", id: draft.id, count: draft.chapters.count, errorCode: nil)
            return destination
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExportError {
            throw error
        } catch PackagingError.validationFailed {
            throw ExportError.validationFailed
        } catch {
            let code = (error as? any StableAppError)?.code ?? "export.unknown"
            AppLog.exporting.error("Export failed book=\(draft.id.uuidString, privacy: .public) code=\(code, privacy: .public)")
            logger.event("export.failed", id: draft.id, count: nil, errorCode: code)
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    private func narratorName(modelID: String, voiceID: String?) -> String {
        if modelID == TTSModelCatalog.kokoroID {
            return TTSModelCatalog.kokoroVoices.first(where: { $0.id == voiceID })?.displayName
                ?? voiceID
                ?? TTSModelCatalog.kokoro.displayName
        }
        return String(localized: "Apple 系统语音")
    }
}
