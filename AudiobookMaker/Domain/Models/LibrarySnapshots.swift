import Foundation

nonisolated enum ModelInstallationState: String, Sendable, Equatable {
    case installed
    case notInstalled
    case downloading
    case verifying
    case installing
    case failed
    case corrupted
    case unavailable
}

nonisolated enum ModelRuntimeState: String, Sendable, Equatable {
    case ready
    case unloaded
    case unavailable
}

nonisolated struct PersistentModelSnapshot: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let framework: String
    let source: String?
    let isDefault: Bool
    let installation: ModelInstallationState
    let runtime: ModelRuntimeState
    let version: String
    let selectedVoiceID: String?
    let downloadProgress: Double
    let failureMessage: String?
    let downloadSize: Int64?

    init(
        id: String,
        displayName: String,
        framework: String,
        source: String?,
        isDefault: Bool,
        installation: ModelInstallationState,
        runtime: ModelRuntimeState,
        version: String = "system",
        selectedVoiceID: String? = nil,
        downloadProgress: Double = 0,
        failureMessage: String? = nil,
        downloadSize: Int64? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.framework = framework
        self.source = source
        self.isDefault = isDefault
        self.installation = installation
        self.runtime = runtime
        self.version = version
        self.selectedVoiceID = selectedVoiceID
        self.downloadProgress = downloadProgress
        self.failureMessage = failureMessage
        self.downloadSize = downloadSize
    }
}

nonisolated struct PersistentSettingsSnapshot: Sendable, Equatable {
    let maxConcurrentJobs: Int
    let selectedModelID: String
    let keepIntermediatePCM: Bool
    let selectedModelVersion: String
    let selectedVoiceID: String?

    init(
        maxConcurrentJobs: Int,
        selectedModelID: String,
        keepIntermediatePCM: Bool,
        selectedModelVersion: String = "system",
        selectedVoiceID: String? = nil
    ) {
        self.maxConcurrentJobs = maxConcurrentJobs
        self.selectedModelID = selectedModelID
        self.keepIntermediatePCM = keepIntermediatePCM
        self.selectedModelVersion = selectedModelVersion
        self.selectedVoiceID = selectedVoiceID
    }
}

nonisolated struct TTSVoiceDescriptor: Identifiable, Codable, Sendable, Equatable, Hashable {
    let id: String
    let displayName: String
    let languageCode: String
    let speakerID: Int32
}

nonisolated struct LockedTTSSelection: Codable, Sendable, Equatable {
    let modelID: String
    let modelVersion: String
    let voiceID: String?
}

nonisolated struct ResumableConversionJob: Sendable, Equatable {
    let id: UUID
    let selection: LockedTTSSelection
}

nonisolated struct PersistentChapterSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let index: Int
    let title: String
    let characterCount: Int
    let status: ChapterStatus
    let durationSeconds: Double?
}

nonisolated struct PersistentBookSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let languageCode: String?
    let coverRelativePath: String?
    let status: BookStatus
    let totalCharacters: Int64
    let jobCompletedUnits: Int64?
    let jobTotalUnits: Int64?
    let modelID: String?
    let chapters: [PersistentChapterSnapshot]
}

nonisolated struct ImportedChapterDraft: Sendable, Equatable {
    let id: UUID
    let index: Int
    let title: String
    let sourceHref: String
    let textRelativePath: String
    let textSHA256: String
    let characterCount: Int
}

nonisolated struct ImportedBookDraft: Sendable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let languageCode: String?
    let publicationDate: Date?
    let sourceRelativePath: String
    let sourceSHA256: String
    let coverRelativePath: String?
    let totalCharacters: Int64
    let chapters: [ImportedChapterDraft]

    init(
        id: UUID,
        title: String,
        author: String,
        languageCode: String?,
        publicationDate: Date? = nil,
        sourceRelativePath: String,
        sourceSHA256: String,
        coverRelativePath: String?,
        totalCharacters: Int64,
        chapters: [ImportedChapterDraft]
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.languageCode = languageCode
        self.publicationDate = publicationDate
        self.sourceRelativePath = sourceRelativePath
        self.sourceSHA256 = sourceSHA256
        self.coverRelativePath = coverRelativePath
        self.totalCharacters = totalCharacters
        self.chapters = chapters
    }
}

nonisolated struct ConversionChapterDraft: Identifiable, Sendable, Equatable {
    let id: UUID
    let index: Int
    let title: String
    let textRelativePath: String
    let textSHA256: String
    let characterCount: Int
    let status: ChapterStatus
}

nonisolated struct QueueSnapshot: Sendable, Equatable {
    let activeCount: Int
    let queuedCount: Int
    let completedUnits: Int64
    let totalUnits: Int64

    var progress: Double {
        totalUnits > 0 ? Double(completedUnits) / Double(totalUnits) : 0
    }
}

nonisolated struct ConversionBookDraft: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let languageCode: String?
    let coverRelativePath: String?
    let chapters: [ConversionChapterDraft]
}

nonisolated struct ExportChapterDraft: Identifiable, Sendable, Equatable {
    let id: UUID
    let index: Int
    let title: String
    let artifactRelativePath: String
    let durationSeconds: Double
    let textSHA256: String
}

nonisolated struct ExportBookDraft: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let languageCode: String?
    let coverRelativePath: String?
    let sourceSHA256: String
    let modelID: String
    let voiceID: String?
    let publicationDate: Date
    let chapters: [ExportChapterDraft]
}

nonisolated struct RecoveryArtifactDraft: Identifiable, Sendable, Equatable {
    let id: UUID
    let bookID: UUID
    let bookTitle: String
    let chapterTitle: String
    let textRelativePath: String
    let artifactRelativePath: String
    let isCommitted: Bool
}

nonisolated struct RecoveryDatabaseSnapshot: Sendable, Equatable {
    let interruptedBookCount: Int
    let artifacts: [RecoveryArtifactDraft]
}
