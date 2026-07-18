import Foundation
import Testing
@testable import AudiobookMaker

@Suite("Safe EPUB parser")
struct EPUBParserTests {
    @Test("EPUB 3 spine and NAV titles define reading order")
    func parsesEPUB3() throws {
        let url = try makeEPUB(version: 3)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parsed = try EPUBParser().parse(url: url)

        #expect(parsed.title == "测试图书")
        #expect(parsed.author == "测试作者")
        #expect(parsed.language == "zh-CN")
        #expect(parsed.chapters.map(\.title) == ["第一章 开始", "第二章 继续"])
        #expect(parsed.chapters.map(\.plainText) == ["这是第一段。", "这是第二段。"])
    }

    @Test("EPUB 2 NCX titles follow OPF spine order")
    func parsesEPUB2() throws {
        let url = try makeEPUB(version: 2)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let parsed = try EPUBParser().parse(url: url)

        #expect(parsed.chapters.map(\.title) == ["第一章 开始", "第二章 继续"])
        #expect(parsed.chapters.map(\.sourceHref) == ["Text/one.xhtml", "Text/two.xhtml"])
    }

    @Test("Unsafe archive paths are rejected before reading content")
    func rejectsZipSlip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "unsafe.epub")
        try ZipSpikeWriter().write(
            entries: [ZipEntryPayload(path: "../outside", data: Data("bad".utf8))],
            to: url
        )

        #expect(throws: ZipContainerError.self) {
            try ZipContainerReader(url: url)
        }
    }

    @Test("Configured expansion limits stop suspicious archives")
    func enforcesExpansionLimits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "large.epub")
        try ZipSpikeWriter().write(
            entries: [ZipEntryPayload(path: "large.txt", data: Data(repeating: 65, count: 2_048))],
            to: url
        )
        let limits = ZipSecurityLimits(
            maximumEntryCount: 10,
            maximumSingleEntrySize: 1_024,
            maximumTotalUncompressedSize: 4_096,
            maximumCompressionRatio: 200
        )

        #expect(throws: ZipContainerError.self) {
            try ZipContainerReader(url: url, limits: limits)
        }
    }

    @Test("CRC corruption is detected when entry data is read")
    func rejectsBadCRC() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "bad-crc.zip")
        try ZipSpikeWriter().write(
            entries: [ZipEntryPayload(path: "text.txt", data: Data("正文".utf8))],
            to: url
        )
        try mutateFirstCentralRecord(at: url) { data, offset in
            data.writeUInt32LE(0, at: offset + 16)
        }
        let archive = try ZipContainerReader(url: url)
        #expect(throws: ZipContainerError.checksumMismatch("text.txt")) {
            _ = try archive.data(for: "text.txt")
        }
    }

    @Test("Encrypted, unsupported and symbolic-link entries are rejected")
    func rejectsUnsupportedEntryKinds() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let encrypted = directory.appending(path: "encrypted.zip")
        try makeSingleEntryArchive(at: encrypted)
        try mutateFirstCentralRecord(at: encrypted) { data, offset in
            data.writeUInt16LE(0x0801, at: offset + 8)
        }
        #expect(throws: ZipContainerError.encryptedEntry("text.txt")) {
            _ = try ZipContainerReader(url: encrypted)
        }

        let unsupported = directory.appending(path: "unsupported.zip")
        try makeSingleEntryArchive(at: unsupported)
        try mutateFirstCentralRecord(at: unsupported) { data, offset in
            data.writeUInt16LE(99, at: offset + 10)
        }
        #expect(throws: ZipContainerError.unsupportedCompressionMethod(99, "text.txt")) {
            _ = try ZipContainerReader(url: unsupported)
        }

        let symlink = directory.appending(path: "symlink.zip")
        try makeSingleEntryArchive(at: symlink)
        try mutateFirstCentralRecord(at: symlink) { data, offset in
            data.writeUInt16LE(0x0314, at: offset + 4)
            data.writeUInt32LE(UInt32(0xA000) << 16, at: offset + 38)
        }
        #expect(throws: ZipContainerError.symbolicLink("text.txt")) {
            _ = try ZipContainerReader(url: symlink)
        }
    }

    @Test("Compression-ratio limit rejects a deflate bomb")
    func rejectsSuspiciousCompressionRatio() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "ratio.zip")
        try ZipSpikeWriter().write(
            entries: [ZipEntryPayload(
                path: "repeated.txt",
                data: Data(repeating: 65, count: 128 * 1_024),
                method: .deflated
            )],
            to: url
        )
        let limits = ZipSecurityLimits(
            maximumEntryCount: 10,
            maximumSingleEntrySize: 256 * 1_024,
            maximumTotalUncompressedSize: 256 * 1_024,
            maximumCompressionRatio: 2
        )
        #expect(throws: ZipContainerError.suspiciousCompressionRatio("repeated.txt")) {
            _ = try ZipContainerReader(url: url, limits: limits)
        }
    }

    @Test("User-provided EPUB parses with expected Chinese metadata and chapters")
    func parsesUserProvidedEPUBWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["AUDIOBOOKMAKER_REAL_EPUB"] else {
            return
        }
        let parsed = try EPUBParser().parse(url: URL(filePath: path))

        #expect(parsed.title == "论中国与世界")
        #expect(parsed.author == "李光耀")
        #expect(parsed.language == "zh-CN")
        #expect(parsed.chapters.count == 14)
        #expect(parsed.coverData?.isEmpty == false)
        #expect(parsed.chapters.contains { $0.title.contains("论中国、美国与世界") })
        #expect(parsed.chapters.allSatisfy { !$0.plainText.isEmpty })
    }

    @Test("Missing metadata and cover fall back while empty chapters are skipped and Unicode is preserved")
    func parsesMetadataAndUnicodeEdgeCases() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "缺少元数据.epub")
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"></metadata>
          <manifest>
            <item id="empty" href="empty.xhtml" media-type="application/xhtml+xml"/>
            <item id="unicode" href="unicode.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="empty"/><itemref idref="unicode"/></spine>
        </package>
        """
        try ZipSpikeWriter().write(entries: [
            ZipEntryPayload(path: "mimetype", data: Data("application/epub+zip".utf8), method: .stored),
            ZipEntryPayload(
                path: "META-INF/container.xml",
                data: Data(#"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#.utf8)
            ),
            ZipEntryPayload(path: "OPS/package.opf", data: Data(opf.utf8)),
            ZipEntryPayload(
                path: "OPS/empty.xhtml",
                data: Data(#"<?xml version="1.0"?><html><head><title>空章节</title></head><body><script>忽略</script><p>   </p></body></html>"#.utf8)
            ),
            ZipEntryPayload(
                path: "OPS/unicode.xhtml",
                data: Data(#"<?xml version="1.0"?><html><head><title>عنوان 😀</title></head><body><p>中文 é</p><p>مرحبا بالعالم 🌍</p></body></html>"#.utf8)
            ),
        ], to: url)

        let parsed = try EPUBParser().parse(url: url)
        #expect(parsed.title == "缺少元数据")
        #expect(parsed.author == nil)
        #expect(parsed.coverData == nil)
        #expect(parsed.chapters.count == 1)
        #expect(parsed.chapters[0].title == "عنوان 😀")
        #expect(parsed.chapters[0].plainText.contains("مرحبا بالعالم 🌍"))
        #expect(parsed.chapters[0].plainText.contains("é"))
        #expect(!parsed.chapters[0].plainText.unicodeScalars.contains("\u{0301}"))
    }

    private func makeEPUB(version: Int) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appending(path: "fixture-v\(version).epub")
        let navigation: ZipEntryPayload
        if version == 3 {
            navigation = ZipEntryPayload(
                path: "OPS/nav.xhtml",
                data: Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <html xmlns="http://www.w3.org/1999/xhtml"><body><nav><ol>
                    <li><a href="Text/one.xhtml">第一章 开始</a></li>
                    <li><a href="Text/two.xhtml">第二章 继续</a></li>
                    </ol></nav></body></html>
                    """.utf8
                )
            )
        } else {
            navigation = ZipEntryPayload(
                path: "OPS/toc.ncx",
                data: Data(
                    """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
                    <navPoint><navLabel><text>第一章 开始</text></navLabel><content src="Text/one.xhtml"/></navPoint>
                    <navPoint><navLabel><text>第二章 继续</text></navLabel><content src="Text/two.xhtml"/></navPoint>
                    </navMap></ncx>
                    """.utf8
                )
            )
        }
        let navigationManifest = version == 3
            ? #"<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>"#
            : #"<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>"#
        let spineTOC = version == 2 ? #" toc="ncx""# : ""
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="\(version).0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>测试图书</dc:title><dc:creator>测试作者</dc:creator><dc:language>zh-CN</dc:language>
          </metadata>
          <manifest>
            \(navigationManifest)
            <item id="one" href="Text/one.xhtml" media-type="application/xhtml+xml"/>
            <item id="two" href="Text/two.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine\(spineTOC)><itemref idref="one"/><itemref idref="two"/></spine>
        </package>
        """
        try ZipSpikeWriter().write(
            entries: [
                ZipEntryPayload(path: "mimetype", data: Data("application/epub+zip".utf8), method: .stored),
                ZipEntryPayload(
                    path: "META-INF/container.xml",
                    data: Data(
                        #"<?xml version="1.0"?><container><rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles></container>"#.utf8
                    )
                ),
                ZipEntryPayload(path: "OPS/package.opf", data: Data(opf.utf8)),
                navigation,
                ZipEntryPayload(
                    path: "OPS/Text/one.xhtml",
                    data: Data(#"<?xml version="1.0"?><html><head><title>忽略标题</title></head><body><p>这是第一段。</p><script>不能朗读</script></body></html>"#.utf8)
                ),
                ZipEntryPayload(
                    path: "OPS/Text/two.xhtml",
                    data: Data(#"<?xml version="1.0"?><html><body><p>这是第二段。</p><div hidden="hidden">隐藏</div></body></html>"#.utf8)
                ),
            ],
            to: url
        )
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSingleEntryArchive(at url: URL) throws {
        try ZipSpikeWriter().write(
            entries: [ZipEntryPayload(path: "text.txt", data: Data("正文".utf8))],
            to: url
        )
    }

    private func mutateFirstCentralRecord(
        at url: URL,
        mutation: (inout Data, Int) -> Void
    ) throws {
        var data = try Data(contentsOf: url)
        let signature = Data([0x50, 0x4B, 0x01, 0x02])
        let range = try #require(data.range(of: signature))
        mutation(&data, range.lowerBound)
        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
