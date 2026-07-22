import AppKit
import AVFoundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum LibrarySection: String, CaseIterable, Identifiable {
    case books
    case models

    var id: Self { self }
    var title: String {
        switch self {
        case .books: String(localized: "书籍")
        case .models: String(localized: "模型")
        }
    }
}

enum BookFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case completed
    case attention

    var id: Self { self }
    var title: String {
        switch self {
        case .all: String(localized: "全部")
        case .active: String(localized: "转换中")
        case .completed: String(localized: "已完成")
        case .attention: String(localized: "需要处理")
        }
    }
}

enum BookPresentationStatus: String, Equatable {
    case ready
    case queued
    case converting
    case paused
    case completed
    case failed

    var label: String {
        switch self {
        case .ready: String(localized: "等待开始")
        case .queued: String(localized: "已加入队列")
        case .converting: String(localized: "正在转换")
        case .paused: String(localized: "已暂停")
        case .completed: String(localized: "已完成")
        case .failed: String(localized: "转换失败")
        }
    }

    var detailLabel: String {
        switch self {
        case .converting: String(localized: "正在转换当前章节")
        default: label
        }
    }

    var primaryActionTitle: String {
        switch self {
        case .ready, .failed: String(localized: "开始转换")
        case .queued: String(localized: "从队列移除")
        case .converting: String(localized: "暂停")
        case .paused: String(localized: "继续")
        case .completed: String(localized: "导出有声书…")
        }
    }

    var symbol: String {
        switch self {
        case .ready: "clock"
        case .queued: "text.line.first.and.arrowtriangle.forward"
        case .converting: "waveform"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ready: .secondary
        case .queued: .orange
        case .converting: .accentColor
        case .paused: .orange
        case .completed: .green
        case .failed: .red
        }
    }
}

struct ChapterSnapshot: Identifiable {
    let id: UUID
    let index: Int
    let title: String
    let duration: String?
    var status: BookPresentationStatus
    var progress: Double? = nil
}

struct BookSnapshot: Identifiable {
    let id: UUID
    var title: String
    var author: String
    var chapterCount: Int
    var completedChapterCount: Int
    var progress: Double
    var status: BookPresentationStatus
    var estimatedHours: Int
    var chapters: [ChapterSnapshot]
    var coverURL: URL?
    var coverColor: Color
    var coverSymbol: String
    var modelID: String? = nil

    var shortTitle: String {
        title.count > 7 ? String(title.prefix(7)) : title
    }
}

struct TTSModelSnapshot: Identifiable {
    let id: String
    let name: String
    let framework: String
    let runtimeStatus: String
    let languages: String
    let isAvailable: Bool
    var isDefault: Bool
    let version: String
    let installation: ModelInstallationState
    let downloadProgress: Double
    let failureMessage: String?
    let downloadSize: Int64?
    var selectedVoiceID: String?
    let voices: [TTSVoiceDescriptor]
}

struct DuplicateImportPrompt: Identifiable {
    var id: UUID { draft.id }
    let draft: ImportedBookDraft
    let existingBookID: UUID
    let sourceName: String
}

@MainActor
@Observable
final class LibraryPresentationStore {
    enum Mode {
        case populated
        case empty
        case paused
        case completed
        case failed
    }

    var section: LibrarySection = .books
    var columnVisibility: NavigationSplitViewVisibility = .all
    var books: [BookSnapshot]
    var models: [TTSModelSnapshot]
    var selectedBookID: UUID?
    var selectedModelID: String?
    var searchText = ""
    var filter: BookFilter = .all
    var isImporting = false
    var importErrorMessage: String?
    var duplicateImports: [DuplicateImportPrompt] = []
    var recentDeletion: DeletedBookToken?
    var isExporting = false
    var exportProgress = 0.0
    var exportCurrentFile: String?
    var lastExportedFileName: String?
    var isPreviewing = false

    private let repository: LibraryRepository?
    private let importer: ImportCoordinator?
    private let directories: AppDirectories?
    private let converter: ConversionCoordinator?
    private let exporter: ExportCoordinator?
    private let recovery: RecoveryCoordinator?
    private let trash: TrashCoordinator?
    private let modelManager: ModelPackageManager?
    private let runtime: (any TTSRuntimeClient)?
    private let speechSwiftPlatformSupport: SpeechSwiftPlatformSupport
    private var hasLoaded = false
    private var deletionCleanupTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var exportCompletionDismissTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var previewPlayer: AVAudioPlayer?
    private var previewURL: URL?

