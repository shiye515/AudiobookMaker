import Foundation
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
        #expect(initial.contains { $0.id == LibraryRepository.cosyVoiceID })
        #expect(initial.count(where: \.isDefault) == 1)
        #expect(initial.first(where: \.isDefault)?.id == LibraryRepository.systemVoiceID)
        #expect(FileManager.default.fileExists(
            atPath: dependencies.directories.modelDirectory(id: LibraryRepository.cosyVoiceID).path
        ))

        try await dependencies.repository.updateSettings(
            maxConcurrentJobs: 2,
            selectedModelID: LibraryRepository.cosyVoiceID,
            keepIntermediatePCM: true
        )
        let updated = try await dependencies.repository.models()
        let settings = try await dependencies.repository.settings()
        #expect(updated.count(where: \.isDefault) == 1)
        #expect(updated.first(where: \.isDefault)?.id == LibraryRepository.cosyVoiceID)
        #expect(settings == PersistentSettingsSnapshot(
            maxConcurrentJobs: 2,
            selectedModelID: LibraryRepository.cosyVoiceID,
            keepIntermediatePCM: true
        ))
    }
}
