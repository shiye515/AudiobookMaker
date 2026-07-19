import Foundation
import SwiftData
import Testing
@testable import AudiobookMaker

@Suite("Import transaction and SwiftData repository")
struct ImportPersistenceTests {
    @Test("User EPUB is copied, parsed and committed without modifying the original")
    @MainActor
    func importsUserEPUBWhenConfigured() async throws {
        guard let path = ProcessInfo.processInfo.environment["AUDIOBOOKMAKER_REAL_EPUB"] else {
            return
        }
        let originalURL = URL(filePath: path)
        let originalData = try Data(contentsOf: originalURL)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)

        let draft = try await dependencies.importer.prepareImport(from: originalURL)
        try await dependencies.repository.importBook(draft)
        let books = try await dependencies.repository.books()

        #expect(books.count == 1)
        #expect(books[0].title == "论中国与世界")
        #expect(books[0].author == "李光耀")
        #expect(books[0].chapters.count == 14)
        #expect(draft.sourceSHA256 == "409fe0568d197bd01e2e7984a173b62f0ec2d12b5cb281f7ee77099b648c697f")
        #expect(try Data(contentsOf: originalURL) == originalData)

        let internalSource = try dependencies.directories.resolve(relativePath: draft.sourceRelativePath)
        #expect(FileManager.default.fileExists(atPath: internalSource.path))
        let firstText = try dependencies.directories.resolve(relativePath: draft.chapters[0].textRelativePath)
        #expect((try String(contentsOf: firstText, encoding: .utf8)).contains("重要人物如何评价"))
    }

    @Test("ModelActor serializes concurrent imports and returns Sendable snapshots")
    @MainActor
    func concurrentRepositoryWrites() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let repository = dependencies.repository

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let id = UUID()
                    let draft = ImportedBookDraft(
                        id: id,
                        title: "Book \(index)",
                        author: "Author",
                        languageCode: "zh-CN",
                        sourceRelativePath: "Books/\(id)/source.epub",
                        sourceSHA256: String(format: "%064x", index + 1),
                        coverRelativePath: nil,
                        totalCharacters: 10,
                        chapters: [
                            ImportedChapterDraft(
                                id: UUID(),
                                index: 0,
                                title: "Chapter",
                                sourceHref: "chapter.xhtml",
                                textRelativePath: "Books/\(id)/text/0000.txt",
                                textSHA256: String(format: "%064x", index + 101),
                                characterCount: 10
                            )
                        ]
                    )
                    try await repository.importBook(draft)
                }
            }
            try await group.waitForAll()
        }

        let snapshots = try await repository.books()
        #expect(snapshots.count == 20)
        #expect(snapshots.allSatisfy { $0.chapters.count == 1 })
    }

    @Test("Duplicate hash requires an explicit copy decision")
    @MainActor
    func duplicateImportCanLocateOrCreateCopy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let hash = String(repeating: "d", count: 64)
        let first = duplicateDraft(id: UUID(), hash: hash)
        let second = duplicateDraft(id: UUID(), hash: hash)
        try await dependencies.repository.importBook(first)
        await #expect(throws: RepositoryError.duplicateBook(existingID: first.id)) {
            try await dependencies.repository.importBook(second)
        }
        try await dependencies.repository.importBook(second, allowDuplicate: true)
        #expect(try await dependencies.repository.books().count == 2)
    }

    @Test("Deleted managed data can be restored in the current session")
    @MainActor
    func deletionUndoReimportsTrashCopyAndProtectsOriginal() async throws {
        guard let path = ProcessInfo.processInfo.environment["AUDIOBOOKMAKER_REAL_EPUB"] else { return }
        let originalURL = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: originalURL.path) else { return }
        let originalHash = try SHA256Hasher.hashFile(at: originalURL)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let draft = try await dependencies.importer.prepareImport(from: originalURL)
        try await dependencies.repository.importBook(draft)
        let token = try dependencies.trash.moveBookToTrash(
            bookID: draft.id,
            title: draft.title
        )
        try await dependencies.repository.deleteBook(id: draft.id)

        let restored = try await dependencies.importer.prepareImport(
            from: dependencies.trash.sourceURL(for: token)
        )
        try await dependencies.repository.importBook(restored, allowDuplicate: true)
        dependencies.trash.purge(token)

        let books = try await dependencies.repository.books()
        #expect(books.count == 1)
        #expect(books[0].title == "论中国与世界")
        #expect(try SHA256Hasher.hashFile(at: originalURL) == originalHash)
    }

    @Test("Failed staged import is cleaned and never commits a book directory")
    @MainActor
    func failedImportCleansAtomicStaging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let invalidEPUB = root.appending(path: "invalid.epub")
        try Data("not a zip archive".utf8).write(to: invalidEPUB)

        await #expect(throws: EPUBParserError.self) {
            _ = try await dependencies.importer.prepareImport(from: invalidEPUB)
        }
        let stagingItems = try FileManager.default.contentsOfDirectory(
            at: dependencies.directories.staging,
            includingPropertiesForKeys: nil
        )
        let bookItems = try FileManager.default.contentsOfDirectory(
            at: dependencies.directories.books,
            includingPropertiesForKeys: nil
        )
        #expect(stagingItems.isEmpty)
        #expect(bookItems.isEmpty)
        #expect(try await dependencies.repository.books().isEmpty)
    }

    @Test("Deleting a book cascades to chapters and conversion jobs")
    @MainActor
    func deletionCascadesRepositoryRelationships() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let draft = duplicateDraft(id: UUID(), hash: String(repeating: "c", count: 64))
        let chapter = ImportedChapterDraft(
            id: UUID(), index: 0, title: "章节", sourceHref: "chapter.xhtml",
            textRelativePath: "Books/fixture/text/0000.txt",
            textSHA256: String(repeating: "f", count: 64), characterCount: 10
        )
        let populated = ImportedBookDraft(
            id: draft.id, title: draft.title, author: draft.author,
            languageCode: draft.languageCode, sourceRelativePath: draft.sourceRelativePath,
            sourceSHA256: draft.sourceSHA256, coverRelativePath: nil,
            totalCharacters: 10, chapters: [chapter]
        )
        try await dependencies.repository.importBook(populated)
        _ = try await dependencies.repository.enqueueConversion(
            bookID: populated.id,
            modelID: LibraryRepository.systemVoiceID
        )
        try await dependencies.repository.deleteBook(id: populated.id)

        let context = ModelContext(dependencies.modelContainer)
        #expect(try context.fetchCount(FetchDescriptor<BookRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChapterRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ConversionJobRecord>()) == 0)
    }

    private func duplicateDraft(id: UUID, hash: String) -> ImportedBookDraft {
        ImportedBookDraft(
            id: id,
            title: "相同内容",
            author: "作者",
            languageCode: "zh-CN",
            sourceRelativePath: "Books/\(id)/source.epub",
            sourceSHA256: hash,
            coverRelativePath: nil,
            totalCharacters: 0,
            chapters: []
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
