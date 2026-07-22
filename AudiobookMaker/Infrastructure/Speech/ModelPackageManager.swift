import CryptoKit
import Foundation

nonisolated enum ModelPackageError: Error, StableAppError, Equatable, Sendable {
    case invalidManifest
    case untrustedHost
    case invalidSize
    case checksumMismatch
    case unsafeArchive
    case missingRequiredFile(String)
    case insufficientSpace(required: Int64, available: Int64)
    case incompatiblePlatform
    case installInProgress(String)
    case modelInUse(String)
    case installFailed(String)
    case cancelled

    var code: String {
        switch self {
        case .invalidManifest: "model.invalidManifest"
        case .untrustedHost: "model.untrustedHost"
        case .invalidSize: "model.invalidSize"
        case .checksumMismatch: "model.checksumMismatch"
        case .unsafeArchive: "model.unsafeArchive"
        case .missingRequiredFile: "model.missingFile"
        case .insufficientSpace: "model.insufficientSpace"
        case .incompatiblePlatform: "model.incompatiblePlatform"
        case .installInProgress: "model.installInProgress"
        case .modelInUse: "model.inUse"
        case .installFailed: "model.installFailed"
        case .cancelled: "model.cancelled"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "模型清单签名无效。"
        case .untrustedHost: "模型下载被重定向到不受信任的网站。"
        case .invalidSize: "模型包大小与清单不符。"
        case .checksumMismatch: "模型包校验失败，请重新下载。"
        case .unsafeArchive: "模型包包含不安全的文件路径或链接。"
        case let .missingRequiredFile(path): "模型缺少必需文件：\(path)"
        case let .insufficientSpace(required, available):
            "模型安装空间不足（需要 \(required) 字节，可用 \(available) 字节）。"
        case .incompatiblePlatform: "此模型需要原生 Apple Silicon、受支持的 macOS 和 Metal。"
        case let .installInProgress(modelID): "模型 \(modelID) 正在安装，请稍候。"
        case let .modelInUse(modelID): "模型 \(modelID) 仍被未完成任务使用，不能删除。"
        case let .installFailed(message): "模型安装失败：\(message)"
        case .cancelled: "模型下载已取消。"
        }
    }
}

nonisolated struct ModelInstallEvent: Sendable, Equatable {
    let modelID: String
    let state: ModelInstallationState
    let progress: Double
    let message: String?

    init(
        modelID: String = TTSModelCatalog.kokoroID,
        state: ModelInstallationState,
        progress: Double,
        message: String?
    ) {
        self.modelID = modelID
        self.state = state
        self.progress = progress
        self.message = message
    }
}

nonisolated private struct InstalledModelReceipt: Codable, Sendable, Equatable {
    nonisolated struct FileEntry: Codable, Sendable, Equatable {
        let path: String
        let sha256: String
    }

    let formatVersion: Int
    let modelID: String
    let modelVersion: String
    let archiveSHA256: String
    let files: [FileEntry]
}

nonisolated private struct ModelResumeEnvelope: Codable, Sendable, Equatable {
    let modelID: String
    let modelVersion: String
    let downloadURL: String
    let archiveSHA256: String
    let artifactRelativePath: String?
    let resumeData: Data

    func matches(_ manifest: DownloadableModelManifest, artifact: ModelArtifactManifest) -> Bool {
        modelID == manifest.id
            && modelVersion == manifest.version
            && downloadURL == artifact.downloadURL.absoluteString
            && archiveSHA256 == artifact.sha256
            && (artifactRelativePath == nil || artifactRelativePath == artifact.relativePath)
    }
}

