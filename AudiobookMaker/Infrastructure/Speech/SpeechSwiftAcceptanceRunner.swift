import AVFoundation
import Darwin
import Darwin.Mach
import Foundation

/// Explicitly invoked release-gate runner. Normal launches never enter this path.
/// It intentionally uses the production installer, runtime, persistence and export
/// coordinators while writing all evidence beneath the caller-provided root.
@MainActor
enum SpeechSwiftAcceptanceRunner {
    static let launchArgument = "--speech-swift-acceptance"

    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelID = environment["SPEECH_SWIFT_ACCEPTANCE_MODEL"],
              let manifest = TTSModelCatalog.manifestsByID[modelID],
              manifest.platformRequirement == .nativeAppleSilicon else {
            throw AcceptanceError.invalidModel
        }
        let platform = SpeechSwiftPlatformSupport().status()
        guard platform.isSupported else { throw ModelPackageError.incompatiblePlatform }

        let workspace = URL(
            filePath: environment["AUDIOBOOKMAKER_WORKSPACE"]
                ?? FileManager.default.currentDirectoryPath,
            directoryHint: .isDirectory
        ).standardizedFileURL
        let epub = workspace.appending(path: "docs/李光耀观天下.epub")
        guard FileManager.default.fileExists(atPath: epub.path) else {
            throw AcceptanceError.missingEPUB(epub.path)
        }
        let slug = modelID.replacingOccurrences(of: "/", with: "--")
        let evidenceRoot = workspace.appending(
            path: "build/acceptance/speech-swift/runtime/\(slug)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        let dependencies = try DependencyContainer(inMemory: false, rootOverride: evidenceRoot)
        try await dependencies.repository.seedDefaults()
        _ = try await dependencies.recovery.recover()
        let audioEvidenceRoot = dependencies.directories.root.appending(
            path: "AcceptanceEvidence",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: audioEvidenceRoot,
            withIntermediateDirectories: true
        )

        let logURL = evidenceRoot.appending(path: "acceptance.log")
        try append("start model=\(modelID) version=\(manifest.version)", to: logURL)
        let manager = ModelPackageManager(
            directories: dependencies.directories,
            eventHandler: { event in
                let progress = String(format: "%.4f", event.progress)
                try? append(
                    "install model=\(event.modelID) state=\(event.state.rawValue) progress=\(progress) file=\(event.message ?? "-")",
                    to: logURL
                )
            },
            runtimeProbe: { candidate in
                let probe = await SpeechSwiftTTSRuntimeClient(directories: dependencies.directories)
                let capabilities = try await probe.capabilities(for: candidate.id)
                guard capabilities.version == candidate.version else {
                    throw RuntimeError.incompatibleRuntime
                }
                await probe.unload()
            },
            referenceCheck: { [repository = dependencies.repository] id, version in
                try await repository.hasUnfinishedJob(modelID: id, modelVersion: version)
            }
        )

        let installStart = ContinuousClock.now
        if (try? await manager.validate(manifest)) == nil {
            try await manager.install(manifest)
        }
        let installSeconds = seconds(since: installStart)
        let modelRoot = try await manager.validate(manifest)
        try await dependencies.repository.updateModelInstallState(
            id: modelID,
            event: ModelInstallEvent(modelID: modelID, state: .installed, progress: 1, message: nil)
        )
        let voice = modelID == TTSModelCatalog.cosyVoiceID ? "default" : "vivian"
        try await dependencies.repository.setVoice(modelID: modelID, voiceID: voice)
        try await dependencies.repository.setDefaultModel(id: modelID)

        let physicalMemoryBytes = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        let residentBeforeLoad = try residentMemoryBytes()
        let peakResidentURL = evidenceRoot.appending(path: "peak-resident-bytes.txt")
        let savedPeakResident = (try? String(contentsOf: peakResidentURL, encoding: .utf8))
            .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        var peakResident = max(savedPeakResident, try residentMemoryBytes())
        func sampleAndPersistPeakResident() throws {
            peakResident = max(peakResident, try residentMemoryBytes())
            try String(peakResident).write(
                to: peakResidentURL,
                atomically: true,
                encoding: .utf8
            )
        }
        try sampleAndPersistPeakResident()
        let runtime = SpeechSwiftTTSRuntimeClient(directories: dependencies.directories)
        let coldStart = ContinuousClock.now
        let capabilities = try await runtime.capabilities(for: modelID)
        let coldLoadSeconds = seconds(since: coldStart)
        guard capabilities.version == manifest.version,
              capabilities.voices.contains(where: { $0.id == voice }) else {
            throw RuntimeError.incompatibleRuntime
        }
        let hotStart = ContinuousClock.now
        let hotCapabilities = try await runtime.capabilities(for: modelID)
        let hotLoadSeconds = seconds(since: hotStart)
        guard hotCapabilities == capabilities else {
            throw RuntimeError.incompatibleRuntime
        }
        try sampleAndPersistPeakResident()

        let samples: [(String, String)] = [
            ("01-numbers", "二〇二六年七月二十二日，人民币一百二十三元四角五分。"),
            ("02-names", "李光耀谈中国、美国与东南亚未来的长期关系。"),
            ("03-mixed", "AudiobookMaker 使用 Apple Silicon 和 MLX 在本机生成语音。"),
            ("04-boundary", "第一章结束。\n\n第二章开始，这是章节边界试听。"),
            ("05-preview", "你好，这是无需联网的本机语音模型固定试听。")
        ]
        var generatedWallSeconds = 0.0
        var generatedAudioSeconds = 0.0
        var firstSegmentSeconds = 0.0
        for (index, sample) in samples.enumerated() {
            let output = audioEvidenceRoot.appending(path: "\(sample.0).caf")
            let start = ContinuousClock.now
            let result = try await runtime.synthesize(request(
                text: sample.1,
                output: output,
                modelID: modelID,
                version: manifest.version,
                voice: voice,
                purpose: .preview
            ))
            let elapsed = seconds(since: start)
            if index == 0 { firstSegmentSeconds = elapsed }
            generatedWallSeconds += elapsed
            generatedAudioSeconds += result.durationSeconds
            try await validateAudio(output)
            try sampleAndPersistPeakResident()
            try append("sample name=\(sample.0) wall=\(elapsed) audio=\(result.durationSeconds)", to: logURL)
        }

        let parsed = try EPUBParser().parse(url: epub)
        let longest = try required(parsed.chapters.max(by: { $0.plainText.count < $1.plainText.count }))
        let longText = String(longest.plainText.prefix(450))
        let longOutput = audioEvidenceRoot.appending(path: "real-epub-long-chunk.caf")
        let longStart = ContinuousClock.now
        let longResult = try await runtime.synthesize(request(
            text: longText,
            output: longOutput,
            modelID: modelID,
            version: manifest.version,
            voice: voice,
            purpose: .conversion,
            language: parsed.language
        ))
        let longSeconds = seconds(since: longStart)
        generatedWallSeconds += longSeconds
        generatedAudioSeconds += longResult.durationSeconds
        try await validateAudio(longOutput)
        try sampleAndPersistPeakResident()

        await runtime.unload()
        let residentAfterUnload = try residentMemoryBytes()
        let restarted = SpeechSwiftTTSRuntimeClient(directories: dependencies.directories)
        let restartOutput = audioEvidenceRoot.appending(path: "offline-restart.caf")
        let restartStart = ContinuousClock.now
        _ = try await restarted.synthesize(request(
            text: "模型安装完成后，应用只从已校验的本地目录恢复合成。",
            output: restartOutput,
            modelID: modelID,
            version: manifest.version,
            voice: voice,
            purpose: .preview
        ))
        let restartSeconds = seconds(since: restartStart)
        try await validateAudio(restartOutput)
        await restarted.unload()

        let sourceHash = try SHA256Hasher.hashFile(at: epub)
        let bookStartedAtURL = evidenceRoot.appending(path: "subset-started-at.txt")
        let timestampFormatter = ISO8601DateFormatter()
        let bookStartedAt: Date
        if let saved = try? String(contentsOf: bookStartedAtURL, encoding: .utf8),
           let parsed = timestampFormatter.date(from: saved.trimmingCharacters(in: .whitespacesAndNewlines)) {
            bookStartedAt = parsed
        } else {
            bookStartedAt = .now
            try timestampFormatter.string(from: bookStartedAt).write(
                to: bookStartedAtURL,
                atomically: true,
                encoding: .utf8
            )
        }
        let acceptanceBookIDURL = evidenceRoot.appending(path: "subset-book-id.txt")
        let bookID: UUID
        if let saved = try? String(contentsOf: acceptanceBookIDURL, encoding: .utf8),
           let savedID = UUID(uuidString: saved.trimmingCharacters(in: .whitespacesAndNewlines)),
           try await dependencies.repository.books().contains(where: { $0.id == savedID }) {
            bookID = savedID
        } else {
            let fullDraft = try await dependencies.importer.prepareImport(from: epub)
            let selectedChapters = try representativeChapters(from: fullDraft.chapters)
            let subsetDraft = ImportedBookDraft(
                id: fullDraft.id,
                title: "\(fullDraft.title)（验收节选）",
                author: fullDraft.author,
                languageCode: fullDraft.languageCode,
                publicationDate: fullDraft.publicationDate,
                sourceRelativePath: fullDraft.sourceRelativePath,
                sourceSHA256: fullDraft.sourceSHA256,
                coverRelativePath: fullDraft.coverRelativePath,
                totalCharacters: selectedChapters.reduce(0) { $0 + Int64($1.characterCount) },
                chapters: selectedChapters
            )
            try await dependencies.repository.importBook(subsetDraft, allowDuplicate: true)
            bookID = subsetDraft.id
            try bookID.uuidString.write(
                to: acceptanceBookIDURL,
                atomically: true,
                encoding: .utf8
            )
        }
        var snapshot = try required(
            try await dependencies.repository.books().first(where: { $0.id == bookID })
        )
        if snapshot.status == .ready {
            await dependencies.converter.start(bookID: bookID)
            try await Task.sleep(for: .seconds(2))
            await dependencies.converter.pause(bookID: bookID)
            try await waitUntilIdle(dependencies.converter, bookID: bookID)
            snapshot = try required(
                try await dependencies.repository.books().first(where: { $0.id == bookID })
            )
            guard snapshot.status == .paused else {
                throw AcceptanceError.unexpectedBookStatus(snapshot.status.rawValue)
            }
            try append("pause checkpoint accepted", to: logURL)
        }
        if snapshot.status == .paused || snapshot.status == .interrupted {
            await dependencies.converter.resume(bookID: bookID)
        }
        while await dependencies.converter.isActive(bookID: bookID) {
            snapshot = try required(
                try await dependencies.repository.books().first(where: { $0.id == bookID })
            )
            try sampleAndPersistPeakResident()
            try append(
                "book status=\(snapshot.status.rawValue) chapters=\(snapshot.chapters.count { $0.status == .completed })/\(snapshot.chapters.count) characters=\(snapshot.jobCompletedUnits ?? 0)/\(snapshot.jobTotalUnits ?? snapshot.totalCharacters)",
                to: logURL
            )
            try await Task.sleep(for: .seconds(15))
        }
        snapshot = try required(
            try await dependencies.repository.books().first(where: { $0.id == bookID })
        )
        guard snapshot.status == .completed,
              snapshot.chapters.allSatisfy({ $0.status == .completed }) else {
            throw AcceptanceError.unexpectedBookStatus(snapshot.status.rawValue)
        }
        let exportURL = evidenceRoot.appending(path: "李光耀观天下-验收节选-\(slug).m4b")
        _ = try await dependencies.exporter.export(bookID: bookID, to: exportURL)
        try await M4BValidator.validateAudiobook(
            url: exportURL,
            expectedTitle: snapshot.title,
            expectedChapterTitles: snapshot.chapters.map(\.title),
            expectsArtwork: parsed.coverData != nil
        )
        guard try SHA256Hasher.hashFile(at: epub) == sourceHash else {
            throw AcceptanceError.sourceChanged
        }
        let m4bAsset = AVURLAsset(url: exportURL)
        let m4bDurationSeconds = try await m4bAsset.load(.duration).seconds
        let subsetCompletedAtURL = evidenceRoot.appending(path: "subset-completed-at.txt")
        let subsetCompletedAt: Date
        if let saved = try? String(contentsOf: subsetCompletedAtURL, encoding: .utf8),
           let parsed = timestampFormatter.date(
               from: saved.trimmingCharacters(in: .whitespacesAndNewlines)
           ) {
            subsetCompletedAt = parsed
        } else {
            let previousMetricsURL = evidenceRoot.appending(path: "metrics.json")
            let previousMetricsData = try? Data(contentsOf: previousMetricsURL)
            let previousTimestamp = previousMetricsData
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { $0["timestamp"] as? String }
                .flatMap(timestampFormatter.date(from:))
            subsetCompletedAt = previousTimestamp ?? .now
            try timestampFormatter.string(from: subsetCompletedAt).write(
                to: subsetCompletedAtURL,
                atomically: true,
                encoding: .utf8
            )
        }
        let subsetWallSeconds = subsetCompletedAt.timeIntervalSince(bookStartedAt)
        let measuredRTF = generatedWallSeconds / max(generatedAudioSeconds, 0.001)
        let subsetWallToAudioRatio = subsetWallSeconds / max(m4bDurationSeconds, 0.001)
        let modelDiskBytes = try directoryBytes(modelRoot)
        let appBundleBytes = try directoryBytes(Bundle.main.bundleURL)
        let hardwareModel = try sysctlString("hw.model")
        let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        let gibibyte: Int64 = 1_073_741_824
        let mebibyte: Int64 = 1_048_576
        let peakResidentLimit = min(12 * gibibyte, physicalMemoryBytes * 3 / 4)
        let residentAfterUnloadLimit = max(
            residentBeforeLoad + 2 * gibibyte,
            peakResident * 7 / 10
        )
        let modelDiskLimit = manifest.expandedBytes
            + max(16 * mebibyte, manifest.expandedBytes / 20)
        var gateFailures: [String] = []
        if coldLoadSeconds > 120 { gateFailures.append("cold_load_seconds") }
        if hotLoadSeconds > 30 { gateFailures.append("hot_load_seconds") }
        if firstSegmentSeconds > 30 { gateFailures.append("first_segment_seconds") }
        if longSeconds > 180 { gateFailures.append("long_chunk_seconds") }
        if measuredRTF > 1.5 { gateFailures.append("measured_rtf") }
        if subsetWallToAudioRatio > 1.5 {
            gateFailures.append("subset_wall_to_audio_ratio")
        }
        if peakResident > peakResidentLimit { gateFailures.append("peak_resident_bytes") }
        if residentAfterUnload > residentAfterUnloadLimit {
            gateFailures.append("resident_after_unload_bytes")
        }
        if modelDiskBytes > modelDiskLimit { gateFailures.append("model_disk_bytes") }

        let metrics: [String: Any] = [
            "schema_version": 2,
            "timestamp": Date().ISO8601Format(),
            "hardware_model": hardwareModel,
            "physical_memory_bytes": physicalMemoryBytes,
            "operating_system": operatingSystem,
            "architecture": "arm64",
            "build_configuration": buildConfiguration,
            "app_bundle_bytes": appBundleBytes,
            "model_id": modelID,
            "model_version": manifest.version,
            "runtime_revision": manifest.runtimeRevision,
            "voice_id": voice,
            "epub": epub.lastPathComponent,
            "corpus_sha256": sourceHash,
            "epub_chapters": parsed.chapters.count,
            "acceptance_scope": "representative_chapter_subset",
            "cold_start_definition": "new runtime actor with no loaded model session",
            "hot_start_definition": "second capability handshake reusing the verified session",
            "fixed_sample_attempts": samples.count + 2,
            "fixed_sample_failures": 0,
            "failure_rate": 0.0,
            "acceptance_chapters": snapshot.chapters.count,
            "acceptance_chapter_indexes": snapshot.chapters.map(\.index),
            "install_or_validate_seconds": installSeconds,
            "cold_load_seconds": coldLoadSeconds,
            "hot_load_seconds": hotLoadSeconds,
            "first_segment_seconds": firstSegmentSeconds,
            "long_chunk_seconds": longSeconds,
            "offline_restart_seconds": restartSeconds,
            "measured_rtf": measuredRTF,
            "resident_before_load_bytes": residentBeforeLoad,
            "peak_resident_bytes": peakResident,
            "peak_resident_limit_bytes": peakResidentLimit,
            "resident_after_unload_bytes": residentAfterUnload,
            "resident_after_unload_limit_bytes": residentAfterUnloadLimit,
            "model_disk_bytes": modelDiskBytes,
            "model_disk_limit_bytes": modelDiskLimit,
            "book_characters": snapshot.totalCharacters,
            "subset_wall_seconds": subsetWallSeconds,
            "m4b_duration_seconds": m4bDurationSeconds,
            "subset_wall_to_audio_ratio": subsetWallToAudioRatio,
            "m4b_bytes": try exportURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,
            "release_gate_passed": gateFailures.isEmpty,
            "release_gate_failures": gateFailures
        ]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: evidenceRoot.appending(path: "metrics.json"), options: .atomic)
        guard gateFailures.isEmpty else {
            try append("release gates failed=\(gateFailures.joined(separator: ","))", to: logURL)
            throw AcceptanceError.releaseGatesFailed(gateFailures)
        }
        try append("complete", to: logURL)
    }

    private static func request(
        text: String,
        output: URL,
        modelID: String,
        version: String,
        voice: String,
        purpose: SynthesisPurpose,
        language: String? = "zh-CN"
    ) -> SynthesisRequest {
        SynthesisRequest(
            text: text,
            languageCode: language,
            voiceIdentifier: voice,
            outputURL: output,
            modelID: modelID,
            modelVersion: version,
            purpose: purpose
        )
    }

    private static func representativeChapters(
        from chapters: [ImportedChapterDraft]
    ) throws -> [ImportedChapterDraft] {
        let readable = chapters.filter { $0.characterCount >= 500 }
        guard readable.count >= 3 else {
            throw AcceptanceError.insufficientRepresentativeChapters
        }
        return [readable[0], readable[readable.count / 2], readable[readable.count - 1]]
            .sorted { $0.index < $1.index }
    }

    private static func validateAudio(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaType: .audio).count == 1,
              try await asset.load(.duration).seconds > 0 else {
            throw RuntimeError.invalidAudio
        }
    }

    private static func waitUntilIdle(_ coordinator: ConversionCoordinator, bookID: UUID) async throws {
        while await coordinator.isActive(bookID: bookID) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw AcceptanceError.missingValue }
        return value
    }

    private nonisolated static var buildConfiguration: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    private nonisolated static func sysctlString(_ name: String) throws -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            throw CocoaError(.coderReadCorrupt)
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return String(cString: buffer)
    }

    private nonisolated static func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private nonisolated static func directoryBytes(_ root: URL) throws -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private nonisolated static func residentMemoryBytes() throws -> Int64 {
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw CocoaError(.coderReadCorrupt) }
        return Int64(information.resident_size)
    }

    private nonisolated static func append(_ line: String, to url: URL) throws {
        let data = Data("\(Date().ISO8601Format()) \(line)\n".utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

nonisolated private enum AcceptanceError: LocalizedError {
    case invalidModel
    case missingEPUB(String)
    case missingValue
    case unexpectedBookStatus(String)
    case sourceChanged
    case releaseGatesFailed([String])
    case insufficientRepresentativeChapters

    var errorDescription: String? {
        switch self {
        case .invalidModel: "SPEECH_SWIFT_ACCEPTANCE_MODEL 不是受支持的 speech-swift 模型。"
        case let .missingEPUB(path): "找不到真实 EPUB：\(path)"
        case .missingValue: "真实验收缺少预期的数据。"
        case let .unexpectedBookStatus(status): "真实书籍转换以非完成状态结束：\(status)"
        case .sourceChanged: "真实 EPUB 在验收期间发生变化。"
        case let .releaseGatesFailed(failures):
            "真实验收未通过发布阈值：\(failures.joined(separator: ", "))"
        case .insufficientRepresentativeChapters:
            "真实 EPUB 中不足三个至少 500 字的代表性章节。"
        }
    }
}
