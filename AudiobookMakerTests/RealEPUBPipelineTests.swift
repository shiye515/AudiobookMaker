import AVFoundation
import Darwin.Mach
import Foundation
import Testing
@testable import AudiobookMaker

struct RealEPUBPipelineTests {
    @Test @MainActor func realEPUBParsesSynthesizesAndPackagesWhenConfigured() async throws {
        let path = realEPUBPath
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        let parsed = try EPUBParser().parse(url: URL(filePath: path))
        let first = try #require(parsed.chapters.first)
        let sampleText = String(first.plainText.prefix(160))
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let segment = directory.appending(path: "real.caf")
        let runtime = SystemSpeechRuntimeClient()
        let synthesis = try await runtime.synthesize(SynthesisRequest(
            text: sampleText,
            languageCode: parsed.language,
            outputURL: segment
        ))
        #expect(synthesis.durationSeconds > 0)

        let output = directory.appending(path: "real-epub-smoke.m4b")
        let result = try await M4BPackager.package(M4BPackageRequest(
            audioSegments: [segment],
            outputURL: output,
            title: parsed.title,
            author: parsed.author ?? "未知作者",
            chapterTitle: first.title,
            chapterIndex: first.index,
            languageCode: parsed.language,
            fullText: sampleText,
            coverData: parsed.coverData
        ))
        #expect(result.durationSeconds > 0)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
    }

    @Test @MainActor func entireRealEPUBCompletesFourteenChapterExportWithMockRuntime() async throws {
        let path = realEPUBPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        let originalURL = URL(filePath: path)
        let originalHash = try SHA256Hasher.hashFile(at: originalURL)
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AudiobookMaker-RealEPUB-Acceptance", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = try DependencyContainer(inMemory: true, rootOverride: root)
        let draft = try await dependencies.importer.prepareImport(from: originalURL)
        try await dependencies.repository.importBook(draft)
        var configuration = MockTTSRuntimeClient.Configuration()
        configuration.maximumTextLength = 2_000
        let coordinator = ConversionCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories,
            runtime: MockTTSRuntimeClient(configuration: configuration)
        )

        var peakResidentBytes = try residentMemoryBytes()
        await coordinator.start(bookID: draft.id)
        while await coordinator.isActive(bookID: draft.id) {
            peakResidentBytes = max(peakResidentBytes, try residentMemoryBytes())
            try await Task.sleep(for: .milliseconds(50))
        }
        let book = try #require(try await dependencies.repository.books().first)
        #expect(book.title == "论中国与世界")
        #expect(book.chapters.count == 14)
        #expect(book.chapters.allSatisfy { $0.status == .completed })

        let zipURL = root.appending(path: "李光耀论中国与世界.zip")
        _ = try await ExportCoordinator(
            repository: dependencies.repository,
            directories: dependencies.directories
        ).export(bookID: draft.id, to: zipURL)
        let archive = try ZipContainerReader(url: zipURL)
        #expect(archive.paths.count { $0.hasSuffix(".m4b") } == 14)
        #expect(try SHA256Hasher.hashFile(at: originalURL) == originalHash)
        #expect(peakResidentBytes < 768 * 1_024 * 1_024)
        Attachment.record(
            "真实 EPUB：\(originalURL.lastPathComponent)\n章节：14\n峰值常驻内存：\(peakResidentBytes) bytes\n原文件哈希未变化：是",
            named: "真实 EPUB 内存与完整性验收.txt"
        )
        Attachment.record(
            [UInt8](try Data(contentsOf: zipURL)),
            named: "李光耀论中国与世界-14章验收.zip"
        )

    }

    private var realEPUBPath: String {
        ProcessInfo.processInfo.environment["AUDIOBOOKMAKER_REAL_EPUB"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Downloads/李光耀论中国与世界_李光耀.epub").path
    }

    private func residentMemoryBytes() throws -> Int64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { throw CocoaError(.coderReadCorrupt) }
        return Int64(information.resident_size)
    }
}