    init(
        mode: Mode = .populated,
        speechSwiftPlatformSupport: SpeechSwiftPlatformSupport = SpeechSwiftPlatformSupport()
    ) {
        repository = nil
        importer = nil
        directories = nil
        converter = nil
        exporter = nil
        recovery = nil
        trash = nil
        modelManager = nil
        runtime = nil
        self.speechSwiftPlatformSupport = speechSwiftPlatformSupport
        var initialBooks = mode == .empty ? [] : Self.previewBooks
        if !initialBooks.isEmpty {
            switch mode {
            case .paused:
                initialBooks[0].status = .paused
            case .completed:
                initialBooks[0].status = .completed
                initialBooks[0].progress = 1
                initialBooks[0].completedChapterCount = initialBooks[0].chapterCount
            case .failed:
                initialBooks[0].status = .failed
                if initialBooks[0].chapters.count > 10 {
                    initialBooks[0].chapters[10].status = .failed
                }
            case .populated, .empty:
                break
            }
        }
        books = initialBooks
        models = Self.previewModels
        selectedBookID = books.first?.id
        selectedModelID = models.first?.id
    }

    init(
        dependencies: DependencyContainer,
        speechSwiftPlatformSupport: SpeechSwiftPlatformSupport = SpeechSwiftPlatformSupport()
    ) {
        repository = dependencies.repository
        importer = dependencies.importer
        directories = dependencies.directories
        converter = dependencies.converter
        exporter = dependencies.exporter
        recovery = dependencies.recovery
        trash = dependencies.trash
        modelManager = dependencies.modelManager
        runtime = dependencies.runtime
        self.speechSwiftPlatformSupport = speechSwiftPlatformSupport
        books = []
        models = Self.liveModels(platformSupport: speechSwiftPlatformSupport)
        selectedModelID = models.first?.id
    }

    func isPlatformCompatible(modelID: String) -> Bool {
        guard TTSModelCatalog.manifestsByID[modelID]?.platformRequirement == .nativeAppleSilicon else {
            return true
        }
        return speechSwiftPlatformSupport.status().isSupported
    }

    var selectedBook: BookSnapshot? {
        guard let selectedBookID else { return nil }
        return books.first { $0.id == selectedBookID }
    }

    var selectedModel: TTSModelSnapshot? {
        guard let selectedModelID else { return nil }
        return models.first { $0.id == selectedModelID }
    }