actor ModelPackageManager {
    typealias EventHandler = @Sendable (ModelInstallEvent) async -> Void
    typealias RuntimeProbe = @Sendable (DownloadableModelManifest) async throws -> Void
    typealias AvailableCapacity = @Sendable (URL) throws -> Int64
    typealias ManifestVerifier = @Sendable (DownloadableModelManifest) -> Bool
    typealias ReferenceCheck = @Sendable (String, String) async throws -> Bool

    private let directories: AppDirectories
    private let downloader: SecureModelDownloader
    private let eventHandler: EventHandler
    private let runtimeProbe: RuntimeProbe
    private let platformSupport: SpeechSwiftPlatformSupport
    private let availableCapacity: AvailableCapacity
    private let manifestVerifier: ManifestVerifier
    private let referenceCheck: ReferenceCheck
    private var activeModelID: String?

    init(
        directories: AppDirectories,
        eventHandler: @escaping EventHandler = { _ in },
        runtimeProbe: @escaping RuntimeProbe = { _ in },
        platformSupport: SpeechSwiftPlatformSupport = SpeechSwiftPlatformSupport(),
        downloader: SecureModelDownloader = SecureModelDownloader(),
        availableCapacity: @escaping AvailableCapacity = { url in
            try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? 0
        },
        manifestVerifier: @escaping ManifestVerifier = { $0.verifySignature() },
        referenceCheck: @escaping ReferenceCheck = { _, _ in false }
    ) {
        self.directories = directories
        self.eventHandler = eventHandler
        self.runtimeProbe = runtimeProbe
        self.platformSupport = platformSupport
        self.downloader = downloader
        self.availableCapacity = availableCapacity
        self.manifestVerifier = manifestVerifier
        self.referenceCheck = referenceCheck
    }

    func install(_ manifest: DownloadableModelManifest = TTSModelCatalog.kokoro) async throws {
        guard manifestVerifier(manifest) else { throw ModelPackageError.invalidManifest }
        guard activeModelID == nil else {
            throw ModelPackageError.installInProgress(activeModelID ?? manifest.id)
        }
        if manifest.platformRequirement == .nativeAppleSilicon,
           !platformSupport.status().isSupported {
            throw ModelPackageError.incompatiblePlatform
        }
        activeModelID = manifest.id
        defer { activeModelID = nil }
        try ensureDiskCapacity(for: manifest)

        let resumeURL = try directories.modelResumeDataURL(id: manifest.id, version: manifest.version)
        let resumeEnvelope = try? JSONDecoder().decode(
            ModelResumeEnvelope.self,
            from: Data(contentsOf: resumeURL)
        )
        await emit(manifest, state: .downloading, progress: 0)
        do {
            if manifest.effectiveArtifacts.count == 1,
               manifest.effectiveArtifacts[0].kind == .archive {
                let artifact = manifest.effectiveArtifacts[0]
                let resumeData = resumeEnvelope?.matches(manifest, artifact: artifact) == true
                    ? resumeEnvelope?.resumeData
                    : nil
                if resumeEnvelope != nil, resumeData == nil {
                    try? FileManager.default.removeItem(at: resumeURL)
                }
                let archive = try await downloader.download(
                    artifact: artifact,
                    allowedHosts: manifest.allowedHosts,
                    resumeData: resumeData,
                    progress: { [eventHandler] progress in
                        Task {
                            await eventHandler(.init(
                                modelID: manifest.id,
                                state: .downloading,
                                progress: progress,
                                message: nil
                            ))
                        }
                    }
                )
                defer { try? FileManager.default.removeItem(at: archive) }
                await emit(manifest, state: .verifying, progress: 1)
                guard try Self.hash(url: archive) == artifact.sha256 else {
                    throw ModelPackageError.checksumMismatch
                }
                await emit(manifest, state: .installing, progress: 1)
                try installVerifiedArchive(archive, manifest: manifest)
            } else {
                try await installSnapshot(
                    manifest,
                    resumeEnvelope: resumeEnvelope,
                    resumeURL: resumeURL
                )
            }
            try? FileManager.default.removeItem(at: resumeURL)
            do {
                try await runtimeProbe(manifest)
            } catch {
                let destination = try directories.modelVersionDirectory(id: manifest.id, version: manifest.version)
                try? FileManager.default.removeItem(at: destination)
                throw ModelPackageError.installFailed("运行时无法加载该模型：\(error.localizedDescription)")
            }
            await emit(manifest, state: .installed, progress: 1)
        } catch let error as SecureModelDownloader.DownloadCancellation {
            try? saveResumeData(
                error.resumeData,
                to: resumeURL,
                manifest: manifest,
                artifact: error.artifact
            )
            await emit(manifest, state: .notInstalled, progress: 0)
            throw ModelPackageError.cancelled
        } catch let interruption as SecureModelDownloader.DownloadInterruption {
            try? saveResumeData(
                interruption.resumeData,
                to: resumeURL,
                manifest: manifest,
                artifact: interruption.artifact
            )
            let error = ModelPackageError.installFailed(interruption.underlying.localizedDescription)
            await emit(manifest, state: .failed, progress: 0, message: error.localizedDescription)
            throw error
        } catch {
            await emit(manifest, state: .failed, progress: 0, message: error.localizedDescription)
            throw error
        }
    }

    func cancel() async { await downloader.cancel() }

    func cancel(modelID: String) async {
        guard activeModelID == modelID else { return }
        await downloader.cancel()
    }

    func remove(_ manifest: DownloadableModelManifest) async throws {
        guard activeModelID != manifest.id else {
            throw ModelPackageError.installInProgress(manifest.id)
        }
        let isReferenced = try await referenceCheck(manifest.id, manifest.version)
        guard !isReferenced else {
            throw ModelPackageError.modelInUse(manifest.id)
        }
        let destination = try directories.modelVersionDirectory(id: manifest.id, version: manifest.version)
        let staging = try directories.modelStagingDirectory(id: manifest.id, version: manifest.version)
        let resume = try directories.modelResumeDataURL(id: manifest.id, version: manifest.version)
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.removeItem(at: resume)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        await emit(manifest, state: .notInstalled, progress: 0)
    }

    private func emit(
        _ manifest: DownloadableModelManifest,
        state: ModelInstallationState,
        progress: Double,
        message: String? = nil
    ) async {
        await eventHandler(.init(
            modelID: manifest.id,
            state: state,
            progress: progress,
            message: message
        ))
    }

    private func saveResumeData(
        _ data: Data?,
        to url: URL,
        manifest: DownloadableModelManifest,
        artifact: ModelArtifactManifest
    ) throws {
        guard let data, !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let envelope = ModelResumeEnvelope(
            modelID: manifest.id,
            modelVersion: manifest.version,
            downloadURL: artifact.downloadURL.absoluteString,
            archiveSHA256: artifact.sha256,
            artifactRelativePath: artifact.relativePath,
            resumeData: data
        )
        try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
    }

    private func installSnapshot(
        _ manifest: DownloadableModelManifest,
        resumeEnvelope: ModelResumeEnvelope?,
        resumeURL: URL
    ) async throws {
        let staging = try directories.modelStagingDirectory(id: manifest.id, version: manifest.version)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let total = max(Int64(1), manifest.downloadBytes)
        var completedBytes: Int64 = 0

        for artifact in manifest.effectiveArtifacts {
            guard artifact.kind == .file,
                  Self.isSafeArchivePath(artifact.relativePath) else {
                throw ModelPackageError.invalidManifest
            }
            let destination = staging.appending(path: artifact.relativePath).standardizedFileURL
            guard destination.pathComponents.starts(with: staging.standardizedFileURL.pathComponents) else {
                throw ModelPackageError.unsafeArchive
            }
            if FileManager.default.fileExists(atPath: destination.path),
               (try? Self.hash(url: destination)) == artifact.sha256 {
                completedBytes += artifact.downloadBytes
                continue
            }
            try? FileManager.default.removeItem(at: destination)
            let resumeData = resumeEnvelope?.matches(manifest, artifact: artifact) == true
                ? resumeEnvelope?.resumeData
                : nil
            let completedBeforeArtifact = completedBytes
            let downloaded = try await downloader.download(
                artifact: artifact,
                allowedHosts: manifest.allowedHosts,
                resumeData: resumeData,
                progress: { [eventHandler] artifactProgress in
                    let weighted = min(
                        1,
                        Double(completedBeforeArtifact) / Double(total)
                            + artifactProgress * Double(artifact.downloadBytes) / Double(total)
                    )
                    Task {
                        await eventHandler(.init(
                            modelID: manifest.id,
                            state: .downloading,
                            progress: weighted,
                            message: artifact.relativePath
                        ))
                    }
                }
            )
            defer { try? FileManager.default.removeItem(at: downloaded) }
            await emit(
                manifest,
                state: .verifying,
                progress: Double(completedBytes + artifact.downloadBytes) / Double(total),
                message: artifact.relativePath
            )
            guard try Self.hash(url: downloaded) == artifact.sha256 else {
                throw ModelPackageError.checksumMismatch
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: downloaded, to: destination)
            completedBytes += artifact.downloadBytes
            try? FileManager.default.removeItem(at: resumeURL)
        }

        for path in manifest.requiredPaths
        where !FileManager.default.fileExists(atPath: staging.appending(path: path).path) {
            throw ModelPackageError.missingRequiredFile(path)
        }
        await emit(manifest, state: .installing, progress: 1)
        try Self.writeReceipt(at: staging, manifest: manifest)
        try commit(staging: staging, manifest: manifest)
    }

    private func commit(staging: URL, manifest: DownloadableModelManifest) throws {
        let destination = try directories.modelVersionDirectory(id: manifest.id, version: manifest.version)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    private func ensureDiskCapacity(for manifest: DownloadableModelManifest) throws {
        let available = try availableCapacity(directories.root)
        let safety = max(Int64(512 * 1_024 * 1_024), manifest.expandedBytes / 10)
        let required = manifest.downloadBytes + manifest.stagingBytes + safety
        guard available >= required else {
            throw ModelPackageError.insufficientSpace(required: required, available: available)
        }
    }

    func validate(_ manifest: DownloadableModelManifest = TTSModelCatalog.kokoro) throws -> URL {
        let root = try directories.modelVersionDirectory(id: manifest.id, version: manifest.version)
        for path in manifest.requiredPaths {
            let url = root.appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ModelPackageError.missingRequiredFile(path)
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.pathComponents.starts(with: root.standardizedFileURL.pathComponents) else {
                throw ModelPackageError.unsafeArchive
            }
        }
        try Self.verifyReceipt(at: root, manifest: manifest)
        return root
    }

    func recoverStaging() throws {
        let contents = try FileManager.default.contentsOfDirectory(at: directories.modelStaging, includingPropertiesForKeys: nil)
        for url in contents { try FileManager.default.removeItem(at: url) }
    }

    func installVerifiedArchive(_ archive: URL, manifest: DownloadableModelManifest) throws {
        let staging = try directories.modelStagingDirectory(id: manifest.id, version: manifest.version)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let listing = try Self.runTar(["-tvf", archive.path])
        try Self.validateListing(listing, maximumExpandedBytes: manifest.expandedBytes)
        _ = try Self.runTar(["-xf", archive.path, "-C", staging.path])
        guard let archiveRoot = manifest.effectiveArtifacts.first?.archiveRoot,
              Self.isSafeArchivePath(archiveRoot) else {
            throw ModelPackageError.invalidManifest
        }
        let packageRoot = staging.appending(path: archiveRoot, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: packageRoot.appending(path: "dict/generate_user_dict.py"))
        for path in manifest.requiredPaths where !FileManager.default.fileExists(atPath: packageRoot.appending(path: path).path) {
            throw ModelPackageError.missingRequiredFile(path)
        }
        try Self.writeReceipt(at: packageRoot, manifest: manifest)
        try commit(staging: packageRoot, manifest: manifest)
    }

    static func validateListing(_ listing: String, maximumExpandedBytes: Int64 = .max) throws {
        let lines = listing.split(separator: "\n")
        guard lines.count <= 20_000 else { throw ModelPackageError.unsafeArchive }
        var expandedBytes: Int64 = 0
        for line in lines {
            let text = String(line)
            let fields = text.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 6,
                  let path = fields.last.map(String.init),
                  Self.isSafeArchivePath(path),
                  let type = text.first, type != "l", type != "h" else {
                throw ModelPackageError.unsafeArchive
            }
            if type != "d" {
                guard let size = Int64(fields[4]), size >= 0,
                      expandedBytes <= maximumExpandedBytes - size else {
                    throw ModelPackageError.invalidSize
                }
                expandedBytes += size
            }
            let permissions = text.prefix(10)
            let allowedTool = path.hasSuffix("/dict/generate_user_dict.py")
            if type != "d", permissions.contains("x"), !allowedTool {
                throw ModelPackageError.unsafeArchive
            }
        }
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in components.enumerated() {
            if component == "." || component == ".." { return false }
            if component.isEmpty, index != components.indices.last { return false }
        }
        return true
    }

    private static func runTar(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe(); let error = Pipe()
        process.standardOutput = output; process.standardError = error
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ModelPackageError.installFailed(message)
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static func hash(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func writeReceipt(at root: URL, manifest: DownloadableModelManifest) throws {
        let receipt = InstalledModelReceipt(
            formatVersion: 1,
            modelID: manifest.id,
            modelVersion: manifest.version,
            archiveSHA256: manifest.sha256,
            files: try receiptEntries(at: root)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(receipt).write(
            to: root.appending(path: ".audiobookmaker-receipt.json"),
            options: .atomic
        )
    }

    private static func verifyReceipt(
        at root: URL,
        manifest: DownloadableModelManifest
    ) throws {
        let receiptURL = root.appending(path: ".audiobookmaker-receipt.json")
        guard let data = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(InstalledModelReceipt.self, from: data),
              receipt.formatVersion == 1,
              receipt.modelID == manifest.id,
              receipt.modelVersion == manifest.version,
              receipt.archiveSHA256 == manifest.sha256 else {
            throw ModelPackageError.checksumMismatch
        }
        let actual = try receiptEntries(at: root)
        guard actual == receipt.files else { throw ModelPackageError.checksumMismatch }
    }

    private static func receiptEntries(at root: URL) throws -> [InstalledModelReceipt.FileEntry] {
        let standardizedRoot = root.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw ModelPackageError.installFailed("无法读取模型目录。") }
        var entries: [InstalledModelReceipt.FileEntry] = []
        while let url = enumerator.nextObject() as? URL {
            if url.lastPathComponent == ".audiobookmaker-receipt.json" { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ModelPackageError.unsafeArchive }
            guard values.isRegularFile == true else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.pathComponents.starts(with: standardizedRoot.pathComponents) else {
                throw ModelPackageError.unsafeArchive
            }
            let prefix = standardizedRoot.path.hasSuffix("/")
                ? standardizedRoot.path
                : standardizedRoot.path + "/"
            guard resolved.path.hasPrefix(prefix) else { throw ModelPackageError.unsafeArchive }
            let relative = String(resolved.path.dropFirst(prefix.count))
            entries.append(.init(path: relative, sha256: try hash(url: resolved)))
        }
        return entries.sorted { $0.path < $1.path }
    }
}

actor SecureModelDownloader {
    struct DownloadCancellation: Error {
        let resumeData: Data?
        let artifact: ModelArtifactManifest
    }
    struct DownloadInterruption: Error, @unchecked Sendable {
        let resumeData: Data?
        let underlying: any Error
        let artifact: ModelArtifactManifest
    }
    private var activeTask: URLSessionDownloadTask?
    private var activeDelegate: DownloadDelegate?
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    func download(
        manifest: DownloadableModelManifest,
        resumeData: Data?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let artifact = manifest.effectiveArtifacts.first else {
            throw ModelPackageError.invalidManifest
        }
        return try await download(
            artifact: artifact,
            allowedHosts: manifest.allowedHosts,
            resumeData: resumeData,
            progress: progress
        )
    }

    func download(
        artifact: ModelArtifactManifest,
        allowedHosts: [String],
        resumeData: Data?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard artifact.downloadURL.scheme == "https",
              allowedHosts.contains(artifact.downloadURL.host ?? "") else {
            throw ModelPackageError.untrustedHost
        }
        configuration.httpAdditionalHeaders = ["User-Agent": "AudiobookMaker/1 ModelInstaller"]
        let delegate = DownloadDelegate(allowedHosts: Set(allowedHosts), artifact: artifact)
        activeDelegate = delegate
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer {
            activeTask = nil
            activeDelegate = nil
            session.finishTasksAndInvalidate()
        }
        let result = try await delegate.start(session: session, url: artifact.downloadURL, resumeData: resumeData, progress: progress) { task in
            activeTask = task
        }
        guard let response = result.response as? HTTPURLResponse,
              (200 ... 299).contains(response.statusCode) else {
            throw ModelPackageError.installFailed("模型服务器返回了无效的 HTTP 状态。")
        }
        guard result.response.expectedContentLength <= 0 || result.response.expectedContentLength == artifact.downloadBytes else {
            throw ModelPackageError.invalidSize
        }
        let size = (try FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? NSNumber)?.int64Value
        guard size == artifact.downloadBytes else { throw ModelPackageError.invalidSize }
        return result.url
    }

    func cancel() {
        guard let activeTask, let activeDelegate else { return }
        activeDelegate.cancel(activeTask)
    }
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(url: URL, response: URLResponse), any Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var downloadedURL: URL?
    private var explicitCancellationRequested = false
    private var rejectedRedirect = false
    private let allowedHosts: Set<String>
    private let artifact: ModelArtifactManifest

    init(allowedHosts: Set<String>, artifact: ModelArtifactManifest) {
        self.allowedHosts = allowedHosts
        self.artifact = artifact
    }

    func cancel(_ task: URLSessionDownloadTask) {
        lock.withLock { explicitCancellationRequested = true }
        task.cancel(byProducingResumeData: { [weak self] resumeData in
            guard let self else { return }
            self.finish(.failure(SecureModelDownloader.DownloadCancellation(
                resumeData: resumeData,
                artifact: self.artifact
            )))
        })
    }

    func start(
        session: URLSession,
        url: URL,
        resumeData: Data?,
        progress: @escaping @Sendable (Double) -> Void,
        created: (URLSessionDownloadTask) -> Void
    ) async throws -> (url: URL, response: URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation; self.progress = progress }
            let task = resumeData.map(session.downloadTask(withResumeData:)) ?? session.downloadTask(with: url)
            created(task); task.resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.withLock { progress }?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".tar.bz2")
            try FileManager.default.moveItem(at: location, to: copy)
            lock.withLock { downloadedURL = copy }
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if lock.withLock({ rejectedRedirect }) {
            finish(.failure(ModelPackageError.untrustedHost))
            return
        }
        if let nsError = error as NSError? {
            let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if lock.withLock({ explicitCancellationRequested }) {
                // cancel(byProducingResumeData:) completes through its dedicated
                // callback so the most complete resume data wins this race.
                return
            }
            finish(.failure(SecureModelDownloader.DownloadInterruption(
                resumeData: data,
                underlying: nsError,
                artifact: artifact
            )))
        } else if let url = lock.withLock({ downloadedURL }), let response = task.response {
            finish(.success((url, response)))
        } else { finish(.failure(ModelPackageError.installFailed("下载没有生成文件。"))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let accepted = Self.isAllowedRedirect(request.url, allowedHosts: allowedHosts)
        if !accepted { lock.withLock { rejectedRedirect = true } }
        completionHandler(accepted ? request : nil)
    }

    nonisolated static func isAllowedRedirect(_ url: URL?, allowedHosts: Set<String>) -> Bool {
        url?.scheme == "https" && allowedHosts.contains(url?.host ?? "")
    }

    private func finish(_ result: Result<(url: URL, response: URLResponse), any Error>) {
        let value = lock.withLock { () -> CheckedContinuation<(url: URL, response: URLResponse), any Error>? in
            defer {
                continuation = nil
                progress = nil
                downloadedURL = nil
                explicitCancellationRequested = false
                rejectedRedirect = false
            }
            return continuation
        }
        value?.resume(with: result)
    }
}
