import Foundation
import Testing
@testable import AudiobookMaker

@Suite("Apple-only ZIP spike")
struct ZipSpikeTests {
    @Test("Store and Deflate entries round-trip with UTF-8 paths")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appending(path: "书籍.zip")
        let entries = [
            ZipEntryPayload(path: "mimetype", data: Data("application/epub+zip".utf8), method: .stored),
            ZipEntryPayload(path: "OEBPS/章节一.xhtml", data: Data(String(repeating: "本地有声书。", count: 100).utf8))
        ]

        try ZipSpikeWriter().write(entries: entries, to: archiveURL)
        let reader = try ZipSpikeReader(url: archiveURL)

        #expect(reader.paths == entries.map(\.path))
        for entry in entries {
            #expect(try reader.data(for: entry.path) == entry.data)
        }
    }

    @Test("EPUB 2 and EPUB 3 package shapes are readable", arguments: [2, 3])
    func epubPackage(version: Int) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appending(path: "epub-\(version).epub")
        let navigationPath = version == 3 ? "OEBPS/nav.xhtml" : "OEBPS/toc.ncx"
        let entries = [
            ZipEntryPayload(path: "mimetype", data: Data("application/epub+zip".utf8), method: .stored),
            ZipEntryPayload(path: "META-INF/container.xml", data: Data(containerXML.utf8)),
            ZipEntryPayload(path: "OEBPS/package.opf", data: Data(opf(version: version).utf8)),
            ZipEntryPayload(path: navigationPath, data: Data("<document>navigation</document>".utf8)),
            ZipEntryPayload(path: "OEBPS/chapter.xhtml", data: Data("<p>Hello EPUB \(version)</p>".utf8))
        ]

        try ZipSpikeWriter().write(entries: entries, to: archiveURL)
        let reader = try ZipSpikeReader(url: archiveURL)

        #expect(try reader.data(for: "mimetype") == Data("application/epub+zip".utf8))
        #expect(reader.paths.contains(navigationPath))
        #expect(try String(decoding: reader.data(for: "OEBPS/package.opf"), as: UTF8.self).contains("version=\"\(version).0\""))
    }

    @Test("System ditto extracts archives created by the writer")
    func systemExtraction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let output = directory.appending(path: "expanded", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appending(path: "finder-compatible.zip")
        let expected = Data("Finder Archive Utility compatibility".utf8)
        try ZipSpikeWriter().write(
            entries: [ZipEntryPayload(path: "书籍/README.txt", data: expected)],
            to: archiveURL
        )

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path(), output.path()]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: output.appending(path: "书籍/README.txt")) == expected)
    }

    private var containerXML: String {
        """
        <?xml version="1.0"?>
        <container><rootfiles><rootfile full-path="OEBPS/package.opf"/></rootfiles></container>
        """
    }

    private func opf(version: Int) -> String {
        """
        <?xml version="1.0"?>
        <package version="\(version).0"><manifest/><spine/></package>
        """
    }
}
