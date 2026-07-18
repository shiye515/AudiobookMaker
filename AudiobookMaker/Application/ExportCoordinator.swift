import Foundation
import OSLog

nonisolated struct ExportMetadata: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Book: Codable, Equatable, Sendable {
        let id: UUID
        let title: String
        let author: String
        let languageCode: String?
        let sourceSHA256: String
    }

    struct Chapter: Codable, Equatable, Sendable {
        let index: Int
        let title: String
        let fileName: String
        let durationSeconds: Double
        let modelID: String
        let textSHA256: String
    }

    let schemaVersion: Int
    let generatedAt: Date
    let book: Book
    let chapters: [Chapter]
}

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
        case .validationFailed: String(localized: "导出的 ZIP 未通过完整性校验。")
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
    let writer: any ZipArchiveWriting
    let diskSpaceChecker: any DiskSpaceChecking
    let logger: any ApplicationLogging

    init(
        repository: LibraryRepository,
        directories: AppDirectories,
        writer: any ZipArchiveWriting = ZipContainerWriter(),
        diskSpaceChecker: any DiskSpaceChecking = SystemDiskSpaceChecker(),
        logger: any ApplicationLogging = PrivacyPreservingApplicationLogger()
    ) {
        self.repository = repository
        self.directories = directories
        self.writer = writer
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
            try export(draft: draft, to: destination, progress: progress)
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
    ) throws -> URL {
        let interval = AppLog.exportSignposter.beginInterval("Book Export")
        defer { AppLog.exportSignposter.endInterval("Book Export", interval) }
        AppLog.exporting.info("Starting export book=\(draft.id.uuidString, privacy: .public) chapters=\(draft.chapters.count)")
        logger.event("export.started", id: draft.id, count: draft.chapters.count, errorCode: nil)
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
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
        let hiddenTemporary = parent.appending(
            path: ".\(destination.lastPathComponent).\(UUID().uuidString).partial.zip"
        )
        defer { try? FileManager.default.removeItem(at: hiddenTemporary) }
        let modelID = "com.audiobookmaker.apple-system-speech"
        var entries: [ZipWriteEntry] = []
        var metadataChapters: [ExportMetadata.Chapter] = []
        for chapter in draft.chapters {
            let title = FileNameSanitizer.visibleName(chapter.title, fallback: "章节")
            let fileName = String(format: "%04d-%@.m4b", chapter.index + 1, title)
            let url = try directories.resolve(relativePath: chapter.artifactRelativePath)
            entries.append(ZipWriteEntry(path: "有声书/\(fileName)", source: .file(url)))
            metadataChapters.append(ExportMetadata.Chapter(
                index: chapter.index,
                title: chapter.title,
                fileName: fileName,
                durationSeconds: chapter.durationSeconds,
                modelID: modelID,
                textSHA256: chapter.textSHA256
            ))
        }
        if let coverPath = draft.coverRelativePath {
            let coverURL = try directories.resolve(relativePath: coverPath)
            entries.append(ZipWriteEntry(
                path: "封面/cover.\(coverURL.pathExtension.lowercased())",
                source: .file(coverURL)
            ))
        }
        let metadata = ExportMetadata(
            schemaVersion: ExportMetadata.currentVersion,
            generatedAt: .now,
            book: .init(
                id: draft.id,
                title: draft.title,
                author: draft.author,
                languageCode: draft.languageCode,
                sourceSHA256: draft.sourceSHA256
            ),
            chapters: metadataChapters
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        entries.append(ZipWriteEntry(
            path: "metadata.json",
            source: .data(try encoder.encode(metadata)),
            method: .deflated
        ))
        let readme = """
        \(draft.title)
        作者：\(draft.author)

        本归档由 AudiobookMaker 在本机生成，包含按阅读顺序排列的 M4B 章节、封面（如有）和 metadata.json。
        """
        entries.append(ZipWriteEntry(
            path: "README.txt",
            source: .data(Data(readme.utf8)),
            method: .deflated
        ))

        do {
            try writer.write(entries: entries, to: hiddenTemporary) { value in
                progress?(ExportProgress(
                    fractionCompleted: 0.05 + value.fractionCompleted * 0.9,
                    currentFile: value.currentPath
                ))
            }
            try Task.checkCancellation()
            let reader = try ZipContainerReader(url: hiddenTemporary)
            let paths = Set(reader.entries.map(\.path))
            let containsEveryChapter = metadataChapters.allSatisfy {
                paths.contains("有声书/\($0.fileName)")
            }
            guard paths.contains("metadata.json"),
                  paths.contains("README.txt"),
                  containsEveryChapter else {
                throw ExportError.validationFailed
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: hiddenTemporary, to: destination)
            progress?(ExportProgress(fractionCompleted: 1, currentFile: nil))
            AppLog.exporting.info("Completed export book=\(draft.id.uuidString, privacy: .public)")
            logger.event("export.completed", id: draft.id, count: draft.chapters.count, errorCode: nil)
            return destination
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ExportError {
            throw error
        } catch {
            let code = (error as? any StableAppError)?.code ?? "export.unknown"
            AppLog.exporting.error("Export failed book=\(draft.id.uuidString, privacy: .public) code=\(code, privacy: .public)")
            logger.event("export.failed", id: draft.id, count: nil, errorCode: code)
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }
}
