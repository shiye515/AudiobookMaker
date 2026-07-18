import Foundation
import Testing
@testable import AudiobookMaker

struct DependencyInjectionTests {
    @Test @MainActor
    func containerExposesEveryServiceThroughItsProtocolBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)

        #expect(dependencies.persistenceService is LibraryRepository)
        #expect(dependencies.fileStorageService is AppDirectories)
        #expect(dependencies.epubService is EPUBParser)
        #expect(dependencies.mediaService is SystemM4BPackaging)
        #expect(dependencies.archiveService is ZipContainerWriter)
        #expect(dependencies.loggingService is PrivacyPreservingApplicationLogger)
        #expect(dependencies.runtime is SystemSpeechRuntimeClient)
    }

    @Test
    func importCoordinatorUsesInjectedParserAndLogger() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(
            root: root.appending(path: "App", directoryHint: .isDirectory),
            cacheRoot: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
        try directories.createIfNeeded()
        let external = root.appending(path: "injected.epub")
        try Data("fixture".utf8).write(to: external)
        let parser = InjectedEPUBParser()
        let logger = RecordingApplicationLogger()
        let importer = ImportCoordinator(
            directories: directories,
            parser: parser,
            diskSpaceChecker: PassingDiskSpaceChecker(),
            logger: logger
        )

        let draft = try await importer.prepareImport(from: external)

        #expect(draft.title == "协议注入书籍")
        #expect(draft.chapters.map(\.title) == ["注入章节"])
        #expect(parser.invocationCount == 1)
        #expect(logger.eventNames == ["import.started", "import.completed"])
    }
}

private final class InjectedEPUBParser: EPUBParsing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var invocationCount: Int { lock.withLock { count } }

    func parse(url: URL) throws -> ParsedEPUB {
        lock.withLock { count += 1 }
        return ParsedEPUB(
            title: "协议注入书籍",
            author: "测试作者",
            language: "zh-CN",
            chapters: [ParsedEPUBChapter(
                index: 0,
                title: "注入章节",
                sourceHref: "injected.xhtml",
                plainText: "由替换解析器提供的正文。"
            )],
            coverData: nil,
            coverExtension: nil
        )
    }
}

private struct PassingDiskSpaceChecker: DiskSpaceChecking {
    func requireAvailable(at url: URL, requiredBytes: Int64) throws {}
}

private final class RecordingApplicationLogger: ApplicationLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    var eventNames: [String] { lock.withLock { names } }

    func event(_ name: String, id: UUID?, count: Int?, errorCode: String?) {
        lock.withLock { names.append(name) }
    }
}
