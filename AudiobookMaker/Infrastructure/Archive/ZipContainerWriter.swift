import Compression
import Foundation

nonisolated enum ZipWriteSource: Sendable {
    case data(Data)
    case file(URL)
}

nonisolated struct ZipWriteEntry: Sendable {
    let path: String
    let source: ZipWriteSource
    let method: ZipCompressionMethod

    init(path: String, source: ZipWriteSource, method: ZipCompressionMethod = .stored) {
        self.path = path
        self.source = source
        self.method = method
    }
}

nonisolated struct ZipWriteProgress: Sendable, Equatable {
    let completedBytes: Int64
    let totalBytes: Int64
    let currentPath: String?

    var fractionCompleted: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 1
    }
}

nonisolated enum ZipWriterError: Error, LocalizedError, Equatable, Sendable {
    case duplicatePath(String)
    case unsafePath(String)
    case valueTooLarge
    case unreadableSource
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case let .duplicatePath(path): "ZIP 中存在重复路径：\(path)"
        case let .unsafePath(path): "ZIP 路径不安全：\(path)"
        case .valueTooLarge: "ZIP 内容超过当前支持的大小。"
        case .unreadableSource: "无法读取待归档文件。"
        case .compressionFailed: "ZIP 压缩失败。"
        }
    }
}

