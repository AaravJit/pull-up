import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PullUpFeatures

/// Security re-check G3 (docs/SECURITY_REPORT.md): videos used to be
/// uploaded exactly as picked, GPS location included.
@Suite("Video sharing")
struct VideoSharingTests {
    struct FixtureFailed: Error {}

    /// A one-second movie that carries a location, like one from the Camera app.
    static func movieWithLocation() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let location = AVMutableMetadataItem()
        location.identifier = .quickTimeMetadataLocationISO6709
        location.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
        location.value = "+37.3349-122.0090+010.000/" as NSString
        writer.metadata = [location]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureFailed() }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer, adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)) else {
                throw writer.error ?? FixtureFailed()
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? FixtureFailed() }
        return try Data(contentsOf: url)
    }

    static func asset(_ data: Data, ext: String) throws -> AVURLAsset {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return AVURLAsset(url: url)
    }

    static func hasLocation(_ asset: AVURLAsset) async throws -> Bool {
        let items = try await asset.load(.metadata)
        return items.contains { $0.identifier == .quickTimeMetadataLocationISO6709 || $0.commonKey == .commonKeyLocation }
    }

    @Test func postedVideosLoseTheirLocation() async throws {
        let picked = try await Self.movieWithLocation()
        // The fixture really does carry a location.
        #expect(try await Self.hasLocation(Self.asset(picked, ext: "mov")))

        let converted = try #require(await VideoInfo.shareable(picked))
        let shared = try Self.asset(converted, ext: "mp4")
        #expect(try await Self.hasLocation(shared) == false)
        // Still the same clip.
        let duration = try await shared.load(.duration)
        #expect(abs(duration.seconds - 1) < 0.2)
    }

    @Test func somethingThatIsNotAVideoIsRefused() async {
        #expect(await VideoInfo.shareable(Data("not a movie".utf8)) == nil)
    }
}
