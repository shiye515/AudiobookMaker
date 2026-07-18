import Foundation

@main
struct M4BSpikeGenerator {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(
                Data("usage: M4BSpikeGenerator <output.m4b>\n".utf8)
            )
            throw Exit.invalidArguments
        }
        let outputURL = URL(filePath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let result = try await M4BSpikeWriter.write(to: outputURL)
        print("Wrote \(result.duration)s M4B spike to \(result.url.path)")
    }

    enum Exit: Error {
        case invalidArguments
    }
}
