@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

nonisolated struct M4BPackageRequest: Sendable {
    let audioSegments: [URL]
    let outputURL: URL
    let title: String
    let author: String
    let chapterTitle: String
    let chapterIndex: Int
    let languageCode: String?
    let fullText: String
    let coverData: Data?
}

nonisolated private final class AudioReadErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?

    var value: (any Error)? { lock.withLock { stored } }

    func store(_ error: any Error) {
        lock.withLock { stored = error }
    }
}

/// AVAssetWriter supports feeding separate inputs from separate queues. The
/// framework types predate Swift Sendable annotations, so keep the related
/// objects in one explicitly shared context for the two coordinated producers.
nonisolated private final class AudiobookWriterContext: @unchecked Sendable {
    let writer: AVAssetWriter
    let audioInput: AVAssetWriterInput
    let chapterInput: AVAssetWriterInput
    let textDescription: CMFormatDescription

    init(
        writer: AVAssetWriter,
        audioInput: AVAssetWriterInput,
        chapterInput: AVAssetWriterInput,
        textDescription: CMFormatDescription
    ) {
        self.writer = writer
        self.audioInput = audioInput
        self.chapterInput = chapterInput
        self.textDescription = textDescription
    }
}

nonisolated struct M4BPackageResult: Equatable, Sendable {
    let url: URL
    let durationSeconds: Double
    let textSHA256: String
}

nonisolated struct M4BAudiobookChapter: Sendable, Equatable {
    let title: String
    let audioURL: URL
}

nonisolated struct M4BAudiobookPackageRequest: Sendable {
    let chapters: [M4BAudiobookChapter]
    let outputURL: URL
    let title: String
    let author: String
    let narrator: String
    let genre: String
    let publicationDate: Date
    let languageCode: String?
    let coverData: Data?
}

nonisolated enum PackagingError: Error, StableAppError, Equatable, Sendable {
    case noAudioSegments
    case unreadableAudio
    case cannotCreateWriter(String)
    case cannotAddTrack(String)
    case cannotAssociateChapterTrack
    case appendFailed(String)
    case writerFailed(String)
    case validationFailed(String)
    case commitFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioSegments: String(localized: "没有可封装的语音片段。")
        case .unreadableAudio: String(localized: "语音片段无法读取。")
        case let .cannotCreateWriter(message): String(
            format: String(localized: "无法创建 M4B：%@"), message
        )
        case let .cannotAddTrack(track): String(
            format: String(localized: "无法添加 %@ 轨道。"), track
        )
        case .cannotAssociateChapterTrack: String(localized: "无法建立章节与音频轨关联。")
        case let .appendFailed(message): String(
            format: String(localized: "写入 M4B 失败：%@"), message
        )
        case let .writerFailed(message): String(
            format: String(localized: "M4B 编码失败：%@"), message
        )
        case let .validationFailed(message): String(
            format: String(localized: "M4B 校验失败：%@"), message
        )
        case let .commitFailed(message): String(
            format: String(localized: "M4B 提交失败：%@"), message
        )
        }
    }

    var code: String {
        switch self {
        case .noAudioSegments: "packaging.noAudioSegments"
        case .unreadableAudio: "packaging.unreadableAudio"
        case .cannotCreateWriter: "packaging.cannotCreateWriter"
        case .cannotAddTrack: "packaging.cannotAddTrack"
        case .cannotAssociateChapterTrack: "packaging.cannotAssociateChapterTrack"
        case .appendFailed: "packaging.appendFailed"
        case .writerFailed: "packaging.writerFailed"
        case .validationFailed: "packaging.validationFailed"
        case .commitFailed: "packaging.commitFailed"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unreadableAudio, .noAudioSegments:
            String(localized: "请重试该章节，系统会重新生成无效片段。")
        default:
            String(localized: "请重试转换；未通过校验的 M4B 不会被提交。")
        }
    }

}

