import AVFoundation
import Testing
@testable import AudiobookMaker

struct TTSRuntimeTests {
    @Test func chunkerPreservesOrderAndLength() throws {
        let text = "第一句很短。第二句也不长，但是我们需要继续写一些文字！最后一段结束。"
        let chunks = try TextChunker.chunks(text: text, maximumLength: 12)

        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 12 })
        #expect(chunks.joined().replacingOccurrences(of: " ", with: "") == text.replacingOccurrences(of: " ", with: ""))
    }

    @Test func chunkerRejectsEmptyText() {
        #expect(throws: RuntimeError.invalidText) {
            try TextChunker.chunks(text: "  \n", maximumLength: 20)
        }
    }

    @Test func mockRuntimeCreatesReadableAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "mock.caf")
        let runtime = await MockTTSRuntimeClient()
        let request = SynthesisRequest(text: "用于测试的短文本", outputURL: output)

        let result = try await runtime.synthesize(request)
        #expect(FileManager.default.fileExists(atPath: result.audioURL.path))
        #expect(result.durationSeconds > 0)
        #expect(result.channelCount == 1)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
    }

    @Test func mockRuntimeReportsDeterministicProgressTimeoutAndCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = MockTTSRuntimeClient.Configuration()
        configuration.delay = .milliseconds(80)
        configuration.progressStepCount = 4
        let runtime = await MockTTSRuntimeClient(configuration: configuration)
        let request = SynthesisRequest(
            text: "进度测试",
            outputURL: directory.appending(path: "progress.caf")
        )
        _ = try await runtime.synthesize(request)
        #expect(await runtime.progressEvents().map(\.fractionCompleted) == [0, 0.25, 0.5, 0.75, 1])

        var timeoutConfiguration = MockTTSRuntimeClient.Configuration()
        timeoutConfiguration.error = .timedOut
        let timeoutRuntime = await MockTTSRuntimeClient(configuration: timeoutConfiguration)
        await #expect(throws: RuntimeError.timedOut) {
            _ = try await timeoutRuntime.synthesize(SynthesisRequest(
                text: "超时测试",
                outputURL: directory.appending(path: "timeout.caf")
            ))
        }

        var cancellationConfiguration = MockTTSRuntimeClient.Configuration()
        cancellationConfiguration.delay = .seconds(1)
        let cancellationRuntime = await MockTTSRuntimeClient(configuration: cancellationConfiguration)
        let cancellationRequest = SynthesisRequest(
            text: "取消测试",
            outputURL: directory.appending(path: "cancel.caf")
        )
        let task = Task { try await cancellationRuntime.synthesize(cancellationRequest) }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消后的 mock 合成不应成功")
        } catch let error as RuntimeError {
            #expect(error == .cancelled)
        }
    }

    @Test @MainActor func systemRuntimeCreatesReadableAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "system.caf")
        let runtime = SystemSpeechRuntimeClient()
        let request = SynthesisRequest(
            text: "这是苹果系统语音的自动测试。",
            languageCode: "zh-CN",
            outputURL: output
        )

        let result = try await runtime.synthesize(request)
        #expect(result.durationSeconds > 0)
        #expect(result.sampleRate > 0)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}
