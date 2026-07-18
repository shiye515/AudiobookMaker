import Foundation
import SwiftData

@MainActor
final class DependencyContainer {
    let modelContainer: ModelContainer
    let repository: LibraryRepository
    let directories: AppDirectories
    let persistenceService: any LibraryPersisting
    let fileStorageService: any AppFileStoring
    let epubService: any EPUBParsing
    let mediaService: any M4BPackaging
    let archiveService: any ZipArchiveWriting
    let loggingService: any ApplicationLogging
    let importer: ImportCoordinator
    let runtime: any TTSRuntimeClient
    let converter: ConversionCoordinator
    let exporter: ExportCoordinator
    let recovery: RecoveryCoordinator
    let trash: TrashCoordinator

    init(
        inMemory: Bool = false,
        rootOverride: URL? = nil,
        runtime runtimeOverride: (any TTSRuntimeClient)? = nil
    ) throws {
        let schema = AudiobookMakerSchema.schema
        let configuration = ModelConfiguration(
            "AudiobookMaker-v1",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        self.modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        if let rootOverride {
            self.directories = AppDirectories(
                root: rootOverride.appending(path: "ApplicationSupport", directoryHint: .isDirectory),
                cacheRoot: rootOverride.appending(path: "Caches", directoryHint: .isDirectory)
            )
            try directories.createIfNeeded()
        } else {
            self.directories = try AppDirectories.live()
        }
        try FileManager.default.createDirectory(
            at: directories.modelDirectory(id: LibraryRepository.cosyVoiceID),
            withIntermediateDirectories: true
        )
        self.repository = LibraryRepository(modelContainer: modelContainer)
        self.persistenceService = repository
        self.fileStorageService = directories
        self.epubService = EPUBParser()
        self.mediaService = SystemM4BPackaging()
        self.archiveService = ZipContainerWriter()
        self.loggingService = PrivacyPreservingApplicationLogger()
        self.importer = ImportCoordinator(
            directories: directories,
            parser: epubService,
            logger: loggingService
        )
        self.runtime = runtimeOverride ?? SystemSpeechRuntimeClient()
        self.converter = ConversionCoordinator(
            repository: repository,
            directories: directories,
            runtime: runtime,
            packager: mediaService,
            logger: loggingService
        )
        self.exporter = ExportCoordinator(
            repository: repository,
            directories: directories,
            writer: archiveService,
            logger: loggingService
        )
        self.recovery = RecoveryCoordinator(repository: repository, directories: directories)
        self.trash = TrashCoordinator(directories: directories)
    }
}