nonisolated enum M4BPackager {
    static let sampleRate = 44_100.0
    static let bitRate = 64_000

    @concurrent
    static func package(_ request: M4BPackageRequest) async throws -> M4BPackageResult {
        guard !request.audioSegments.isEmpty else { throw PackagingError.noAudioSegments }
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partialURL = request.outputURL
            .deletingPathExtension()
            .appendingPathExtension("partial")
            .appendingPathExtension(request.outputURL.pathExtension)
        try? FileManager.default.removeItem(at: partialURL)
        let normalizedDirectory = request.outputURL.deletingLastPathComponent()
            .appending(path: ".normalized-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: normalizedDirectory) }
        let normalizedSegments = try normalizeAudioSegments(
            request.audioSegments,
            in: normalizedDirectory
        )
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: partialURL) } }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: partialURL, fileType: .m4a)
        } catch {
            throw PackagingError.cannotCreateWriter(error.localizedDescription)
        }
        let firstAsset = AVURLAsset(url: normalizedSegments[0])
        guard let firstTrack = try await firstAsset.loadTracks(withMediaType: .audio).first,
              let audioDescription = try await firstTrack.load(.formatDescriptions).first else {
            throw PackagingError.validationFailed("标准化音频没有可读轨道")
        }
        let textDescription = try makeTextDescription()
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ],
            sourceFormatHint: audioDescription
        )
        let chapterInput = AVAssetWriterInput(
            mediaType: .text,
            outputSettings: nil,
            sourceFormatHint: textDescription
        )
        let textInput = AVAssetWriterInput(
            mediaType: .text,
            outputSettings: nil,
            sourceFormatHint: textDescription
        )
        [audioInput, chapterInput, textInput].forEach { $0.expectsMediaDataInRealTime = false }
        chapterInput.mediaDataLocation = .interleavedWithMainMediaData
        textInput.mediaDataLocation = .interleavedWithMainMediaData
        try add(audioInput, name: "音频", writer: writer)
        try add(chapterInput, name: "章节", writer: writer)
        try add(textInput, name: "正文", writer: writer)
        guard audioInput.canAddTrackAssociation(
            withTrackOf: chapterInput,
            type: AVAssetTrack.AssociationType.chapterList.rawValue
        ) else { throw PackagingError.cannotAssociateChapterTrack }
        audioInput.addTrackAssociation(
            withTrackOf: chapterInput,
            type: AVAssetTrack.AssociationType.chapterList.rawValue
        )
        writer.metadata = metadata(for: request)
        guard writer.startWriting() else { throw writerFailure(writer) }
        writer.startSession(atSourceTime: .zero)

        let expectedDuration = try await totalDuration(of: normalizedSegments)
        guard expectedDuration.isNumeric, expectedDuration.seconds > 0 else {
            throw PackagingError.unreadableAudio
        }
        try await appendText(
            request.chapterTitle,
            duration: expectedDuration,
            input: chapterInput,
            description: textDescription,
            writer: writer
        )
        try await appendText(
            request.fullText,
            duration: expectedDuration,
            input: textInput,
            description: textDescription,
            writer: writer
        )
        chapterInput.markAsFinished()
        textInput.markAsFinished()
        let offset = try await appendAudioSegments(
            normalizedSegments,
            input: audioInput,
            writer: writer
        )
        guard offset.isNumeric, offset.seconds > 0 else { throw PackagingError.unreadableAudio }
        audioInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writerFailure(writer) }

        try await M4BValidator.validate(
            url: partialURL,
            expectedTitle: request.title,
            expectedChapterTitle: request.chapterTitle,
            expectedFullText: request.fullText
        )
        do {
            try? FileManager.default.removeItem(at: request.outputURL)
            try FileManager.default.moveItem(at: partialURL, to: request.outputURL)
        } catch {
            throw PackagingError.commitFailed(error.localizedDescription)
        }
        committed = true
        return M4BPackageResult(
            url: request.outputURL,
            durationSeconds: offset.seconds,
            textSHA256: SHA256.hash(data: Data(request.fullText.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    /// Combines the already converted chapter artifacts into one standards-based
    /// audiobook file with a single audio timeline and timed chapter navigation.
    @concurrent
    static func packageAudiobook(
        _ request: M4BAudiobookPackageRequest,
        progress: (@Sendable (Double, String?) -> Void)? = nil
    ) async throws -> URL {
        guard !request.chapters.isEmpty else { throw PackagingError.noAudioSegments }
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let partialURL = request.outputURL
            .deletingPathExtension()
            .appendingPathExtension("partial")
            .appendingPathExtension(request.outputURL.pathExtension)
        try? FileManager.default.removeItem(at: partialURL)
        let normalizedDirectory = request.outputURL.deletingLastPathComponent()
            .appending(path: ".audiobook-normalized-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: normalizedDirectory) }
        let normalizedSegments = try normalizeAudioSegments(
            request.chapters.map(\.audioURL),
            in: normalizedDirectory
        )
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: partialURL) } }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: partialURL, fileType: .m4a)
        } catch {
            throw PackagingError.cannotCreateWriter(error.localizedDescription)
        }
        let firstAsset = AVURLAsset(url: normalizedSegments[0])
        guard let firstTrack = try await firstAsset.loadTracks(withMediaType: .audio).first,
              let audioDescription = try await firstTrack.load(.formatDescriptions).first else {
            throw PackagingError.validationFailed("标准化音频没有可读轨道")
        }
        let textDescription = try makeTextDescription()
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: bitRate,
            ],
            sourceFormatHint: audioDescription
        )
        let chapterInput = AVAssetWriterInput(
            mediaType: .text,
            outputSettings: nil,
            sourceFormatHint: textDescription
        )
        audioInput.expectsMediaDataInRealTime = false
        chapterInput.expectsMediaDataInRealTime = false
        chapterInput.mediaDataLocation = .interleavedWithMainMediaData
        try add(audioInput, name: "音频", writer: writer)
        try add(chapterInput, name: "章节", writer: writer)
        guard audioInput.canAddTrackAssociation(
            withTrackOf: chapterInput,
            type: AVAssetTrack.AssociationType.chapterList.rawValue
        ) else { throw PackagingError.cannotAssociateChapterTrack }
        audioInput.addTrackAssociation(
            withTrackOf: chapterInput,
            type: AVAssetTrack.AssociationType.chapterList.rawValue
        )
        writer.metadata = audiobookMetadata(for: request)
        guard writer.startWriting() else { throw writerFailure(writer) }
        writer.startSession(atSourceTime: .zero)
        let context = AudiobookWriterContext(
            writer: writer,
            audioInput: audioInput,
            chapterInput: chapterInput,
            textDescription: textDescription
        )

        // Feed both inputs together. Writing every chapter marker before starting
        // audio eventually fills AVAssetWriter's text queue on real, long books;
        // the text input then stays back-pressured while the untouched audio input
        // is the only thing that could let the muxer advance.
        async let chapterWriting: Void = appendAudiobookChapters(
            request: request,
            normalizedSegments: normalizedSegments,
            context: context,
            progress: progress
        )
        async let audioWriting: CMTime = appendAudiobookAudio(
            normalizedSegments,
            context: context
        )
        let (_, finalDuration) = try await (chapterWriting, audioWriting)
        guard finalDuration.isNumeric, finalDuration.seconds > 0 else {
            throw PackagingError.unreadableAudio
        }
        progress?(0.9, nil)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writerFailure(writer) }

        try await M4BValidator.validateAudiobook(
            url: partialURL,
            expectedTitle: request.title,
            expectedChapterTitles: request.chapters.map(\.title),
            expectsArtwork: request.coverData != nil
        )
        do {
            try? FileManager.default.removeItem(at: request.outputURL)
            try FileManager.default.moveItem(at: partialURL, to: request.outputURL)
        } catch {
            throw PackagingError.commitFailed(error.localizedDescription)
        }
        committed = true
        progress?(1, nil)
        return request.outputURL
    }

    private static func appendAudiobookChapters(
        request: M4BAudiobookPackageRequest,
        normalizedSegments: [URL],
        context: AudiobookWriterContext,
        progress: (@Sendable (Double, String?) -> Void)?
    ) async throws {
        var chapterOffset = CMTime.zero
        for (index, segment) in normalizedSegments.enumerated() {
            try Task.checkCancellation()
            let duration = try await AVURLAsset(url: segment).load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else {
                throw PackagingError.unreadableAudio
            }
            try await appendText(
                request.chapters[index].title,
                duration: duration,
                presentationTime: chapterOffset,
                input: context.chapterInput,
                description: context.textDescription,
                writer: context.writer
            )
            chapterOffset = CMTimeAdd(chapterOffset, duration)
            progress?(
                0.1 + 0.2 * Double(index + 1) / Double(request.chapters.count),
                request.chapters[index].title
            )
        }
        context.chapterInput.markAsFinished()
    }

    private static func appendAudiobookAudio(
        _ urls: [URL],
        context: AudiobookWriterContext
    ) async throws -> CMTime {
        let duration = try await appendAudioSegments(
            urls,
            input: context.audioInput,
            writer: context.writer
        )
        context.audioInput.markAsFinished()
        return duration
    }

    /// Normalizes every runtime result to the frozen packaging format before it
    /// reaches AVAssetWriter. This keeps mixed sample rates/channel layouts from
    /// leaking into the chapter timeline and makes the conversion boundary explicit.
    private static func normalizeAudioSegments(
        _ urls: [URL],
        in directory: URL
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw PackagingError.unreadableAudio }

        return try urls.enumerated().map { index, url in
            try Task.checkCancellation()
            let inputFile: AVAudioFile
            do {
                inputFile = try AVAudioFile(forReading: url)
            } catch {
                throw PackagingError.unreadableAudio
            }
            let inputFormat = inputFile.processingFormat
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw PackagingError.validationFailed("输入音频格式无效")
            }
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw PackagingError.appendFailed(
                    "无法创建 AVAudioConverter：\(inputFormat) → \(outputFormat)"
                )
            }

            let outputURL = directory.appending(path: String(format: "%04d.caf", index))
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: outputFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let outputCapacity: AVAudioFrameCount = 4_096
            var reachedEnd = false
            while !reachedEnd {
                try Task.checkCancellation()
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: outputCapacity
                ) else { throw PackagingError.appendFailed("无法创建标准化输出缓冲区") }
                var conversionError: NSError?
                let inputReadError = AudioReadErrorBox()
                let status = converter.convert(to: outputBuffer, error: &conversionError) {
                    requestedPacketCount, inputStatus in
                    let remainingFrames = inputFile.length - inputFile.framePosition
                    guard remainingFrames > 0 else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    let ratio = inputFormat.sampleRate / outputFormat.sampleRate
                    let requestedCapacity = AVAudioFrameCount(max(
                        1,
                        ceil(Double(requestedPacketCount) * ratio) + 32
                    ))
                    let capacity = min(requestedCapacity, AVAudioFrameCount(remainingFrames))
                    guard let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: inputFormat,
                        frameCapacity: capacity
                    ) else {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        try inputFile.read(into: inputBuffer)
                        guard inputBuffer.frameLength > 0 else {
                            inputStatus.pointee = .endOfStream
                            return nil
                        }
                        inputStatus.pointee = .haveData
                        return inputBuffer
                    } catch {
                        inputReadError.store(error)
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                }
                if let readError = inputReadError.value {
                    let detail = readError as NSError
                    throw PackagingError.appendFailed(
                        "\(detail.domain) \(detail.code): \(detail.localizedDescription)"
                    )
                }
                if let conversionError {
                    throw PackagingError.appendFailed(conversionError.localizedDescription)
                }
                guard status != .error else {
                    throw PackagingError.appendFailed("AVAudioConverter 转换失败")
                }
                if outputBuffer.frameLength > 0 {
                    try outputFile.write(from: outputBuffer)
                }
                reachedEnd = status == .endOfStream
            }
            return outputURL
        }
    }

    private static func appendAudioSegments(
        _ urls: [URL],
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws -> CMTime {
        var segments: [AudioAppendPump.Segment] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw PackagingError.unreadableAudio
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw PackagingError.unreadableAudio }
            reader.add(output)
            guard reader.startReading() else { throw PackagingError.unreadableAudio }
            segments.append(.init(reader: reader, output: output))
        }
        return try await AudioAppendPump(input: input, writer: writer, segments: segments).run()
    }

    private static func totalDuration(of urls: [URL]) async throws -> CMTime {
        var total = CMTime.zero
        for url in urls {
            let duration = try await AVURLAsset(url: url).load(.duration)
            guard duration.isNumeric, duration.seconds > 0 else {
                throw PackagingError.unreadableAudio
            }
            total = CMTimeAdd(total, duration)
        }
        return total
    }

    private static func appendText(
        _ text: String,
        duration: CMTime,
        presentationTime: CMTime = .zero,
        input: AVAssetWriterInput,
        description: CMFormatDescription,
        writer: AVAssetWriter
    ) async throws {
        try await waitUntilReady(input, writer: writer)
        let bytes = Data(text.utf8.prefix(Int(UInt16.max)))
        let length = UInt16(bytes.count)
        var payload = Data([UInt8(length >> 8), UInt8(length & 0xff)])
        payload.append(bytes)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else {
            throw PackagingError.appendFailed("无法创建文本缓冲区")
        }
        status = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard status == noErr else { throw PackagingError.appendFailed("无法写入文本缓冲区") }
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var size = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: description,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample, input.append(sample) else {
            throw PackagingError.appendFailed(writer.error?.localizedDescription ?? "文本轨拒绝样本")
        }
    }

    private static func add(_ input: AVAssetWriterInput, name: String, writer: AVAssetWriter) throws {
        guard writer.canAdd(input) else { throw PackagingError.cannotAddTrack(name) }
        writer.add(input)
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else {
                let detail = (writer.error as NSError?).map {
                    "\($0.domain) \($0.code): \($0.localizedDescription); \($0.userInfo)"
                } ?? "status=\(writer.status.rawValue)"
                throw PackagingError.appendFailed("媒体写入器无响应：\(detail)")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func metadata(for request: M4BPackageRequest) -> [AVMetadataItem] {
        var result = [
            metadataItem(.commonIdentifierTitle, value: request.title),
            metadataItem(.commonIdentifierArtist, value: request.author),
            metadataItem(.commonIdentifierAlbumName, value: request.title),
            metadataItem(
                .commonIdentifierDescription,
                value: "第 \(request.chapterIndex + 1) 章 · \(request.chapterTitle)"
            ),
        ]
        if let language = request.languageCode {
            result.append(metadataItem(.commonIdentifierLanguage, value: language))
        }
        if let cover = request.coverData {
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = cover as NSData
            artwork.dataType = cover.starts(with: [0x89, 0x50, 0x4e, 0x47])
                ? kCMMetadataBaseDataType_PNG as String
                : kCMMetadataBaseDataType_JPEG as String
            result.append(artwork)
        }
        return result
    }

    private static func audiobookMetadata(
        for request: M4BAudiobookPackageRequest
    ) -> [AVMetadataItem] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var result = [
            metadataItem(.commonIdentifierTitle, value: request.title),
            metadataItem(.commonIdentifierArtist, value: request.author),
            metadataItem(.commonIdentifierAlbumName, value: request.title),
            metadataItem(.iTunesMetadataAuthor, value: request.author),
            metadataItem(.iTunesMetadataPerformer, value: request.narrator),
            metadataItem(.iTunesMetadataUserGenre, value: request.genre),
            metadataItem(.iTunesMetadataReleaseDate, value: formatter.string(from: request.publicationDate)),
            metadataItem(.iTunesMetadataEncodingTool, value: "AudiobookMaker"),
        ]
        if let language = request.languageCode {
            result.append(metadataItem(.commonIdentifierLanguage, value: language))
        }
        if let cover = request.coverData {
            let artwork = AVMutableMetadataItem()
            artwork.identifier = .commonIdentifierArtwork
            artwork.value = cover as NSData
            artwork.dataType = cover.starts(with: [0x89, 0x50, 0x4e, 0x47])
                ? kCMMetadataBaseDataType_PNG as String
                : kCMMetadataBaseDataType_JPEG as String
            result.append(artwork)
        }
        return result
    }

    private static func metadataItem(
        _ identifier: AVMetadataIdentifier,
        value: String
    ) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static func makeTextDescription() throws -> CMFormatDescription {
        let transparentBlack: [String: Any] = [
            kCMTextFormatDescriptionColor_Red as String: 0,
            kCMTextFormatDescriptionColor_Green as String: 0,
            kCMTextFormatDescriptionColor_Blue as String: 0,
            kCMTextFormatDescriptionColor_Alpha as String: 0,
        ]
        let opaqueWhite: [String: Any] = [
            kCMTextFormatDescriptionColor_Red as String: 255,
            kCMTextFormatDescriptionColor_Green as String: 255,
            kCMTextFormatDescriptionColor_Blue as String: 255,
            kCMTextFormatDescriptionColor_Alpha as String: 255,
        ]
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: -1,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: transparentBlack,
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: [
                kCMTextFormatDescriptionRect_Top as String: 0,
                kCMTextFormatDescriptionRect_Left as String: 0,
                kCMTextFormatDescriptionRect_Bottom as String: 0,
                kCMTextFormatDescriptionRect_Right as String: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                kCMTextFormatDescriptionStyle_StartChar as String: 0,
                kCMTextFormatDescriptionStyle_EndChar as String: 0,
                kCMTextFormatDescriptionStyle_Font as String: 1,
                kCMTextFormatDescriptionStyle_FontFace as String: 0,
                kCMTextFormatDescriptionStyle_FontSize as String: 18,
                kCMTextFormatDescriptionStyle_ForegroundColor as String: opaqueWhite,
            ],
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Helvetica"],
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Text,
            mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw PackagingError.cannotCreateWriter("无法创建文本格式")
        }
        return description
    }

    private static func writerFailure(_ writer: AVAssetWriter) -> PackagingError {
        guard let error = writer.error as NSError? else {
            return .writerFailed("未知错误")
        }
        return .writerFailed("\(error.domain) \(error.code): \(error.localizedDescription); \(error.userInfo)")
    }
}

