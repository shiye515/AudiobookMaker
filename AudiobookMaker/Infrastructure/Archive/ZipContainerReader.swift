import Compression
import Foundation

nonisolated struct ZipSecurityLimits: Sendable, Equatable {
    var maximumEntryCount = 10_000
    var maximumSingleEntrySize: UInt64 = 128 * 1_024 * 1_024
    var maximumTotalUncompressedSize: UInt64 = 1_024 * 1_024 * 1_024
    var maximumCompressionRatio = 200.0

    static let epub = ZipSecurityLimits()
}

nonisolated enum ZipContainerError: LocalizedError, Equatable {
    case invalidArchive
    case multiDiskArchive
    case zip64Unsupported
    case encryptedEntry(String)
    case unsupportedCompressionMethod(UInt16, String)
    case invalidPath(String)
    case symbolicLink(String)
    case duplicatePath(String)
    case tooManyEntries(Int)
    case entryTooLarge(String)
    case archiveTooLarge
    case suspiciousCompressionRatio(String)
    case checksumMismatch(String)
    case decompressionFailed(String)
    case missingEntry(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "ZIP 归档结构无效。"
        case .multiDiskArchive: "不支持多磁盘 ZIP 归档。"
        case .zip64Unsupported: "该 ZIP64 归档超出当前支持范围。"
        case .encryptedEntry(let path): "ZIP 条目已加密：\(path)"
        case .unsupportedCompressionMethod(let method, let path):
            "ZIP 条目使用不支持的压缩方法 \(method)：\(path)"
        case .invalidPath(let path): "ZIP 包含不安全路径：\(path)"
        case .symbolicLink(let path): "ZIP 包含不允许的符号链接：\(path)"
        case .duplicatePath(let path): "ZIP 包含重复路径：\(path)"
        case .tooManyEntries(let count): "ZIP 文件数量超过安全限制（\(count)）。"
        case .entryTooLarge(let path): "ZIP 条目超过单文件安全限制：\(path)"
        case .archiveTooLarge: "ZIP 展开后的总大小超过安全限制。"
        case .suspiciousCompressionRatio(let path): "ZIP 条目的压缩比异常：\(path)"
        case .checksumMismatch(let path): "ZIP 条目校验失败：\(path)"
        case .decompressionFailed(let path): "ZIP 条目解压失败：\(path)"
        case .missingEntry(let path): "ZIP 中缺少文件：\(path)"
        }
    }
}

nonisolated struct ZipContainerEntry: Sendable, Equatable {
    let path: String
    let compressionMethod: ZipCompressionMethod
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let crc32: UInt32
    let localHeaderOffset: UInt64
    let isDirectory: Bool
}

