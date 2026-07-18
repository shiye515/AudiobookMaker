import AVFoundation
import Foundation

nonisolated private final class ThrowingContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: sending Value) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(returning: value)
    }

    func resume(throwing error: sending any Error) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(throwing: error)
    }
}

nonisolated private func makeXPCErrorHandler<Value: Sendable>(
    for gate: ThrowingContinuationGate<Value>
) -> @Sendable (any Error) -> Void {
    { _ in gate.resume(throwing: RuntimeError.connectionInvalidated) }
}

nonisolated private func makeXPCReplyHandler<Value: Sendable>(
    for gate: ThrowingContinuationGate<Value>
) -> @Sendable (Value) -> Void {
    { value in gate.resume(returning: value) }
}

nonisolated private func makeXPCVoidReplyHandler(
    for continuation: CheckedContinuation<Void, Never>
) -> @Sendable () -> Void {
    { continuation.resume() }
}

nonisolated private func ignoreXPCError(_: any Error) {}

@objc nonisolated protocol TTSXPCServiceProtocol {
    func handshake(withReply reply: @escaping (XPCHandshakeReply) -> Void)
    func synthesize(
        _ request: XPCSynthesisRequestDTO,
        withReply reply: @escaping (XPCSynthesisReplyDTO) -> Void
    )
    func cancel(_ requestID: NSUUID, withReply reply: @escaping () -> Void)
}

nonisolated final class XPCHandshakeReply: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }
    let protocolVersion: Int
    let runtimeID: String
    let displayName: String
    let runtimeVersion: String
    let maximumTextLength: Int
    let recommendedConcurrency: Int
    let supportsImmediateCancellation: Bool

    init(
        protocolVersion: Int,
        runtimeID: String,
        displayName: String,
        runtimeVersion: String,
        maximumTextLength: Int,
        recommendedConcurrency: Int,
        supportsImmediateCancellation: Bool
    ) {
        self.protocolVersion = protocolVersion
        self.runtimeID = runtimeID
        self.displayName = displayName
        self.runtimeVersion = runtimeVersion
        self.maximumTextLength = maximumTextLength
        self.recommendedConcurrency = recommendedConcurrency
        self.supportsImmediateCancellation = supportsImmediateCancellation
    }

    required init?(coder: NSCoder) {
        guard let runtimeID = coder.decodeObject(of: NSString.self, forKey: "runtimeID") as String?,
              let displayName = coder.decodeObject(of: NSString.self, forKey: "displayName") as String?,
              let runtimeVersion = coder.decodeObject(of: NSString.self, forKey: "runtimeVersion") as String?
        else { return nil }
        protocolVersion = coder.decodeInteger(forKey: "protocolVersion")
        self.runtimeID = runtimeID
        self.displayName = displayName
        self.runtimeVersion = runtimeVersion
        maximumTextLength = coder.decodeInteger(forKey: "maximumTextLength")
        recommendedConcurrency = coder.decodeInteger(forKey: "recommendedConcurrency")
        supportsImmediateCancellation = coder.decodeBool(forKey: "supportsImmediateCancellation")
    }

    func encode(with coder: NSCoder) {
        coder.encode(protocolVersion, forKey: "protocolVersion")
        coder.encode(runtimeID as NSString, forKey: "runtimeID")
        coder.encode(displayName as NSString, forKey: "displayName")
        coder.encode(runtimeVersion as NSString, forKey: "runtimeVersion")
        coder.encode(maximumTextLength, forKey: "maximumTextLength")
        coder.encode(recommendedConcurrency, forKey: "recommendedConcurrency")
        coder.encode(supportsImmediateCancellation, forKey: "supportsImmediateCancellation")
    }
}

