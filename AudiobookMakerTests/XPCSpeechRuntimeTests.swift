import AVFoundation
import Foundation
import Testing
@testable import AudiobookMaker

@Suite(.serialized)
struct XPCSpeechRuntimeTests {
    @Test @MainActor
    func compatibleHandshakeTransfersAudioFileAndSupportsIdempotentCancel() async throws {
        let fixture = try XPCFixture()
        defer { fixture.stop() }
        let client = XPCSpeechRuntimeClient(
            endpoint: fixture.listener.endpoint,
            directories: fixture.directories,
            expectedRuntimeID: fixture.service.runtimeID,
            timeout: .seconds(2)
        )
        let capabilities = try await client.capabilities()
        #expect(capabilities.maximumTextLength == 36)
        #expect(capabilities.runtimeID == fixture.service.runtimeID)

        let requestID = UUID()
        let output = fixture.directories.runtime.appending(path: "xpc-result.caf")
        let result = try await client.synthesize(SynthesisRequest(
            requestID: requestID,
            text: "XPC 语音",
            languageCode: "zh-CN",
            outputURL: output
        ))
        #expect(result.audioURL == output)
        #expect(result.durationSeconds > 0)
        #expect(FileManager.default.fileExists(atPath: output.path))

        await client.cancel(requestID: requestID)
        await client.cancel(requestID: requestID)
        #expect(fixture.service.cancelCount == 1)
        client.invalidate()
    }

    @Test @MainActor
    func rejectsWrongIdentityVersionAndOutsidePath() async throws {
        let identityFixture = try XPCFixture(protocolVersion: 999)
        defer { identityFixture.stop() }
        let incompatible = XPCSpeechRuntimeClient(
            endpoint: identityFixture.listener.endpoint,
            directories: identityFixture.directories,
            expectedRuntimeID: identityFixture.service.runtimeID,
            timeout: .seconds(1)
        )
        await #expect(throws: RuntimeError.incompatibleRuntime) {
            _ = try await incompatible.capabilities()
        }
        incompatible.invalidate()

        let outsideFixture = try XPCFixture(replyOutsideRoot: true)
        defer { outsideFixture.stop() }
        let outside = XPCSpeechRuntimeClient(
            endpoint: outsideFixture.listener.endpoint,
            directories: outsideFixture.directories,
            expectedRuntimeID: outsideFixture.service.runtimeID,
            timeout: .seconds(1)
        )
        let output = outsideFixture.directories.runtime.appending(path: "safe.caf")
        await #expect(throws: RuntimeError.invalidAudio) {
            _ = try await outside.synthesize(SynthesisRequest(text: "安全边界", outputURL: output))
        }
        outside.invalidate()
    }

    @Test @MainActor
    func reportsTimeoutAndConnectionInvalidation() async throws {
        let timeoutFixture = try XPCFixture(dropSynthesisReply: true)
        defer { timeoutFixture.stop() }
        let timeoutClient = XPCSpeechRuntimeClient(
            endpoint: timeoutFixture.listener.endpoint,
            directories: timeoutFixture.directories,
            expectedRuntimeID: timeoutFixture.service.runtimeID,
            timeout: .milliseconds(80)
        )
        let output = timeoutFixture.directories.runtime.appending(path: "timeout.caf")
        await #expect(throws: RuntimeError.timedOut) {
            _ = try await timeoutClient.synthesize(SynthesisRequest(text: "超时", outputURL: output))
        }
        timeoutClient.invalidate()

        let invalidatedFixture = try XPCFixture()
        let invalidatedClient = XPCSpeechRuntimeClient(
            endpoint: invalidatedFixture.listener.endpoint,
            directories: invalidatedFixture.directories,
            expectedRuntimeID: invalidatedFixture.service.runtimeID,
            timeout: .seconds(1)
        )
        invalidatedFixture.stopListenerOnly()
        await #expect(throws: RuntimeError.connectionInvalidated) {
            _ = try await invalidatedClient.capabilities()
        }
        invalidatedClient.invalidate()
        invalidatedFixture.cleanup()
    }

    @Test
    func secureDTOsRoundTrip() throws {
        let request = XPCSynthesisRequestDTO(
            requestID: UUID(),
            text: "正文",
            languageCode: "zh-CN",
            voiceIdentifier: nil,
            outputRelativePath: "Runtime/result.caf"
        )
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: request,
            requiringSecureCoding: true
        )
        let decoded = try #require(try NSKeyedUnarchiver.unarchivedObject(
            ofClass: XPCSynthesisRequestDTO.self,
            from: data
        ))
        #expect(decoded.requestID == request.requestID)
        #expect(decoded.text == request.text)
        #expect(decoded.outputRelativePath == request.outputRelativePath)
    }
}

