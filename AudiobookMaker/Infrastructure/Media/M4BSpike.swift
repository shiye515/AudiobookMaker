@preconcurrency import AVFoundation
import CoreMedia
import Foundation

nonisolated enum M4BSpikeError: Error, Equatable {
    case cannotCreateWriter(String)
    case cannotCreateFormatDescription(OSStatus)
    case cannotCreateSampleBuffer(OSStatus)
    case cannotAddInput(String)
    case cannotAssociateChapterTrack
    case inputBackPressure(String)
    case appendFailed(String)
    case writerFailed(String)
}

nonisolated struct M4BSpikeResult: Sendable {
    let url: URL
    let duration: TimeInterval
    let chapterTitle: String
    let fullText: String
}

/// A deliberately small AVFoundation feasibility spike. Production packaging is
/// implemented later by M4BPackager; this type freezes only the container choices
/// that have been proven to round-trip through AVURLAsset.
nonisolated enum M4BSpikeWriter {
    static let duration: TimeInterval = 30
    static let sampleRate: Double = 44_100
    static let channelCount: UInt32 = 1
    static let bitRate = 64_000

    static func write(to outputURL: URL) async throws -> M4BSpikeResult {
        try? FileManager.default.removeItem(at: outputURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        } catch {
            throw M4BSpikeError.cannotCreateWriter(error.localizedDescription)
        }

        let audioDescription = try makeAudioFormatDescription()
        let textDescription = try makeTextFormatDescription()
        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channelCount),
                AVEncoderBitRateKey: bitRate,
            ],
            sourceFormatHint: audioDescription
        )
        let chapterInput = AVAssetWriterInput(
            mediaType: .text,
            outputSettings: nil,
            sourceFormatHint: textDescription
        )
        let fullTextInput = AVAssetWriterInput(
            mediaType: .text,
            outputSettings: nil,
            sourceFormatHint: textDescription
        )
        audioInput.expectsMediaDataInRealTime = false
        chapterInput.expectsMediaDataInRealTime = false
        fullTextInput.expectsMediaDataInRealTime = false
        chapterInput.mediaDataLocation = .interleavedWithMainMediaData
        fullTextInput.mediaDataLocation = .interleavedWithMainMediaData

        try add(audioInput, named: "audio", to: writer)
        try add(chapterInput, named: "chapter", to: writer)
        try add(fullTextInput, named: "full text", to: writer)

        guard audioInput.canAddTrackAssociation(
            withTrackOf: chapterInput,
            type: AVAssetTrack.AssociationType.chapterList.rawValue
        ) else {
            throw M4BSpikeError.cannotAssociateChapterTrack
        }
        audioInput.addTrackAssociation(
            withTrackOf: chapterInput,
            type: AVAssetTrack.AssociationType.chapterList.rawValue
        )

        let chapterTitle = "第一章 · AVFoundation Spike"
        let fullText = "这是覆盖完整三十秒音频的独立整章文本轨。AudiobookMaker M4B spike."
        writer.metadata = makeContainerMetadata()

        guard writer.startWriting() else {
            throw writerError(writer)
        }
        writer.startSession(atSourceTime: .zero)

        try appendPCM(to: audioInput, description: audioDescription, writer: writer)
        try appendText(
            chapterTitle,
            duration: CMTime(seconds: duration, preferredTimescale: 600),
            to: chapterInput,
            description: textDescription,
            writer: writer
        )
        try appendText(
            fullText,
            duration: CMTime(seconds: duration, preferredTimescale: 600),
            to: fullTextInput,
            description: textDescription,
            writer: writer
        )

        audioInput.markAsFinished()
        chapterInput.markAsFinished()
        fullTextInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writerError(writer)
        }

        return M4BSpikeResult(
            url: outputURL,
            duration: duration,
            chapterTitle: chapterTitle,
            fullText: fullText
        )
    }

    private static func add(
        _ input: AVAssetWriterInput,
        named name: String,
        to writer: AVAssetWriter
    ) throws {
        guard writer.canAdd(input) else {
            throw M4BSpikeError.cannotAddInput(name)
        }
        writer.add(input)
    }

    private static func makeAudioFormatDescription() throws -> CMAudioFormatDescription {
        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw M4BSpikeError.cannotCreateFormatDescription(status)
        }
        return description
    }

    private static func makeTextFormatDescription() throws -> CMFormatDescription {
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
        let textBox: [String: Any] = [
            kCMTextFormatDescriptionRect_Top as String: 0,
            kCMTextFormatDescriptionRect_Left as String: 0,
            kCMTextFormatDescriptionRect_Bottom as String: 0,
            kCMTextFormatDescriptionRect_Right as String: 0,
        ]
        let defaultStyle: [String: Any] = [
            kCMTextFormatDescriptionStyle_StartChar as String: 0,
            kCMTextFormatDescriptionStyle_EndChar as String: 0,
            kCMTextFormatDescriptionStyle_Font as String: 1,
            kCMTextFormatDescriptionStyle_FontFace as String: 0,
            kCMTextFormatDescriptionStyle_FontSize as String: 18,
            kCMTextFormatDescriptionStyle_ForegroundColor as String: opaqueWhite,
        ]
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: -1,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: transparentBlack,
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: textBox,
            kCMTextFormatDescriptionExtension_DefaultStyle as String: defaultStyle,
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
            throw M4BSpikeError.cannotCreateFormatDescription(status)
        }
        return description
    }

    private static func appendPCM(
        to input: AVAssetWriterInput,
        description: CMAudioFormatDescription,
        writer: AVAssetWriter
    ) throws {
        let totalFrames = Int64(sampleRate * duration)
        // One 30-second mono PCM buffer is only ~2.6 MB. Keeping the feasibility
        // sample to one append avoids conflating the container spike with the
        // production stream scheduler that M4BPackager will own.
        let framesPerBuffer = totalFrames
        var firstFrame: Int64 = 0
        while firstFrame < totalFrames {
            try waitUntilReady(input, named: "audio", writer: writer)
            let frameCount = min(framesPerBuffer, totalFrames - firstFrame)
            let byteCount = Int(frameCount * 2)
            var blockBuffer: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == kCMBlockBufferNoErr, let blockBuffer else {
                throw M4BSpikeError.cannotCreateSampleBuffer(status)
            }
            let silence = Data(count: byteCount)
            status = silence.withUnsafeBytes { bytes in
                CMBlockBufferReplaceDataBytes(
                    with: bytes.baseAddress!,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: byteCount
                )
            }
            guard status == kCMBlockBufferNoErr else {
                throw M4BSpikeError.cannotCreateSampleBuffer(status)
            }

            var sampleBuffer: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: description,
                sampleCount: CMItemCount(frameCount),
                presentationTimeStamp: CMTime(value: firstFrame, timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            )
            guard status == noErr, let sampleBuffer else {
                throw M4BSpikeError.cannotCreateSampleBuffer(status)
            }
            guard input.append(sampleBuffer) else {
                throw appendError("audio", writer: writer)
            }
            firstFrame += frameCount
        }
    }

    private static func appendText(
        _ text: String,
        duration: CMTime,
        to input: AVAssetWriterInput,
        description: CMFormatDescription,
        writer: AVAssetWriter
    ) throws {
        try waitUntilReady(input, named: "text", writer: writer)
        let textData = Data(text.utf8)
        precondition(textData.count <= Int(UInt16.max))
        let length = UInt16(textData.count)
        var payload = Data([UInt8(length >> 8), UInt8(length & 0xff)])
        payload.append(textData)

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw M4BSpikeError.cannotCreateSampleBuffer(status)
        }
        status = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: payload.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw M4BSpikeError.cannotCreateSampleBuffer(status)
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: description,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw M4BSpikeError.cannotCreateSampleBuffer(status)
        }
        guard input.append(sampleBuffer) else {
            throw appendError("text", writer: writer)
        }
    }

    private static func waitUntilReady(
        _ input: AVAssetWriterInput,
        named name: String,
        writer: AVAssetWriter
    ) throws {
        let deadline = Date().addingTimeInterval(10)
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, Date() < deadline else {
                throw M4BSpikeError.inputBackPressure(name)
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private static func makeContainerMetadata() -> [AVMetadataItem] {
        let title = metadataItem(.commonIdentifierTitle, value: "AudiobookMaker Spike")
        let artist = metadataItem(.commonIdentifierArtist, value: "AudiobookMaker")
        let album = metadataItem(.commonIdentifierAlbumName, value: "Container Validation")
        let artwork = AVMutableMetadataItem()
        artwork.identifier = .commonIdentifierArtwork
        artwork.value = coverPNG as NSData
        artwork.dataType = kCMMetadataBaseDataType_PNG as String
        return [title, artist, album, artwork]
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

    private static let coverPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private static func appendError(
        _ input: String,
        writer: AVAssetWriter
    ) -> M4BSpikeError {
        .appendFailed("\(input): \(writer.error?.localizedDescription ?? "unknown error")")
    }

    private static func writerError(_ writer: AVAssetWriter) -> M4BSpikeError {
        guard let error = writer.error as NSError? else {
            return .writerFailed("unknown error")
        }
        return .writerFailed(
            "\(error.domain) \(error.code): \(error.localizedDescription); \(error.userInfo)"
        )
    }
}
