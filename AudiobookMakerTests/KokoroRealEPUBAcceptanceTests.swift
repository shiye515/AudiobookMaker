import AVFoundation
import Foundation
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
struct KokoroRealEPUBAcceptanceTests {
    private let sentinel = URL(filePath: "/tmp/AudiobookMaker-Run-Full-Kokoro-Acceptance")
    private let epub = URL(filePath: "/tmp/AudiobookMaker-RealEPUB.epub")
    private let archive = URL(filePath: "/tmp/kokoro-int8-multi-lang-v1_1.tar.bz2")
    private let root = URL(filePath: "/tmp/AudiobookMaker-Kokoro-Full-Acceptance", directoryHint: .isDirectory)

    @Test @MainActor
    func fullChineseEPUBPauseRestartResumeAndExportWhenEnabled() async throws {
        guard FileManager.default.fileExists(atPath: sentinel.path) else { return }
        #expect(FileManager.default.fileExists(atPath: epub.path))
        #expect(FileManager.default.fileExists(atPath: archive.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originalHash = try SHA256Hasher.hashFile(at: epub)

        var acceptedBookID: UUID?
        do {
            let dependencies = try DependencyContainer(inMemory: false, rootOverride: root)
            try await dependencies.repository.seedDefaults()
            _ = try await dependencies.recovery.recover()
            try await installModelIfNeeded(in: dependencies.directories)
            try await dependencies.repository.updateModelInstallState(
                id: TTSModelCatalog.kokoroID,
                event: ModelInstallEvent(state: .installed, progress: 1, message: nil)
            )
            try await dependencies.repository.setVoice(
                modelID: TTSModelCatalog.kokoroID,
                voiceID: "zf_001"
            )
            try await dependencies.repository.setDefaultModel(id: TTSModelCatalog.kokoroID)

            let sourceHash = try SHA256Hasher.hashFile(at: epub)
            let bookID: UUID
            if let existing = try await dependencies.repository.bookID(forSourceHash: sourceHash) {
                bookID = existing
            } else {
                let draft = try await dependencies.importer.prepareImport(from: epub)
                try await dependencies.repository.importBook(draft)
                bookID = draft.id
            }
            acceptedBookID = bookID

            let previewURL = root.appending(path: "Kokoro-zf_001-preview.caf")
            if !FileManager.default.fileExists(atPath: previewURL.path) {
                let runtime = KokoroTTSRuntimeClient(directories: dependencies.directories)
                _ = try await runtime.synthesize(SynthesisRequest(
                    text: "你好，这是 Kokoro 中文女声 zf_001 的本机试听。",
                    languageCode: "zh-CN",
                    voiceIdentifier: "zf_001",
                    outputURL: previewURL,
                    modelID: TTSModelCatalog.kokoroID,
                    modelVersion: TTSModelCatalog.kokoro.version,
                    purpose: .preview
                ))
                #expect(try await AVURLAsset(url: previewURL).loadTracks(withMediaType: .audio).count == 1)
            }

            let snapshot = try #require(
                try await dependencies.repository.books().first(where: { $0.id == bookID })
            )
            if snapshot.status == .ready {
                await dependencies.converter.start(bookID: bookID)
                try await Task.sleep(for: .milliseconds(500))
                await dependencies.converter.pause(bookID: bookID)
                try await waitUntilIdle(dependencies.converter, bookID: bookID)
                let paused = try #require(
                    try await dependencies.repository.books().first(where: { $0.id == bookID })
                )
                #expect(paused.status == .paused)
                let locked = try await dependencies.repository.resumableConversion(bookID: bookID)
                #expect(locked.selection == LockedTTSSelection(
                    modelID: TTSModelCatalog.kokoroID,
                    modelVersion: TTSModelCatalog.kokoro.version,
                    voiceID: "zf_001"
                ))
            }
        }

        // Reopen both SwiftData and the native runtime from the persistent root.
        // No downloader or network API is created on this path.
        do {
            let dependencies = try DependencyContainer(inMemory: false, rootOverride: root)
            try await dependencies.repository.seedDefaults()
            _ = try await dependencies.recovery.recover()
            let bookID = try #require(acceptedBookID)
            var snapshot = try #require(
                try await dependencies.repository.books().first(where: { $0.id == bookID })
            )
            if snapshot.status == .paused || snapshot.status == .interrupted {
                await dependencies.converter.resume(bookID: bookID)
                var lastReport = Date.distantPast
                while await dependencies.converter.isActive(bookID: bookID) {
                    if Date().timeIntervalSince(lastReport) >= 30 {
                        snapshot = try #require(
                            try await dependencies.repository.books().first(where: { $0.id == bookID })
                        )
                        try progressReport(snapshot).write(
                            to: root.appending(path: "progress.txt"),
                            atomically: true,
                            encoding: .utf8
                        )
                        lastReport = .now
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                snapshot = try #require(
                    try await dependencies.repository.books().first(where: { $0.id == bookID })
                )
            }
            #expect(snapshot.status == .completed)
            #expect(snapshot.chapters.count == 14)
            #expect(snapshot.chapters.allSatisfy { $0.status == .completed })

            let exportURL = root.appending(path: "李光耀论中国与世界-Kokoro-zf_001.m4b")
            _ = try await dependencies.exporter.export(bookID: bookID, to: exportURL)
            try await M4BValidator.validateAudiobook(
                url: exportURL,
                expectedTitle: snapshot.title,
                expectedChapterTitles: snapshot.chapters.map(\.title),
                expectsArtwork: false
            )
            #expect(try SHA256Hasher.hashFile(at: epub) == originalHash)
            let report = progressReport(snapshot) + "\nexport=\(exportURL.path)\nsource_sha256=\(originalHash)\n"
            try report.write(
                to: root.appending(path: "completed.txt"),
                atomically: true,
                encoding: .utf8
            )
            Attachment.record(report, named: "Kokoro 真实 EPUB 全书验收.txt")
            try? FileManager.default.removeItem(at: sentinel)
        }
    }

    private func installModelIfNeeded(in directories: AppDirectories) async throws {
        let manager = ModelPackageManager(directories: directories)
        let destination = try directories.modelVersionDirectory(
            id: TTSModelCatalog.kokoroID,
            version: TTSModelCatalog.kokoro.version
        )
        if TTSModelCatalog.kokoro.requiredPaths.allSatisfy({
            FileManager.default.fileExists(atPath: destination.appending(path: $0).path)
        }) {
            _ = try await manager.validate()
            return
        }
        try? FileManager.default.removeItem(at: destination)
        guard try SHA256Hasher.hashFile(at: archive) == TTSModelCatalog.kokoro.sha256 else {
            throw ModelPackageError.checksumMismatch
        }
        try await manager.installVerifiedArchive(archive, manifest: TTSModelCatalog.kokoro)
        _ = try await manager.validate()
    }

    private func waitUntilIdle(_ coordinator: ConversionCoordinator, bookID: UUID) async throws {
        while await coordinator.isActive(bookID: bookID) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func progressReport(_ snapshot: PersistentBookSnapshot) -> String {
        let completed = snapshot.jobCompletedUnits ?? 0
        let total = snapshot.jobTotalUnits ?? snapshot.totalCharacters
        return "timestamp=\(Date().ISO8601Format())\n" +
            "status=\(snapshot.status.rawValue)\n" +
            "chapters_completed=\(snapshot.chapters.count { $0.status == .completed })/\(snapshot.chapters.count)\n" +
            "characters_completed=\(completed)/\(total)\n" +
            "model_id=\(TTSModelCatalog.kokoroID)\n" +
            "model_version=\(TTSModelCatalog.kokoro.version)\n" +
            "voice_id=zf_001\n"
    }
}
