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
    let modelManager: ModelPackageManager
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
        let configuration: ModelConfiguration
        if !inMemory, let rootOverride {
            let persistenceDirectory = rootOverride.appending(
                path: "Persistence",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: persistenceDirectory,
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(
                "AudiobookMaker-v1",
                schema: schema,
                url: persistenceDirectory.appending(path: "AudiobookMaker.store"),
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "AudiobookMaker-v1",
                schema: schema,
                isStoredInMemoryOnly: inMemory
            )
        }
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
        let runtime = runtimeOverride ?? RoutingTTSRuntimeClient(directories: directories)
        self.runtime = runtime
        self.modelManager = ModelPackageManager(
            directories: directories,
            eventHandler: { [repository] event in
                try? await repository.updateModelInstallState(id: event.modelID, event: event)
            },
            runtimeProbe: { manifest in
                let capabilities = try await runtime.capabilities(for: manifest.id)
                guard capabilities.version == manifest.version else { throw RuntimeError.incompatibleRuntime }
            },
            referenceCheck: { [repository] modelID, version in
                try await repository.hasUnfinishedJob(modelID: modelID, modelVersion: version)
            }
        )
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
            logger: loggingService
        )
        self.recovery = RecoveryCoordinator(repository: repository, directories: directories)
        self.trash = TrashCoordinator(directories: directories)
    }
}
