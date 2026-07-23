import CryptoKit
import Foundation
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
@MainActor
struct ModelPackageManagerMultiModelTests {
    @Test("A signed snapshot installs multiple files atomically with model-scoped events")
    func snapshotInstall() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = fixture.manifest(id: "test/snapshot", paths: ["config.json", "weights/model.bin"])
        SnapshotURLProtocol.configure(data: fixture.payload)
        let recorder = ModelInstallEventRecorder2()
        let manager = fixture.manager { event in await recorder.append(event) }

        try await manager.install(manifest)

        let installed = try await manager.validate(manifest)
        #expect(try Data(contentsOf: installed.appending(path: "config.json")) == fixture.payload)
        #expect(try Data(contentsOf: installed.appending(path: "weights/model.bin")) == fixture.payload)
        #expect(FileManager.default.fileExists(atPath: installed.appending(path: ".audiobookmaker-receipt.json").path))
        let events = await recorder.snapshot()
        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.modelID == manifest.id })
        #expect(events.last?.state == .installed)
    }

    @Test("Only the active model can be cancelled and a second install is rejected")
    func concurrentInstallAndScopedCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.manifest(id: "test/first", paths: ["model.bin"])
        let second = fixture.manifest(id: "test/second", paths: ["model.bin"])
        SnapshotURLProtocol.configure(data: fixture.payload, delay: 0.3)
        let manager = fixture.manager()
        let task = Task { try await manager.install(first) }
        try await Task.sleep(for: .milliseconds(40))

        await #expect(throws: ModelPackageError.installInProgress(first.id)) {
            try await manager.install(second)
        }
        await manager.cancel(modelID: second.id)
        try await Task.sleep(for: .milliseconds(20))
        await manager.cancel(modelID: first.id)
        await #expect(throws: ModelPackageError.cancelled) { try await task.value }
    }

    @Test("Snapshot paths cannot escape staging and low disk capacity fails before networking")
    func pathAndCapacityGuards() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        SnapshotURLProtocol.configure(data: fixture.payload)

        let unsafe = fixture.manifest(id: "test/unsafe", paths: ["../escape"])
        await #expect(throws: ModelPackageError.invalidManifest) {
            try await fixture.manager().install(unsafe)
        }

        let valid = fixture.manifest(id: "test/capacity", paths: ["model.bin"])
        let required = valid.downloadBytes + valid.stagingBytes + Int64(512 * 1_024 * 1_024)
        await #expect(throws: ModelPackageError.insufficientSpace(required: required, available: 0)) {
            try await fixture.manager(availableCapacity: 0).install(valid)
        }
    }

    @Test("A mismatched artifact hash never replaces an existing version")
    func checksumAndAtomicReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var manifest = fixture.manifest(id: "test/atomic", paths: ["model.bin"], sha256: String(repeating: "0", count: 64))
        SnapshotURLProtocol.configure(data: fixture.payload)
        let existing = try fixture.directories.modelVersionDirectory(id: manifest.id, version: manifest.version)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existing.appending(path: "old.marker"))

        await #expect(throws: ModelPackageError.checksumMismatch) {
            try await fixture.manager().install(manifest)
        }
        #expect(try Data(contentsOf: existing.appending(path: "old.marker")) == Data("old".utf8))

        manifest = fixture.manifest(id: "test/atomic", paths: ["model.bin"])
        try await fixture.manager().install(manifest)
        #expect(!FileManager.default.fileExists(atPath: existing.appending(path: "old.marker").path))
        #expect(try Data(contentsOf: existing.appending(path: "model.bin")) == fixture.payload)
    }

    @Test("Startup recovery removes only model staging content")
    func stagingRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = fixture.directories.modelStaging.appending(path: "stale")
        let installed = fixture.directories.models.appending(path: "preserved")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try await fixture.manager().recoverStaging()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: installed.path))
    }

    @Test("Redirects require HTTPS and an exact host from the signed manifest")
    func redirectAllowlist() {
        let hosts: Set<String> = [
            "huggingface.co", "cdn-lfs.huggingface.co", "cas-bridge.xethub.hf.co",
            "us.aws.cdn.hf.co"
        ]
        #expect(DownloadDelegate.isAllowedRedirect(
            URL(string: "https://cas-bridge.xethub.hf.co/blob"), allowedHosts: hosts
        ))
        #expect(DownloadDelegate.isAllowedRedirect(
            URL(string: "https://us.aws.cdn.hf.co/xet-bridge-us/blob"), allowedHosts: hosts
        ))
        #expect(!DownloadDelegate.isAllowedRedirect(
            URL(string: "http://huggingface.co/model"), allowedHosts: hosts
        ))
        #expect(!DownloadDelegate.isAllowedRedirect(
            URL(string: "https://huggingface.co.attacker.example/model"), allowedHosts: hosts
        ))
    }

    @Test("An incompatible process is rejected before any model request starts")
    func incompatiblePlatformDoesNotDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        SnapshotURLProtocol.configure(data: fixture.payload)
        let manifest = fixture.manifest(
            id: "test/apple-silicon-only",
            paths: ["model.bin"],
            platformRequirement: .nativeAppleSilicon
        )
        await #expect(throws: ModelPackageError.incompatiblePlatform) {
            try await fixture.manager(platformSupported: false).install(manifest)
        }
        #expect(SnapshotURLProtocol.requestCount == 0)
    }

    @Test("Model requests contain no book, preview, voice or generated-audio data")
    func requestPrivacy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        SnapshotURLProtocol.configure(data: fixture.payload)
        let manifest = fixture.manifest(id: "test/privacy", paths: ["model.bin"])
        try await fixture.manager().install(manifest)

        let requests = SnapshotURLProtocol.requestSummaries
        #expect(requests.count == 1)
        #expect(requests[0].contains("AudiobookMaker/1 ModelInstaller"))
        for sensitive in ["李光耀观天下.epub", "这是试听文本", "vivian", "generated.caf"] {
            #expect(!requests[0].contains(sensitive))
        }
    }

    @Test("An installed version cannot be removed while an unfinished job references it")
    func referencedVersionRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        SnapshotURLProtocol.configure(data: fixture.payload)
        let manifest = fixture.manifest(id: "test/referenced", paths: ["model.bin"])
        try await fixture.manager().install(manifest)

        await #expect(throws: ModelPackageError.modelInUse(manifest.id)) {
            try await fixture.manager(isReferenced: true).remove(manifest)
        }
        _ = try await fixture.manager().validate(manifest)
        try await fixture.manager(isReferenced: false).remove(manifest)
        await #expect(throws: ModelPackageError.missingRequiredFile("model.bin")) {
            _ = try await fixture.manager().validate(manifest)
        }
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let directories: AppDirectories
    let payload = Data("verified-snapshot-artifact".utf8)

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ModelSnapshotTests-\(UUID().uuidString)")
        directories = AppDirectories(root: root.appending(path: "App"), cacheRoot: root.appending(path: "Cache"))
        try directories.createIfNeeded()
    }

    func manifest(
        id: String,
        paths: [String],
        sha256: String? = nil,
        platformRequirement: RuntimePlatformRequirement = .anyMac
    ) -> DownloadableModelManifest {
        let digest = sha256 ?? SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let artifacts = paths.enumerated().map { index, path in
            ModelArtifactManifest(
                relativePath: path,
                downloadURL: URL(string: "https://huggingface.co/test/model/resolve/revision/file-\(index)")!,
                downloadBytes: Int64(payload.count),
                sha256: digest
            )
        }
        let totalBytes = Int64(payload.count) * Int64(paths.count)
        let sourceURL = URL(string: "https://huggingface.co/test/model")!
        let downloadURL = artifacts[0].downloadURL
        return DownloadableModelManifest(
            id: id,
            displayName: "Test Snapshot",
            version: "revision+tokenizer",
            runtimeVersion: "test",
            downloadURL: downloadURL,
            downloadBytes: totalBytes,
            expandedBytes: totalBytes,
            sha256: digest,
            requiredPaths: paths,
            signatureBase64: "fixture",
            formatVersion: 2,
            variant: "fixture",
            platformRequirement: platformRequirement,
            minimumSystemMajorVersion: 0,
            runtimeRevision: "fixture",
            licenseIdentifier: "Apache-2.0",
            sourceURL: sourceURL,
            allowedHosts: ["huggingface.co"],
            stagingBytes: totalBytes,
            artifacts: artifacts
        )
    }

    func manager(
        availableCapacity: Int64 = .max,
        platformSupported: Bool = true,
        isReferenced: Bool = false,
        eventHandler: @escaping ModelPackageManager.EventHandler = { _ in }
    ) -> ModelPackageManager {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SnapshotURLProtocol.self]
        return ModelPackageManager(
            directories: directories,
            eventHandler: eventHandler,
            platformSupport: .init(snapshotProvider: {
                .init(
                    isNativeAppleSilicon: platformSupported,
                    operatingSystemVersion: .init(majorVersion: 26, minorVersion: 0, patchVersion: 0),
                    hasMetalDevice: platformSupported,
                    hasRuntimeResources: platformSupported
                )
            }),
            downloader: SecureModelDownloader(configuration: configuration),
            availableCapacity: { _ in availableCapacity },
            manifestVerifier: { _ in true },
            referenceCheck: { _, _ in isReferenced }
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor ModelInstallEventRecorder2 {
    private var events: [ModelInstallEvent] = []
    func append(_ event: ModelInstallEvent) { events.append(event) }
    func snapshot() -> [ModelInstallEvent] { events }
}

private final class SnapshotURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (data: Data(), delay: 0.0)
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var summaries: [String] = []

    static var requestCount: Int { lock.withLock { requests } }
    static var requestSummaries: [String] { lock.withLock { summaries } }

    static func configure(data: Data, delay: TimeInterval = 0) {
        lock.withLock {
            response = (data, delay)
            requests = 0
            summaries = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let value = Self.lock.withLock {
            Self.requests += 1
            let headers = self.request.allHTTPHeaderFields ?? [:]
            Self.summaries.append("\(self.request.url?.absoluteString ?? "") \(headers)")
            return Self.response
        }
        if value.delay > 0 { Thread.sleep(forTimeInterval: value.delay) }
        guard !Thread.current.isCancelled else { return }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(value.data.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
