@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import AudiobookMaker

@Suite("M4B AVFoundation spike")
struct M4BSpikeTests {
    @Test("AAC, artwork, t=0 chapter and independent full-text track round-trip")
    func roundTrip() async throws {
        let retainedOutput = ProcessInfo.processInfo.environment["AUDIOBOOKMAKER_M4B_SPIKE_OUTPUT"]
            .map { URL(filePath: $0) }
        let directory = retainedOutput?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            if retainedOutput == nil {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let outputURL = retainedOutput ?? directory.appending(path: "spike.m4b")
        let result = try await M4BSpikeWriter.write(to: outputURL)
        let asset = AVURLAsset(url: result.url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - result.duration) < 0.1)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let textTracks = try await asset.loadTracks(withMediaType: .text)
        #expect(audioTracks.count == 1)
        #expect(textTracks.count == 2)
        let audioTrack = try #require(audioTracks.first)
        let audioDescriptions = try await audioTrack.load(.formatDescriptions)
        let audioDescription = try #require(audioDescriptions.first)
        #expect(CMFormatDescriptionGetMediaSubType(audioDescription) == kAudioFormatMPEG4AAC)

        let metadata = try await asset.load(.commonMetadata)
        #expect(metadata.contains { $0.commonKey == .commonKeyArtwork })
        var hasExpectedTitle = false
        for item in metadata where item.commonKey == .commonKeyTitle {
            if try await item.load(.stringValue) == "AudiobookMaker Spike" {
                hasExpectedTitle = true
            }
        }
        #expect(hasExpectedTitle)

        let chapterTracks = try await audioTrack.loadAssociatedTracks(ofType: .chapterList)
        let chapterTrack = try #require(chapterTracks.first)
        #expect(chapterTracks.count == 1)

        let chapterSample = try readOnlyTextSample(from: chapterTrack, asset: asset)
        #expect(chapterSample.presentationTime == .zero)
        #expect(abs(chapterSample.duration.seconds - result.duration) < 0.1)
        #expect(chapterSample.text == result.chapterTitle)

        let fullTextTrack = try #require(textTracks.first { track in
            !chapterTracks.contains { $0.trackID == track.trackID }
        })
        let fullTextSample = try readOnlyTextSample(from: fullTextTrack, asset: asset)
        #expect(fullTextSample.presentationTime == .zero)
        #expect(abs(fullTextSample.duration.seconds - result.duration) < 0.1)
        #expect(fullTextSample.text == result.fullText)
    }

    private func readOnlyTextSample(
        from track: AVAssetTrack,
        asset: AVAsset
    ) throws -> (text: String, presentationTime: CMTime, duration: CMTime) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        #expect(reader.canAdd(output))
        reader.add(output)
        #expect(reader.startReading())
        var meaningfulSamples: [(String, CMTime, CMTime)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else {
                continue // AVAssetReader may expose a zero-sample edit boundary.
            }
            let size = CMBlockBufferGetDataLength(dataBuffer)
            var bytes = Data(count: size)
            let status = bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(
                    dataBuffer,
                    atOffset: 0,
                    dataLength: size,
                    destination: destination.baseAddress!
                )
            }
            #expect(status == kCMBlockBufferNoErr)
            guard bytes.count >= 2 else { continue }
            let declaredLength = Int(bytes[0]) << 8 | Int(bytes[1])
            guard declaredLength > 0 else { continue }
            meaningfulSamples.append((
                String(decoding: bytes.dropFirst(2).prefix(declaredLength), as: UTF8.self),
                CMSampleBufferGetPresentationTimeStamp(sample),
                CMSampleBufferGetDuration(sample)
            ))
        }
        #expect(meaningfulSamples.count == 1)
        let sample = try #require(meaningfulSamples.first)
        return (sample.0, sample.1, sample.2)
    }
}
