import Foundation
import SwiftData

nonisolated enum RepositoryError: LocalizedError, Equatable, Sendable {
    case duplicateBook(existingID: UUID)
    case bookNotFound
    case illegalTransition
    case modelUnavailable
    case invalidVoice

    var errorDescription: String? {
        switch self {
        case .duplicateBook: "这本书已经存在于资料库中。"
        case .bookNotFound: "找不到指定书籍。"
        case .illegalTransition: "任务状态变更不合法。"
        case .modelUnavailable: "所选模型尚未安装或当前不可用。"
        case .invalidVoice: "所选音色不属于当前模型版本。"
        }
    }
}

@ModelActor
actor LibraryRepository {
    nonisolated static let systemVoiceID = "com.audiobookmaker.apple-system-speech"
    nonisolated static let kokoroID = TTSModelCatalog.kokoroID

    func seedDefaults() throws {
        let settingDescriptor = FetchDescriptor<AppSettingRecord>()
        if try modelContext.fetchCount(settingDescriptor) == 0 {
            modelContext.insert(AppSettingRecord())
        }
        let legacyIDs = ["aufklarer/" + "Cosy" + "Voice3-0.5B-" + "M" + "LX-8bit-full", "cosy" + "voice", "cosy" + "voice3"]
        let existingSettings = try modelContext.fetch(FetchDescriptor<AppSettingRecord>())
        for setting in existingSettings where legacyIDs.contains(where: { setting.selectedModelID.localizedCaseInsensitiveContains($0) }) {
            setting.selectedModelID = Self.systemVoiceID
            setting.selectedModelVersion = "system"
            setting.selectedVoiceID = nil
        }
        let existingJobs = try modelContext.fetch(FetchDescriptor<ConversionJobRecord>())
        for job in existingJobs where legacyIDs.contains(where: { job.modelID.localizedCaseInsensitiveContains($0) }) {
            job.legacyRuntimeDiagnostic = "Migrated unsupported legacy runtime: \(job.modelID)"
        }
        let legacyModels = try modelContext.fetch(FetchDescriptor<TTSModelRecord>())
        for model in legacyModels where legacyIDs.contains(where: { model.id.localizedCaseInsensitiveContains($0) }) {
            modelContext.delete(model)
        }

        let modelID = Self.kokoroID
        let modelDescriptor = FetchDescriptor<TTSModelRecord>(
            predicate: #Predicate { $0.id == modelID }
        )
        let currentKokoroVoices = TTSModelCatalog.kokoroVoices
        let currentKokoroVoicesData = try JSONEncoder().encode(currentKokoroVoices)
        if let record = try modelContext.fetch(modelDescriptor).first {
            // The bundled manifest is authoritative for this versioned model ID.
            // Older app builds may have created the record before voicesData was
            // populated, while the UI already displays the current catalog.
            record.displayName = TTSModelCatalog.kokoro.displayName
            record.frameworkRaw = "sherpa-onnx"
            record.source = TTSModelCatalog.kokoro.downloadURL.absoluteString
            record.version = TTSModelCatalog.kokoro.version
            record.downloadSize = TTSModelCatalog.kokoro.downloadBytes
            record.voicesData = currentKokoroVoicesData
            if !currentKokoroVoices.contains(where: { $0.id == record.selectedVoiceID }) {
                record.selectedVoiceID = TTSModelCatalog.kokoroDefaultVoiceID
            }
        } else {
            let record = TTSModelRecord(
                id: modelID,
                displayName: TTSModelCatalog.kokoro.displayName,
                frameworkRaw: "sherpa-onnx",
                source: TTSModelCatalog.kokoro.downloadURL.absoluteString,
                isDefault: false,
                installationRaw: "notInstalled",
                runtimeRaw: "unloaded"
            )
            record.version = TTSModelCatalog.kokoro.version
            record.downloadSize = TTSModelCatalog.kokoro.downloadBytes
            record.selectedVoiceID = TTSModelCatalog.kokoroDefaultVoiceID
            record.voicesData = currentKokoroVoicesData
            modelContext.insert(record)
        }
        let systemVoiceID = Self.systemVoiceID
        let systemVoiceDescriptor = FetchDescriptor<TTSModelRecord>(
            predicate: #Predicate { $0.id == systemVoiceID }
        )
        if try modelContext.fetchCount(systemVoiceDescriptor) == 0 {
            modelContext.insert(
                TTSModelRecord(
                    id: systemVoiceID,
                    displayName: "Apple 系统语音",
                    frameworkRaw: "AVFoundation",
                    isDefault: true,
                    installationRaw: "installed",
                    runtimeRaw: "ready"
                )
            )
        }
        let allModels = try modelContext.fetch(FetchDescriptor<TTSModelRecord>())
        if !allModels.contains(where: { $0.isDefault && ($0.id == systemVoiceID || ($0.id == Self.kokoroID && $0.installationRaw == "installed")) }) {
            for model in allModels { model.isDefault = model.id == systemVoiceID }
        }
        if let defaultKokoro = allModels.first(where: { $0.id == modelID && $0.isDefault }) {
            for setting in existingSettings where setting.selectedModelID == modelID {
                setting.selectedModelVersion = defaultKokoro.version
                setting.selectedVoiceID = defaultKokoro.selectedVoiceID
            }
        }
        try modelContext.save()
    }

    func models() throws -> [PersistentModelSnapshot] {
        try modelContext.fetch(
            FetchDescriptor<TTSModelRecord>(sortBy: [SortDescriptor(\TTSModelRecord.displayName)])
        ).map {
            PersistentModelSnapshot(
                id: $0.id,
                displayName: $0.displayName,
                framework: $0.frameworkRaw,
                source: $0.source,
                isDefault: $0.isDefault,
                installation: ModelInstallationState(rawValue: $0.installationRaw) ?? .unavailable,
                runtime: ModelRuntimeState(rawValue: $0.runtimeRaw) ?? .unavailable
                ,version: $0.version,
                selectedVoiceID: $0.selectedVoiceID,
                downloadProgress: $0.downloadProgress,
                failureMessage: $0.failureMessage,
                downloadSize: $0.downloadSize > 0 ? $0.downloadSize : nil
            )
        }
    }

    func settings() throws -> PersistentSettingsSnapshot {
        let records = try modelContext.fetch(FetchDescriptor<AppSettingRecord>())
        let record: AppSettingRecord
        if let existing = records.first {
            record = existing
        } else {
            record = AppSettingRecord()
            modelContext.insert(record)
            try modelContext.save()
        }
        return PersistentSettingsSnapshot(
            maxConcurrentJobs: record.maxConcurrentJobs,
            selectedModelID: record.selectedModelID,
            keepIntermediatePCM: record.keepIntermediatePCM
            ,selectedModelVersion: record.selectedModelVersion,
            selectedVoiceID: record.selectedVoiceID
        )
    }

    func setDefaultModel(id: String) throws {
        let models = try modelContext.fetch(FetchDescriptor<TTSModelRecord>())
        guard let selected = models.first(where: { $0.id == id }) else {
            throw RepositoryError.bookNotFound
        }
        guard selected.installationRaw == ModelInstallationState.installed.rawValue,
              selected.runtimeRaw != ModelRuntimeState.unavailable.rawValue else {
            throw RepositoryError.modelUnavailable
        }
        for model in models { model.isDefault = model.id == id }
        let settings = try modelContext.fetch(FetchDescriptor<AppSettingRecord>()).first
            ?? AppSettingRecord()
        if settings.modelContext == nil { modelContext.insert(settings) }
        settings.selectedModelID = id
        settings.selectedModelVersion = selected.version
        settings.selectedVoiceID = selected.selectedVoiceID
        try modelContext.save()
    }

    func updateModelInstallState(id: String, event: ModelInstallEvent) throws {
        let descriptor = FetchDescriptor<TTSModelRecord>(predicate: #Predicate { $0.id == id })
        guard let model = try modelContext.fetch(descriptor).first else { throw RepositoryError.bookNotFound }
        model.installationRaw = event.state.rawValue
        model.downloadProgress = event.progress
        model.failureMessage = event.message
        model.runtimeRaw = event.state == .installed ? ModelRuntimeState.ready.rawValue : ModelRuntimeState.unloaded.rawValue
        if event.state == .installed { model.lastValidatedAt = .now }
        try modelContext.save()
    }

    func setVoice(modelID: String, voiceID: String) throws {
        let descriptor = FetchDescriptor<TTSModelRecord>(predicate: #Predicate { $0.id == modelID })
        guard let model = try modelContext.fetch(descriptor).first else { throw RepositoryError.bookNotFound }
        let voices = (try? JSONDecoder().decode([TTSVoiceDescriptor].self, from: model.voicesData ?? Data())) ?? []
        guard voices.contains(where: { $0.id == voiceID }) else { throw RepositoryError.invalidVoice }
        model.selectedVoiceID = voiceID
        if model.isDefault, let setting = try modelContext.fetch(FetchDescriptor<AppSettingRecord>()).first {
            setting.selectedVoiceID = voiceID
        }
        try modelContext.save()
    }

    func voices(modelID: String) throws -> [TTSVoiceDescriptor] {
        let descriptor = FetchDescriptor<TTSModelRecord>(predicate: #Predicate { $0.id == modelID })
        guard let model = try modelContext.fetch(descriptor).first else { return [] }
        return (try? JSONDecoder().decode([TTSVoiceDescriptor].self, from: model.voicesData ?? Data())) ?? []
    }

    func updateSettings(
        maxConcurrentJobs: Int,
        selectedModelID: String,
        keepIntermediatePCM: Bool
    ) throws {
        guard maxConcurrentJobs == 1 || maxConcurrentJobs == 2 else {
            throw RepositoryError.illegalTransition
        }
        try setDefaultModel(id: selectedModelID)
        let setting = try modelContext.fetch(FetchDescriptor<AppSettingRecord>()).first
            ?? AppSettingRecord()
        if setting.modelContext == nil { modelContext.insert(setting) }
        setting.maxConcurrentJobs = maxConcurrentJobs
        setting.selectedModelID = selectedModelID
        setting.keepIntermediatePCM = keepIntermediatePCM
        try modelContext.save()
    }

    func importBook(_ draft: ImportedBookDraft, allowDuplicate: Bool = false) throws {
        if !allowDuplicate {
            let hash = draft.sourceSHA256
            let duplicateDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.sourceSHA256 == hash }
            )
            if let existing = try modelContext.fetch(duplicateDescriptor).first {
                throw RepositoryError.duplicateBook(existingID: existing.id)
            }
        }

        let book = BookRecord(
            id: draft.id,
            title: draft.title,
            author: draft.author,
            languageCode: draft.languageCode,
            publicationDate: draft.publicationDate,
            sourceRelativePath: draft.sourceRelativePath,
            sourceSHA256: draft.sourceSHA256,
            coverRelativePath: draft.coverRelativePath,
            totalCharacters: draft.totalCharacters
        )
        for chapterDraft in draft.chapters {
            let chapter = ChapterRecord(
                id: chapterDraft.id,
                index: chapterDraft.index,
                title: chapterDraft.title,
                sourceHref: chapterDraft.sourceHref,
                textRelativePath: chapterDraft.textRelativePath,
                textSHA256: chapterDraft.textSHA256,
                characterCount: chapterDraft.characterCount
            )
            chapter.book = book
            book.chapters.append(chapter)
        }
        modelContext.insert(book)
        try modelContext.save()
    }

    func books() throws -> [PersistentBookSnapshot] {
        let descriptor = FetchDescriptor<BookRecord>(
            sortBy: [SortDescriptor(\BookRecord.importedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { book in
            let latestJob = book.jobs.max { $0.queueOrdinal < $1.queueOrdinal }
            return PersistentBookSnapshot(
                id: book.id,
                title: book.title,
                author: book.author,
                languageCode: book.languageCode,
                coverRelativePath: book.coverRelativePath,
                status: book.status,
                totalCharacters: book.totalCharacters,
                jobCompletedUnits: latestJob?.completedUnits,
                jobTotalUnits: latestJob?.totalUnits,
                modelID: latestJob?.modelID,
                chapters: book.chapters
                    .sorted { $0.index < $1.index }
                    .map {
                        PersistentChapterSnapshot(
                            id: $0.id,
                            index: $0.index,
                            title: $0.title,
                            characterCount: $0.characterCount,
                            status: $0.status,
                            durationSeconds: $0.durationSeconds
                        )
                    }
            )
        }
    }

    func bookID(forSourceHash hash: String) throws -> UUID? {
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.sourceSHA256 == hash }
        )
        return try modelContext.fetch(descriptor).first?.id
    }

    func deleteBook(id: UUID) throws {
        let descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == id })
        guard let book = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        modelContext.delete(book)
        try modelContext.save()
    }

    func transitionJob(id: UUID, to destination: JobState) throws {
        let descriptor = FetchDescriptor<ConversionJobRecord>(predicate: #Predicate { $0.id == id })
        guard let job = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        guard job.state.canTransition(to: destination) else {
            throw RepositoryError.illegalTransition
        }
        job.state = destination
        if destination == .running { job.startedAt = job.startedAt ?? .now }
        if destination == .completed || destination == .failed || destination == .cancelled {
            job.finishedAt = .now
        }
        try modelContext.save()
    }

    func conversionDraft(bookID: UUID) throws -> ConversionBookDraft {
        let descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        guard let book = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        return ConversionBookDraft(
            id: book.id,
            title: book.title,
            author: book.author,
            languageCode: book.languageCode,
            coverRelativePath: book.coverRelativePath,
            chapters: book.chapters.sorted { $0.index < $1.index }.map {
                ConversionChapterDraft(
                    id: $0.id,
                    index: $0.index,
                    title: $0.title,
                    textRelativePath: $0.textRelativePath,
                    textSHA256: $0.textSHA256,
                    characterCount: $0.characterCount,
                    status: $0.status
                )
            }
        )
    }

    func enqueueConversion(bookID: UUID, modelID: String) throws -> UUID {
        try enqueueConversion(bookID: bookID, selection: LockedTTSSelection(modelID: modelID, modelVersion: "system", voiceID: nil))
    }

    func enqueueConversion(bookID: UUID, selection: LockedTTSSelection) throws -> UUID {
        let descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        guard let book = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        let jobDescriptor = FetchDescriptor<ConversionJobRecord>(
            sortBy: [SortDescriptor(\ConversionJobRecord.queueOrdinal, order: .reverse)]
        )
        let nextOrdinal = (try modelContext.fetch(jobDescriptor).first?.queueOrdinal ?? 0) + 1
        let job = ConversionJobRecord(
            modelID: selection.modelID,
            modelVersion: selection.modelVersion,
            voiceID: selection.voiceID,
            queueOrdinal: nextOrdinal,
            totalUnits: book.totalCharacters
        )
        job.book = book
        book.status = .queued
        book.jobs.append(job)
        book.updatedAt = .now
        modelContext.insert(job)
        try modelContext.save()
        return job.id
    }

    func startConversion(bookID: UUID, jobID: UUID) throws {
        let bookDescriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        let jobDescriptor = FetchDescriptor<ConversionJobRecord>(predicate: #Predicate { $0.id == jobID })
        guard let book = try modelContext.fetch(bookDescriptor).first,
              let job = try modelContext.fetch(jobDescriptor).first else {
            throw RepositoryError.bookNotFound
        }
        guard job.state == .queued else { throw RepositoryError.illegalTransition }
        job.state = .preparing
        job.state = .running
        job.startedAt = .now
        book.status = .converting
        book.updatedAt = .now
        try modelContext.save()
    }

    func beginConversion(bookID: UUID, modelID: String) throws -> UUID {
        let jobID = try enqueueConversion(bookID: bookID, modelID: modelID)
        try startConversion(bookID: bookID, jobID: jobID)
        return jobID
    }

    func jobSelection(id: UUID) throws -> LockedTTSSelection {
        let descriptor = FetchDescriptor<ConversionJobRecord>(predicate: #Predicate { $0.id == id })
        guard let job = try modelContext.fetch(descriptor).first else { throw RepositoryError.bookNotFound }
        return LockedTTSSelection(modelID: job.modelID, modelVersion: job.modelVersion, voiceID: job.voiceID)
    }

    func resumableConversion(bookID: UUID) throws -> ResumableConversionJob {
        let descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        guard let book = try modelContext.fetch(descriptor).first,
              let job = book.jobs
                .filter({ $0.state == .paused || $0.state == .interrupted })
                .max(by: { $0.queueOrdinal < $1.queueOrdinal }) else {
            throw RepositoryError.illegalTransition
        }
        return ResumableConversionJob(
            id: job.id,
            selection: LockedTTSSelection(
                modelID: job.modelID,
                modelVersion: job.modelVersion,
                voiceID: job.voiceID
            )
        )
    }

    func requeueConversion(bookID: UUID, jobID: UUID) throws {
        let bookDescriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        let jobDescriptor = FetchDescriptor<ConversionJobRecord>(predicate: #Predicate { $0.id == jobID })
        guard let book = try modelContext.fetch(bookDescriptor).first,
              let job = try modelContext.fetch(jobDescriptor).first,
              job.book?.id == bookID,
              job.state.canTransition(to: .queued) else {
            throw RepositoryError.illegalTransition
        }
        job.state = .queued
        job.lastHeartbeatAt = .now
        book.status = .queued
        book.updatedAt = .now
        try modelContext.save()
    }

    func cancelQueuedConversion(bookID: UUID, jobID: UUID) throws {
        let bookDescriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        let jobDescriptor = FetchDescriptor<ConversionJobRecord>(predicate: #Predicate { $0.id == jobID })
        guard let book = try modelContext.fetch(bookDescriptor).first,
              let job = try modelContext.fetch(jobDescriptor).first else {
            throw RepositoryError.bookNotFound
        }
        guard job.state == .queued else { throw RepositoryError.illegalTransition }
        job.state = .cancelled
        job.finishedAt = .now
        book.status = .ready
        try modelContext.save()
    }

    func markChapter(id: UUID, status: ChapterStatus) throws {
        let descriptor = FetchDescriptor<ChapterRecord>(predicate: #Predicate { $0.id == id })
        guard let chapter = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        chapter.status = status
        chapter.updatedAt = .now
        chapter.book?.updatedAt = .now
        try modelContext.save()
    }

    func completeChapter(
        id: UUID,
        artifactRelativePath: String,
        durationSeconds: Double
    ) throws {
        let descriptor = FetchDescriptor<ChapterRecord>(predicate: #Predicate { $0.id == id })
        guard let chapter = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        chapter.status = .completed
        chapter.artifactRelativePath = artifactRelativePath
        chapter.durationSeconds = durationSeconds
        chapter.lastErrorCode = nil
        chapter.lastErrorMessage = nil
        chapter.updatedAt = .now
        try modelContext.save()
    }

    func updateJobProgress(id: UUID, completedUnits: Int64) throws {
        let descriptor = FetchDescriptor<ConversionJobRecord>(predicate: #Predicate { $0.id == id })
        guard let job = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        job.completedUnits = min(job.totalUnits, max(job.completedUnits, completedUnits))
        job.lastHeartbeatAt = .now
        try modelContext.save()
    }

    func finishConversion(bookID: UUID, jobID: UUID) throws {
        let bookDescriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        let jobDescriptor = FetchDescriptor<ConversionJobRecord>(predicate: #Predicate { $0.id == jobID })
        guard let book = try modelContext.fetch(bookDescriptor).first,
              let job = try modelContext.fetch(jobDescriptor).first else {
            throw RepositoryError.bookNotFound
        }
        book.status = .completed
        book.updatedAt = .now
        job.state = .completing
        job.state = .completed
        job.completedUnits = job.totalUnits
        job.finishedAt = .now
        try modelContext.save()
    }

    func pauseConversion(bookID: UUID, jobID: UUID?) throws {
        let descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        guard let book = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        book.status = .paused
        for chapter in book.chapters where chapter.status == .synthesizing || chapter.status == .packaging {
            chapter.status = .paused
        }
        if let jobID {
            let jobs = FetchDescriptor<ConversionJobRecord>(predicate: #Predicate { $0.id == jobID })
            if let job = try modelContext.fetch(jobs).first {
                job.state = .pausing
                job.state = .paused
            }
        }
        try modelContext.save()
    }

    func failConversion(
        bookID: UUID,
        jobID: UUID?,
        chapterID: UUID?,
        code: String,
        message: String
    ) throws {
        let descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        guard let book = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        book.status = .failed
        if let chapterID, let chapter = book.chapters.first(where: { $0.id == chapterID }) {
            chapter.status = .failed
            chapter.lastErrorCode = code
            chapter.lastErrorMessage = message
            chapter.attemptCount += 1
        }
        if let jobID, let job = book.jobs.first(where: { $0.id == jobID }) {
            job.state = .failed
            job.errorCode = code
            job.errorMessage = message
            job.finishedAt = .now
        }
        try modelContext.save()
    }

    func exportDraft(bookID: UUID) throws -> ExportBookDraft {
        let descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate { $0.id == bookID })
        guard let book = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        let chapters = try book.chapters.sorted { $0.index < $1.index }.map { chapter in
            guard chapter.status == .completed,
                  let artifact = chapter.artifactRelativePath,
                  let duration = chapter.durationSeconds else {
                throw ExportError.bookIncomplete
            }
            return ExportChapterDraft(
                id: chapter.id,
                index: chapter.index,
                title: chapter.title,
                artifactRelativePath: artifact,
                durationSeconds: duration,
                textSHA256: chapter.textSHA256
            )
        }
        guard !chapters.isEmpty else { throw ExportError.bookIncomplete }
        let latestJob = book.jobs.max { $0.queueOrdinal < $1.queueOrdinal }
        let modelID = latestJob?.modelID ?? TTSModelCatalog.systemID
        return ExportBookDraft(
            id: book.id,
            title: book.title,
            author: book.author,
            languageCode: book.languageCode,
            coverRelativePath: book.coverRelativePath,
            sourceSHA256: book.sourceSHA256,
            modelID: modelID,
            voiceID: latestJob?.voiceID,
            publicationDate: book.publicationDate ?? book.importedAt,
            chapters: chapters
        )
    }

    func recoverTransientState() throws -> RecoveryDatabaseSnapshot {
        let books = try modelContext.fetch(FetchDescriptor<BookRecord>())
        var interruptedBookCount = 0
        for book in books {
            if book.status == .converting {
                book.status = .interrupted
                interruptedBookCount += 1
            }
            for chapter in book.chapters where chapter.status == .synthesizing || chapter.status == .packaging {
                chapter.status = .paused
            }
            for job in book.jobs {
                switch job.state {
                case .preparing, .running, .pausing, .completing:
                    job.state = .interrupted
                    job.finishedAt = .now
                default:
                    break
                }
            }
        }
        try modelContext.save()
        let artifacts: [RecoveryArtifactDraft] = books.flatMap { book -> [RecoveryArtifactDraft] in
            book.chapters.map { chapter -> RecoveryArtifactDraft in
                let expectedName = String(
                    format: "%04d-%@.m4b",
                    chapter.index + 1,
                    FileNameSanitizer.visibleName(chapter.title, fallback: "章节")
                )
                let artifact = chapter.artifactRelativePath
                    ?? "Books/\(book.id.uuidString)/audio/\(expectedName)"
                return RecoveryArtifactDraft(
                    id: chapter.id,
                    bookID: book.id,
                    bookTitle: book.title,
                    chapterTitle: chapter.title,
                    textRelativePath: chapter.textRelativePath,
                    artifactRelativePath: artifact,
                    isCommitted: chapter.status == .completed && chapter.artifactRelativePath != nil
                )
            }
        }
        return RecoveryDatabaseSnapshot(
            interruptedBookCount: interruptedBookCount,
            artifacts: artifacts
        )
    }

    func invalidateRecoveredArtifact(chapterID: UUID, message: String) throws {
        let descriptor = FetchDescriptor<ChapterRecord>(predicate: #Predicate { $0.id == chapterID })
        guard let chapter = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        chapter.status = .failed
        chapter.artifactRelativePath = nil
        chapter.durationSeconds = nil
        chapter.lastErrorCode = "recoveryValidationFailed"
        chapter.lastErrorMessage = message
        chapter.book?.status = .failed
        try modelContext.save()
    }

    func commitRecoveredArtifact(
        chapterID: UUID,
        artifactRelativePath: String,
        durationSeconds: Double
    ) throws {
        let descriptor = FetchDescriptor<ChapterRecord>(predicate: #Predicate { $0.id == chapterID })
        guard let chapter = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.bookNotFound
        }
        chapter.status = .completed
        chapter.artifactRelativePath = artifactRelativePath
        chapter.durationSeconds = durationSeconds
        chapter.lastErrorCode = nil
        chapter.lastErrorMessage = nil
        chapter.updatedAt = .now
        try modelContext.save()
    }
}
