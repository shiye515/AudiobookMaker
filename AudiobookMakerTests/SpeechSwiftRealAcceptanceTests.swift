import AVFoundation
import Darwin.Mach
import Foundation
import Testing
@testable import AudiobookMaker

/// Opt-in hardware acceptance. Run one model per invocation so MLX sessions do
/// not overlap. Artifacts and verified downloads remain under build/acceptance.
@Suite(.serialized)
struct SpeechSwiftRealAcceptanceTests {
    @Test @MainActor
    func downloadColdHotPreviewLongTextOfflineRestartAndRealEPUBWhenEnabled() async throws {
        guard let modelID = ProcessInfo.processInfo.environment["SPEECH_SWIFT_ACCEPTANCE_MODEL"] else {
            return
        }
        let manifest = try #require(TTSModelCatalog.manifestsByID[modelID])
        guard manifest.platformRequirement == .nativeAppleSilicon else { return }
        let platform = SpeechSwiftPlatformSupport().status()
        #expect(platform.isSupported)

        let workspace = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let epub = workspace.appending(path: "docs/李光耀观天下.epub")
        #expect(FileManager.default.fileExists(atPath: epub.path))
        let slug = modelID.replacingOccurrences(of: "/", with: "--")
        let acceptanceRoot = workspace.appending(
            path: "build/acceptance/speech-swift/runtime/\(slug)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: acceptanceRoot, withIntermediateDirectories: true)
        let dependencies = try DependencyContainer(inMemory: false, rootOverride: acceptanceRoot)
        try await dependencies.repository.seedDefaults()

        let installStart = ContinuousClock.now
        if (try? await dependencies.modelManager.validate(manifest)) == nil {
            try await dependencies.modelManager.install(manifest)
        }
        let installSeconds = seconds(since: installStart)
        let modelRoot = try await dependencies.modelManager.validate(manifest)
        try await dependencies.repository.updateModelInstallState(
            id: modelID,
            event: ModelInstallEvent(state: .installed, progress: 1, message: nil)
        )
        let voice = modelID == TTSModelCatalog.cosyVoiceID ? "default" : "vivian"
        try await dependencies.repository.setVoice(modelID: modelID, voiceID: voice)
        try await dependencies.repository.setDefaultModel(id: modelID)

        var peakResident = try residentMemoryBytes()
        let runtime = SpeechSwiftTTSRuntimeClient(directories: dependencies.directories)
        let coldStart = ContinuousClock.now
        let capabilities = try await runtime.capabilities(for: modelID)
        let coldLoadSeconds = seconds(since: coldStart)
        #expect(capabilities.version == manifest.version)
        #expect(capabilities.voices.contains(where: { $0.id == voice }))
        peakResident = max(peakResident, try residentMemoryBytes())

        let samples: [(String, String)] = [
            ("01-numbers", "二〇二六年七月二十二日，人民币一百二十三元四角五分。"),
            ("02-names", "李光耀谈中国、美国与东南亚未来的长期关系。"),
            ("03-mixed", "AudiobookMaker 使用 Apple Silicon 和 MLX 在本机生成语音。"),
            ("04-boundary", "第一章结束。\n\n第二章开始，这是章节边界试听。"),
            ("05-preview", "你好，这是无需联网的本机语音模型固定试听。")
        ]
        var sampleDurations: [String: Double] = [:]
        var firstSegmentSeconds = 0.0
        for (index, sample) in samples.enumerated() {
            let output = acceptanceRoot.appending(path: "\(slug)-\(sample.0).caf")
            let start = ContinuousClock.now
            let result = try await runtime.synthesize(SynthesisRequest(
                text: sample.1,
                languageCode: "zh-CN",
                voiceIdentifier: voice,
                outputURL: output,
                modelID: modelID,
                modelVersion: manifest.version,
                purpose: .preview
            ))
            let elapsed = seconds(since: start)
            if index == 0 { firstSegmentSeconds = elapsed }
            sampleDurations[sample.0] = result.durationSeconds
            #expect(try await AVURLAsset(url: output).loadTracks(withMediaType: .audio).count == 1)
            peakResident = max(peakResident, try residentMemoryBytes())
        }

        let parsed = try EPUBParser().parse(url: epub)
        let longestChapter = try #require(parsed.chapters.max(by: { $0.plainText.count < $1.plainText.count }))
        let longText = String(longestChapter.plainText.prefix(450))
        let longOutput = acceptanceRoot.appending(path: "\(slug)-real-epub-long-chunk.caf")
        let longStart = ContinuousClock.now
        let longResult = try await runtime.synthesize(SynthesisRequest(
            text: longText,
            languageCode: parsed.language ?? "zh-CN",
            voiceIdentifier: voice,
            outputURL: longOutput,
            modelID: modelID,
            modelVersion: manifest.version,
            purpose: .conversion
        ))
        let longSeconds = seconds(since: longStart)
        #expect(longResult.durationSeconds > 0)
        peakResident = max(peakResident, try residentMemoryBytes())

        await runtime.unload()
        let afterUnload = try residentMemoryBytes()
        let restarted = SpeechSwiftTTSRuntimeClient(directories: dependencies.directories)
        let offlineOutput = acceptanceRoot.appending(path: "\(slug)-offline-restart.caf")
        let restartStart = ContinuousClock.now
        let offlineResult = try await restarted.synthesize(SynthesisRequest(
            text: "断开模型下载流程后，应用仍从已校验的本地目录恢复合成。",
            languageCode: "zh-CN",
            voiceIdentifier: voice,
            outputURL: offlineOutput,
            modelID: modelID,
            modelVersion: manifest.version,
            purpose: .preview
        ))
        let restartSeconds = seconds(since: restartStart)
        #expect(offlineResult.durationSeconds > 0)
        peakResident = max(peakResident, try residentMemoryBytes())
        await restarted.unload()

        let modelBytes = try directoryBytes(modelRoot)
        let audioSeconds = sampleDurations.values.reduce(0, +) + longResult.durationSeconds
        let generationSeconds = firstSegmentSeconds + longSeconds
        let metrics: [String: Any] = [
            "timestamp": Date().ISO8601Format(),
            "model_id": modelID,
            "model_version": manifest.version,
            "voice_id": voice,
            "epub": epub.lastPathComponent,
            "epub_chapters": parsed.chapters.count,
            "install_or_validate_seconds": installSeconds,
            "cold_load_seconds": coldLoadSeconds,
            "first_segment_seconds": firstSegmentSeconds,
            "long_chunk_seconds": longSeconds,
            "offline_restart_seconds": restartSeconds,
            "measured_rtf": generationSeconds / max(audioSeconds, 0.001),
            "peak_resident_bytes": peakResident,
            "resident_after_unload_bytes": afterUnload,
            "model_disk_bytes": modelBytes,
            "sample_audio_seconds": sampleDurations
        ]
        let metricsData = try JSONSerialization.data(
            withJSONObject: metrics,
            options: [.prettyPrinted, .sortedKeys]
        )
        let metricsURL = acceptanceRoot.appending(path: "metrics.json")
        try metricsData.write(to: metricsURL, options: .atomic)
        Attachment.record(String(decoding: metricsData, as: UTF8.self), named: "speech-swift 实机指标.json")
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func directoryBytes(_ root: URL) throws -> Int64 {
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

    private func residentMemoryBytes() throws -> Int64 {
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
}
