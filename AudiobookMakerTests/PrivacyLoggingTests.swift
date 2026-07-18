import Foundation
import Testing

struct PrivacyLoggingTests {
    @Test
    func productionLogStatementsContainOnlyStableIdentifiersCountsAndErrorCodes() throws {
        let repositoryRoot = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcePaths = [
            "AudiobookMaker/Application/ImportCoordinator.swift",
            "AudiobookMaker/Application/ConversionCoordinator.swift",
            "AudiobookMaker/Application/ExportCoordinator.swift",
        ]
        let forbiddenFragments = [
            "request.text", "plainText", "draft.title", "draft.author",
            "absoluteString", ".path, privacy: .public", "localizedDescription, privacy: .public",
        ]

        for sourcePath in sourcePaths {
            let source = try String(
                contentsOf: repositoryRoot.appending(path: sourcePath),
                encoding: .utf8
            )
            let logLines = source.split(separator: "\n").filter {
                $0.contains("AppLog.") && ($0.contains(".info(") || $0.contains(".error("))
            }
            #expect(!logLines.isEmpty, "缺少可审计的日志语句：\(sourcePath)")
            for line in logLines {
                for forbidden in forbiddenFragments {
                    #expect(!line.contains(forbidden), "日志可能泄露内容：\(line)")
                }
            }
        }
    }
}