/// A bounded ZIP reader for untrusted EPUB input. It reads only the central
/// directory up front and fetches one entry payload at a time with FileHandle.
nonisolated struct ZipContainerReader: Sendable {
    let url: URL
    let entries: [ZipContainerEntry]

    private let entriesByPath: [String: ZipContainerEntry]

    init(url: URL, limits: ZipSecurityLimits = .epub) throws {
        self.url = url
        let parsed = try Self.readCentralDirectory(url: url, limits: limits)
        self.entries = parsed
        self.entriesByPath = Dictionary(uniqueKeysWithValues: parsed.map { ($0.path, $0) })
    }

    var paths: [String] { entries.map(\.path) }

    func contains(_ path: String) -> Bool {
        guard let normalized = try? Self.normalizedArchivePath(path) else { return false }
        return entriesByPath[normalized] != nil
    }

    func data(for path: String) throws -> Data {
        let normalized = try Self.normalizedArchivePath(path)
        guard let entry = entriesByPath[normalized] else {
            throw ZipContainerError.missingEntry(path)
        }
        guard !entry.isDirectory else { return Data() }
        guard entry.compressedSize <= UInt64(Int.max),
              entry.uncompressedSize <= UInt64(Int.max)
        else {
            throw ZipContainerError.entryTooLarge(path)
        }

        let localHeader = try Self.read(url: url, offset: entry.localHeaderOffset, count: 30)
        guard localHeader.uint32LE(at: 0) == 0x0403_4B50,
              let flags = localHeader.uint16LE(at: 6),
              flags & 0x0001 == 0,
              localHeader.uint16LE(at: 8) == entry.compressionMethod.rawValue,
              let nameLength = localHeader.uint16LE(at: 26),
              let extraLength = localHeader.uint16LE(at: 28)
        else {
            throw ZipContainerError.invalidArchive
        }

        let payloadOffset = entry.localHeaderOffset
            + 30
            + UInt64(nameLength)
            + UInt64(extraLength)
        let compressed = try Self.read(
            url: url,
            offset: payloadOffset,
            count: Int(entry.compressedSize)
        )
        let output: Data
        switch entry.compressionMethod {
        case .stored:
            output = compressed
        case .deflated:
            output = try RawZipDeflate.decompress(
                compressed,
                expectedSize: Int(entry.uncompressedSize),
                path: entry.path
            )
        }
        guard output.count == Int(entry.uncompressedSize) else {
            throw ZipContainerError.decompressionFailed(entry.path)
        }
        guard ZipCRC32.checksum(output) == entry.crc32 else {
            throw ZipContainerError.checksumMismatch(entry.path)
        }
        return output
    }

    private static func readCentralDirectory(
        url: URL,
        limits: ZipSecurityLimits
    ) throws -> [ZipContainerEntry] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSizeNumber = attributes[.size] as? NSNumber else {
            throw ZipContainerError.invalidArchive
        }
        let fileSize = fileSizeNumber.uint64Value
        let minimumEOCDSize: UInt64 = 22
        guard fileSize >= minimumEOCDSize else { throw ZipContainerError.invalidArchive }

        let tailSize = min(fileSize, minimumEOCDSize + UInt64(UInt16.max))
        let tailOffset = fileSize - tailSize
        let tail = try read(url: url, offset: tailOffset, count: Int(tailSize))
        guard let eocdIndex = tail.lastIndex(ofLittleEndian: 0x0605_4B50),
              let diskNumber = tail.uint16LE(at: eocdIndex + 4),
              let centralDisk = tail.uint16LE(at: eocdIndex + 6),
              let diskCount = tail.uint16LE(at: eocdIndex + 8),
              let totalCount = tail.uint16LE(at: eocdIndex + 10),
              let centralSize32 = tail.uint32LE(at: eocdIndex + 12),
              let centralOffset32 = tail.uint32LE(at: eocdIndex + 16),
              let commentLength = tail.uint16LE(at: eocdIndex + 20),
              eocdIndex + 22 + Int(commentLength) <= tail.count
        else {
            throw ZipContainerError.invalidArchive
        }
        guard diskNumber == 0, centralDisk == 0 else {
            throw ZipContainerError.multiDiskArchive
        }
        let usesZip64 = totalCount == UInt16.max
            || centralSize32 == UInt32.max
            || centralOffset32 == UInt32.max
        let entryCount64: UInt64
        let centralOffset: UInt64
        let centralSize: UInt64
        if usesZip64 {
            let eocdAbsoluteOffset = tailOffset + UInt64(eocdIndex)
            guard eocdAbsoluteOffset >= 20 else { throw ZipContainerError.invalidArchive }
            let locator = try read(url: url, offset: eocdAbsoluteOffset - 20, count: 20)
            guard locator.uint32LE(at: 0) == 0x0706_4B50,
                  locator.uint32LE(at: 4) == 0,
                  let zip64Offset = locator.uint64LE(at: 8),
                  locator.uint32LE(at: 16) == 1
            else { throw ZipContainerError.zip64Unsupported }
            let zip64End = try read(url: url, offset: zip64Offset, count: 56)
            guard zip64End.uint32LE(at: 0) == 0x0606_4B50,
                  let recordSize = zip64End.uint64LE(at: 4), recordSize >= 44,
                  zip64End.uint32LE(at: 16) == 0,
                  zip64End.uint32LE(at: 20) == 0,
                  let diskEntries = zip64End.uint64LE(at: 24),
                  let allEntries = zip64End.uint64LE(at: 32),
                  diskEntries == allEntries,
                  let size = zip64End.uint64LE(at: 40),
                  let offset = zip64End.uint64LE(at: 48)
            else { throw ZipContainerError.zip64Unsupported }
            entryCount64 = allEntries
            centralSize = size
            centralOffset = offset
        } else {
            guard diskCount == totalCount else { throw ZipContainerError.multiDiskArchive }
            entryCount64 = UInt64(totalCount)
            centralOffset = UInt64(centralOffset32)
            centralSize = UInt64(centralSize32)
        }
        guard entryCount64 <= UInt64(Int.max) else { throw ZipContainerError.zip64Unsupported }
        let entryCount = Int(entryCount64)
        guard entryCount <= limits.maximumEntryCount else {
            throw ZipContainerError.tooManyEntries(entryCount)
        }

        guard centralOffset <= fileSize,
              centralSize <= fileSize - centralOffset,
              centralSize <= UInt64(Int.max)
        else {
            throw ZipContainerError.invalidArchive
        }
        let directory = try read(url: url, offset: centralOffset, count: Int(centralSize))

        var entries: [ZipContainerEntry] = []
        entries.reserveCapacity(entryCount)
        var seen = Set<String>()
        var totalUncompressed: UInt64 = 0
        var offset = 0

        for _ in 0..<entryCount {
            guard directory.uint32LE(at: offset) == 0x0201_4B50,
                  let versionMadeBy = directory.uint16LE(at: offset + 4),
                  let flags = directory.uint16LE(at: offset + 8),
                  let methodValue = directory.uint16LE(at: offset + 10),
                  let crc32 = directory.uint32LE(at: offset + 16),
                  let compressedSize32 = directory.uint32LE(at: offset + 20),
                  let uncompressedSize32 = directory.uint32LE(at: offset + 24),
                  let nameLength = directory.uint16LE(at: offset + 28),
                  let extraLength = directory.uint16LE(at: offset + 30),
                  let commentLength = directory.uint16LE(at: offset + 32),
                  let diskStart = directory.uint16LE(at: offset + 34),
                  let externalAttributes = directory.uint32LE(at: offset + 38),
                  let localOffset32 = directory.uint32LE(at: offset + 42)
            else {
                throw ZipContainerError.invalidArchive
            }
            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            let extraEnd = nameEnd + Int(extraLength)
            let recordEnd = extraEnd + Int(commentLength)
            guard nameStart >= 0, nameEnd <= directory.count, recordEnd <= directory.count,
                  let rawPath = String(data: directory[nameStart..<nameEnd], encoding: .utf8)
            else {
                throw ZipContainerError.invalidArchive
            }
            let path = try normalizedArchivePath(rawPath)
            guard seen.insert(path).inserted else {
                throw ZipContainerError.duplicatePath(path)
            }
            guard flags & 0x0001 == 0, flags & 0x0040 == 0 else {
                throw ZipContainerError.encryptedEntry(path)
            }
            guard let method = ZipCompressionMethod(rawValue: methodValue) else {
                throw ZipContainerError.unsupportedCompressionMethod(methodValue, path)
            }

            let hostSystem = versionMadeBy >> 8
            let unixMode = UInt16((externalAttributes >> 16) & 0xF000)
            if hostSystem == 3, unixMode == 0xA000 {
                throw ZipContainerError.symbolicLink(path)
            }

            let zip64Values = try parseZip64Extra(
                directory[nameEnd..<extraEnd],
                needsUncompressed: uncompressedSize32 == UInt32.max,
                needsCompressed: compressedSize32 == UInt32.max,
                needsOffset: localOffset32 == UInt32.max,
                needsDisk: diskStart == UInt16.max
            )
            let compressedSize = zip64Values.compressed ?? UInt64(compressedSize32)
            let uncompressedSize = zip64Values.uncompressed ?? UInt64(uncompressedSize32)
            let localOffset = zip64Values.offset ?? UInt64(localOffset32)
            let resolvedDisk = zip64Values.disk ?? UInt32(diskStart)
            guard resolvedDisk == 0 else { throw ZipContainerError.multiDiskArchive }
            guard uncompressedSize <= limits.maximumSingleEntrySize else {
                throw ZipContainerError.entryTooLarge(path)
            }
            let (newTotal, overflow) = totalUncompressed.addingReportingOverflow(uncompressedSize)
            guard !overflow, newTotal <= limits.maximumTotalUncompressedSize else {
                throw ZipContainerError.archiveTooLarge
            }
            totalUncompressed = newTotal
            if uncompressedSize > 0 {
                guard compressedSize > 0 else {
                    throw ZipContainerError.suspiciousCompressionRatio(path)
                }
                let ratio = Double(uncompressedSize) / Double(compressedSize)
                guard ratio <= limits.maximumCompressionRatio else {
                    throw ZipContainerError.suspiciousCompressionRatio(path)
                }
            }

            entries.append(
                ZipContainerEntry(
                    path: path,
                    compressionMethod: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    crc32: crc32,
                    localHeaderOffset: localOffset,
                    isDirectory: rawPath.hasSuffix("/")
                )
            )
            offset = recordEnd
        }
        guard offset <= directory.count else { throw ZipContainerError.invalidArchive }
        return entries
    }

    private static func parseZip64Extra(
        _ extra: Data.SubSequence,
        needsUncompressed: Bool,
        needsCompressed: Bool,
        needsOffset: Bool,
        needsDisk: Bool
    ) throws -> (uncompressed: UInt64?, compressed: UInt64?, offset: UInt64?, disk: UInt32?) {
        guard needsUncompressed || needsCompressed || needsOffset || needsDisk else {
            return (nil, nil, nil, nil)
        }
        let data = Data(extra)
        var cursor = 0
        var payload: Data?
        while cursor + 4 <= data.count {
            guard let identifier = data.uint16LE(at: cursor),
                  let length = data.uint16LE(at: cursor + 2)
            else { throw ZipContainerError.invalidArchive }
            let end = cursor + 4 + Int(length)
            guard end <= data.count else { throw ZipContainerError.invalidArchive }
            if identifier == 0x0001 {
                payload = Data(data[(cursor + 4)..<end])
                break
            }
            cursor = end
        }
        guard let payload else { throw ZipContainerError.zip64Unsupported }
        cursor = 0
        func next64() throws -> UInt64 {
            guard let value = payload.uint64LE(at: cursor) else {
                throw ZipContainerError.zip64Unsupported
            }
            cursor += 8
            return value
        }
        let uncompressed = try needsUncompressed ? next64() : nil
        let compressed = try needsCompressed ? next64() : nil
        let offset = try needsOffset ? next64() : nil
        let disk: UInt32? = if needsDisk {
            try payload.uint32LE(at: cursor).unwrapZip64()
        } else { nil }
        return (uncompressed, compressed, offset, disk)
    }

    static func normalizedArchivePath(_ rawPath: String) throws -> String {
        let path = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw ZipContainerError.invalidPath(rawPath)
        }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component == "." { continue }
            guard component != "..", !component.contains(":"),
                  !component.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                throw ZipContainerError.invalidPath(rawPath)
            }
            components.append(component)
        }
        guard !components.isEmpty else { throw ZipContainerError.invalidPath(rawPath) }
        return components.joined(separator: "/")
    }

    private static func read(url: URL, offset: UInt64, count: Int) throws -> Data {
        guard count >= 0 else { throw ZipContainerError.invalidArchive }
        if count == 0 { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ZipContainerError.invalidArchive
        }
        return data
    }
}

