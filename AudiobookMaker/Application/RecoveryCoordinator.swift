import Foundation

nonisolated struct RecoveryReport: Equatable, Sendable {
    let interruptedBookCount: Int
    let removedPartialCount: Int
    let invalidArtifactCount: Int
}

nonisolated struct RecoveryCoordinator: Sendable {
    let repository: LibraryRepository
    let directories: AppDirectories

    func recover() async throws -> RecoveryReport {
        let database = try await repository.recoverTransientState()
        return try await Task.detached(priority: .utility) {
            let removed = try removePartialArtifacts()
            var invalid = 0
            for artifact in database.artifacts {
                do {
                    let audioURL = try directories.resolve(relativePath: artifact.artifactRelativePath)
                    if !artifact.isCommitted,
                       !FileManager.default.fileExists(atPath: audioURL.path) {
                        continue
                    }
                    let textURL = try directories.resolve(relativePath: artifact.textRelativePath)
                    let text = try String(contentsOf: textURL, encoding: .utf8)
                    let duration = try await M4BValidator.validate(
                        url: audioURL,
                        expectedTitle: artifact.bookTitle,
                        expectedChapterTitle: artifact.chapterTitle,
                        expectedFullText: text
                    )
                    if !artifact.isCommitted {
                        try await repository.commitRecoveredArtifact(
                            chapterID: artifact.id,
                            artifactRelativePath: artifact.artifactRelativePath,
                            durationSeconds: duration
                        )
                    }
                } catch {
                    if !artifact.isCommitted,
                       let audioURL = try? directories.resolve(
                           relativePath: artifact.artifactRelativePath
                       ), !FileManager.default.fileExists(atPath: audioURL.path) {
                        continue
                    }
                    invalid += 1
                    try? await repository.invalidateRecoveredArtifact(
                        chapterID: artifact.id,
                        message: error.localizedDescription
                    )
                }
            }
            return RecoveryReport(
                interruptedBookCount: database.interruptedBookCount,
                removedPartialCount: removed,
                invalidArtifactCount: invalid
            )
        }.value
    }

    private func removePartialArtifacts() throws -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directories.root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return 0 }
        var removed = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.contains(".partial.") || name.hasSuffix(".partial") else { continue }
            try FileManager.default.removeItem(at: url)
            removed += 1
        }
        return removed
    }
}
