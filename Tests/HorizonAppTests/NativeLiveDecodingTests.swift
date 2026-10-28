import XCTest
import AVFoundation
import VideoToolbox
import HorizonCore
@testable import FrigateHorizon

final class NativeLiveDecodingTests: XCTestCase {
    @MainActor
    func testHTTPSFragmentIsDecodedByAppleVideoFrameworks() async throws {
        // A pre-encoded color-bar fixture avoids depending on simulator encoder availability.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "native-live-synthetic", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let sourceTrack = try XCTUnwrap(tracks.first)
        let descriptions = try await sourceTrack.load(.formatDescriptions)
        let sourceFormat = try XCTUnwrap(descriptions.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(sourceFormat), kCMVideoCodecType_H264)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var encoded: CMSampleBuffer?
        while let candidate = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(candidate) > 0, CMSampleBufferGetDataBuffer(candidate) != nil {
                encoded = candidate
                break
            }
        }
        let frame = try XCTUnwrap(encoded, "The synthetic fixture must contain a compressed video frame.")
        let atoms = try XCTUnwrap(CMFormatDescriptionGetExtension(sourceFormat,
            extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Data])
        let config = try XCTUnwrap(atoms["avcC"])
        let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(frame))
        var payload = Data(count: CMBlockBufferGetDataLength(block))
        let length = payload.count
        let copyStatus = payload.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
        }
        XCTAssertEqual(copyStatus, noErr)
        reader.cancelReading()

        var demuxer = FragmentedMP4()
        _ = try demuxer.append(initialization(configuration: config))
        let sample = try XCTUnwrap(demuxer.append(fragment(payload: payload)).first)
        let track = try XCTUnwrap(demuxer.tracks[1])
        let live = HTTPSLiveStream()
        let format = try live.format(track)
        let buffer = try live.makeBuffer(sample, format: format)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, 64)
        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 1)

        let decoded = DecodedFrame()
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { context, _, status, _, image, _, _ in
                guard let context else { return }
                let result = Unmanaged<DecodedFrame>.fromOpaque(context).takeUnretainedValue()
                result.set(status == noErr && image != nil)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(decoded).toOpaque()
        )
        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: nil,
            outputCallback: &callback, decompressionSessionOut: &session
        ), noErr)
        let decoder = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(decoder) }
        XCTAssertEqual(VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: buffer,
            flags: [], frameRefcon: nil, infoFlagsOut: nil), noErr)
        XCTAssertEqual(VTDecompressionSessionFinishDelayedFrames(decoder), noErr)
        XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(decoder), noErr)
        XCTAssertTrue(decoded.value, "The native HTTPS path must produce an actual decoded video frame.")
    }

    private func initialization(configuration: Data) -> Data {
        var header = Data(repeating: 0, count: 16)
        header.replaceSubrange(12..<16, with: uint(1))
        var clock = Data(repeating: 0, count: 16)
        clock.replaceSubrange(12..<16, with: uint(90000))
        var entry = Data(repeating: 0, count: 78)
        entry.replaceSubrange(24..<28, with: Data([0, 64, 0, 64]))
        entry.append(box("avcC", configuration))
        let stsd = box("stsd", uint(0) + uint(1) + box("avc1", entry))
        let media = box("mdia", box("mdhd", clock) + box("minf", box("stbl", stsd)))
        return box("moov", box("trak", box("tkhd", header) + media))
    }

    private func fragment(payload: Data) -> Data {
        let header = box("tfhd", uint(0x20000) + uint(1))
        let clock = box("tfdt", uint(0) + uint(0))
        func run(_ offset: UInt32) -> Data {
            box("trun", uint(0x701) + uint(1) + uint(offset)
                + uint(3000) + uint(UInt32(payload.count)) + uint(0x2000000))
        }
        let temporary = box("moof", box("traf", header + clock + run(0)))
        return box("moof", box("traf", header + clock + run(UInt32(temporary.count + 8)))) + box("mdat", payload)
    }

    private func uint(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
              UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    private func box(_ type: String, _ contents: Data) -> Data {
        uint(UInt32(contents.count + 8)) + Data(type.utf8) + contents
    }
}

private final class DecodedFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var decoded = false
    func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; decoded = value }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return decoded }
}
