import AVFoundation
import Testing
@testable import AudiobookMaker

struct M4BPackagerTests {
    @Test func packagesSingleAudiobookWithMultipleTimedChapterMarkers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = await MockTTSRuntimeClient()
        var chapters: [M4BAudiobookChapter] = []
        for (index, title) in ["第一章", "第二章"].enumerated() {
            let text = "\(title)的测试正文"
            let segment = directory.appending(path: "segment-\(index).caf")
            _ = try await runtime.synthesize(SynthesisRequest(text: text, outputURL: segment))
            let chapterURL = directory.appending(path: "chapter-\(index).m4b")
            _ = try await M4BPackager.package(M4BPackageRequest(
                audioSegments: [segment], outputURL: chapterURL,
                title: "整书测试", author: "测试作者", chapterTitle: title,
                chapterIndex: index, languageCode: "zh-CN", fullText: text,
                coverData: nil
            ))
            chapters.append(M4BAudiobookChapter(title: title, audioURL: chapterURL))
        }
        let output = directory.appending(path: "整书测试.m4b")

        _ = try await M4BPackager.packageAudiobook(M4BAudiobookPackageRequest(
            chapters: chapters,
            outputURL: output,
            title: "整书测试",
            author: "测试作者",
            narrator: "测试旁白",
            genre: "有声书",
            publicationDate: Date(timeIntervalSince1970: 1_700_000_000),
            languageCode: "zh-CN",
            coverData: nil
        ))

        try await M4BValidator.validateAudiobook(
            url: output,
            expectedTitle: "整书测试",
            expectedChapterTitles: ["第一章", "第二章"],
            expectsArtwork: false
        )
        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func packagesManyChaptersWithoutTextTrackBackpressureTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let segment = directory.appending(path: "segment.caf")
        _ = try await MockTTSRuntimeClient().synthesize(SynthesisRequest(
            text: "短章节",
            outputURL: segment
        ))
        let chapterURL = directory.appending(path: "chapter.m4b")
        _ = try await M4BPackager.package(M4BPackageRequest(
            audioSegments: [segment], outputURL: chapterURL,
            title: "长书", author: "作者", chapterTitle: "模板章节",
            chapterIndex: 0, languageCode: "zh-CN", fullText: "短章节",
            coverData: nil
        ))
        let titles = (1...80).map { "第 \($0) 章" }
        let output = directory.appending(path: "many-chapters.m4b")

        _ = try await M4BPackager.packageAudiobook(M4BAudiobookPackageRequest(
            chapters: titles.map { M4BAudiobookChapter(title: $0, audioURL: chapterURL) },
            outputURL: output,
            title: "长书",
            author: "作者",
            narrator: "旁白",
            genre: "有声书",
            publicationDate: Date(timeIntervalSince1970: 1_700_000_000),
            languageCode: "zh-CN",
            coverData: nil
        ))