    var filteredBooks: [BookSnapshot] {
        books.filter { book in
            let matchesSearch = searchText.isEmpty
                || book.title.localizedStandardContains(searchText)
                || book.author.localizedStandardContains(searchText)
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .active: book.status == .converting || book.status == .queued
            case .completed: book.status == .completed
            case .attention: book.status == .failed || book.status == .paused
            }
            return matchesSearch && matchesFilter
        }
    }

    var queuedCount: Int { books.count { $0.status == .queued } }
    var activeCount: Int { books.count { $0.status == .converting } }
    var completedCount: Int { books.count { $0.status == .completed } }

    func modelLabel(for book: BookSnapshot) -> String {
        let modelID = book.modelID ?? models.first(where: \.isDefault)?.id
        let name = models.first(where: { $0.id == modelID })?.name
            ?? modelID.flatMap { TTSModelCatalog.manifestsByID[$0]?.displayName }
            ?? String(localized: "Apple 系统语音")
        return "\(name) · \(String(localized: "本机运行"))"
    }

    func performPrimaryBookAction() {
        guard let index = books.firstIndex(where: { $0.id == selectedBookID }) else { return }
        switch books[index].status {
        case .ready, .failed:
            books[index].status = .converting
            guard let converter else { return }
            let bookID = books[index].id
            Task {
                await converter.start(bookID: bookID)
                repeat {
                    try? await Task.sleep(for: .milliseconds(350))
                    await reloadBooks(selecting: nil)
                } while await converter.isActive(bookID: bookID)
                await reloadBooks(selecting: nil)
            }
        case .paused:
            books[index].status = .converting
            guard let converter else { return }
            let bookID = books[index].id
            Task {
                await converter.resume(bookID: bookID)
                repeat {
                    try? await Task.sleep(for: .milliseconds(350))
                    await reloadBooks(selecting: nil)
                } while await converter.isActive(bookID: bookID)
                await reloadBooks(selecting: nil)
            }
        case .queued:
            books[index].status = .ready
            if let converter {
                let bookID = books[index].id
                Task {
                    await converter.cancelQueued(bookID: bookID)
                    await reloadBooks(selecting: nil)
                }
            }
        case .converting:
            books[index].status = .paused
            if let converter {
                let bookID = books[index].id
                Task {
                    await converter.pause(bookID: bookID)
                    await reloadBooks(selecting: nil)
                }
            }
        case .completed:
            exportBook(books[index])
        }
    }

    func pauseSelectedBook() {
        guard let index = books.firstIndex(where: { $0.id == selectedBookID }),
              books[index].status == .converting else { return }
        books[index].status = .paused
        if let converter {
            let bookID = books[index].id
            Task {
                await converter.pause(bookID: bookID)
                await reloadBooks(selecting: nil)
            }
        }
    }

    func deleteSelectedBook() {
        guard let id = selectedBookID else { return }
        guard let repository, let trash else {
            books.removeAll { $0.id == id }
            selectedBookID = books.first?.id
            return
        }
        let title = books.first(where: { $0.id == id })?.title ?? "书籍"
        Task {
            var token: DeletedBookToken?
            do {
                token = try trash.moveBookToTrash(bookID: id, title: title)
                try await repository.deleteBook(id: id)
                if let previous = recentDeletion { trash.purge(previous) }
                recentDeletion = token
                await reloadBooks(selecting: nil)
                scheduleDeletionCleanup()
            } catch {
                if let token { try? trash.restoreDirectory(token) }
                importErrorMessage = error.localizedDescription
            }
        }
    }

    func undoRecentDeletion() {
        guard let token = recentDeletion,
              let trash,
              let importer,
              let repository else { return }
        deletionCleanupTask?.cancel()
        recentDeletion = nil
        Task {
            do {
                let draft = try await importer.prepareImport(from: trash.sourceURL(for: token))
                try await repository.importBook(draft, allowDuplicate: true)
                trash.purge(token)
                await reloadBooks(selecting: draft.id)
            } catch {
                recentDeletion = token
                importErrorMessage = "无法撤销删除：\(error.localizedDescription)"
            }
        }
    }

    private func scheduleDeletionCleanup() {
        deletionCleanupTask?.cancel()
        deletionCleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, let token = self.recentDeletion else { return }
            self.trash?.purge(token)
            self.recentDeletion = nil
        }
    }

    func makeSelectedModelDefault() {
        guard let selectedModelID else { return }
        for index in models.indices {
            models[index].isDefault = models[index].id == selectedModelID
        }
        guard let repository else { return }
        Task {
            do {
                try await repository.setDefaultModel(id: selectedModelID)
                await reloadModels()
            } catch {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    func installSelectedModel() {
        guard let selectedModelID,
              let manifest = TTSModelCatalog.manifestsByID[selectedModelID],
              let modelManager else { return }
        if manifest.platformRequirement == .nativeAppleSilicon,
           !speechSwiftPlatformSupport.status().isSupported {
            importErrorMessage = ModelPackageError.incompatiblePlatform.localizedDescription
            return
        }
        modelTask?.cancel()
        modelTask = Task {
            let refresh = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    await self?.reloadModels()
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { refresh.cancel() }
            do { try await modelManager.install(manifest) }
            catch ModelPackageError.cancelled { }
            catch { importErrorMessage = error.localizedDescription }
            await reloadModels()
            modelTask = nil
        }
    }

    func cancelModelInstall() {
        guard let modelManager, let selectedModelID else { return }
        Task { await modelManager.cancel(modelID: selectedModelID) }
    }

    func selectVoice(_ voiceID: String) {
        guard let selectedModelID, let repository else { return }
        Task {
            do {
                try await repository.setVoice(modelID: selectedModelID, voiceID: voiceID)
                importErrorMessage = nil
                await reloadModels()
            } catch { importErrorMessage = error.localizedDescription }
        }
    }

    func toggleVoicePreview() {
        if isPreviewing { stopVoicePreview(); return }
        guard activeCount == 0, let model = selectedModel, model.isAvailable,
              let runtime, let directories else { return }
        stopVoicePreview()
        let voice = model.voices.first(where: { $0.id == model.selectedVoiceID })
        // Keep preview text in the selected voice's language and within Kokoro's
        // known lexicon. The product name produces the unsupported English `ɚ`
        // phoneme, while `〇` is converted to Kokoro's unknown-token marker.
        let sample = voice?.languageCode == "en-US"
            ? "Hello. This is a local voice sample."
            : "你好，这是本地音色试听。"
        let url = directories.cacheRoot.appending(path: "VoicePreview-\(UUID().uuidString).caf")
        isPreviewing = true
        previewURL = url
        Task {
            do {
                _ = try await runtime.synthesize(SynthesisRequest(
                    text: sample,
                    languageCode: voice?.languageCode,
                    voiceIdentifier: voice?.id,
                    outputURL: url,
                    modelID: model.id,
                    modelVersion: model.version,
                    purpose: .preview
                ))
                guard isPreviewing else { try? FileManager.default.removeItem(at: url); return }
                let player = try AVAudioPlayer(contentsOf: url)
                previewPlayer = player
                guard player.prepareToPlay(), player.play() else { throw RuntimeError.invalidAudio }
                let playbackMilliseconds = Int64((player.duration + 0.25) * 1_000)
                try await Task.sleep(for: .milliseconds(playbackMilliseconds))
                guard previewURL == url, previewPlayer === player else { return }
                stopVoicePreview()
            } catch is CancellationError {
                guard previewURL == url else { return }
                stopVoicePreview()
            } catch { importErrorMessage = error.localizedDescription; stopVoicePreview() }
        }
    }

    func stopVoicePreview() {
        previewPlayer?.stop(); previewPlayer = nil; isPreviewing = false
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
        previewURL = nil
    }

    func openSelectedModelLicense() {
        guard let directories, let model = selectedModel,
              let manifest = TTSModelCatalog.manifestsByID[model.id] else { return }
        if model.id == TTSModelCatalog.kokoroID,
           let root = try? directories.modelVersionDirectory(id: model.id, version: model.version) {
            let license = root.appending(path: "LICENSE")
            if FileManager.default.fileExists(atPath: license.path) {
                NSWorkspace.shared.open(license)
                return
            }
        }
        NSWorkspace.shared.open(manifest.sourceURL)
    }

    func exportSelectedBook() {
        guard let book = selectedBook, book.status == .completed else { return }
        exportBook(book)
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    func revealSelectedBookInFinder() {
        guard let id = selectedBookID, let directories else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directories.bookDirectory(id: id)])
    }

    private func exportBook(_ book: BookSnapshot) {
        guard exporter != nil else { return }
        if ProcessInfo.processInfo.arguments.contains("--uitest-e2e"), let directories {
            beginExport(
                book: book,
                to: directories.root.appending(path: "端到端测试有声书.m4b"),
                revealInFinder: false
            )
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出有声书"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "\(FileNameSanitizer.visibleName(book.title)).m4b"
        panel.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .mpeg4Audio]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.beginExport(book: book, to: destination, revealInFinder: true)
        }
    }

    private func beginExport(book: BookSnapshot, to destination: URL, revealInFinder: Bool) {
        guard let exporter else { return }
        isExporting = true
        exportProgress = 0
        exportCurrentFile = nil
        exportCompletionDismissTask?.cancel()
        exportCompletionDismissTask = nil
        lastExportedFileName = nil
        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let exported = try await exporter.export(
                    bookID: book.id,
                    to: destination
                ) { value in
                    Task { @MainActor [weak self] in
                        self?.exportProgress = value.fractionCompleted
                        self?.exportCurrentFile = value.currentFile
                    }
                }
                self.showExportCompletion(fileName: exported.lastPathComponent)
                if revealInFinder {
                    NSWorkspace.shared.activateFileViewerSelecting([exported])
                }
            } catch is CancellationError {
                // Cancellation is user initiated; the coordinator removes its partial file.
            } catch {
                self.importErrorMessage = error.localizedDescription
            }
            self.isExporting = false
            self.exportProgress = 0
            self.exportCurrentFile = nil
            self.exportTask = nil
        }
    }

    private func showExportCompletion(fileName: String) {
        exportCompletionDismissTask?.cancel()
        lastExportedFileName = fileName
        exportCompletionDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.lastExportedFileName = nil
            self?.exportCompletionDismissTask = nil
        }
    }

    func load() async {
        guard !hasLoaded, let repository else { return }
        hasLoaded = true
        do {
            try await repository.seedDefaults()
            if let modelManager {
                try await modelManager.recoverStaging()
                let persistedModels = try await repository.models()
                for model in persistedModels where model.installation == .installed {
                    guard let manifest = TTSModelCatalog.manifestsByID[model.id] else { continue }
                    if manifest.platformRequirement == .nativeAppleSilicon,
                       !speechSwiftPlatformSupport.status().isSupported {
                        continue
                    }
                    do {
                        _ = try await modelManager.validate(manifest)
                    } catch {
                        try await repository.updateModelInstallState(
                            id: model.id,
                            event: .init(
                                modelID: model.id,
                                state: .corrupted,
                                progress: 0,
                                message: error.localizedDescription
                            )
                        )
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--uitest-kokoro-ready") {
                try await repository.updateModelInstallState(
                    id: TTSModelCatalog.kokoroID,
                    event: .init(state: .installed, progress: 1, message: nil)
                )
            } else if ProcessInfo.processInfo.arguments.contains("--uitest-speech-swift-ready") {
                for modelID in [TTSModelCatalog.cosyVoiceID, TTSModelCatalog.qwen3TTSID] {
                    try await repository.updateModelInstallState(
                        id: modelID,
                        event: .init(modelID: modelID, state: .installed, progress: 1, message: nil)
                    )
                }
            } else if ProcessInfo.processInfo.arguments.contains("--uitest-model-not-installed") {
                try await repository.updateModelInstallState(
                    id: TTSModelCatalog.kokoroID,
                    event: .init(state: .notInstalled, progress: 0, message: nil)
                )
            }
            _ = try await recovery?.recover()
            await reloadModels()
            if ProcessInfo.processInfo.arguments.contains("--uitest-e2e"),
               let importer,
               let directories {
                let fixture = directories.root.appending(path: "端到端测试.epub")
                try Self.writeEndToEndFixture(to: fixture)
                let draft = try await importer.prepareImport(from: fixture)
                try await repository.importBook(draft)
                await reloadBooks(selecting: draft.id)
                if ProcessInfo.processInfo.arguments.contains("--uitest-profile-e2e"),
                   let converter {
                    await converter.start(bookID: draft.id)
                    while await converter.isActive(bookID: draft.id) {
                        try await Task.sleep(for: .milliseconds(100))
                        await reloadBooks(selecting: draft.id)
                    }
                    await reloadBooks(selecting: draft.id)
                    if let completed = selectedBook, completed.status == .completed {
                        beginExport(
                            book: completed,
                            to: directories.root.appending(path: "性能审计有声书.m4b"),
                            revealInFinder: false
                        )
                    }
                }
            } else {
                await reloadBooks(selecting: nil)
            }
            if ProcessInfo.processInfo.arguments.contains("--uitest-preview-busy") {
                books = Self.previewBooks
                selectedBookID = books.first?.id
            }
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private static func writeEndToEndFixture(to url: URL) throws {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>端到端测试图书</dc:title><dc:creator>测试作者</dc:creator><dc:language>zh-CN</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="one" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
            <item id="two" href="Text/two.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="one"/><itemref idref="two"/></spine>
        </package>
        """
        let entries = [
            ZipWriteEntry(path: "mimetype", source: .data(Data("application/epub+zip".utf8))),
            ZipWriteEntry(
                path: "META-INF/container.xml",
                source: .data(Data(#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#.utf8))
            ),
            ZipWriteEntry(path: "OPS/package.opf", source: .data(Data(opf.utf8))),
            ZipWriteEntry(
                path: "OPS/nav.xhtml",
                source: .data(Data(#"<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body><nav><ol><li><a href="Text/one.xhtml">第一章</a></li><li><a href="Text/two.xhtml">第二章</a></li></ol></nav></body></html>"#.utf8))
            ),
            ZipWriteEntry(
                path: "OPS/Text/one.xhtml",
                source: .data(Data(#"<?xml version="1.0"?><html><body><p>这是第一章的端到端测试正文。</p></body></html>"#.utf8))
            ),
            ZipWriteEntry(
                path: "OPS/Text/two.xhtml",
                source: .data(Data(#"<?xml version="1.0"?><html><body><p>这是第二章，验证队列、音频封装和导出。</p></body></html>"#.utf8))
            ),
        ]
        try ZipContainerWriter().write(entries: entries, to: url)
    }

    func importBooks(from urls: [URL]) {
        guard let importer, let repository else { return }
        guard !urls.isEmpty else { return }
        isImporting = true
        importErrorMessage = nil
        Task {
            var importedID: UUID?
            var failures: [String] = []
            for url in urls {
                var prepared: ImportedBookDraft?
                do {
                    let draft = try await importer.prepareImport(from: url)
                    prepared = draft
                    try await repository.importBook(draft)
                    importedID = importedID ?? draft.id
                } catch let error as RepositoryError {
                    if case .duplicateBook(let existingID) = error {
                        if let prepared {
                            duplicateImports.append(DuplicateImportPrompt(
                                draft: prepared,
                                existingBookID: existingID,
                                sourceName: url.lastPathComponent
                            ))
                        }
                    } else {
                        if let prepared { importer.discardPreparedImport(prepared) }
                        failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                } catch {
                    if let prepared { importer.discardPreparedImport(prepared) }
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            await reloadBooks(selecting: importedID)
            isImporting = false
            if !failures.isEmpty { importErrorMessage = failures.joined(separator: "\n") }
        }
    }

    func locateExistingDuplicate() {
        guard let prompt = duplicateImports.first, let importer else { return }
        importer.discardPreparedImport(prompt.draft)
        duplicateImports.removeFirst()
        Task { await reloadBooks(selecting: prompt.existingBookID) }
    }

    func createDuplicateImport() {
        guard let prompt = duplicateImports.first, let repository else { return }
        duplicateImports.removeFirst()
        Task {
            do {
                try await repository.importBook(prompt.draft, allowDuplicate: true)
                await reloadBooks(selecting: prompt.draft.id)
            } catch {
                importer?.discardPreparedImport(prompt.draft)
                importErrorMessage = error.localizedDescription
            }
        }
    }

    func cancelDuplicateImport() {
        guard let prompt = duplicateImports.first else { return }
        importer?.discardPreparedImport(prompt.draft)
        duplicateImports.removeFirst()
    }

    private func reloadBooks(selecting preferredID: UUID?) async {
        guard let repository else { return }
        do {
            let snapshots = try await repository.books()
            books = snapshots.map(makePresentationBook)
            let candidate = preferredID ?? selectedBookID
            selectedBookID = candidate.flatMap { id in books.contains { $0.id == id } ? id : nil }
                ?? books.first?.id
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func reloadModels() async {
        guard let repository else { return }
        do {
            let snapshots = try await repository.models()
            // The repository call is an actor hop. Read the selection after it
            // returns so a click made while the refresh was suspended wins.
            let currentlySelectedModelID = selectedModelID
            models = snapshots.map { model in
                let platformCompatible = isPlatformCompatible(modelID: model.id)
                let available = model.runtime == .ready && platformCompatible
                let runtimeStatus: String = switch (model.installation, model.runtime) {
                case _ where !platformCompatible: String(localized: "需要原生 Apple Silicon")
                case (_, .ready): String(localized: "已就绪")
                case (.notInstalled, _): String(localized: "未安装")
                case (.installed, .unloaded): String(localized: "未加载")
                case (.downloading, _): String(localized: "正在下载")
                case (.verifying, _): String(localized: "正在校验")
                case (.installing, _): String(localized: "正在安装")
                case (.failed, _): String(localized: "安装失败")
                case (.corrupted, _): String(localized: "模型已损坏")
                default: String(localized: "当前设备不可用")
                }
                let voices: [TTSVoiceDescriptor] = switch model.id {
                case TTSModelCatalog.kokoroID: TTSModelCatalog.kokoroVoices
                case TTSModelCatalog.cosyVoiceID: TTSModelCatalog.cosyVoiceVoices
                case TTSModelCatalog.qwen3TTSID: TTSModelCatalog.qwen3TTSVoices
                default: []
                }
                return TTSModelSnapshot(
                    id: model.id,
                    name: model.displayName,
                    framework: model.framework,
                    runtimeStatus: runtimeStatus,
                    languages: model.id == LibraryRepository.systemVoiceID
                        ? String(localized: "随 macOS 已安装语音")
                        : String(localized: "中文、英文"),
                    isAvailable: available,
                    isDefault: model.isDefault,
                    version: model.version,
                    installation: platformCompatible ? model.installation : .unavailable,
                    downloadProgress: model.downloadProgress,
                    failureMessage: model.failureMessage,
                    downloadSize: model.downloadSize,
                    selectedVoiceID: model.selectedVoiceID,
                    voices: voices
                )
            }
            selectedModelID = models.contains(where: { $0.id == currentlySelectedModelID })
                ? currentlySelectedModelID
                : models.first(where: \.isDefault)?.id ?? models.first?.id
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func makePresentationBook(_ snapshot: PersistentBookSnapshot) -> BookSnapshot {
        let completedCharacters = snapshot.chapters
            .filter { $0.status == .completed }
            .reduce(0) { $0 + $1.characterCount }
        let persistedCompleted = snapshot.jobCompletedUnits ?? Int64(completedCharacters)
        let activeChapterUnits = max(0, persistedCompleted - Int64(completedCharacters))
        let chapters = snapshot.chapters.map { chapter in
            let status = Self.presentationStatus(chapter.status)
            let chapterProgress: Double? = if status == .converting {
                chapter.status == .packaging
                    ? 1
                    : min(1, Double(activeChapterUnits) / Double(max(1, chapter.characterCount)))
            } else {
                nil
            }
            return ChapterSnapshot(
                id: chapter.id,
                index: chapter.index + 1,
                title: chapter.title,
                duration: chapter.durationSeconds.map(Self.durationString),
                status: status,
                progress: chapterProgress
            )
        }
        let completed = snapshot.chapters.count { $0.status == .completed }
        let persistedTotal = snapshot.jobTotalUnits ?? snapshot.totalCharacters
        let progress = persistedTotal > 0
            ? min(1, Double(persistedCompleted) / Double(persistedTotal))
            : 0
        return BookSnapshot(
            id: snapshot.id,
            title: snapshot.title,
            author: snapshot.author,
            chapterCount: chapters.count,
            completedChapterCount: completed,
            progress: progress,
            status: Self.presentationStatus(snapshot.status),
            estimatedHours: max(1, Int(ceil(Double(snapshot.totalCharacters) / 15_000))),
            chapters: chapters,
            coverURL: snapshot.coverRelativePath.flatMap { try? directories?.resolve(relativePath: $0) },
            coverColor: .indigo,
            coverSymbol: "book.closed.fill",
            modelID: snapshot.modelID
        )
    }

    private static func durationString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func presentationStatus(_ status: BookStatus) -> BookPresentationStatus {
        switch status {
        case .ready: .ready
        case .queued: .queued
        case .converting: .converting
        case .paused, .interrupted: .paused
        case .completed: .completed
        case .failed: .failed
        }
    }

    private static func presentationStatus(_ status: ChapterStatus) -> BookPresentationStatus {
        switch status {
        case .pending: .ready
        case .queued: .queued
        case .synthesizing, .packaging: .converting
        case .paused: .paused
        case .completed: .completed
        case .failed: .failed
        }
    }

    private static let previewBooks: [BookSnapshot] = [
        BookSnapshot(
            id: UUID(), title: "漫长的旅程", author: "林知远", chapterCount: 24,
            completedChapterCount: 10, progress: 0.42, status: .converting,
            estimatedHours: 11,
            chapters: makeChapters(count: 24, completed: 10, current: 11),
            coverURL: nil,
            coverColor: .blue, coverSymbol: "mountain.2.fill"
        ),
        BookSnapshot(
            id: UUID(), title: "潮汐以北", author: "周海", chapterCount: 18,
            completedChapterCount: 18, progress: 1, status: .completed,
            estimatedHours: 8,
            chapters: makeChapters(count: 18, completed: 18),
            coverURL: nil,
            coverColor: .brown, coverSymbol: "water.waves"
        ),
        BookSnapshot(
            id: UUID(), title: "山中来信", author: "陈默", chapterCount: 31,
            completedChapterCount: 0, progress: 0, status: .queued,
            estimatedHours: 14,
            chapters: makeChapters(count: 31, completed: 0),
            coverURL: nil,
            coverColor: .green, coverSymbol: "leaf.fill"
        ),
    ]

    private static let previewModels: [TTSModelSnapshot] = [
        TTSModelSnapshot(
            id: TTSModelCatalog.systemID,
            name: "Apple 系统语音", framework: "AVFoundation",
            runtimeStatus: "已就绪", languages: "随 macOS 已安装语音", isAvailable: true, isDefault: true,
            version: "system", installation: .installed, downloadProgress: 1, failureMessage: nil,
            downloadSize: nil, selectedVoiceID: nil, voices: []
        ),
        TTSModelSnapshot(
            id: TTSModelCatalog.kokoroID, name: "Kokoro 多语言 Int8", framework: "sherpa-onnx",
            runtimeStatus: "未安装", languages: "中文、英文", isAvailable: false, isDefault: false,
            version: TTSModelCatalog.kokoro.version, installation: .notInstalled, downloadProgress: 0,
            failureMessage: nil, downloadSize: TTSModelCatalog.kokoro.downloadBytes,
            selectedVoiceID: "zf_001", voices: TTSModelCatalog.kokoroVoices
        ),
        TTSModelSnapshot(
            id: TTSModelCatalog.cosyVoiceID,
            name: TTSModelCatalog.cosyVoice.displayName,
            framework: "speech-swift / MLX", runtimeStatus: "未安装",
            languages: "中文、英文、日文、韩文", isAvailable: false, isDefault: false,
            version: TTSModelCatalog.cosyVoice.version, installation: .notInstalled,
            downloadProgress: 0, failureMessage: nil,
            downloadSize: TTSModelCatalog.cosyVoice.downloadBytes,
            selectedVoiceID: "default", voices: TTSModelCatalog.cosyVoiceVoices
        ),
        TTSModelSnapshot(
            id: TTSModelCatalog.qwen3TTSID,
            name: TTSModelCatalog.qwen3TTS.displayName,
            framework: "speech-swift / MLX", runtimeStatus: "未安装",
            languages: "中文、英文、日文、韩文", isAvailable: false, isDefault: false,
            version: TTSModelCatalog.qwen3TTS.version, installation: .notInstalled,
            downloadProgress: 0, failureMessage: nil,
            downloadSize: TTSModelCatalog.qwen3TTS.downloadBytes,
            selectedVoiceID: "vivian", voices: TTSModelCatalog.qwen3TTSVoices
        ),
    ]

    private static func liveModels(
        platformSupport: SpeechSwiftPlatformSupport
    ) -> [TTSModelSnapshot] {
        [TTSModelSnapshot(
            id: "com.audiobookmaker.apple-system-speech",
            name: "Apple 系统语音", framework: "AVFoundation",
            runtimeStatus: "已就绪", languages: "随 macOS 已安装语音", isAvailable: true, isDefault: true
            ,version: "system", installation: .installed, downloadProgress: 1, failureMessage: nil,
            downloadSize: nil, selectedVoiceID: nil, voices: []
        ),
        TTSModelSnapshot(
            id: TTSModelCatalog.kokoroID,
            name: "Kokoro 多语言 Int8", framework: "sherpa-onnx",
            runtimeStatus: "未安装", languages: "中文、英文", isAvailable: false, isDefault: false,
            version: TTSModelCatalog.kokoro.version, installation: .notInstalled, downloadProgress: 0,
            failureMessage: nil, downloadSize: TTSModelCatalog.kokoro.downloadBytes,
            selectedVoiceID: "zf_001", voices: TTSModelCatalog.kokoroVoices
        ),
        speechSwiftInitialModel(
            TTSModelCatalog.cosyVoice,
            voices: TTSModelCatalog.cosyVoiceVoices,
            defaultVoiceID: "default",
            platformSupport: platformSupport
        ),
        speechSwiftInitialModel(
            TTSModelCatalog.qwen3TTS,
            voices: TTSModelCatalog.qwen3TTSVoices,
            defaultVoiceID: "vivian",
            platformSupport: platformSupport
        )]
    }

    private static func speechSwiftInitialModel(
        _ manifest: DownloadableModelManifest,
        voices: [TTSVoiceDescriptor],
        defaultVoiceID: String,
        platformSupport: SpeechSwiftPlatformSupport
    ) -> TTSModelSnapshot {
        let supported = platformSupport.status().isSupported
        return TTSModelSnapshot(
            id: manifest.id,
            name: manifest.displayName,
            framework: "speech-swift / MLX",
            runtimeStatus: supported ? "未安装" : "需要原生 Apple Silicon",
            languages: "中文、英文、日文、韩文",
            isAvailable: false,
            isDefault: false,
            version: manifest.version,
            installation: supported ? .notInstalled : .unavailable,
            downloadProgress: 0,
            failureMessage: supported ? nil : "需要原生 Apple Silicon、macOS 15 或更高版本及 Metal",
            downloadSize: manifest.downloadBytes,
            selectedVoiceID: defaultVoiceID,
            voices: voices
        )
    }

    private static func makeChapters(
        count: Int,
        completed: Int,
        current: Int? = nil
    ) -> [ChapterSnapshot] {
        let names = ["启程之前", "穿过雨季", "陌生的港口", "夜航", "旧地图", "越过群山", "抵达之后"]
        return (1...count).map { index in
            let status: BookPresentationStatus
            if index <= completed {
                status = .completed
            } else if index == current {
                status = .converting
            } else {
                status = .ready
            }
            return ChapterSnapshot(
                id: UUID(),
                index: index,
                title: index <= names.count ? names[index - 1] : "第 \(index) 章",
                duration: index <= completed ? String(format: "%02d:%02d", 20 + index % 12, index * 7 % 60) : nil,
                status: status,
                progress: status == .converting ? 0.42 : nil
            )
        }
    }
}
