import Foundation
import ArgumentParser

/// Run an async block from a synchronous ArgumentParser `run()` method.
public func runAsync(_ block: @escaping () async throws -> Void) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    Task {
        do {
            try await block()
        } catch {
            print("Error: \(error)")
            exitCode = 1
        }
        semaphore.signal()
    }

    semaphore.wait()
    if exitCode != 0 {
        throw ExitCode(exitCode)
    }
}

/// Git commit hash baked in at build time, or read from .git at runtime.
///
/// ``Process`` isn't available on iOS and the rest of Apple's embedded
/// platforms, so the CLI-only git probe is gated on macOS. iOS-bound targets
/// (libraries sharing this module via ``runAsync`` / ``reportProgress``)
/// still compile cleanly and just see ``"unknown"``.
public let buildVersion: String = {
    #if os(macOS)
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--short", "HEAD"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    if let execURL = Bundle.main.executableURL {
        process.currentDirectoryURL = execURL.deletingLastPathComponent()
    }
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let hash = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hash.isEmpty {
            return hash
        }
    } catch {}
    return "unknown"
    #else
    return "unknown"
    #endif
}()

/// Print model loading progress in a consistent format.
public func reportProgress(_ progress: Double, _ status: String) {
    print("  [\(Int(progress * 100))%] \(status)")
}

/// Format audio duration from sample count.
public func formatDuration(_ samples: Int, sampleRate: Int = 24000) -> String {
    String(format: "%.2f", Double(samples) / Double(sampleRate))
}