nonisolated struct ZipContainerWriter: Sendable {
    private struct CentralRecord {
        let pathData: Data
        let method: ZipCompressionMethod
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localOffset: UInt64
    }

    func write(
        entries: [ZipWriteEntry],
        to outputURL: URL,
        progress: (@Sendable (ZipWriteProgress) -> Void)? = nil
    ) throws {
        let totalBytes = try entries.reduce(Int64(0)) { total, entry in
            let size: Int64 = switch entry.source {
            case let .data(data): Int64(data.count)
            case let .file(url): Int64(
                (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            )
            }
            return total + size
        }
        var completedBytes: Int64 = 0
        progress?(ZipWriteProgress(completedBytes: 0, totalBytes: totalBytes, currentPath: nil))
        var seen = Set<String>()
        try? FileManager.default.removeItem(at: outputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { try? FileManager.default.removeItem(at: outputURL) }
        }
        var central: [CentralRecord] = []
        for entry in entries {
            try Task.checkCancellation()
            guard seen.insert(entry.path).inserted else { throw ZipWriterError.duplicatePath(entry.path) }
            let pathData = try safePathData(entry.path)
            let prepared = try prepare(entry)
            let offset = handle.offsetInFile
            let needsZip64Sizes = prepared.compressedSize >= UInt64(UInt32.max)
                || prepared.uncompressedSize >= UInt64(UInt32.max)
            var localExtra = Data()
            if needsZip64Sizes {
                var payload = Data()
                payload.zipAppend(prepared.uncompressedSize)
                payload.zipAppend(prepared.compressedSize)
                localExtra.zipAppend(UInt16(0x0001))
                localExtra.zipAppend(UInt16(payload.count))
                localExtra.append(payload)
            }
            var header = Data()
            header.zipAppend(UInt32(0x0403_4B50))
            header.zipAppend(UInt16(needsZip64Sizes ? 45 : 20))
            header.zipAppend(UInt16(0x0800))
            header.zipAppend(entry.method.rawValue)
            header.zipAppend(UInt16(0)); header.zipAppend(UInt16(0))
            header.zipAppend(prepared.crc32)
            header.zipAppend(needsZip64Sizes ? UInt32.max : UInt32(prepared.compressedSize))
            header.zipAppend(needsZip64Sizes ? UInt32.max : UInt32(prepared.uncompressedSize))
            header.zipAppend(UInt16(pathData.count)); header.zipAppend(UInt16(localExtra.count))
            header.append(pathData); header.append(localExtra)
            try handle.write(contentsOf: header)
            try prepared.write(to: handle) { count in
                completedBytes = min(totalBytes, completedBytes + Int64(count))
                progress?(ZipWriteProgress(
                    completedBytes: completedBytes,
                    totalBytes: totalBytes,
                    currentPath: entry.path
                ))
            }
            central.append(CentralRecord(
                pathData: pathData,
                method: entry.method,
                crc32: prepared.crc32,
                compressedSize: prepared.compressedSize,
                uncompressedSize: prepared.uncompressedSize,
                localOffset: offset
            ))
        }

        let centralOffset = handle.offsetInFile
        for record in central {
            let needsUncompressed = record.uncompressedSize >= UInt64(UInt32.max)
            let needsCompressed = record.compressedSize >= UInt64(UInt32.max)
            let needsOffset = record.localOffset >= UInt64(UInt32.max)
            var zip64Payload = Data()
            if needsUncompressed { zip64Payload.zipAppend(record.uncompressedSize) }
            if needsCompressed { zip64Payload.zipAppend(record.compressedSize) }
            if needsOffset { zip64Payload.zipAppend(record.localOffset) }
            var extra = Data()
            if !zip64Payload.isEmpty {
                extra.zipAppend(UInt16(0x0001))
                extra.zipAppend(UInt16(zip64Payload.count))
                extra.append(zip64Payload)
            }
            var item = Data()
            item.zipAppend(UInt32(0x0201_4B50))
            item.zipAppend(UInt16(45)); item.zipAppend(UInt16(extra.isEmpty ? 20 : 45)); item.zipAppend(UInt16(0x0800))
            item.zipAppend(record.method.rawValue)
            item.zipAppend(UInt16(0)); item.zipAppend(UInt16(0)); item.zipAppend(record.crc32)
            item.zipAppend(needsCompressed ? UInt32.max : UInt32(record.compressedSize))
            item.zipAppend(needsUncompressed ? UInt32.max : UInt32(record.uncompressedSize))
            item.zipAppend(UInt16(record.pathData.count)); item.zipAppend(UInt16(extra.count)); item.zipAppend(UInt16(0))
            item.zipAppend(UInt16(0)); item.zipAppend(UInt16(0)); item.zipAppend(UInt32(0))
            item.zipAppend(needsOffset ? UInt32.max : UInt32(record.localOffset))
            item.append(record.pathData); item.append(extra)
            try handle.write(contentsOf: item)
        }
        let centralSize = handle.offsetInFile - centralOffset
        let needsZip64End = central.count >= Int(UInt16.max)
            || centralSize >= UInt64(UInt32.max)
            || centralOffset >= UInt64(UInt32.max)
        if needsZip64End {
            let zip64EndOffset = handle.offsetInFile
            var zip64End = Data()
            zip64End.zipAppend(UInt32(0x0606_4B50))
            zip64End.zipAppend(UInt64(44))
            zip64End.zipAppend(UInt16(45)); zip64End.zipAppend(UInt16(45))
            zip64End.zipAppend(UInt32(0)); zip64End.zipAppend(UInt32(0))
            zip64End.zipAppend(UInt64(central.count)); zip64End.zipAppend(UInt64(central.count))
            zip64End.zipAppend(centralSize); zip64End.zipAppend(centralOffset)
            try handle.write(contentsOf: zip64End)
            var locator = Data()
            locator.zipAppend(UInt32(0x0706_4B50)); locator.zipAppend(UInt32(0))
            locator.zipAppend(zip64EndOffset); locator.zipAppend(UInt32(1))
            try handle.write(contentsOf: locator)
        }
        var end = Data()
        end.zipAppend(UInt32(0x0605_4B50)); end.zipAppend(UInt16(0)); end.zipAppend(UInt16(0))
        end.zipAppend(needsZip64End ? UInt16.max : UInt16(central.count))
        end.zipAppend(needsZip64End ? UInt16.max : UInt16(central.count))
        end.zipAppend(needsZip64End ? UInt32.max : UInt32(centralSize))
        end.zipAppend(needsZip64End ? UInt32.max : UInt32(centralOffset)); end.zipAppend(UInt16(0))
        try handle.write(contentsOf: end)
        try handle.synchronize()
        progress?(ZipWriteProgress(
            completedBytes: totalBytes,
            totalBytes: totalBytes,
            currentPath: nil
        ))
        succeeded = true
    }

    private func safePathData(_ path: String) throws -> Data {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"),
              !path.split(separator: "/").contains(".."),
              let data = path.data(using: .utf8), data.count <= Int(UInt16.max) else {
            throw ZipWriterError.unsafePath(path)
        }
        return data
    }

    private struct Prepared {
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let data: Data?
        let fileURL: URL?

        func write(
            to handle: FileHandle,
            onBytesWritten: (Int) -> Void
        ) throws {
            try Task.checkCancellation()
            if let data {
                try handle.write(contentsOf: data)
                onBytesWritten(Int(uncompressedSize))
                return
            }
            guard let fileURL else { throw ZipWriterError.unreadableSource }
            let source = try FileHandle(forReadingFrom: fileURL)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                onBytesWritten(chunk.count)
            }
        }
    }

    private func prepare(_ entry: ZipWriteEntry) throws -> Prepared {
        switch (entry.source, entry.method) {
        case let (.data(data), .stored):
            return Prepared(crc32: ExportCRC32.checksum(data), compressedSize: UInt64(data.count), uncompressedSize: UInt64(data.count), data: data, fileURL: nil)
        case let (.data(data), .deflated):
            let compressed = try ExportDeflate.compress(data)
            return Prepared(crc32: ExportCRC32.checksum(data), compressedSize: UInt64(compressed.count), uncompressedSize: UInt64(data.count), data: compressed, fileURL: nil)
        case let (.file(url), .stored):
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize else { throw ZipWriterError.unreadableSource }
            return Prepared(crc32: try ExportCRC32.checksumFile(url), compressedSize: UInt64(size), uncompressedSize: UInt64(size), data: nil, fileURL: url)
        case let (.file(url), .deflated):
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let compressed = try ExportDeflate.compress(data)
            return Prepared(crc32: ExportCRC32.checksum(data), compressedSize: UInt64(compressed.count), uncompressedSize: UInt64(data.count), data: compressed, fileURL: nil)
        }
    }

}

nonisolated private enum ExportCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB8_8320 : 0)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { update(&crc, byte: byte) }
        return crc ^ UInt32.max
    }

    static func checksumFile(_ url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc = UInt32.max
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            for byte in data { update(&crc, byte: byte) }
        }
        return crc ^ UInt32.max
    }

    private static func update(_ crc: inout UInt32, byte: UInt8) {
        let index = Int((crc ^ UInt32(byte)) & 0xFF)
        crc = table[index] ^ (crc >> 8)
    }
}

nonisolated private enum ExportDeflate {
    static func compress(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        var capacity = max(64, input.count + input.count / 8 + 64)
        for _ in 0..<8 {
            var output = Data(count: capacity)
            let count = output.withUnsafeMutableBytes { destination in
                input.withUnsafeBytes { source in
                    compression_encode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if count > 0 { return output.prefix(count) }
            capacity *= 2
        }
        throw ZipWriterError.compressionFailed
    }
}

nonisolated private extension Data {
    mutating func zipAppend<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