nonisolated private enum RawZipDeflate {
    static func decompress(_ input: Data, expectedSize: Int, path: String) throws -> Data {
        guard expectedSize >= 0 else { throw ZipContainerError.decompressionFailed(path) }
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw ZipContainerError.decompressionFailed(path) }
        return output
    }
}

nonisolated private enum ZipCRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ UInt32.max
    }
}

nonisolated private extension Data {
    func lastIndex(ofLittleEndian value: UInt32) -> Int? {
        guard count >= 4 else { return nil }
        for index in stride(from: count - 4, through: 0, by: -1) {
            if uint32LE(at: index) == value { return index }
        }
        return nil
    }

    func uint16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= count - 2 else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= count - 4 else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func uint64LE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= count - 8 else { return nil }
        return UInt64(self[offset])
            | (UInt64(self[offset + 1]) << 8)
            | (UInt64(self[offset + 2]) << 16)
            | (UInt64(self[offset + 3]) << 24)
            | (UInt64(self[offset + 4]) << 32)
            | (UInt64(self[offset + 5]) << 40)
            | (UInt64(self[offset + 6]) << 48)
            | (UInt64(self[offset + 7]) << 56)
    }
}

nonisolated private extension Optional where Wrapped == UInt32 {
    func unwrapZip64() throws -> UInt32 {
        guard let self else { throw ZipContainerError.zip64Unsupported }
        return self
    }
}