nonisolated final class XPCSynthesisRequestDTO: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }
    let requestID: UUID
    let text: String
    let languageCode: String?
    let voiceIdentifier: String?
    let outputRelativePath: String

    init(
        requestID: UUID,
        text: String,
        languageCode: String?,
        voiceIdentifier: String?,
        outputRelativePath: String
    ) {
        self.requestID = requestID
        self.text = text
        self.languageCode = languageCode
        self.voiceIdentifier = voiceIdentifier
        self.outputRelativePath = outputRelativePath
    }

    required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSUUID.self, forKey: "requestID") as UUID?,
              let text = coder.decodeObject(of: NSString.self, forKey: "text") as String?,
              let outputRelativePath = coder.decodeObject(
                of: NSString.self,
                forKey: "outputRelativePath"
              ) as String?
        else { return nil }
        self.requestID = requestID
        self.text = text
        languageCode = coder.decodeObject(of: NSString.self, forKey: "languageCode") as String?
        voiceIdentifier = coder.decodeObject(of: NSString.self, forKey: "voiceIdentifier") as String?
        self.outputRelativePath = outputRelativePath
    }

    func encode(with coder: NSCoder) {
        coder.encode(requestID as NSUUID, forKey: "requestID")
        coder.encode(text as NSString, forKey: "text")
        coder.encode(languageCode as NSString?, forKey: "languageCode")
        coder.encode(voiceIdentifier as NSString?, forKey: "voiceIdentifier")
        coder.encode(outputRelativePath as NSString, forKey: "outputRelativePath")
    }
}

