import Foundation

nonisolated struct DeletedBookToken: Identifiable, Equatable, Sendable {
    let id: UUID
    let originalBookID: UUID
    let title: String
    let trashURL: URL
}

nonisolated struct TrashCoordinator: Sendable {
    let directories: AppDirectories

    func moveBookToTrash(bookID: UUID, title: String) throws -> DeletedBookToken {
        let source = directories.bookDirectory(id: bookID)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw RepositoryError.bookNotFound
        }
        let tokenID = UUID()
        let destination = directories.trash
            .appending(path: tokenID.uuidString, directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: source, to: destination)
        return DeletedBookToken(
            id: tokenID,
            originalBookID: bookID,
            title: title,
            trashURL: destination
        )
    }

    func restoreDirectory(_ token: DeletedBookToken) throws {
        let destination = directories.bookDirectory(id: token.originalBookID)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.moveItem(at: token.trashURL, to: destination)
    }

    func sourceURL(for token: DeletedBookToken) -> URL {
        token.trashURL.appending(path: "source.epub")
    }

    func purge(_ token: DeletedBookToken) {
        try? FileManager.default.removeItem(at: token.trashURL)
    }
}
