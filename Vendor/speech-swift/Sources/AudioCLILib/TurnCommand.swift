import Foundation
import ArgumentParser
import SpeechVAD
import AudioCommon

public struct TurnCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "turn",
        abstract: "Estimate whether a recorded utterance is a finished turn (Smart Turn v3.2)"
    )

    @Argument(help: "Audio file with one user turn (WAV, any sample rate); the last 8 s are used")
    public var audioFile: String

    @Option(name: .shortAndLong, help: "Model ID on HuggingFace")
    public var model: String = SmartTurnModel.defaultModelId

    @Option(name: .long, help: "Local directory holding smart_turn.mlmodelc and config.json (offline; skips the download)")
    public var modelDir: String?

    @Option(name: .long, help: "Probability at or above which the turn counts as complete")
    public var threshold: Float = SmartTurnModel.defaultThreshold

    @Flag(name: .long, help: "Output as JSON")
    public var json: Bool = false

    public init() {}

    public func run() throws {
        #if canImport(CoreML)
        try runAsync {
            let audio = try AudioFileLoader.load(
                url: URL(fileURLWithPath: audioFile), targetSampleRate: SmartTurnModel.sampleRate)
            if !json {
                let duration = formatDuration(audio.count, sampleRate: SmartTurnModel.sampleRate)
                print("Loaded \(audioFile) (\(duration)s)")
                print("Loading Smart Turn model: \(model)")
            }
            let turnModel = try await SmartTurnModel.fromPretrained(
                modelId: model,
                cacheDir: modelDir.map { URL(fileURLWithPath: $0, isDirectory: true) },
                offlineMode: modelDir != nil,
                progressHandler: json ? nil : reportProgress
            )

            let start = Date()
            let probability = try turnModel.turnCompleteProbability(
                audio: audio, sampleRate: SmartTurnModel.sampleRate)
            let elapsedMs = Date().timeIntervalSince(start) * 1000
            let complete = probability >= threshold

            if json {
                let payload: [String: Any] = [
                    "probability": Double(String(format: "%.4f", probability))!,
                    "threshold": Double(String(format: "%.2f", threshold))!,
                    "complete": complete,
                    "latency_ms": Double(String(format: "%.1f", elapsedMs))!,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) {
                    print(text)
                }
            } else {
                print(String(
                    format: "Turn complete probability: %.3f (%@, threshold %.2f, %.1f ms)",
                    probability, complete ? "complete" : "incomplete", threshold, elapsedMs))
            }
        }
        #else
        throw AudioModelError.invalidConfiguration(
            model: "Smart Turn v3.2", reason: "CoreML not available on this platform")
        #endif
    }
}
