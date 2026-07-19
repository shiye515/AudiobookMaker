import Foundation
import SwiftData

@Model
final class BookRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String
    var languageCode: String?
    var publicationDate: Date?
    var importedAt: Date
    var updatedAt: Date
    var sourceRelativePath: String
    var sourceSHA256: String
    var coverRelativePath: String?
    var statusRaw: String
    var totalCharacters: Int64

    @Relationship(deleteRule: .cascade, inverse: \ChapterRecord.book)
    var chapters: [ChapterRecord]

    @Relationship(deleteRule: .cascade, inverse: \ConversionJobRecord.book)
    var jobs: [ConversionJobRecord]

    var status: BookStatus {
        get { BookStatus(rawValue: statusRaw) ?? .ready }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID,
        title: String,
        author: String,
        languageCode: String?,
        publicationDate: Date? = nil,
        importedAt: Date = .now,
        sourceRelativePath: String,
        sourceSHA256: String,
        coverRelativePath: String?,
        totalCharacters: Int64
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.languageCode = languageCode
        self.publicationDate = publicationDate
        self.importedAt = importedAt
        self.updatedAt = importedAt
        self.sourceRelativePath = sourceRelativePath
        self.sourceSHA256 = sourceSHA256
        self.coverRelativePath = coverRelativePath
        self.statusRaw = BookStatus.ready.rawValue
        self.totalCharacters = totalCharacters
        self.chapters = []
        self.jobs = []
    }
}

@Model
final class ChapterRecord {
    @Attribute(.unique) var id: UUID
    var index: Int
    var title: String
    var sourceHref: String
    var textRelativePath: String
    var textSHA256: String
    var characterCount: Int
    var statusRaw: String
    var artifactRelativePath: String?
    var durationSeconds: Double?
    var attemptCount: Int
    var lastErrorCode: String?
    var lastErrorMessage: String?
    var updatedAt: Date
    var book: BookRecord?

    var status: ChapterStatus {
        get { ChapterStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        sourceHref: String,
        textRelativePath: String,
        textSHA256: String,
        characterCount: Int
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.sourceHref = sourceHref
        self.textRelativePath = textRelativePath
        self.textSHA256 = textSHA256
        self.characterCount = characterCount
        self.statusRaw = ChapterStatus.pending.rawValue
        self.attemptCount = 0
        self.updatedAt = .now
    }
}

@Model
final class TTSModelRecord {
    @Attribute(.unique) var id: String
    var displayName: String
    var frameworkRaw: String
    var source: String?
    var isDefault: Bool
    var installationRaw: String
    var runtimeRaw: String
    var capabilitiesData: Data?
    var lastValidatedAt: Date?
    var version: String = "system"
    var selectedVoiceID: String?
    var downloadProgress: Double = 0
    var failureMessage: String?
    var downloadSize: Int64 = 0
    var voicesData: Data?

    init(
        id: String,
        displayName: String,
        frameworkRaw: String,
        source: String? = nil,
        isDefault: Bool = false,
        installationRaw: String = "unavailable",
        runtimeRaw: String = "unloaded"
    ) {
        self.id = id
        self.displayName = displayName
        self.frameworkRaw = frameworkRaw
        self.source = source
        self.isDefault = isDefault
        self.installationRaw = installationRaw
        self.runtimeRaw = runtimeRaw
    }
}

@Model
final class ConversionJobRecord {
    @Attribute(.unique) var id: UUID
    var modelID: String
    var modelVersion: String = "system"
    var voiceID: String?
    var requestPurposeRaw: String = "conversion"
    var legacyRuntimeDiagnostic: String?
    var stateRaw: String
    var priority: Int
    @Attribute(.unique) var queueOrdinal: Int64
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var completedUnits: Int64
    var totalUnits: Int64
    var lastHeartbeatAt: Date?
    var errorCode: String?
    var errorMessage: String?
    var book: BookRecord?

    var state: JobState {
        get { JobState(rawValue: stateRaw) ?? .queued }
        set { stateRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        modelID: String,
        modelVersion: String = "system",
        voiceID: String? = nil,
        requestPurposeRaw: String = "conversion",
        queueOrdinal: Int64,
        totalUnits: Int64
    ) {
        self.id = id
        self.modelID = modelID
        self.modelVersion = modelVersion
        self.voiceID = voiceID
        self.requestPurposeRaw = requestPurposeRaw
        self.stateRaw = JobState.queued.rawValue
        self.priority = 0
        self.queueOrdinal = queueOrdinal
        self.createdAt = .now
        self.completedUnits = 0
        self.totalUnits = totalUnits
    }
}

@Model
final class AppSettingRecord {
    @Attribute(.unique) var key: String
    var maxConcurrentJobs: Int
    var selectedModelID: String
    var keepIntermediatePCM: Bool
    var selectedModelVersion: String = "system"
    var selectedVoiceID: String?
    var recentVoicesData: Data?
    var lastExportDirectoryBookmark: Data?

    init(
        key: String = "default",
        maxConcurrentJobs: Int = 1,
        selectedModelID: String = "com.audiobookmaker.apple-system-speech",
        keepIntermediatePCM: Bool = false
    ) {
        self.key = key
        self.maxConcurrentJobs = maxConcurrentJobs
        self.selectedModelID = selectedModelID
        self.keepIntermediatePCM = keepIntermediatePCM
    }
}

nonisolated enum AudiobookMakerSchema {
    static var schema: Schema {
        Schema([
            BookRecord.self,
            ChapterRecord.self,
            TTSModelRecord.self,
            ConversionJobRecord.self,
            AppSettingRecord.self,
        ])
    }
}
