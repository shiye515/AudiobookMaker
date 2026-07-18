import Foundation
import OSLog

nonisolated protocol EPUBParsing: Sendable {
    func parse(url: URL) throws -> ParsedEPUB
}

nonisolated protocol ZipArchiveWriting: Sendable {
    func write(
        entries: [ZipWriteEntry],
        to outputURL: URL,
        progress: (@Sendable (ZipWriteProgress) -> Void)?
    ) throws
}

nonisolated protocol M4BPackaging: Sendable {
    func package(_ request: M4BPackageRequest) async throws -> M4BPackageResult
}

nonisolated protocol AppFileStoring: Sendable {
    var root: URL { get }
    var cacheRoot: URL { get }
    var books: URL { get }
    var staging: URL { get }
    var trash: URL { get }
    func bookDirectory(id: UUID) -> URL
    func relativePath(for url: URL) throws -> String
    func resolve(relativePath: String) throws -> URL
}

nonisolated protocol LibraryPersisting: Sendable {
    func seedDefaults() async throws
    func models() async throws -> [PersistentModelSnapshot]
    func settings() async throws -> PersistentSettingsSnapshot
    func setDefaultModel(id: String) async throws
    func updateSettings(
        maxConcurrentJobs: Int,
        selectedModelID: String,
        keepIntermediatePCM: Bool
    ) async throws
    func importBook(_ draft: ImportedBookDraft, allowDuplicate: Bool) async throws
    func books() async throws -> [PersistentBookSnapshot]
    func deleteBook(id: UUID) async throws
    func conversionDraft(bookID: UUID) async throws -> ConversionBookDraft
    func enqueueConversion(bookID: UUID, modelID: String) async throws -> UUID
    func startConversion(bookID: UUID, jobID: UUID) async throws
    func beginConversion(bookID: UUID, modelID: String) async throws -> UUID
    func cancelQueuedConversion(bookID: UUID, jobID: UUID) async throws
    func markChapter(id: UUID, status: ChapterStatus) async throws
    func completeChapter(
        id: UUID,
        artifactRelativePath: String,
        durationSeconds: Double
    ) async throws
    func updateJobProgress(id: UUID, completedUnits: Int64) async throws
    func finishConversion(bookID: UUID, jobID: UUID) async throws
    func pauseConversion(bookID: UUID, jobID: UUID?) async throws
    func failConversion(
        bookID: UUID,
        jobID: UUID?,
        chapterID: UUID?,
        code: String,
        message: String
    ) async throws
    func exportDraft(bookID: UUID) async throws -> ExportBookDraft
    func recoverTransientState() async throws -> RecoveryDatabaseSnapshot
    func invalidateRecoveredArtifact(chapterID: UUID, message: String) async throws
    func commitRecoveredArtifact(
        chapterID: UUID,
        artifactRelativePath: String,
        durationSeconds: Double
    ) async throws
}

nonisolated protocol ApplicationLogging: Sendable {
    func event(_ name: String, id: UUID?, count: Int?, errorCode: String?)
}

nonisolated struct SystemM4BPackaging: M4BPackaging {
    func package(_ request: M4BPackageRequest) async throws -> M4BPackageResult {
        try await M4BPackager.package(request)
    }
}

nonisolated struct PrivacyPreservingApplicationLogger: ApplicationLogging {
    func event(_ name: String, id: UUID?, count: Int?, errorCode: String?) {
        AppLog.application.info(
            "event=\(name, privacy: .public) id=\(id?.uuidString ?? "none", privacy: .public) count=\(count ?? 0) code=\(errorCode ?? "none", privacy: .public)"
        )
    }
}

extension EPUBParser: EPUBParsing {}
extension ZipContainerWriter: ZipArchiveWriting {}
extension AppDirectories: AppFileStoring {}
extension LibraryRepository: LibraryPersisting {}
