import Foundation
import Testing
@testable import AudiobookMaker

struct ZipWriterProgressTests {
    @Test
    func reportsDeterminateProgress() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appending(path: "progress.zip")
        let recorder = ProgressRecorder()

        try ZipContainerWriter().write(entries: [
            ZipWriteEntry(path: "中文/一.txt", source: .data(Data(repeating: 1, count: 4_096))),
            ZipWriteEntry(path: "metadata.json", source: .data(Data("{}".utf8)), method: .deflated),
        ], to: output) { recorder.append($0) }

        let values = recorder.values
        #expect(values.first?.fractionCompleted == 0)
        #expect(values.last?.fractionCompleted == 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0.fractionCompleted <= $1.fractionCompleted })
        #expect(try ZipContainerReader(url: output).paths.contains("中文/一.txt"))
    }

    @Test
    func cancellationRemovesIncompleteArchive() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "large.bin")
        let output = root.appending(path: "cancelled.zip")
        try Data(repeating: 0x5A, count: 32 * 1_024 * 1_024).write(to: source)

        let operation = Task.detached {
            try ZipContainerWriter().write(
                entries: [ZipWriteEntry(path: "large.bin", source: .file(source))],
                to: output
            )
        }
        try await Task.sleep(for: .milliseconds(2))
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func zip64EntryCountRoundTripsThroughWriterAndReader() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appending(path: "zip64-count.zip")
        let entries = (0..<Int(UInt16.max)).map { index in
            ZipWriteEntry(path: String(format: "items/%05d.txt", index), source: .data(Data()))
        }

        try ZipContainerWriter().write(entries: entries, to: output)
        var limits = ZipSecurityLimits.epub
        limits.maximumEntryCount = entries.count
        let reader = try ZipContainerReader(url: output, limits: limits)

        #expect(reader.entries.count == entries.count)
        #expect(reader.contains("items/00000.txt"))
        #expect(reader.contains("items/65534.txt"))
        #expect(try reader.data(for: "items/65534.txt").isEmpty)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ZipWriteProgress] = []

    var values: [ZipWriteProgress] { lock.withLock { storage } }
    func append(_ value: ZipWriteProgress) { lock.withLock { storage.append(value) } }
}
