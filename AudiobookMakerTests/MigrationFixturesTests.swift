import Foundation
import SwiftData
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
struct MigrationFixturesTests {
    @Test @MainActor
    func migratesLegacyKokoroStateIdempotentlyAndBlocksResume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let context = dependencies.modelContainer.mainContext

        let setting = AppSettingRecord()
        setting.selectedModelID = LibraryRepository.kokoroID
        setting.selectedModelVersion = "v1.0"
        setting.selectedVoiceID = "zf_001"
        let model = TTSModelRecord(
            id: LibraryRepository.kokoroID,
            displayName: "Kokoro 多语言 Int8",
            frameworkRaw: "sherpa-onnx",
            isDefault: true,
            installationRaw: ModelInstallationState.installed.rawValue,
            runtimeRaw: ModelRuntimeState.ready.rawValue
        )
        model.version = "v1.0"
        model.selectedVoiceID = "zf_001"
        let unfinishedBook = makeBook(title: "未完成任务")
        let completedBook = makeBook(title: "已完成任务")
        let paused = makeJob(state: .paused, ordinal: 1, book: unfinishedBook)
        let queued = makeJob(state: .queued, ordinal: 2, book: unfinishedBook)
        let interrupted = makeJob(state: .interrupted, ordinal: 3, book: unfinishedBook)
        let completed = makeJob(state: .completed, ordinal: 4, book: completedBook)
        context.insert(setting)
        context.insert(model)
        context.insert(unfinishedBook)
        context.insert(completedBook)
        for job in [paused, queued, interrupted, completed] { context.insert(job) }
        try context.save()

        try await dependencies.repository.seedDefaults()
        try await dependencies.repository.seedDefaults()

        let verificationContext = ModelContext(dependencies.modelContainer)
        let migratedSetting = try #require(
            verificationContext.fetch(FetchDescriptor<AppSettingRecord>()).first
        )
        #expect(migratedSetting.selectedModelID == TTSModelCatalog.systemID)
        #expect(migratedSetting.selectedModelVersion == "system")
        #expect(migratedSetting.selectedVoiceID == nil)
        #expect(migratedSetting.migrationVersion == LibraryRepository.currentMigrationVersion)
        let migratedModels = try verificationContext.fetch(FetchDescriptor<TTSModelRecord>())
        #expect(!migratedModels.contains { $0.id == LibraryRepository.kokoroID })
        let migratedJobs = try verificationContext.fetch(FetchDescriptor<ConversionJobRecord>())
        for jobID in [paused.id, queued.id, interrupted.id] {
            let job = try #require(migratedJobs.first { $0.id == jobID })
            #expect(job.requiresRestart)
            #expect(job.state == .failed)
            #expect(job.errorCode == "runtime.modelRemoved")
        }
        let preserved = try #require(migratedJobs.first { $0.id == completed.id })
        #expect(preserved.state == .completed)
        #expect(!preserved.requiresRestart)
        await #expect(throws: RepositoryError.illegalTransition) {
            try await dependencies.repository.resumableConversion(bookID: unfinishedBook.id)
        }
    }

    @Test @MainActor
    func restartDeletesLegacyCheckpointsBeforeCreatingSupportedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(
            inMemory: true,
            rootOverride: root,
            runtime: MockTTSRuntimeClient()
        )
        let context = dependencies.modelContainer.mainContext
        let setting = AppSettingRecord()
        setting.selectedModelID = LibraryRepository.kokoroID
        let book = makeBook(title: "需要重新开始")
        let job = makeJob(state: .paused, ordinal: 1, book: book)
        context.insert(setting)
        context.insert(book)
        context.insert(job)
        try context.save()
        try await dependencies.repository.seedDefaults()

        let checkpoint = dependencies.directories.bookDirectory(id: book.id)
            .appending(path: "audio/legacy/checkpoint.caf")
        try FileManager.default.createDirectory(
            at: checkpoint.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy checkpoint".utf8).write(to: checkpoint)

        await dependencies.converter.start(bookID: book.id)
        while await dependencies.converter.isActive(bookID: book.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
        let verificationContext = ModelContext(dependencies.modelContainer)
        let jobs = try verificationContext.fetch(FetchDescriptor<ConversionJobRecord>())
        let migratedJob = try #require(jobs.first { $0.id == job.id })
        #expect(!migratedJob.requiresRestart)
        #expect(migratedJob.state == .cancelled)
        let replacement = try #require(jobs.max { $0.queueOrdinal < $1.queueOrdinal })
        #expect(replacement.id != job.id)
        #expect(replacement.modelID == TTSModelCatalog.systemID)
        #expect(replacement.modelVersion == "system")
    }

    @Test
    func removesOnlyCanonicalManagedKokoroArtifacts() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(
            root: root.appending(path: "ApplicationSupport", directoryHint: .isDirectory),
            cacheRoot: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
        try directories.createIfNeeded()
        let model = directories.modelDirectory(id: LibraryRepository.kokoroID)
        let staging = try directories.modelStagingDirectory(
            id: LibraryRepository.kokoroID,
            version: "v1.0"
        )
        let resume = try directories.modelResumeDataURL(
            id: LibraryRepository.kokoroID,
            version: "v1.0"
        )
        let unrelated = directories.models.appending(path: "keep-me")
        for url in [model, staging, unrelated] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try Data("resume".utf8).write(to: resume)

        let removed = try directories.removeLegacyKokoroArtifacts()

        #expect(
            Set(removed.map(\.lastPathComponent))
                == Set([model, staging, resume].map(\.lastPathComponent))
        )
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func legacyCleanupFailsClosedForEscapingSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(
            root: root.appending(path: "ApplicationSupport", directoryHint: .isDirectory),
            cacheRoot: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
        try directories.createIfNeeded()
        let outside = root.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appending(path: "sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let managedPath = directories.modelDirectory(id: LibraryRepository.kokoroID)
        try FileManager.default.createSymbolicLink(at: managedPath, withDestinationURL: outside)

        #expect(throws: AppDirectoryError.unsafeRelativePath) {
            try directories.removeLegacyKokoroArtifacts()
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(FileManager.default.fileExists(atPath: managedPath.path))
    }

    @MainActor
    private func makeBook(title: String) -> BookRecord {
        BookRecord(
            id: UUID(),
            title: title,
            author: "Author",
            languageCode: "zh-CN",
            sourceRelativePath: "Books/fixture/source.epub",
            sourceSHA256: UUID().uuidString,
            coverRelativePath: nil,
            totalCharacters: 0
        )
    }

    @MainActor
    private func makeJob(
        state: JobState,
        ordinal: Int64,
        book: BookRecord
    ) -> ConversionJobRecord {
        let job = ConversionJobRecord(
            modelID: LibraryRepository.kokoroID,
            modelVersion: "v1.0",
            voiceID: "zf_001",
            queueOrdinal: ordinal,
            totalUnits: 0
        )
        job.state = state
        job.book = book
        book.jobs.append(job)
        return job
    }
}
