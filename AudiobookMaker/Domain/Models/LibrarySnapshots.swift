import Foundation

nonisolated enum ModelInstallationState: String, Sendable, Equatable {
    case installed
    case notInstalled
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
}

nonisolated struct PersistentSettingsSnapshot: Sendable, Equatable {
    let maxConcurrentJobs: Int
    let selectedModelID: String
    let keepIntermediatePCM: Bool
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
    let sourceRelativePath: String
    let sourceSHA256: String
    let coverRelativePath: String?
    let totalCharacters: Int64
    let chapters: [ImportedChapterDraft]
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