nonisolated private final class AudioAppendPump: @unchecked Sendable {
    nonisolated struct Segment {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
    }

    private let input: AVAssetWriterInput
    private let writer: AVAssetWriter
    private let segments: [Segment]
    private let queue = DispatchQueue(label: "com.audiobookmaker.m4b.audio-writer")
    private var continuation: CheckedContinuation<CMTime, any Error>?
    private var segmentIndex = 0
    private var segmentOffset = CMTime.zero
    private var finalTime = CMTime.zero
    private var isDone = false

    init(input: AVAssetWriterInput, writer: AVAssetWriter, segments: [Segment]) {
        self.input = input
        self.writer = writer
        self.segments = segments
    }

    func run() async throws -> CMTime {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            input.requestMediaDataWhenReady(on: queue) { [weak self] in
                self?.drain()
            }
        }
    }

    private func drain() {
        guard !isDone else { return }
        do {
            while input.isReadyForMoreMediaData, !isDone {
                guard segmentIndex < segments.count else {
                    finish(returning: finalTime)
                    return
                }
                let segment = segments[segmentIndex]
                if let sample = segment.output.copyNextSampleBuffer() {
                    let shifted = try Self.shift(sample, by: segmentOffset)
                    guard input.append(shifted) else {
                        throw PackagingError.appendFailed(
                            writer.error?.localizedDescription ?? "音频轨拒绝样本"
                        )
                    }
                    finalTime = max(
                        finalTime,
                        CMTimeAdd(
                            CMSampleBufferGetPresentationTimeStamp(shifted),
                            CMSampleBufferGetDuration(shifted)
                        )
                    )
                } else {
                    guard segment.reader.status == .completed else {
                        throw PackagingError.appendFailed(
                            segment.reader.error?.localizedDescription ?? "读取音频失败"
                        )
                    }
                    segmentOffset = finalTime
                    segmentIndex += 1
                }
            }
        } catch {
            finish(throwing: error)
        }
    }

    private func finish(returning time: CMTime) {
        guard !isDone else { return }
        isDone = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: time)
    }

    private func finish(throwing error: any Error) {
        guard !isDone else { return }
        isDone = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: error)
    }

    private static func shift(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
        let decode = CMSampleBufferGetDecodeTimeStamp(sample)
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sample),
            presentationTimeStamp: presentation.isValid ? CMTimeAdd(presentation, offset) : offset,
            decodeTimeStamp: decode.isValid ? CMTimeAdd(decode, offset) : .invalid
        )
        var shifted: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &shifted
        )
        guard status == noErr, let shifted else {
            throw PackagingError.appendFailed("无法调整样本时间")
        }
        return shifted
    }
}

