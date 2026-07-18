import Foundation
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
struct ExportCoordinatorTests {
    @Test @MainActor
    func completedUnicodeBookExportsAndSystemDittoExtractsIt() async throws {
        let fixture = try await ExportFixture.make(
            completed: true,
            title: "世界：你好/再见",
            chapterTitle: "第一章：出发/归来"
        )
        defer { fixture.cleanup() }
        let destination = fixture.root.appending(path: "李光耀论中国与世界.zip")

        _ = try await fixture.exporter.export(bookID: fixture.bookID, to: destination)
        let archive = try ZipContainerReader(url: destination)
        #expect(archive.paths.contains("metadata.json"))
        #expect(archive.paths.contains("README.txt"))
        #expect(archive.paths.contains { $0 == "有声书/0001-第一章：出发-归来.m4b" })

        let extracted = fixture.root.appending(path: "FinderExtract", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", destination.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(
            atPath: extracted.appending(path: "metadata.json").path
        ))
    }

    @Test @MainActor
    func incompleteBookCannotExport() async throws {
        let fixture = try await ExportFixture.make(completed: false)
        defer { fixture.cleanup() }
        let destination = fixture.root.appending(path: "incomplete.zip")

        await #expect(throws: ExportError.bookIncomplete) {
            _ = try await fixture.exporter.export(bookID: fixture.bookID, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test @MainActor
    func cancellationRemovesTemporaryArchiveAndDoesNotCommitDestination() async throws {
        let fixture = try await ExportFixture.make(completed: true, artifactSize: 128 * 1_024 * 1_024)
        defer { fixture.cleanup() }
        let destination = fixture.root.appending(path: "cancelled.zip")
        let operation = Task {
            try await fixture.exporter.export(bookID: fixture.bookID, to: destination)
        }

        try await Task.sleep(for: .milliseconds(5))
        operation.cancel()
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".partial.zip") }
        #expect(leftovers.isEmpty)
    }

    @Test @MainActor
    func insufficientDiskSpaceFailsBeforeCreatingArchive() async throws {
        let fixture = try await ExportFixture.make(completed: true)
        defer { fixture.cleanup() }
        let destination = fixture.root.appending(path: "no-space.zip")
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
        let destination = locked.appending(path: "revoked.zip")

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
        artifactSize: UInt64 = 4_096
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
            coverRelativePath: nil,
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
        if completed {
            let audioURL = bookDirectory.appending(path: "audio/0001.m4b")
            try FileManager.default.createDirectory(
                at: audioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: audioURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: audioURL)
            try handle.truncate(atOffset: artifactSize)
            try handle.close()
            let jobID = try await dependencies.repository.beginConversion(
                bookID: bookID,
                modelID: LibraryRepository.systemVoiceID
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
