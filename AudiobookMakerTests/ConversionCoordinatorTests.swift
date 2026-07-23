import Foundation
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
struct ConversionCoordinatorTests {
    @Test @MainActor func convertsTwoChaptersInOrderAndCommitsM4B() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let runtime = MockTTSRuntimeClient()
        let coordinator = ConversionCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories,
            runtime: runtime
        )
        let bookID = UUID()
        let bookDirectory = dependencies.directories.bookDirectory(id: bookID)
        let textDirectory = bookDirectory.appending(path: "text", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: textDirectory, withIntermediateDirectories: true)
        var chapters: [ImportedChapterDraft] = []
        for index in 0..<2 {
            let text = "第\(index + 1)章的确定性测试正文。"
            let data = Data(text.utf8)
            let url = textDirectory.appending(path: String(format: "%04d.txt", index))
            try data.write(to: url)
            chapters.append(ImportedChapterDraft(
                id: UUID(),
                index: index,
                title: "第 \(index + 1) 章",
                sourceHref: "\(index).xhtml",
                textRelativePath: try dependencies.directories.relativePath(for: url),
                textSHA256: SHA256Hasher.hash(data),
                characterCount: text.count
            ))
        }
        try await dependencies.repository.importBook(ImportedBookDraft(
            id: bookID,
            title: "转换测试书",
            author: "AudiobookMaker",
            languageCode: "zh-CN",
            sourceRelativePath: "Books/\(bookID)/source.epub",
            sourceSHA256: String(repeating: "a", count: 64),
            coverRelativePath: nil,
            totalCharacters: Int64(chapters.reduce(0) { $0 + $1.characterCount }),
            chapters: chapters
        ))

        await coordinator.start(bookID: bookID)
        while await coordinator.isActive(bookID: bookID) {
            try await Task.sleep(for: .milliseconds(20))
        }

        let book = try #require(try await dependencies.repository.books().first)
        #expect(book.status == .completed)
        #expect(book.chapters.allSatisfy { $0.status == .completed })
        #expect(book.chapters.allSatisfy { ($0.durationSeconds ?? 0) > 0 })
        let artifacts = try FileManager.default.contentsOfDirectory(
            at: bookDirectory.appending(path: "audio", directoryHint: .isDirectory),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "m4b" }
        #expect(artifacts.count == 2)

        let exportURL = root.appending(path: "转换测试书.m4b")
        _ = try await ExportCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories
        ).export(bookID: bookID, to: exportURL)
        try await M4BValidator.validateAudiobook(
            url: exportURL,
            expectedTitle: "转换测试书",
            expectedChapterTitles: ["第 1 章", "第 2 章"],
            expectsArtwork: false
        )
    }

    @Test @MainActor func twoBooksRunInPersistentFIFOOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        var configuration = MockTTSRuntimeClient.Configuration()
        configuration.delay = .milliseconds(250)
        configuration.maximumTextLength = 100
        let runtime = MockTTSRuntimeClient(configuration: configuration)
        let coordinator = ConversionCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories,
            runtime: runtime
        )
        let firstID = try await insertBook(
            title: "第一本", text: "FIRST", hashCharacter: "e",
            dependencies: dependencies
        )
        let secondID = try await insertBook(
            title: "第二本", text: "SECOND", hashCharacter: "f",
            dependencies: dependencies
        )

        await coordinator.start(bookID: firstID)
        await coordinator.start(bookID: secondID)
        try await Task.sleep(for: .milliseconds(40))
        let running = try await dependencies.repository.books()
        #expect(running.first(where: { $0.id == firstID })?.status == .converting)
        #expect(running.first(where: { $0.id == secondID })?.status == .queued)
        while true {
            let firstActive = await coordinator.isActive(bookID: firstID)
            let secondActive = await coordinator.isActive(bookID: secondID)
            if !firstActive, !secondActive { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await runtime.synthesizedTexts() == ["FIRST", "SECOND"])
    }

    @Test @MainActor func transientErrorsRetryTwiceButPermanentErrorsFailImmediately() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        var transientConfiguration = MockTTSRuntimeClient.Configuration()
        transientConfiguration.error = .timedOut
        let transientRuntime = MockTTSRuntimeClient(configuration: transientConfiguration)
        let transientCoordinator = ConversionCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories,
            runtime: transientRuntime
        )
        let transientID = try await insertBook(
            title: "瞬时错误", text: "RETRY", hashCharacter: "1",
            dependencies: dependencies
        )
        await transientCoordinator.start(bookID: transientID)
        while await transientCoordinator.isActive(bookID: transientID) {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await transientRuntime.synthesizedTexts().count == 3)
        #expect(try await dependencies.repository.books()
            .first(where: { $0.id == transientID })?.status == .failed)

        var permanentConfiguration = MockTTSRuntimeClient.Configuration()
        permanentConfiguration.error = .modelUnavailable
        let permanentRuntime = MockTTSRuntimeClient(configuration: permanentConfiguration)
        let permanentCoordinator = ConversionCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories,
            runtime: permanentRuntime
        )
        let permanentID = try await insertBook(
            title: "永久错误", text: "FAIL", hashCharacter: "2",
            dependencies: dependencies
        )
        await permanentCoordinator.start(bookID: permanentID)
        while await permanentCoordinator.isActive(bookID: permanentID) {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await permanentRuntime.synthesizedTexts().count == 1)
        #expect(try await dependencies.repository.books()
            .first(where: { $0.id == permanentID })?.status == .paused)
    }

    @Test @MainActor func nonImmediateRuntimePausesAfterCurrentFragmentAndResumesCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        var configuration = MockTTSRuntimeClient.Configuration()
        configuration.delay = .milliseconds(120)
        configuration.maximumTextLength = 4
        configuration.supportsImmediateCancellation = false
        let runtime = MockTTSRuntimeClient(configuration: configuration)
        let coordinator = ConversionCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories,
            runtime: runtime
        )
        let bookID = try await insertBook(
            title: "暂停恢复", text: "AAAABBBBCCCC", hashCharacter: "3",
            dependencies: dependencies
        )

        await coordinator.start(bookID: bookID)
        let synthesisDeadline = ContinuousClock.now + .seconds(5)
        while await runtime.progressEvents().isEmpty, ContinuousClock.now < synthesisDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await runtime.progressEvents().isEmpty == false)
        await coordinator.pause(bookID: bookID)
        while await coordinator.isActive(bookID: bookID) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pausedBook = try #require(try await dependencies.repository.books().first)
        #expect(pausedBook.status == .paused)
        #expect(pausedBook.jobCompletedUnits == 4)
        #expect(pausedBook.jobTotalUnits == 12)
        #expect(await runtime.synthesizedTexts() == ["AAAA"])

        let resumable = try await dependencies.repository.resumableConversion(bookID: bookID)
        await coordinator.resume(bookID: bookID)
        while await coordinator.isActive(bookID: bookID) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await dependencies.repository.books().first?.status == .completed)
        #expect(await runtime.synthesizedTexts() == ["AAAA", "BBBB", "CCCC"])
        #expect(resumable.selection.modelID == TTSModelCatalog.systemID)
    }

    @Test @MainActor func userRuntimeAndSafetyConcurrencyLimitsAreEnforced() async throws {
        let defaults = UserDefaults.standard
        let prior = defaults.object(forKey: "maxConcurrentJobs")
        defer {
            if let prior { defaults.set(prior, forKey: "maxConcurrentJobs") }
            else { defaults.removeObject(forKey: "maxConcurrentJobs") }
        }

        let firstRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: firstRoot) }
        let firstDependencies = try DependencyContainer(inMemory: true, rootOverride: firstRoot)
        var configuration = MockTTSRuntimeClient.Configuration()
        configuration.delay = .milliseconds(180)
        configuration.recommendedConcurrency = 2
        let serialRuntime = MockTTSRuntimeClient(configuration: configuration)
        let serialCoordinator = ConversionCoordinator(
            repository: firstDependencies.repository,
            directories: firstDependencies.directories,
            runtime: serialRuntime
        )
        defaults.set(1, forKey: "maxConcurrentJobs")
        let serialFirst = try await insertBook(
            title: "串行一", text: "ONE", hashCharacter: "4", dependencies: firstDependencies
        )
        let serialSecond = try await insertBook(
            title: "串行二", text: "TWO", hashCharacter: "5", dependencies: firstDependencies
        )
        await serialCoordinator.start(bookID: serialFirst)
        await serialCoordinator.start(bookID: serialSecond)
        try await waitUntilIdle(serialCoordinator, bookIDs: [serialFirst, serialSecond])
        #expect(await serialRuntime.maximumObservedConcurrency() == 1)

        let secondRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        let secondDependencies = try DependencyContainer(inMemory: true, rootOverride: secondRoot)
        let parallelRuntime = MockTTSRuntimeClient(configuration: configuration)
        let parallelCoordinator = ConversionCoordinator(
            repository: secondDependencies.repository,
            directories: secondDependencies.directories,
            runtime: parallelRuntime
        )
        defaults.set(2, forKey: "maxConcurrentJobs")
        let parallelFirst = try await insertBook(
            title: "并行一", text: "RED", hashCharacter: "6", dependencies: secondDependencies
        )
        let parallelSecond = try await insertBook(
            title: "并行二", text: "BLUE", hashCharacter: "7", dependencies: secondDependencies
        )
        await parallelCoordinator.start(bookID: parallelFirst)
        await parallelCoordinator.start(bookID: parallelSecond)
        try await waitUntilIdle(parallelCoordinator, bookIDs: [parallelFirst, parallelSecond])
        #expect(await parallelRuntime.maximumObservedConcurrency() == 2)

        let safetyRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: safetyRoot) }
        let safetyDependencies = try DependencyContainer(inMemory: true, rootOverride: safetyRoot)
        configuration.maximumSafeConcurrency = 1
        let safetyRuntime = MockTTSRuntimeClient(configuration: configuration)
        let safetyCoordinator = ConversionCoordinator(
            repository: safetyDependencies.repository,
            directories: safetyDependencies.directories,
            runtime: safetyRuntime
        )
        let safetyFirst = try await insertBook(
            title: "安全一", text: "SAFE", hashCharacter: "c", dependencies: safetyDependencies
        )
        let safetySecond = try await insertBook(
            title: "安全二", text: "LIMIT", hashCharacter: "d", dependencies: safetyDependencies
        )
        await safetyCoordinator.start(bookID: safetyFirst)
        await safetyCoordinator.start(bookID: safetySecond)
        try await waitUntilIdle(safetyCoordinator, bookIDs: [safetyFirst, safetySecond])
        #expect(await safetyRuntime.maximumObservedConcurrency() == 1)
    }

    @Test @MainActor func immediateCancellationPausesInFlightFragmentAndResumes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        var configuration = MockTTSRuntimeClient.Configuration()
        configuration.delay = .milliseconds(300)
        configuration.maximumTextLength = 4
        configuration.supportsImmediateCancellation = true
        let runtime = MockTTSRuntimeClient(configuration: configuration)
        let coordinator = ConversionCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories,
            runtime: runtime
        )
        let bookID = try await insertBook(
            title: "即时暂停", text: "AAAABBBB", hashCharacter: "8", dependencies: dependencies
        )

        await coordinator.start(bookID: bookID)
        try await Task.sleep(for: .milliseconds(50))
        await coordinator.pause(bookID: bookID)
        try await waitUntilIdle(coordinator, bookIDs: [bookID])
        let paused = try #require(try await dependencies.repository.books().first)
        #expect(paused.status == .paused)
        #expect(paused.jobCompletedUnits == 0)
        #expect(await runtime.synthesizedTexts().isEmpty)

        let resumable = try await dependencies.repository.resumableConversion(bookID: bookID)
        let chapterID = try #require(paused.chapters.first?.id)
        let invalidCheckpoint = dependencies.directories.bookDirectory(id: bookID)
            .appending(path: "audio/\(chapterID.uuidString)/\(resumable.id.uuidString)/0000.caf")
        try FileManager.default.createDirectory(
            at: invalidCheckpoint.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("truncated checkpoint".utf8).write(to: invalidCheckpoint)
        await coordinator.resume(bookID: bookID)
        try await waitUntilIdle(coordinator, bookIDs: [bookID])
        #expect(try await dependencies.repository.books().first?.status == .completed)
        #expect(await runtime.synthesizedTexts() == ["AAAA", "BBBB"])
        #expect(resumable.selection.modelID == TTSModelCatalog.systemID)
    }

    @Test @MainActor func progressUsesCompletedCharacterWeightNotChapterCount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        var configuration = MockTTSRuntimeClient.Configuration()
        configuration.delay = .milliseconds(180)
        configuration.maximumTextLength = 100
        let runtime = MockTTSRuntimeClient(configuration: configuration)
        let coordinator = ConversionCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories,
            runtime: runtime
        )
        let bookID = try await insertBook(
            title: "字符权重", texts: ["A", "BBBBBBBBB"], dependencies: dependencies
        )

        await coordinator.start(bookID: bookID)
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let snapshot = try #require(
                try await dependencies.repository.books().first(where: { $0.id == bookID })
            )
            if let completed = snapshot.jobCompletedUnits, completed > 0 {
                #expect(completed == 1)
                #expect(snapshot.jobTotalUnits == 10)
                #expect(Double(completed) / Double(snapshot.jobTotalUnits ?? 1) == 0.1)
                break
            }
            guard ContinuousClock.now < deadline else {
                Issue.record("转换进度在 10 秒内没有产生首章 checkpoint，当前状态：\(snapshot.status)")
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await waitUntilIdle(coordinator, bookIDs: [bookID])
    }

    @MainActor
    private func insertBook(
        title: String,
        text: String,
        hashCharacter: Character,
        dependencies: DependencyContainer
    ) async throws -> UUID {
        let id = UUID()
        let textURL = dependencies.directories.bookDirectory(id: id)
            .appending(path: "text/0000.txt")
        try FileManager.default.createDirectory(
            at: textURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(text.utf8)
        try data.write(to: textURL)
        try await dependencies.repository.importBook(ImportedBookDraft(
            id: id,
            title: title,
            author: "作者",
            languageCode: "zh-CN",
            sourceRelativePath: "Books/\(id)/source.epub",
            sourceSHA256: String(repeating: String(hashCharacter), count: 64),
            coverRelativePath: nil,
            totalCharacters: Int64(text.count),
            chapters: [ImportedChapterDraft(
                id: UUID(), index: 0, title: "章节", sourceHref: "chapter.xhtml",
                textRelativePath: try dependencies.directories.relativePath(for: textURL),
                textSHA256: SHA256Hasher.hash(data), characterCount: text.count
            )]
        ))
        return id
    }

    @MainActor
    private func insertBook(
        title: String,
        texts: [String],
        dependencies: DependencyContainer
    ) async throws -> UUID {
        let id = UUID()
        var chapters: [ImportedChapterDraft] = []
        for (index, text) in texts.enumerated() {
            let textURL = dependencies.directories.bookDirectory(id: id)
                .appending(path: String(format: "text/%04d.txt", index))
            try FileManager.default.createDirectory(
                at: textURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data(text.utf8)
            try data.write(to: textURL)
            chapters.append(ImportedChapterDraft(
                id: UUID(), index: index, title: "章节 \(index + 1)",
                sourceHref: "\(index).xhtml",
                textRelativePath: try dependencies.directories.relativePath(for: textURL),
                textSHA256: SHA256Hasher.hash(data), characterCount: text.count
            ))
        }
        try await dependencies.repository.importBook(ImportedBookDraft(
            id: id, title: title, author: "作者", languageCode: "zh-CN",
            sourceRelativePath: "Books/\(id)/source.epub",
            sourceSHA256: UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            coverRelativePath: nil,
            totalCharacters: Int64(texts.reduce(0) { $0 + $1.count }),
            chapters: chapters
        ))
        return id
    }

    private func waitUntilIdle(
        _ coordinator: ConversionCoordinator,
        bookIDs: [UUID]
    ) async throws {
        while true {
            var hasActiveBook = false
            for bookID in bookIDs {
                if await coordinator.isActive(bookID: bookID) {
                    hasActiveBook = true
                }
            }
            if !hasActiveBook { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
