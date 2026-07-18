import Foundation
import Testing
@testable import AudiobookMaker

struct StorageSecurityTests {
    @Test
    func relativePathResolverRejectsTraversalAbsoluteAndControlCharacters() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = AppDirectories(
            root: root.appending(path: "App", directoryHint: .isDirectory),
            cacheRoot: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
        try directories.createIfNeeded()

        #expect(throws: AppDirectoryError.unsafeRelativePath) {
            _ = try directories.resolve(relativePath: "../outside.txt")
        }
        #expect(throws: AppDirectoryError.unsafeRelativePath) {
            _ = try directories.resolve(relativePath: "/tmp/outside.txt")
        }
        #expect(throws: AppDirectoryError.unsafeRelativePath) {
            _ = try directories.resolve(relativePath: "Books\\..\\outside.txt")
        }
        #expect(throws: AppDirectoryError.unsafeRelativePath) {
            _ = try directories.resolve(relativePath: "Books/unsafe\u{0}.txt")
        }
    }

    @Test
    func symlinkInsideManagedRootCannotEscapeContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appending(path: "App", directoryHint: .isDirectory)
        let outside = root.appending(path: "Outside", directoryHint: .isDirectory)
        let directories = AppDirectories(
            root: managed,
            cacheRoot: root.appending(path: "Caches", directoryHint: .isDirectory)
        )
        try directories.createIfNeeded()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = directories.books.appending(path: "escape", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(throws: AppDirectoryError.unsafeRelativePath) {
            _ = try directories.resolve(relativePath: "Books/escape/secret.txt")
        }
        #expect(throws: AppDirectoryError.unsafeRelativePath) {
            _ = try directories.relativePath(for: link.appending(path: "secret.txt"))
        }
    }
}
