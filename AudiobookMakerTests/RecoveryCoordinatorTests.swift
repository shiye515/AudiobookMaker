import Foundation
import Testing
@testable import AudiobookMaker

struct RecoveryCoordinatorTests {
    @Test @MainActor func transientStateBecomesInterruptedAndPartialIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let bookID = UUID()
        let chapterID = UUID()
        try await dependencies.repository.importBook(ImportedBookDraft(
            id: bookID,
            title: "恢复测试",
            author: "AudiobookMaker",
            languageCode: "zh-CN",
            sourceRelativePath: "Books/\(bookID)/source.epub",
            sourceSHA256: String(repeating: "b", count: 64),
            coverRelativePath: nil,
            totalCharacters: 4,
            chapters: [ImportedChapterDraft(
                id: chapterID,
                index: 0,
                title: "章节",
                sourceHref: "chapter.xhtml",
                textRelativePath: "Books/\(bookID)/text/0000.txt",
                textSHA256: String(repeating: "c", count: 64),
                characterCount: 4
            )]
        ))
        _ = try await dependencies.repository.beginConversion(
            bookID: bookID,
            modelID: "com.audiobookmaker.mock"
        )
        try await dependencies.repository.markChapter(id: chapterID, status: .synthesizing)
        let partial = dependencies.directories.bookDirectory(id: bookID)
            .appending(path: "audio/0001.partial.m4b")
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(to: partial)

        let report = try await dependencies.recovery.recover()
        let book = try #require(try await dependencies.repository.books().first)
        #expect(report.interruptedBookCount == 1)
        #expect(report.removedPartialCount == 1)
        #expect(book.status == .interrupted)
        #expect(book.chapters[0].status == .paused)
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test @MainActor func validFinalArtifactBeforeDatabaseCommitIsRecovered() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let bookID = UUID()
        let chapterID = UUID()
        let text = "数据库提交前已经完成封装的正文。"
        let textData = Data(text.utf8)
        let textURL = dependencies.directories.bookDirectory(id: bookID)
            .appending(path: "text/0000.txt")
        try FileManager.default.createDirectory(
            at: textURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try textData.write(to: textURL)
        try await dependencies.repository.importBook(ImportedBookDraft(
            id: bookID,
            title: "提交窗口恢复",
            author: "AudiobookMaker",
            languageCode: "zh-CN",
            sourceRelativePath: "Books/\(bookID)/source.epub",
            sourceSHA256: String(repeating: "9", count: 64),
            coverRelativePath: nil,
            totalCharacters: Int64(text.count),
            chapters: [ImportedChapterDraft(
                id: chapterID, index: 0, title: "第一章", sourceHref: "chapter.xhtml",
                textRelativePath: try dependencies.directories.relativePath(for: textURL),
                textSHA256: SHA256Hasher.hash(textData), characterCount: text.count
            )]
        ))
        _ = try await dependencies.repository.beginConversion(
            bookID: bookID,
            modelID: "com.audiobookmaker.mock"
        )
        try await dependencies.repository.markChapter(id: chapterID, status: .packaging)
        let audioDirectory = dependencies.directories.bookDirectory(id: bookID)
            .appending(path: "audio", directoryHint: .isDirectory)
        let segment = audioDirectory.appending(path: "segment.caf")
        _ = try await MockTTSRuntimeClient().synthesize(SynthesisRequest(
            requestID: UUID(), text: text, languageCode: "zh-CN", outputURL: segment
        ))
        let finalURL = audioDirectory.appending(path: "0001-第一章.m4b")
        _ = try await M4BPackager.package(M4BPackageRequest(
            audioSegments: [segment], outputURL: finalURL,
            title: "提交窗口恢复", author: "AudiobookMaker",
            chapterTitle: "第一章", chapterIndex: 0, languageCode: "zh-CN",
            fullText: text, coverData: nil
        ))

        let report = try await dependencies.recovery.recover()
        let book = try #require(try await dependencies.repository.books().first)
        #expect(report.interruptedBookCount == 1)
        #expect(report.invalidArtifactCount == 0)
        #expect(book.status == .interrupted)
        #expect(book.chapters[0].status == .completed)
        #expect((book.chapters[0].durationSeconds ?? 0) > 0)
        #expect(FileManager.default.fileExists(atPath: finalURL.path))

        let resumeRuntime = MockTTSRuntimeClient()
        let coordinator = ConversionCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories,
            runtime: resumeRuntime
        )
        await coordinator.start(bookID: bookID)
        while await coordinator.isActive(bookID: bookID) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await dependencies.repository.books().first?.status == .completed)
        #expect(await resumeRuntime.synthesizedTexts().isEmpty)
    }
}
