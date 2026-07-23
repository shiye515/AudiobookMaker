import Foundation
import SwiftData
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
struct RepositoryModelSettingsTests {
    @Test @MainActor
    func seedsModelCatalogAndPersistsOneDefault() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)

        try await dependencies.repository.seedDefaults()
        let initial = try await dependencies.repository.models()
        #expect(initial.contains { $0.id == LibraryRepository.systemVoiceID })
        #expect(initial.contains { $0.id == TTSModelCatalog.cosyVoiceID })
        #expect(initial.contains { $0.id == TTSModelCatalog.qwen3TTSID })
        #expect(initial.count(where: \.isDefault) == 1)
        #expect(initial.first(where: \.isDefault)?.id == LibraryRepository.systemVoiceID)
        #expect(initial.first(where: { $0.id == TTSModelCatalog.cosyVoiceID })?.installation == .notInstalled)

        await #expect(throws: RepositoryError.modelUnavailable) {
            try await dependencies.repository.updateSettings(
                maxConcurrentJobs: 2,
                selectedModelID: TTSModelCatalog.cosyVoiceID,
                keepIntermediatePCM: true
            )
        }
        try await dependencies.repository.updateModelInstallState(
            id: TTSModelCatalog.cosyVoiceID,
            event: ModelInstallEvent(modelID: TTSModelCatalog.cosyVoiceID, state: .installed, progress: 1, message: nil)
        )
        try await dependencies.repository.setVoice(modelID: TTSModelCatalog.cosyVoiceID, voiceID: "default")
        try await dependencies.repository.updateSettings(
            maxConcurrentJobs: 2,
            selectedModelID: TTSModelCatalog.cosyVoiceID,
            keepIntermediatePCM: true
        )
        let updated = try await dependencies.repository.models()
        let settings = try await dependencies.repository.settings()
        #expect(updated.count(where: \.isDefault) == 1)
        #expect(updated.first(where: \.isDefault)?.id == TTSModelCatalog.cosyVoiceID)
        #expect(settings == PersistentSettingsSnapshot(
            maxConcurrentJobs: 2,
            selectedModelID: TTSModelCatalog.cosyVoiceID,
            keepIntermediatePCM: true,
            selectedModelVersion: TTSModelCatalog.cosyVoice.version,
            selectedVoiceID: "default"
        ))
    }

    @Test @MainActor
    func speechSwiftVoiceSelectionPersistsPerStableModelID() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        try await dependencies.repository.seedDefaults()

        try await dependencies.repository.updateModelInstallState(
            id: TTSModelCatalog.qwen3TTSID,
            event: .init(
                modelID: TTSModelCatalog.qwen3TTSID,
                state: .installed,
                progress: 1,
                message: nil
            )
        )
        try await dependencies.repository.setVoice(modelID: TTSModelCatalog.qwen3TTSID, voiceID: "aiden")
        try await dependencies.repository.updateSettings(
            maxConcurrentJobs: 1,
            selectedModelID: TTSModelCatalog.qwen3TTSID,
            keepIntermediatePCM: false
        )
        try await dependencies.repository.seedDefaults()

        #expect(try await dependencies.repository.voices(modelID: TTSModelCatalog.qwen3TTSID) == TTSModelCatalog.qwen3TTSVoices)
        let settings = try await dependencies.repository.settings()
        #expect(settings.selectedModelID == TTSModelCatalog.qwen3TTSID)
        #expect(settings.selectedModelVersion == TTSModelCatalog.qwen3TTS.version)
        #expect(settings.selectedVoiceID == "aiden")
        #expect(try await dependencies.repository.models().first(where: {
            $0.id == TTSModelCatalog.cosyVoiceID
        })?.selectedVoiceID == "default")
    }

    @Test @MainActor
    func migratesLegacyDefaultAndPreservesJobDiagnostic() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let context = dependencies.modelContainer.mainContext
        let legacyID = "aufklarer/" + "Cosy" + "Voice3-0.5B-" + "MLX-8bit-full"
        let settings = AppSettingRecord()
        settings.selectedModelID = legacyID
        let model = TTSModelRecord(
            id: legacyID, displayName: "Legacy", frameworkRaw: "legacy",
            isDefault: true, installationRaw: "installed", runtimeRaw: "ready"
        )
        let job = ConversionJobRecord(modelID: legacyID, queueOrdinal: 1, totalUnits: 1)
        context.insert(settings); context.insert(model); context.insert(job)
        try context.save()

        try await dependencies.repository.seedDefaults()
        let migrated = try await dependencies.repository.settings()
        #expect(migrated.selectedModelID == TTSModelCatalog.systemID)
        #expect(try await dependencies.repository.models().contains(where: { $0.id == legacyID }) == false)
        let storedJob = try context.fetch(FetchDescriptor<ConversionJobRecord>()).first
        #expect(storedJob?.legacyRuntimeDiagnostic?.contains("Migrated unsupported legacy runtime") == true)
    }

    @Test @MainActor
    func refreshesExistingSpeechSwiftVoiceCatalogAndRepairsSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let context = dependencies.modelContainer.mainContext
        let staleVoice = TTSVoiceDescriptor(
            id: "removed_voice",
            displayName: "旧音色",
            languageCode: "zh-CN",
            speakerID: 0
        )
        let staleModel = TTSModelRecord(
            id: TTSModelCatalog.cosyVoiceID,
            displayName: "CosyVoice3",
            frameworkRaw: "speech-swift / MLX",
            isDefault: true,
            installationRaw: ModelInstallationState.installed.rawValue,
            runtimeRaw: ModelRuntimeState.ready.rawValue
        )
        staleModel.version = "old-version"
        staleModel.selectedVoiceID = staleVoice.id
        staleModel.voicesData = try JSONEncoder().encode([staleVoice])
        let staleSettings = AppSettingRecord()
        staleSettings.selectedModelID = TTSModelCatalog.cosyVoiceID
        staleSettings.selectedModelVersion = "old-version"
        staleSettings.selectedVoiceID = staleVoice.id
        context.insert(staleModel)
        context.insert(staleSettings)
        try context.save()

        try await dependencies.repository.seedDefaults()

        let voices = try await dependencies.repository.voices(modelID: TTSModelCatalog.cosyVoiceID)
        let settings = try await dependencies.repository.settings()
        #expect(voices == TTSModelCatalog.cosyVoiceVoices)
        #expect(settings.selectedModelVersion == TTSModelCatalog.cosyVoice.version)
        #expect(settings.selectedVoiceID == "default")
    }

    @Test @MainActor
    func locksModelVersionAndVoiceWhenJobIsCreated() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        try await dependencies.repository.seedDefaults()
        let bookID = UUID()
        try await dependencies.repository.importBook(ImportedBookDraft(
            id: bookID, title: "锁定测试", author: "测试", languageCode: "zh-CN",
            sourceRelativePath: "Books/source.epub", sourceSHA256: UUID().uuidString,
            coverRelativePath: nil, totalCharacters: 1, chapters: []
        ))
        let locked = LockedTTSSelection(
            modelID: TTSModelCatalog.cosyVoiceID,
            modelVersion: TTSModelCatalog.cosyVoice.version,
            voiceID: "default"
        )
        let jobID = try await dependencies.repository.enqueueConversion(bookID: bookID, selection: locked)
        try await dependencies.repository.setVoice(modelID: TTSModelCatalog.cosyVoiceID, voiceID: "default")
        #expect(try await dependencies.repository.jobSelection(id: jobID) == locked)
        #expect(try await dependencies.repository.books().first?.modelID == TTSModelCatalog.cosyVoiceID)
        #expect(try await dependencies.repository.hasUnfinishedJob(
            modelID: locked.modelID,
            modelVersion: locked.modelVersion
        ))
        try await dependencies.repository.transitionJob(id: jobID, to: .cancelled)
        let remainsReferenced = try await dependencies.repository.hasUnfinishedJob(
            modelID: locked.modelID,
            modelVersion: locked.modelVersion
        )
        #expect(!remainsReferenced)
    }
}