        try await M4BValidator.validateAudiobook(
            url: output,
            expectedTitle: "长书",
            expectedChapterTitles: titles,
            expectsArtwork: false
        )
    }

    @Test func packagesMultipleSegmentsAndAtomicallyCommits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = await MockTTSRuntimeClient()
        var segments: [URL] = []
        for (index, text) in ["第一段", "第二段"].enumerated() {
            let url = directory.appending(path: "\(index).caf")
            _ = try await runtime.synthesize(SynthesisRequest(text: text, outputURL: url))
            segments.append(url)
        }
        let output = directory.appending(path: "chapter.m4b")
        let result = try await M4BPackager.package(M4BPackageRequest(
            audioSegments: segments,
            outputURL: output,
            title: "测试书籍",
            author: "测试作者",
            chapterTitle: "第一章",
            chapterIndex: 0,
            languageCode: "zh-CN",
            fullText: "第一段第二段",
            coverData: nil
        ))

        #expect(result.durationSeconds > 0.15)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
    }

    @Test func rejectsEmptySegmentsWithoutLeavingPartial() async {
        let output = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).m4b")
        await #expect(throws: PackagingError.noAudioSegments) {
            try await M4BPackager.package(M4BPackageRequest(
                audioSegments: [], outputURL: output, title: "书", author: "作者",
                chapterTitle: "章", chapterIndex: 0, languageCode: nil,
                fullText: "正文", coverData: nil
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
    }

    @Test func packagesLongUnicodeTextWithoutCover() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = String(repeating: "长章节正文包含中文、emoji 🎧 和 RTL العربية。", count: 240)
        let segment = directory.appending(path: "long.caf")
        _ = try await MockTTSRuntimeClient().synthesize(SynthesisRequest(
            text: String(text.prefix(180)), outputURL: segment
        ))
        let output = directory.appending(path: "long.m4b")

        let result = try await M4BPackager.package(M4BPackageRequest(
            audioSegments: [segment], outputURL: output,
            title: "长文本书籍", author: "作者", chapterTitle: "长章节",
            chapterIndex: 8, languageCode: "zh-CN", fullText: text, coverData: nil
        ))

        #expect(result.textSHA256 == SHA256Hasher.hash(Data(text.utf8)))
        #expect(result.durationSeconds > 0)
        try await M4BValidator.validate(
            url: output,
            expectedTitle: "长文本书籍",
            expectedChapterTitle: "长章节",
            expectedFullText: text
        )
    }

    @Test func rejectsUnreadableAudioAndCleansPartial() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalid = directory.appending(path: "invalid.caf")
        try Data("not audio".utf8).write(to: invalid)
        let output = directory.appending(path: "invalid.m4b")

        await #expect(throws: PackagingError.unreadableAudio) {
            _ = try await M4BPackager.package(M4BPackageRequest(
                audioSegments: [invalid], outputURL: output,
                title: "书", author: "作者", chapterTitle: "章", chapterIndex: 0,
                languageCode: nil, fullText: "正文", coverData: nil
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
    }

    @Test func encodingDestinationFailureDoesNotLeavePartial() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let segment = directory.appending(path: "segment.caf")
        _ = try await MockTTSRuntimeClient().synthesize(SynthesisRequest(
            text: "编码失败", outputURL: segment
        ))
        let parentFile = directory.appending(path: "not-a-directory")
        try Data().write(to: parentFile)
        let output = parentFile.appending(path: "chapter.m4b")

        await #expect(throws: (any Error).self) {
            _ = try await M4BPackager.package(M4BPackageRequest(
                audioSegments: [segment], outputURL: output,
                title: "书", author: "作者", chapterTitle: "章", chapterIndex: 0,
                languageCode: nil, fullText: "正文", coverData: nil
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: partialURL(for: output).path))
    }

    @Test func validatorRejectsMissingTracksAndMetadataMismatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let segment = directory.appending(path: "audio-only.caf")
        _ = try await MockTTSRuntimeClient().synthesize(SynthesisRequest(
            text: "校验正文", outputURL: segment
        ))
        await #expect(throws: (any Error).self) {
            try await M4BValidator.validate(
                url: segment, expectedTitle: "书", expectedChapterTitle: "章",
                expectedFullText: "校验正文"
            )
        }

        let output = directory.appending(path: "valid.m4b")
        _ = try await M4BPackager.package(M4BPackageRequest(
            audioSegments: [segment], outputURL: output,
            title: "正确书名", author: "作者", chapterTitle: "正确章节",
            chapterIndex: 0, languageCode: "zh-CN", fullText: "校验正文", coverData: nil
        ))
        await #expect(throws: (any Error).self) {
            try await M4BValidator.validate(
                url: output, expectedTitle: "错误书名", expectedChapterTitle: "正确章节",
                expectedFullText: "校验正文"
            )
        }
        await #expect(throws: (any Error).self) {
            try await M4BValidator.validate(
                url: output, expectedTitle: "正确书名", expectedChapterTitle: "正确章节",
                expectedFullText: "错误正文"
            )
        }
    }

    private func partialURL(for output: URL) -> URL {
        output.deletingPathExtension()
            .appendingPathExtension("partial")
            .appendingPathExtension(output.pathExtension)
    }
}
