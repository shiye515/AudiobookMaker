import Foundation
import Testing
@testable import AudiobookMaker

struct DependencyInjectionTests {
    @Test @MainActor
    func modelPresentationUsesInjectedIncompatiblePlatformAndKeepsOtherModelsVisible() throws {
        let unsupported = SpeechSwiftPlatformSupport(snapshotProvider: {
            .init(
                architecture: .x86_64,
                isRosettaTranslated: false,
                operatingSystemVersion: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                hasMetalDevice: true
            )
        })
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let store = LibraryPresentationStore(
            dependencies: dependencies,
            speechSwiftPlatformSupport: unsupported
        )

        let system = try #require(store.models.first { $0.id == TTSModelCatalog.systemID })
        let kokoro = try #require(store.models.first { $0.id == TTSModelCatalog.kokoroID })
        let qwen = try #require(store.models.first { $0.id == TTSModelCatalog.qwen3TTSID })
        #expect(system.isAvailable)
        #expect(kokoro.installation == .notInstalled)
        #expect(!store.isPlatformCompatible(modelID: qwen.id))
        #expect(qwen.installation == .unavailable)
        #expect(qwen.runtimeStatus == "需要原生 Apple Silicon")
    }

    @Test @MainActor
    func makingAReadyModelDefaultLeavesExactlyOneDefault() throws {
        let store = LibraryPresentationStore()
        let qwenIndex = try #require(store.models.firstIndex { $0.id == TTSModelCatalog.qwen3TTSID })
        store.models[qwenIndex] = TTSModelSnapshot(
            id: TTSModelCatalog.qwen3TTSID,
            name: TTSModelCatalog.qwen3TTS.displayName,
            framework: "speech-swift / MLX",
            runtimeStatus: "已就绪",
            languages: "中文、英文",
            isAvailable: true,
            isDefault: false,
            version: TTSModelCatalog.qwen3TTS.version,
            installation: .installed,
            downloadProgress: 1,
            failureMessage: nil,
            downloadSize: TTSModelCatalog.qwen3TTS.downloadBytes,
            selectedVoiceID: "vivian",
            voices: TTSModelCatalog.qwen3TTSVoices
        )
        store.selectedModelID = TTSModelCatalog.qwen3TTSID

        store.makeSelectedModelDefault()

        #expect(store.models.count { $0.isDefault } == 1)
        #expect(store.models[qwenIndex].isDefault)
    }

    @Test @MainActor
    func bookModelLabelUsesDefaultUntilAConversionLocksItsModel() throws {
        let store = LibraryPresentationStore()
        for index in store.models.indices {
            store.models[index].isDefault = store.models[index].id == TTSModelCatalog.kokoroID
        }
        var book = try #require(store.books.first)

        #expect(store.modelLabel(for: book).contains("Kokoro"))
        book.modelID = TTSModelCatalog.systemID
        #expect(store.modelLabel(for: book).contains("Apple 系统语音"))
    }

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
        #expect(dependencies.runtime is RoutingTTSRuntimeClient)
    }

    @Test @MainActor
    func completedVoicePreviewResetsStateAndRemovesTemporaryAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = MockTTSRuntimeClient()
        let dependencies = try DependencyContainer(
            inMemory: true,
            rootOverride: root,
            runtime: runtime
        )
        let store = LibraryPresentationStore(dependencies: dependencies)
        store.models = [TTSModelSnapshot(
            id: TTSModelCatalog.kokoroID,
            name: "Kokoro 多语言 Int8",
            framework: "sherpa-onnx",
            runtimeStatus: "已就绪",
            languages: "中文、英文",
            isAvailable: true,
            isDefault: true,
            version: TTSModelCatalog.kokoro.version,
            installation: .installed,
            downloadProgress: 1,
            failureMessage: nil,
            downloadSize: TTSModelCatalog.kokoro.downloadBytes,
            selectedVoiceID: TTSModelCatalog.kokoroDefaultVoiceID,
            voices: TTSModelCatalog.kokoroVoices
        )]
        store.selectedModelID = TTSModelCatalog.kokoroID

        store.toggleVoicePreview()
        #expect(store.isPreviewing)
        try await Task.sleep(for: .seconds(1.5))
        #expect(!store.isPreviewing)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: dependencies.directories.cacheRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("VoicePreview-") }
        #expect(leftovers.isEmpty)
        let synthesizedTexts = await runtime.synthesizedTexts()
        #expect(synthesizedTexts == ["你好，这是本地音色试听。"])
        #expect(synthesizedTexts.first?.contains("〇") == false)
        #expect(synthesizedTexts.first?.contains(where: { $0.isASCII }) == false)
    }

    @Test @MainActor
    func conversionProgressRefreshDoesNotStealBookSelection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = MockTTSRuntimeClient.Configuration()
        configuration.delay = .seconds(2)
        let dependencies = try DependencyContainer(
            inMemory: true,
            rootOverride: root,
            runtime: MockTTSRuntimeClient(configuration: configuration)
        )
        let convertingBookID = try await insertBook(
            title: "正在转换的书",
            text: "这段正文会保持转换任务运行。",
            hashCharacter: "a",
            dependencies: dependencies
        )
        let otherBookID = try await insertBook(
            title: "仍然可以选择的书",
            text: "另一本书的正文。",
            hashCharacter: "b",
            dependencies: dependencies
        )
        let store = LibraryPresentationStore(dependencies: dependencies)
        await store.load()
        store.selectedBookID = convertingBookID

        store.performPrimaryBookAction()
        try await Task.sleep(for: .milliseconds(100))
        store.selectedBookID = otherBookID
        try await Task.sleep(for: .milliseconds(500))

        #expect(store.selectedBookID == otherBookID)
        await dependencies.converter.pause(bookID: convertingBookID)
        while await dependencies.converter.isActive(bookID: convertingBookID) {
            try await Task.sleep(for: .milliseconds(20))
        }
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

    @MainActor
    private func insertBook(
        title: String,
        text: String,
        hashCharacter: Character,
        dependencies: DependencyContainer
    ) async throws -> UUID {
        let id = UUID()
        let textDirectory = dependencies.directories.bookDirectory(id: id)
            .appending(path: "text", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: textDirectory, withIntermediateDirectories: true)
        let textURL = textDirectory.appending(path: "0000.txt")
        let data = Data(text.utf8)
        try data.write(to: textURL)
        let chapter = ImportedChapterDraft(
            id: UUID(),
            index: 0,
            title: "第一章",
            sourceHref: "chapter.xhtml",
            textRelativePath: try dependencies.directories.relativePath(for: textURL),
            textSHA256: SHA256Hasher.hash(data),
            characterCount: text.count
        )
        try await dependencies.repository.importBook(ImportedBookDraft(
            id: id,
            title: title,
            author: "测试作者",
            languageCode: "zh-CN",
            sourceRelativePath: "Books/\(id)/source.epub",
            sourceSHA256: String(repeating: hashCharacter, count: 64),
            coverRelativePath: nil,
            totalCharacters: Int64(text.count),
            chapters: [chapter]
        ))
        return id
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
            publicationDate: nil,
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
