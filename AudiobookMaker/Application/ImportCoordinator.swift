import CryptoKit
import Foundation
import OSLog

nonisolated enum ImportError: StableAppError, Equatable, Sendable {
    case unsupportedEPUB
    case unreadableFile
    case duplicateBook(existingID: UUID)
    case commitFailed
    case insufficientDiskSpace(requiredBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedEPUB: String(localized: "请选择扩展名为 .epub 的文件。")
        case .unreadableFile: String(localized: "无法读取所选 EPUB，请检查文件权限。")
        case .duplicateBook: String(localized: "这本书已经导入。")
        case .commitFailed: String(localized: "导入结果无法提交到资料库。")
        case let .insufficientDiskSpace(requiredBytes):
            String(
                format: String(localized: "可用磁盘空间不足，至少需要 %@。"),
                ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
            )
        }
    }

    var code: String {
        switch self {
        case .unsupportedEPUB: "import.unsupportedEPUB"
        case .unreadableFile: "import.unreadableFile"
        case .duplicateBook: "import.duplicateBook"
        case .commitFailed: "import.commitFailed"
        case .insufficientDiskSpace: "storage.insufficientDiskSpace"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unsupportedEPUB: String(localized: "请选择未加密的 EPUB 文件。")
        case .unreadableFile: String(localized: "请在 Finder 中确认文件仍存在，然后重新选择。")
        case .duplicateBook: String(localized: "可以显示已有书籍，或明确创建副本。")
        case .commitFailed: String(localized: "请重新导入；失败的暂存内容已清理。")
        case .insufficientDiskSpace: String(localized: "请释放磁盘空间后重试。")
        }
    }
}

nonisolated struct ImportCoordinator: Sendable {
    let directories: AppDirectories
    let parser: any EPUBParsing
    let diskSpaceChecker: any DiskSpaceChecking
    let logger: any ApplicationLogging

    init(
        directories: AppDirectories,
        parser: any EPUBParsing = EPUBParser(),
        diskSpaceChecker: any DiskSpaceChecking = SystemDiskSpaceChecker(),
        logger: any ApplicationLogging = PrivacyPreservingApplicationLogger()
    ) {
        self.directories = directories
        self.parser = parser
        self.diskSpaceChecker = diskSpaceChecker
        self.logger = logger
    }

    func prepareImport(from externalURL: URL) async throws -> ImportedBookDraft {
        try await Task.detached(priority: .utility) {
            try prepareSynchronously(from: externalURL)
        }.value
    }

    private func prepareSynchronously(from externalURL: URL) throws -> ImportedBookDraft {
        let interval = AppLog.importSignposter.beginInterval("EPUB Import")
        defer { AppLog.importSignposter.endInterval("EPUB Import", interval) }
        guard externalURL.pathExtension.lowercased() == "epub" else {
            throw ImportError.unsupportedEPUB
        }
        let didAccess = externalURL.startAccessingSecurityScopedResource()
        defer { if didAccess { externalURL.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.isReadableFile(atPath: externalURL.path) else {
            throw ImportError.unreadableFile
        }
        let sourceSize = Int64(
            (try? externalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        try diskSpaceChecker.requireAvailable(
            at: directories.root,
            requiredBytes: max(64 * 1_024 * 1_024, sourceSize * 4)
        )

        let bookID = UUID()
        logger.event("import.started", id: bookID, count: nil, errorCode: nil)
        AppLog.importing.info("Preparing imported book id=\(bookID.uuidString, privacy: .public)")
        let stagingDirectory = directories.staging
            .appending(path: bookID.uuidString, directoryHint: .isDirectory)
        let finalDirectory = directories.bookDirectory(id: bookID)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        do {
            let sourceURL = stagingDirectory.appending(path: "source.epub")
            try FileManager.default.copyItem(at: externalURL, to: sourceURL)
            let sourceHash = try SHA256Hasher.hashFile(at: sourceURL)
            let parsed = try parser.parse(url: sourceURL)

            let textDirectory = stagingDirectory.appending(path: "text", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: textDirectory, withIntermediateDirectories: true)
            var chapterDrafts: [ImportedChapterDraft] = []
            var totalCharacters: Int64 = 0
            for chapter in parsed.chapters {
                let chapterID = UUID()
                let fileName = String(format: "%04d.txt", chapter.index)
                let textURL = textDirectory.appending(path: fileName)
                let textData = Data(chapter.plainText.utf8)
                try textData.write(to: textURL, options: .atomic)
                totalCharacters += Int64(chapter.plainText.count)
                chapterDrafts.append(
                    ImportedChapterDraft(
                        id: chapterID,
                        index: chapter.index,
                        title: chapter.title,
                        sourceHref: chapter.sourceHref,
                        textRelativePath: "Books/\(bookID.uuidString)/text/\(fileName)",
                        textSHA256: SHA256Hasher.hash(textData),
                        characterCount: chapter.plainText.count
                    )
                )
            }

            var coverRelativePath: String?
            if let coverData = parsed.coverData {
                let extensionName = FileNameSanitizer.safeExtension(parsed.coverExtension)
                let coverDirectory = stagingDirectory.appending(path: "cover", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
                let coverURL = coverDirectory.appending(path: "original.\(extensionName)")
                try coverData.write(to: coverURL, options: .atomic)
                coverRelativePath = "Books/\(bookID.uuidString)/cover/original.\(extensionName)"
            }

            try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
            AppLog.importing.info("Imported book id=\(bookID.uuidString, privacy: .public) chapters=\(chapterDrafts.count)")
            logger.event("import.completed", id: bookID, count: chapterDrafts.count, errorCode: nil)
            return ImportedBookDraft(
                id: bookID,
                title: parsed.title,
                author: parsed.author ?? String(localized: "未知作者"),
                languageCode: parsed.language,
                publicationDate: parsed.publicationDate,
                sourceRelativePath: "Books/\(bookID.uuidString)/source.epub",
                sourceSHA256: sourceHash,
                coverRelativePath: coverRelativePath,
                totalCharacters: totalCharacters,
                chapters: chapterDrafts
            )
        } catch {
            let code = (error as? any StableAppError)?.code ?? "import.unknown"
            AppLog.importing.error("Import failed id=\(bookID.uuidString, privacy: .public) code=\(code, privacy: .public)")
            logger.event("import.failed", id: bookID, count: nil, errorCode: code)
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    func discardPreparedImport(_ draft: ImportedBookDraft) {
        try? FileManager.default.removeItem(at: directories.bookDirectory(id: draft.id))
    }
}

nonisolated protocol DiskSpaceChecking: Sendable {
    func requireAvailable(at url: URL, requiredBytes: Int64) throws
}

nonisolated struct SystemDiskSpaceChecker: DiskSpaceChecking {
    func requireAvailable(at url: URL, requiredBytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)
        guard available >= requiredBytes else {
            throw ImportError.insufficientDiskSpace(requiredBytes: requiredBytes)
        }
    }
}

nonisolated enum SHA256Hasher {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hashFile(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum FileNameSanitizer {
    static func safeExtension(_ candidate: String?) -> String {
        switch candidate?.lowercased() {
        case "png": "png"
        case "gif": "gif"
        case "webp": "webp"
        default: "jpg"
        }
    }

    static func visibleName(_ candidate: String, fallback: String = "未命名") -> String {
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let cleaned = candidate.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? fallback : cleaned).prefix(120))
    }
}
