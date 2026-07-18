import Compression
import Foundation

nonisolated enum ZipCompressionMethod: UInt16, Sendable {
    case stored = 0
    case deflated = 8
}

nonisolated struct ZipEntryPayload: Sendable, Equatable {
    let path: String
    let data: Data
    let method: ZipCompressionMethod

    init(path: String, data: Data, method: ZipCompressionMethod = .deflated) {
        self.path = path
        self.data = data
        self.method = method
    }
}

nonisolated enum ZipSpikeError: Error, Equatable {
    case invalidArchive
    case unsupportedMethod(UInt16)
    case invalidUTF8Path
    case duplicatePath(String)
    case compressionFailed
    case decompressionFailed
    case checksumMismatch(String)
    case valueTooLarge
}

/// A deliberately small ZIP implementation used to validate the Apple-only
/// archive approach before the hardened streaming implementation is built.
nonisolated struct ZipSpikeWriter: Sendable {
    func write(entries: [ZipEntryPayload], to url: URL) throws {
        guard entries.count <= Int(UInt16.max) else {
            throw ZipSpikeError.valueTooLarge
        }

        var seen = Set<String>()
        var archive = Data()
        var centralDirectory: [(entry: ZipEntryPayload, crc32: UInt32, compressed: Data, offset: UInt32)] = []

        for entry in entries {
            guard seen.insert(entry.path).inserted else {
                throw ZipSpikeError.duplicatePath(entry.path)
            }
            guard let pathData = entry.path.data(using: .utf8), pathData.count <= Int(UInt16.max) else {
                throw ZipSpikeError.invalidUTF8Path
            }
            guard archive.count <= Int(UInt32.max), entry.data.count <= Int(UInt32.max) else {
                throw ZipSpikeError.valueTooLarge
            }

            let compressed: Data
            switch entry.method {
            case .stored:
                compressed = entry.data
            case .deflated:
                compressed = try RawDeflate.compress(entry.data)
            }
            guard compressed.count <= Int(UInt32.max) else {
                throw ZipSpikeError.valueTooLarge
            }

            let crc32 = CRC32.checksum(entry.data)
            let offset = UInt32(archive.count)
            archive.appendLittleEndian(UInt32(0x0403_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(entry.method.rawValue)
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(crc32)
            archive.appendLittleEndian(UInt32(compressed.count))
            archive.appendLittleEndian(UInt32(entry.data.count))
            archive.appendLittleEndian(UInt16(pathData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.append(pathData)
            archive.append(compressed)

            centralDirectory.append((entry, crc32, compressed, offset))
        }

        guard archive.count <= Int(UInt32.max) else {
            throw ZipSpikeError.valueTooLarge
        }
        let centralOffset = UInt32(archive.count)

        for item in centralDirectory {
            guard let pathData = item.entry.path.data(using: .utf8) else {
                throw ZipSpikeError.invalidUTF8Path
            }
            archive.appendLittleEndian(UInt32(0x0201_4B50))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(20))
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(item.entry.method.rawValue)
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(item.crc32)
            archive.appendLittleEndian(UInt32(item.compressed.count))
            archive.appendLittleEndian(UInt32(item.entry.data.count))
            archive.appendLittleEndian(UInt16(pathData.count))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt32(0))
            archive.appendLittleEndian(item.offset)
            archive.append(pathData)
        }

        let centralSize = archive.count - Int(centralOffset)
        guard centralSize <= Int(UInt32.max) else {
            throw ZipSpikeError.valueTooLarge
        }
        archive.appendLittleEndian(UInt32(0x0605_4B50))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt32(centralSize))
        archive.appendLittleEndian(centralOffset)
        archive.appendLittleEndian(UInt16(0))

        try archive.write(to: url, options: .atomic)
    }
}

nonisolated struct ZipSpikeReader: Sendable {
    private struct Record: Sendable {
        let path: String
        let method: ZipCompressionMethod
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let archive: Data
    private let records: [Record]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        self.archive = data
        self.records = try Self.parseCentralDirectory(data)
    }

    var paths: [String] {
        records.map(\.path)
    }

    func data(for path: String) throws -> Data {
        guard let record = records.first(where: { $0.path == path }) else {
            throw ZipSpikeError.invalidArchive
        }
        let offset = record.localHeaderOffset
        guard archive.uint32LE(at: offset) == 0x0403_4B50,
              let nameLength = archive.uint16LE(at: offset + 26),
              let extraLength = archive.uint16LE(at: offset + 28)
        else {
            throw ZipSpikeError.invalidArchive
        }
        let dataStart = offset + 30 + Int(nameLength) + Int(extraLength)
        guard dataStart >= 0,
              record.compressedSize >= 0,
              dataStart <= archive.count,
              record.compressedSize <= archive.count - dataStart
        else {
            throw ZipSpikeError.invalidArchive
        }
        let compressed = archive.subdata(in: dataStart..<(dataStart + record.compressedSize))
        let output: Data
        switch record.method {
        case .stored:
            output = compressed
        case .deflated:
            output = try RawDeflate.decompress(compressed, expectedSize: record.uncompressedSize)
        }
        guard output.count == record.uncompressedSize else {
            throw ZipSpikeError.decompressionFailed
        }
        guard CRC32.checksum(output) == record.crc32 else {
            throw ZipSpikeError.checksumMismatch(path)
        }
        return output
    }

    private static func parseCentralDirectory(_ data: Data) throws -> [Record] {
        let minimumEOCDSize = 22
        guard data.count >= minimumEOCDSize else {
            throw ZipSpikeError.invalidArchive
        }
        let searchStart = max(0, data.count - minimumEOCDSize - Int(UInt16.max))
        var eocdOffset: Int?
        var cursor = data.count - minimumEOCDSize
        while cursor >= searchStart {
            if data.uint32LE(at: cursor) == 0x0605_4B50 {
                eocdOffset = cursor
                break
            }
            cursor -= 1
        }
        guard let eocdOffset,
              data.uint16LE(at: eocdOffset + 4) == 0,
              data.uint16LE(at: eocdOffset + 6) == 0,
              let count = data.uint16LE(at: eocdOffset + 10),
              let centralSize = data.uint32LE(at: eocdOffset + 12),
              let centralOffset = data.uint32LE(at: eocdOffset + 16),
              Int(centralOffset) <= data.count,
              Int(centralSize) <= data.count - Int(centralOffset)
        else {
            throw ZipSpikeError.invalidArchive
        }

        var records: [Record] = []
        records.reserveCapacity(Int(count))
        var offset = Int(centralOffset)
        var seen = Set<String>()

        for _ in 0..<count {
            guard data.uint32LE(at: offset) == 0x0201_4B50,
                  let flags = data.uint16LE(at: offset + 8),
                  flags & 0x0001 == 0,
                  let methodValue = data.uint16LE(at: offset + 10),
                  let method = ZipCompressionMethod(rawValue: methodValue),
                  let crc32 = data.uint32LE(at: offset + 16),
                  let compressedSize = data.uint32LE(at: offset + 20),
                  let uncompressedSize = data.uint32LE(at: offset + 24),
                  let nameLength = data.uint16LE(at: offset + 28),
                  let extraLength = data.uint16LE(at: offset + 30),
                  let commentLength = data.uint16LE(at: offset + 32),
                  let localOffset = data.uint32LE(at: offset + 42)
            else {
                throw ZipSpikeError.invalidArchive
            }
            let nameStart = offset + 46
            let nameEnd = nameStart + Int(nameLength)
            guard nameStart >= 0, nameEnd <= data.count,
                  let path = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8),
                  seen.insert(path).inserted
            else {
                throw ZipSpikeError.invalidUTF8Path
            }
            records.append(
                Record(
                    path: path,
                    method: method,
                    crc32: crc32,
                    compressedSize: Int(compressedSize),
                    uncompressedSize: Int(uncompressedSize),
                    localHeaderOffset: Int(localOffset)
                )
            )
            offset = nameEnd + Int(extraLength) + Int(commentLength)
        }
        return records
    }
}

nonisolated private enum RawDeflate {
    static func compress(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var capacity = max(64, input.count + input.count / 8 + 64)
        for _ in 0..<8 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    compression_encode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!,
                        capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!,
                        input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0 {
                return output.prefix(written)
            }
            capacity *= 2
        }
        throw ZipSpikeError.compressionFailed
    }

    static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw ZipSpikeError.decompressionFailed }
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
        guard written == expectedSize else {
            throw ZipSpikeError.decompressionFailed
        }
        return output
    }
}

nonisolated private enum CRC32 {
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
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
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
}
