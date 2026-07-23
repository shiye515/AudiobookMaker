import AVFoundation
import Foundation
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
struct ExportCoordinatorTests {
    @Test @MainActor
    func completedUnicodeBookExportsOneValidatedM4B() async throws {
        let fixture = try await ExportFixture.make(
            completed: true,
            title: "世界：你好/再见",
            chapterTitle: "第一章：出发/归来",
            modelID: TTSModelCatalog.cosyVoiceID
        )
        defer { fixture.cleanup() }
        let destination = fixture.root.appending(path: "李光耀论中国与世界.m4b")

        _ = try await fixture.exporter.export(bookID: fixture.bookID, to: destination)
        #expect(destination.pathExtension == "m4b")
        try await M4BValidator.validateAudiobook(
            url: destination,
            expectedTitle: "世界：你好/再见",
            expectedChapterTitles: ["第一章：出发/归来"],
            expectsArtwork: true
        )
        let asset = AVURLAsset(url: destination)
        let metadata = try await asset.loadMetadata(for: .iTunesMetadata)
        #expect(try await metadata.first(where: { $0.identifier == .iTunesMetadataAuthor })?.load(.stringValue) == "测试作者")
        #expect(try await metadata.first(where: { $0.identifier == .iTunesMetadataPerformer })?.load(.stringValue) != nil)
        #expect(try await metadata.first(where: { $0.identifier == .iTunesMetadataUserGenre })?.load(.stringValue) == "有声书")
        #expect(try await metadata.first(where: { $0.identifier == .iTunesMetadataReleaseDate })?.load(.stringValue) != nil)
    }

    @Test @MainActor
    func incompleteBookCannotExport() async throws {
        let fixture = try await ExportFixture.make(completed: false)
        defer { fixture.cleanup() }
        let destination = fixture.root.appending(path: "incomplete.m4b")

        await #expect(throws: ExportError.bookIncomplete) {
            _ = try await fixture.exporter.export(bookID: fixture.bookID, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test @MainActor
    func cancellationRemovesTemporaryArchiveAndDoesNotCommitDestination() async throws {
        let fixture = try await ExportFixture.make(completed: true)
        defer { fixture.cleanup() }
        let destination = fixture.root.appending(path: "cancelled.m4b")
        let operation = Task {
            try await fixture.exporter.export(bookID: fixture.bookID, to: destination)
        }

        operation.cancel()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.dependencies.directories.cacheRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains("Export-") && $0.pathExtension == "m4b" }
        #expect(leftovers.isEmpty)
    }

    @Test @MainActor
    func insufficientDiskSpaceFailsBeforeCreatingArchive() async throws {
        let fixture = try await ExportFixture.make(completed: true)
        defer { fixture.cleanup() }
        let destination = fixture.root.appending(path: "no-space.m4b")
        let exporter = ExportCoordinator(
            repository: fixture.dependencies.repository,
            directories: fixture.dependencies.directories,
            diskSpaceChecker: FailingDiskSpaceChecker()
        )

        do {
            _ = try await exporter.export(bookID: fixture.bookID, to: destination)
            Issue.record("磁盘空间不足时不应导出成功")
        } catch let error as ExportError {
            #expect(error.code == "export.writeFailed")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test @MainActor
    func revokedDestinationPermissionIsRejectedWithoutTemporaryFiles() async throws {
        let fixture = try await ExportFixture.make(completed: true)
        defer { fixture.cleanup() }
        let locked = fixture.root.appending(path: "Revoked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: locked.path
            )
        }
        let destination = locked.appending(path: "revoked.m4b")

        await #expect(throws: ExportError.invalidDestination) {
            _ = try await fixture.exporter.export(bookID: fixture.bookID, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: locked.path)).isEmpty)
    }
}

private struct FailingDiskSpaceChecker: DiskSpaceChecking {
    func requireAvailable(at url: URL, requiredBytes: Int64) throws {
        throw ImportError.insufficientDiskSpace(requiredBytes: requiredBytes)
    }
}

@MainActor
private struct ExportFixture {
    let root: URL
    let dependencies: DependencyContainer
    let bookID: UUID

    var exporter: ExportCoordinator {
        ExportCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories
        )
    }

    static func make(
        completed: Bool,
        title: String = "导出测试",
        chapterTitle: String = "第一章",
        modelID: String = LibraryRepository.systemVoiceID
    ) async throws -> ExportFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let bookID = UUID()
        let chapterID = UUID()
        let bookDirectory = dependencies.directories.bookDirectory(id: bookID)
        let textURL = bookDirectory.appending(path: "text/0000.txt")
        try FileManager.default.createDirectory(
            at: textURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let text = Data("用于导出测试的正文".utf8)
        try text.write(to: textURL)
        try await dependencies.repository.importBook(ImportedBookDraft(
            id: bookID,
            title: title,
            author: "测试作者",
            languageCode: "zh-CN",
            sourceRelativePath: "Books/\(bookID)/source.epub",
            sourceSHA256: UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            coverRelativePath: "Books/\(bookID)/cover.png",
            totalCharacters: Int64(text.count),
            chapters: [ImportedChapterDraft(
                id: chapterID,
                index: 0,
                title: chapterTitle,
                sourceHref: "chapter.xhtml",
                textRelativePath: try dependencies.directories.relativePath(for: textURL),
                textSHA256: SHA256Hasher.hash(text),
                characterCount: text.count
            )]
        ))
        let coverURL = bookDirectory.appending(path: "cover.png")
        let coverData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        try coverData.write(to: coverURL)
        if completed {
            let audioURL = bookDirectory.appending(path: "audio/0001.m4b")
            try FileManager.default.createDirectory(
                at: audioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let segmentURL = bookDirectory.appending(path: "audio/0001.caf")
            _ = try await MockTTSRuntimeClient().synthesize(SynthesisRequest(
                text: "用于导出测试的正文",
                languageCode: "zh-CN",
                outputURL: segmentURL
            ))
            _ = try await M4BPackager.package(M4BPackageRequest(
                audioSegments: [segmentURL],
                outputURL: audioURL,
                title: title,
                author: "测试作者",
                chapterTitle: chapterTitle,
                chapterIndex: 0,
                languageCode: "zh-CN",
                fullText: "用于导出测试的正文",
                coverData: coverData
            ))
            let jobID = try await dependencies.repository.beginConversion(
                bookID: bookID,
                modelID: modelID
            )
            try await dependencies.repository.completeChapter(
                id: chapterID,
                artifactRelativePath: try dependencies.directories.relativePath(for: audioURL),
                durationSeconds: 1.25
            )
            try await dependencies.repository.finishConversion(bookID: bookID, jobID: jobID)
        }
        return ExportFixture(root: root, dependencies: dependencies, bookID: bookID)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