private final class XPCFixture: @unchecked Sendable {
    let root: URL
    let directories: AppDirectories
    let service: MockXPCSpeechService
    let delegate: MockXPCListenerDelegate
    let listener: NSXPCListener

    init(
        protocolVersion: Int = XPCSpeechRuntimeClient.protocolVersion,
        replyOutsideRoot: Bool = false,
        dropSynthesisReply: Bool = false
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        directories = AppDirectories(
            root: root.appending(path: "ApplicationSupport", directoryHint: .isDirectory),
            cacheRoot: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
        try directories.createIfNeeded()
        service = MockXPCSpeechService(
            directories: directories,
            protocolVersion: protocolVersion,
            replyOutsideRoot: replyOutsideRoot,
            dropSynthesisReply: dropSynthesisReply
        )
        delegate = MockXPCListenerDelegate(service: service)
        listener = .anonymous()
        listener.delegate = delegate
        listener.resume()
    }

    func stopListenerOnly() { listener.invalidate() }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func stop() { stopListenerOnly(); cleanup() }
}

private nonisolated final class MockXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: MockXPCSpeechService
    init(service: MockXPCSpeechService) { self.service = service }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: TTSXPCServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private nonisolated final class MockXPCSpeechService: NSObject, TTSXPCServiceProtocol, @unchecked Sendable {
    let runtimeID = "com.audiobookmaker.mock-xpc"
    private let directories: AppDirectories
    private let protocolVersion: Int
    private let replyOutsideRoot: Bool
    private let dropSynthesisReply: Bool
    private let lock = NSLock()
    private var cancellations: Set<UUID> = []

    var cancelCount: Int { lock.withLock { cancellations.count } }

    init(
        directories: AppDirectories,
        protocolVersion: Int,
        replyOutsideRoot: Bool,
        dropSynthesisReply: Bool
    ) {
        self.directories = directories
        self.protocolVersion = protocolVersion
        self.replyOutsideRoot = replyOutsideRoot
        self.dropSynthesisReply = dropSynthesisReply
    }

    func handshake(withReply reply: @escaping (XPCHandshakeReply) -> Void) {
        reply(XPCHandshakeReply(
            protocolVersion: protocolVersion,
            runtimeID: runtimeID,
            displayName: "Mock XPC",
            runtimeVersion: "1",
            maximumTextLength: 36,
            recommendedConcurrency: 1,
            supportsImmediateCancellation: true
        ))
    }

    func synthesize(
        _ request: XPCSynthesisRequestDTO,
        withReply reply: @escaping (XPCSynthesisReplyDTO) -> Void
    ) {
        if dropSynthesisReply { return }
        if replyOutsideRoot {
            reply(XPCSynthesisReplyDTO(
                requestID: request.requestID,
                outputRelativePath: "../outside.caf",
                durationSeconds: 0.1,
                sampleRate: 22_050,
                channelCount: 1
            ))
            return
        }
        do {
            let output = try directories.resolve(relativePath: request.outputRelativePath)
            try Self.writeTone(to: output)
            reply(XPCSynthesisReplyDTO(
                requestID: request.requestID,
                outputRelativePath: request.outputRelativePath,
                durationSeconds: 0.1,
                sampleRate: 22_050,
                channelCount: 1
            ))
        } catch {
            reply(XPCSynthesisReplyDTO(
                requestID: request.requestID,
                outputRelativePath: nil,
                errorCode: "runtime.invalidOutputPath",
                errorMessage: error.localizedDescription
            ))
        }
    }

    func cancel(_ requestID: NSUUID, withReply reply: @escaping () -> Void) {
        _ = lock.withLock { cancellations.insert(requestID as UUID) }
        reply()
    }

    private static func writeTone(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sampleRate = 22_050.0
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleRate / 10)
        ))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = sin(2 * .pi * 440 * Float(frame) / Float(sampleRate)) * 0.05
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