nonisolated enum M4BValidator {
    static func validateAudiobook(
        url: URL,
        expectedTitle: String,
        expectedChapterTitles: [String],
        expectsArtwork: Bool
    ) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PackagingError.validationFailed("文件不存在")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isNumeric, duration.seconds > 0, audio.count == 1 else {
            throw PackagingError.validationFailed("整书音频轨或时长无效")
        }
        let associated = try await audio[0].loadAssociatedTracks(ofType: .chapterList)
        guard associated.count == 1 else {
            throw PackagingError.validationFailed("整书章节轨未关联")
        }
        let chapterTitles = try readAllText(from: associated[0], asset: asset)
        guard chapterTitles == expectedChapterTitles else {
            throw PackagingError.validationFailed("整书章节标记不匹配")
        }
        let metadata = try await asset.load(.commonMetadata)
        var titleMatches = false
        var hasArtwork = false
        for item in metadata {
            if item.commonKey == .commonKeyTitle,
               try await item.load(.stringValue) == expectedTitle {
                titleMatches = true
            }
            if item.commonKey == .commonKeyArtwork,
               try await item.load(.dataValue) != nil {
                hasArtwork = true
            }
        }
        guard titleMatches, !expectsArtwork || hasArtwork else {
            throw PackagingError.validationFailed("整书标题或封面元数据不完整")
        }
    }

    @discardableResult
    static func validate(
        url: URL,
        expectedTitle: String,
        expectedChapterTitle: String,
        expectedFullText: String
    ) async throws -> Double {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PackagingError.validationFailed("文件不存在")
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let text = try await asset.loadTracks(withMediaType: .text)
        guard duration.isNumeric, duration.seconds > 0, audio.count == 1, text.count == 2 else {
            throw PackagingError.validationFailed("音频、时长或文本轨不完整")
        }
        let associated = try await audio[0].loadAssociatedTracks(ofType: .chapterList)
        guard associated.count == 1 else {
            throw PackagingError.validationFailed("章节轨未关联")
        }
        let metadata = try await asset.load(.commonMetadata)
        var titleMatches = false
        for item in metadata where item.commonKey == .commonKeyTitle {
            if try await item.load(.stringValue) == expectedTitle { titleMatches = true }
        }
        guard titleMatches else { throw PackagingError.validationFailed("书名元数据不匹配") }
        let chapter = try readText(from: associated[0], asset: asset)
        let bodyTrack = text.first { track in !associated.contains { $0.trackID == track.trackID } }
        guard chapter == expectedChapterTitle,
              let bodyTrack,
              try readText(from: bodyTrack, asset: asset) == expectedFullText else {
            throw PackagingError.validationFailed("章节或正文文本不匹配")
        }
        return duration.seconds
    }

    private static func readText(from track: AVAssetTrack, asset: AVAsset) throws -> String {
        guard let first = try readAllText(from: track, asset: asset).first else {
            throw PackagingError.validationFailed("文本轨没有正文")
        }
        return first
    }

    private static func readAllText(from track: AVAssetTrack, asset: AVAsset) throws -> [String] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw PackagingError.validationFailed("文本轨不可读") }
        reader.add(output)
        guard reader.startReading() else { throw PackagingError.validationFailed("文本轨无法启动") }
        var result: [String] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let count = CMBlockBufferGetDataLength(block)
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!)
            }
            guard status == noErr, data.count >= 2 else { continue }
            let length = Int(data[0]) << 8 | Int(data[1])
            if length > 0 {
                result.append(String(decoding: data.dropFirst(2).prefix(length), as: UTF8.self))
            }
        }
        guard !result.isEmpty else { throw PackagingError.validationFailed("文本轨没有正文") }
        return result
    }
}
