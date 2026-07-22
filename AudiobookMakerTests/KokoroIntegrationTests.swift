import AVFoundation
import Foundation
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
struct KokoroIntegrationTests {
    @Test func manifestAndVoiceCatalogAreStable() throws {
        #expect(TTSModelCatalog.kokoro.verifySignature())
        #expect(TTSModelCatalog.kokoro.downloadBytes == 147_031_220)
        #expect(TTSModelCatalog.kokoroVoices.count == 103)
        #expect(TTSModelCatalog.kokoroVoices.map(\.speakerID) == (0..<103).map(Int32.init))
        #expect(Set(TTSModelCatalog.kokoroVoices.map(\.id)).count == 103)
        #expect(TTSModelCatalog.kokoroVoices.allSatisfy { !$0.id.isEmpty })
        #expect(TTSModelCatalog.kokoroVoices.contains {
            $0.id == TTSModelCatalog.kokoroDefaultVoiceID
                && $0.languageCode == "zh-CN"
                && $0.speakerID == 3
        })
    }

    @Test func modelPathsRemainInsideApplicationSupport() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(root: root.appending(path: "App"), cacheRoot: root.appending(path: "Cache"))
        try directories.createIfNeeded()
        let version = try directories.modelVersionDirectory(id: TTSModelCatalog.kokoroID, version: TTSModelCatalog.kokoro.version)
        #expect(version.pathComponents.starts(with: directories.models.pathComponents))
        #expect(throws: AppDirectoryError.unsafeRelativePath) {
            _ = try directories.modelVersionDirectory(id: TTSModelCatalog.kokoroID, version: "../escape")
        }
    }

    @Test func applicationBundleDoesNotContainModelWeights() throws {
        let enumerator = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)
        let forbidden = [
            "model.int8.onnx", "voices.bin", "kokoro-int8-multi-lang-v1_1",
            "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
            "flow.pt", "hift.pt", "campplus.onnx", "speech_tokenizer_v1.onnx",
        ]
        while let url = enumerator?.nextObject() as? URL {
            #expect(!forbidden.contains(where: { url.lastPathComponent.localizedCaseInsensitiveContains($0) }))
        }
        let metallib = Bundle.main.bundleURL.appending(path: "Contents/Resources/MLX/mlx.metallib")
        #expect(FileManager.default.fileExists(atPath: metallib.path))
        if FileManager.default.fileExists(atPath: metallib.path) {
            #expect((try metallib.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0)
        }
    }

    @Test func archiveListingRejectsTraversalLinksAndExecutables() throws {
        #expect(throws: ModelPackageError.unsafeArchive) {
            try ModelPackageManager.validateListing("-rw-r--r--  0 user group 1 Jan 1 00:00 ../escape")
        }
        #expect(throws: ModelPackageError.unsafeArchive) {
            try ModelPackageManager.validateListing("lrwxr-xr-x  0 user group 1 Jan 1 00:00 model/link")
        }
        #expect(throws: ModelPackageError.unsafeArchive) {
            try ModelPackageManager.validateListing("-rwxr-xr-x  0 user group 1 Jan 1 00:00 model/run-me")
        }
        #expect(throws: ModelPackageError.unsafeArchive) {
            try ModelPackageManager.validateListing("drwxr-xr-x  0 user group 0 Jan 1 00:00 model/..")
        }
        #expect(throws: ModelPackageError.unsafeArchive) {
            try ModelPackageManager.validateListing("-rw-r--r--  0 user group 1 Jan 1 00:00 model/./weight.onnx")
        }
        #expect(throws: ModelPackageError.invalidSize) {
            try ModelPackageManager.validateListing(
                "-rw-r--r--  0 user group 11 Jan 1 00:00 model/weight.onnx",
                maximumExpandedBytes: 10
            )
        }
        try ModelPackageManager.validateListing("-rwxr-xr-x  0 user group 1 Jan 1 00:00 model/dict/generate_user_dict.py")
    }

    @Test func stagingRecoveryAndInstalledCorruptionDetection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(root: root.appending(path: "App"), cacheRoot: root.appending(path: "Cache"))
        try directories.createIfNeeded()
        let stale = directories.modelStaging.appending(path: "interrupted")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let manager = ModelPackageManager(directories: directories)
        try await manager.recoverStaging()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        await #expect(throws: ModelPackageError.self) {
            _ = try await manager.validate()
        }
    }

    @Test func installedReceiptDetectsContentCorruption() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(root: root.appending(path: "App"), cacheRoot: root.appending(path: "Cache"))
        try directories.createIfNeeded()
        let manifest = testManifest(downloadBytes: 4, requiredPaths: ["model.bin"])
        let destination = try directories.modelVersionDirectory(id: manifest.id, version: manifest.version)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let model = destination.appending(path: "model.bin")
        try Data("good".utf8).write(to: model)
        try ModelPackageManager.writeReceipt(at: destination, manifest: manifest)
        let manager = ModelPackageManager(directories: directories)
        #expect(try await manager.validate(manifest) == destination)

        try Data("evil".utf8).write(to: model)
        await #expect(throws: ModelPackageError.checksumMismatch) {
            _ = try await manager.validate(manifest)
        }
    }

    @Test func secureDownloaderAcceptsValidResponseAndRejectsHostStatusAndSize() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelURLProtocol.self]
        let data = Data("verified-model-package".utf8)
        let manifest = testManifest(downloadBytes: Int64(data.count))

        ModelURLProtocol.setResponse(status: 200, data: data)
        let downloader = SecureModelDownloader(configuration: configuration)
        let downloaded = try await downloader.download(manifest: manifest, resumeData: nil, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: downloaded) }
        #expect(try Data(contentsOf: downloaded) == data)

        ModelURLProtocol.setResponse(status: 503, data: data)
        await #expect(throws: ModelPackageError.self) {
            _ = try await downloader.download(manifest: manifest, resumeData: nil, progress: { _ in })
        }

        ModelURLProtocol.setResponse(status: 200, data: data + Data([0]))
        await #expect(throws: ModelPackageError.invalidSize) {
            _ = try await downloader.download(manifest: manifest, resumeData: nil, progress: { _ in })
        }

        let untrusted = testManifest(downloadBytes: Int64(data.count), url: URL(string: "https://example.com/model.tar.bz2")!)
        #expect(!untrusted.verifySignature())
        await #expect(throws: ModelPackageError.untrustedHost) {
            _ = try await downloader.download(manifest: untrusted, resumeData: nil, progress: { _ in })
        }

        ModelURLProtocol.setFailure(.networkConnectionLost)
        await #expect(throws: SecureModelDownloader.DownloadInterruption.self) {
            _ = try await downloader.download(manifest: manifest, resumeData: nil, progress: { _ in })
        }

        ModelURLProtocol.setResponse(status: 200, data: data, delay: 1)
        let cancelledDownload = Task {
            try await downloader.download(manifest: manifest, resumeData: nil, progress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(50))
        await downloader.cancel()
        await #expect(throws: SecureModelDownloader.DownloadCancellation.self) {
            _ = try await cancelledDownload.value
        }

        ModelURLProtocol.setResponse(status: 200, data: data)
        let retry = try await downloader.download(manifest: manifest, resumeData: nil, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: retry) }
        #expect(try Data(contentsOf: retry) == data)
    }

    @Test @MainActor
    func realOfficialDownloadVerifyInstallAndOfflineProbeWhenEnabled() async throws {
        let sentinel = URL(filePath: "/tmp/AudiobookMaker-Run-Official-Kokoro-Download")
        guard FileManager.default.fileExists(atPath: sentinel.path) else { return }
        let root = URL(
            filePath: "/tmp/AudiobookMaker-Kokoro-Official-Install-Acceptance",
            directoryHint: .isDirectory
        )
        let directories = AppDirectories(
            root: root.appending(path: "ApplicationSupport", directoryHint: .isDirectory),
            cacheRoot: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
        try directories.createIfNeeded()
        let recorder = ModelInstallEventRecorder()
        let manager = ModelPackageManager(
            directories: directories,
            eventHandler: { event in await recorder.append(event) },
            runtimeProbe: { _ in
                let runtime = await MainActor.run {
                    KokoroTTSRuntimeClient(directories: directories)
                }
                let capabilities = try await runtime.capabilities()
                guard capabilities.voices.count == 103 else {
                    throw RuntimeError.incompatibleRuntime
                }
            }
        )

        let started = Date()
        try await manager.install()
        let destination = try await manager.validate()
        let elapsed = Date().timeIntervalSince(started)
        let events = await recorder.snapshot()
        #expect(events.first?.state == .downloading)
        #expect(events.contains { $0.state == .verifying })
        #expect(events.contains { $0.state == .installing })
        #expect(events.last?.state == .installed)
        #expect(FileManager.default.fileExists(
            atPath: destination.appending(path: ".audiobookmaker-receipt.json").path
        ))

        let runtime = KokoroTTSRuntimeClient(directories: directories)
        #expect(try await runtime.capabilities().voices.count == 103)
        let report = "url=\(TTSModelCatalog.kokoro.downloadURL.absoluteString)\n" +
            "sha256=\(TTSModelCatalog.kokoro.sha256)\n" +
            "bytes=\(TTSModelCatalog.kokoro.downloadBytes)\n" +
            "elapsed_seconds=\(elapsed)\n" +
            "installed_path=\(destination.path)\n"
        try report.write(
            to: root.appending(path: "completed.txt"),
            atomically: true,
            encoding: .utf8
        )
        Attachment.record(report, named: "Kokoro 官方下载安装验收.txt")
        try? FileManager.default.removeItem(at: sentinel)
    }

    @Test @MainActor func realKokoroSmokeTestWhenArchiveIsProvided() async throws {
        let fallback = "/tmp/kokoro-int8-multi-lang-v1_1.tar.bz2"
        guard let archivePath = ProcessInfo.processInfo.environment["KOKORO_MODEL_ARCHIVE"]
                ?? (FileManager.default.fileExists(atPath: fallback) ? fallback : nil) else { return }
        let root = FileManager.default.temporaryDirectory.appending(path: "Kokoro-Smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(root: root.appending(path: "ApplicationSupport"), cacheRoot: root.appending(path: "Caches"))
        try directories.createIfNeeded()
        let destination = try directories.modelVersionDirectory(id: TTSModelCatalog.kokoroID, version: TTSModelCatalog.kokoro.version)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archivePath, "-C", destination.deletingLastPathComponent().path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let extracted = destination.deletingLastPathComponent().appending(path: "kokoro-int8-multi-lang-v1_1")
        try FileManager.default.moveItem(at: extracted, to: destination)

        let runtime = KokoroTTSRuntimeClient(directories: directories)
        let capabilities = try await runtime.capabilities()
        #expect(capabilities.voices.count == 103)
        let output = root.appending(path: "smoke.caf")
        let result = try await runtime.synthesize(SynthesisRequest(
            text: "你好，这是 Kokoro 在本机运行的测试。",
            languageCode: "zh-CN",
            voiceIdentifier: "zf_001",
            outputURL: output,
            modelID: TTSModelCatalog.kokoroID,
            modelVersion: TTSModelCatalog.kokoro.version,
            purpose: .preview
        ))
        #expect(result.sampleRate == 24_000)
        #expect(result.durationSeconds > 0)
        #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).count == 1)

        let longText = String(repeating: "中国与世界正在变化。科技、经济与文化彼此连接。", count: 18)
        let cancellationID = UUID()
        let cancelledOutput = root.appending(path: "cancelled.caf")
        let cancellationStarted = Date()
        let synthesis = Task {
            try await runtime.synthesize(SynthesisRequest(
                requestID: cancellationID,
                text: longText,
                languageCode: "zh-CN",
                voiceIdentifier: "zf_001",
                outputURL: cancelledOutput,
                modelID: TTSModelCatalog.kokoroID,
                modelVersion: TTSModelCatalog.kokoro.version
            ))
        }
        try await Task.sleep(for: .milliseconds(100))
        await runtime.cancel(requestID: cancellationID)
        do {
            _ = try await synthesis.value
            Issue.record("Kokoro synthesis completed instead of honoring cancellation")
        } catch RuntimeError.cancelled {
            // Expected: the native progress callback observed the stop request.
        } catch {
            Issue.record("Unexpected Kokoro cancellation error: \(error)")
        }
        let cancellationSeconds = Date().timeIntervalSince(cancellationStarted)
        #expect(cancellationSeconds < 10)
        #expect(!FileManager.default.fileExists(atPath: cancelledOutput.path))

        let timedRuntime = KokoroTTSRuntimeClient(
            directories: directories,
            synthesisTimeout: .milliseconds(20)
        )
        let timedOutput = root.appending(path: "timed-out.caf")
        let timeoutStarted = Date()
        await #expect(throws: RuntimeError.timedOut) {
            _ = try await timedRuntime.synthesize(SynthesisRequest(
                text: longText,
                languageCode: "zh-CN",
                voiceIdentifier: "zf_001",
                outputURL: timedOutput,
                modelID: TTSModelCatalog.kokoroID,
                modelVersion: TTSModelCatalog.kokoro.version
            ))
        }
        let timeoutSeconds = Date().timeIntervalSince(timeoutStarted)
        #expect(timeoutSeconds < 20)
        #expect(!FileManager.default.fileExists(atPath: timedOutput.path))
        #if arch(arm64)
        let nativeArchitecture = "arm64"
        #elseif arch(x86_64)
        let nativeArchitecture = "x86_64"
        #else
        let nativeArchitecture = "unknown"
        #endif
        Attachment.record(
            "\(nativeArchitecture) Kokoro cancellation: \(cancellationSeconds) s\n" +
            "\(nativeArchitecture) Kokoro timeout stop: \(timeoutSeconds) s",
            named: "Kokoro cancellation and timeout.txt"
        )
    }

    private func testManifest(
        downloadBytes: Int64,
        url: URL = TTSModelCatalog.kokoro.downloadURL,
        requiredPaths: [String] = []
    ) -> DownloadableModelManifest {
        DownloadableModelManifest(
            id: TTSModelCatalog.kokoroID,
            displayName: "Test",
            version: "test",
            runtimeVersion: "test",
            downloadURL: url,
            downloadBytes: downloadBytes,
            expandedBytes: downloadBytes,
            sha256: "test",
            requiredPaths: requiredPaths,
            signatureBase64: ""
        )
    }
}

private actor ModelInstallEventRecorder {
    private var events: [ModelInstallEvent] = []

    func append(_ event: ModelInstallEvent) { events.append(event) }

    func snapshot() -> [ModelInstallEvent] { events }
}

private final class ModelURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (
        status: 200,
        data: Data(),
        delay: 0.0,
        error: URLError?.none
    )

    static func setResponse(status: Int, data: Data, delay: TimeInterval = 0) {
        lock.withLock { response = (status, data, delay, nil) }
    }

    static func setFailure(_ code: URLError.Code) {
        lock.withLock { response = (0, Data(), 0, URLError(code)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let value = Self.lock.withLock { Self.response }
        if value.delay > 0 { Thread.sleep(forTimeInterval: value.delay) }
        if let error = value.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: value.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(value.data.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