nonisolated final class XPCSynthesisReplyDTO: NSObject, NSSecureCoding, @unchecked Sendable {
    static var supportsSecureCoding: Bool { true }
    let requestID: UUID
    let outputRelativePath: String?
    let durationSeconds: Double
    let sampleRate: Double
    let channelCount: Int
    let errorCode: String?
    let errorMessage: String?

    init(
        requestID: UUID,
        outputRelativePath: String?,
        durationSeconds: Double = 0,
        sampleRate: Double = 0,
        channelCount: Int = 0,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.outputRelativePath = outputRelativePath
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    required init?(coder: NSCoder) {
        guard let requestID = coder.decodeObject(of: NSUUID.self, forKey: "requestID") as UUID?
        else { return nil }
        self.requestID = requestID
        outputRelativePath = coder.decodeObject(of: NSString.self, forKey: "outputRelativePath") as String?
        durationSeconds = coder.decodeDouble(forKey: "durationSeconds")
        sampleRate = coder.decodeDouble(forKey: "sampleRate")
        channelCount = coder.decodeInteger(forKey: "channelCount")
        errorCode = coder.decodeObject(of: NSString.self, forKey: "errorCode") as String?
        errorMessage = coder.decodeObject(of: NSString.self, forKey: "errorMessage") as String?
    }

    func encode(with coder: NSCoder) {
        coder.encode(requestID as NSUUID, forKey: "requestID")
        coder.encode(outputRelativePath as NSString?, forKey: "outputRelativePath")
        coder.encode(durationSeconds, forKey: "durationSeconds")
        coder.encode(sampleRate, forKey: "sampleRate")
        coder.encode(channelCount, forKey: "channelCount")
        coder.encode(errorCode as NSString?, forKey: "errorCode")
        coder.encode(errorMessage as NSString?, forKey: "errorMessage")
    }
}

@MainActor
final class XPCSpeechRuntimeClient: TTSRuntimeClient {
    nonisolated static let protocolVersion = 1

    private let connection: NSXPCConnection
    private let directories: AppDirectories
    private let expectedRuntimeID: String
    private let timeout: Duration
    private var cachedCapabilities: RuntimeCapabilities?
    private var cancelledRequestIDs: Set<UUID> = []

    init(
        endpoint: NSXPCListenerEndpoint,
        directories: AppDirectories,
        expectedRuntimeID: String,
        timeout: Duration = .seconds(120)
    ) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        self.directories = directories
        self.expectedRuntimeID = expectedRuntimeID
        self.timeout = timeout
        connection.remoteObjectInterface = NSXPCInterface(with: TTSXPCServiceProtocol.self)
        connection.resume()
    }

    func invalidate() {
        cachedCapabilities = nil
        connection.invalidate()
    }

    func capabilities() async throws -> RuntimeCapabilities {
        if let cachedCapabilities { return cachedCapabilities }
        let reply = try await withTimeout { try await self.requestHandshake() }
        guard reply.protocolVersion == Self.protocolVersion,
              reply.runtimeID == expectedRuntimeID,
              reply.maximumTextLength > 0,
              reply.recommendedConcurrency > 0 else {
            throw RuntimeError.incompatibleRuntime
        }
        let result = RuntimeCapabilities(
            runtimeID: reply.runtimeID,
            displayName: reply.displayName,
            version: reply.runtimeVersion,
            maximumTextLength: reply.maximumTextLength,
            recommendedConcurrency: reply.recommendedConcurrency,
            supportsImmediateCancellation: reply.supportsImmediateCancellation,
            outputFileType: "caf"
        )
        cachedCapabilities = result
        return result
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisResult {
        let capabilities = try await capabilities()
        guard !request.text.isEmpty else { throw RuntimeError.invalidText }
        guard request.text.count <= capabilities.maximumTextLength else {
            throw RuntimeError.textTooLong(maximum: capabilities.maximumTextLength)
        }
        let relativePath: String
        do {
            relativePath = try directories.relativePath(for: request.outputURL)
        } catch {
            throw RuntimeError.invalidOutputPath
        }
        let dto = XPCSynthesisRequestDTO(
            requestID: request.requestID,
            text: request.text,
            languageCode: request.languageCode,
            voiceIdentifier: request.voiceIdentifier,
            outputRelativePath: relativePath
        )
        let reply = try await withTaskCancellationHandler {
            try await withTimeout { try await self.requestSynthesis(dto) }
        } onCancel: {
            Task { await self.cancel(requestID: request.requestID) }
        }
        guard reply.requestID == request.requestID else {
            throw RuntimeError.connectionInvalidated
        }
        if let errorCode = reply.errorCode {
            throw Self.runtimeError(code: errorCode, message: reply.errorMessage)
        }
        guard reply.outputRelativePath == relativePath,
              let outputRelativePath = reply.outputRelativePath,
              let outputURL = try? directories.resolve(relativePath: outputRelativePath),
              outputURL == request.outputURL.standardizedFileURL,
              FileManager.default.isReadableFile(atPath: outputURL.path),
              reply.durationSeconds > 0,
              reply.sampleRate > 0,
              reply.channelCount > 0 else {
            throw RuntimeError.invalidAudio
        }
        let asset = AVURLAsset(url: outputURL)
        guard let duration = try? await asset.load(.duration),
              duration.isNumeric,
              duration.seconds > 0,
              (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false else {
            throw RuntimeError.invalidAudio
        }
        return SynthesisResult(
            requestID: request.requestID,
            audioURL: outputURL,
            durationSeconds: reply.durationSeconds,
            sampleRate: reply.sampleRate,
            channelCount: reply.channelCount
        )
    }

    func cancel(requestID: UUID) async {
        guard cancelledRequestIDs.insert(requestID).inserted else { return }
        guard let proxy = remoteProxy() else { return }
        await withCheckedContinuation { continuation in
            proxy.cancel(requestID as NSUUID, withReply: makeXPCVoidReplyHandler(for: continuation))
        }
    }

    private func requestHandshake() async throws -> XPCHandshakeReply {
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler(
                makeXPCErrorHandler(for: gate)
            ) as? any TTSXPCServiceProtocol else {
                gate.resume(throwing: RuntimeError.connectionInvalidated)
                return
            }
            proxy.handshake(withReply: makeXPCReplyHandler(for: gate))
        }
    }

    private func requestSynthesis(_ request: XPCSynthesisRequestDTO) async throws -> XPCSynthesisReplyDTO {
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler(
                makeXPCErrorHandler(for: gate)
            ) as? any TTSXPCServiceProtocol else {
                gate.resume(throwing: RuntimeError.connectionInvalidated)
                return
            }
            proxy.synthesize(request, withReply: makeXPCReplyHandler(for: gate))
        }
    }

    private func remoteProxy() -> (any TTSXPCServiceProtocol)? {
        connection.remoteObjectProxyWithErrorHandler(ignoreXPCError) as? any TTSXPCServiceProtocol
    }

    private func withTimeout<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let timeout = timeout
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ThrowingContinuationGate(continuation)
            Task {
                do {
                    gate.resume(returning: try await operation())
                } catch {
                    gate.resume(throwing: error)
                }
            }
            Task {
                do {
                    try await Task.sleep(for: timeout)
                    gate.resume(throwing: RuntimeError.timedOut)
                } catch is CancellationError {
                    return
                } catch {
                    gate.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func runtimeError(code: String, message: String?) -> RuntimeError {
        switch code {
        case "runtime.modelUnavailable": .modelUnavailable
        case "runtime.invalidText": .invalidText
        case "runtime.invalidAudio": .invalidAudio
        case "runtime.cancelled": .cancelled
        case "runtime.timedOut": .timedOut
        default: .synthesisFailed(message ?? code)
        }
    }
}
