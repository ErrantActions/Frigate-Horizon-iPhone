import XCTest
@testable import HorizonCore

final class FragmentedMP4Tests: XCTestCase {
    func testReadsVideoInitializationAndFragmentTiming() throws {
        var parser = FragmentedMP4()
        XCTAssertTrue(try parser.append(initialization()).isEmpty)
        let track = try XCTUnwrap(parser.tracks[1])
        XCTAssertEqual(track.codec, "avc1")
        XCTAssertEqual(track.timescale, 90000)
        XCTAssertEqual(track.width, 1280)
        XCTAssertEqual(track.height, 720)
        let samples = try parser.append(fragment())
        let sample = try XCTUnwrap(samples.first)
        XCTAssertEqual(sample.data, Data([0, 0, 0, 1, 0x65]))
        XCTAssertEqual(sample.duration, 1.0 / 30, accuracy: 0.00001)
        XCTAssertEqual(sample.decodeTime, 2, accuracy: 0.00001)
        XCTAssertEqual(sample.presentationTime, 2, accuracy: 0.00001)
        XCTAssertTrue(sample.keyframe)
    }

    func testSignedCompositionOffsetAndNonKeyframeFlags() throws {
        var parser = FragmentedMP4()
        _ = try parser.append(initialization())
        let sample = try XCTUnwrap(parser.append(fragment(composition: -3000, flags: 0x1010000)).first)
        XCTAssertEqual(sample.presentationTime, 2 - 1.0 / 30, accuracy: 0.00001)
        XCTAssertFalse(sample.keyframe)
    }

    func testFragmentRequiresInitializationAndValidDataRange() throws {
        var parser = FragmentedMP4()
        XCTAssertThrowsError(try parser.append(fragment()))
        _ = try parser.append(initialization())
        XCTAssertThrowsError(try parser.append(fragment(declaredSize: 1024)))
        XCTAssertThrowsError(try parser.append(fragment(offset: -100)))
    }

    func testTruncatedOrOversizedBoxesFailExplicitly() throws {
        let initData = initialization()
        for count in [1, 7, initData.count - 1] {
            var parser = FragmentedMP4()
            XCTAssertThrowsError(try parser.append(Data(initData.prefix(count))))
        }
        var parser = FragmentedMP4()
        XCTAssertThrowsError(try parser.append(Data([0, 0, 0, 4, 109, 111, 111, 118])))
        XCTAssertThrowsError(try parser.append(box("moov", box("trak", Data()))))
    }

    func testConfiguredHTTPSWebSocketPreservesProxyPath() throws {
        let address = try ServerAddress("https://example.com/horizon")
        let url = address.webSocket(stream: "Front & Yard", transport: "mse")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.path, "/horizon/live/mse/api/ws")
        XCTAssertEqual(components.queryItems?.first?.value, "Front & Yard")
    }

    func testAACAudioConfigurationIsExtractedForNativeDecoding() throws {
        var parser = FragmentedMP4()
        _ = try parser.append(initialization(includeAudio: true))
        let track = try XCTUnwrap(parser.tracks[2])
        XCTAssertEqual(track.codec, "mp4a")
        XCTAssertEqual(track.channels, 2)
        XCTAssertEqual(track.timescale, 48000)
        XCTAssertEqual(track.configuration, Data([0x11, 0x90]))
    }

    private func initialization(includeAudio: Bool = false) -> Data {
        var header = Data(repeating: 0, count: 16)
        header.replaceSubrange(12..<16, with: uint(1))
        var clock = Data(repeating: 0, count: 16)
        clock.replaceSubrange(12..<16, with: uint(90000))
        var entry = Data(repeating: 0, count: 78)
        entry.replaceSubrange(24..<28, with: Data([5, 0, 2, 208]))
        entry.append(box("avcC", Data([1, 100, 0, 41, 255])))
        let sampleDescription = box("stsd", Data(repeating: 0, count: 4) + uint(1) + box("avc1", entry))
        let table = box("stbl", sampleDescription)
        let media = box("mdia", box("mdhd", clock) + box("minf", table))
        var tracks = box("trak", box("tkhd", header) + media)
        if includeAudio {
            var audioHeader = Data(repeating: 0, count: 16)
            audioHeader.replaceSubrange(12..<16, with: uint(2))
            var audioClock = Data(repeating: 0, count: 16)
            audioClock.replaceSubrange(12..<16, with: uint(48000))
            var audioEntry = Data(repeating: 0, count: 28)
            audioEntry.replaceSubrange(16..<18, with: Data([0, 2]))
            let config = descriptor(5, Data([0x11, 0x90]))
            let decoder = descriptor(4, Data([0x40, 0x15]) + Data(repeating: 0, count: 11) + config)
            let esds = box("esds", uint(0) + descriptor(3, Data([0, 2, 0]) + decoder))
            let stsd = box("stsd", uint(0) + uint(1) + box("mp4a", audioEntry + esds))
            let audioMedia = box("mdia", box("mdhd", audioClock) + box("minf", box("stbl", stsd)))
            tracks.append(box("trak", box("tkhd", audioHeader) + audioMedia))
        }
        return box("ftyp", Data("isom".utf8)) + box("moov", tracks)
    }

    private func descriptor(_ tag: UInt8, _ content: Data) -> Data { Data([tag, UInt8(content.count)]) + content }

    private func fragment(composition: Int32 = 0, flags: UInt32 = 0x2000000,
                          declaredSize: UInt32 = 5, offset: Int32? = nil) -> Data {
        let header = box("tfhd", uint(0x20000) + uint(1))
        let clock = box("tfdt", uint(0) + uint(180000))
        func run(_ dataOffset: Int32) -> Data {
            box("trun", uint(0x01000F01) + uint(1) + uint(UInt32(bitPattern: dataOffset))
                + uint(3000) + uint(declaredSize) + uint(flags) + uint(UInt32(bitPattern: composition)))
        }
        let temporary = box("moof", box("traf", header + clock + run(0)))
        let movie = box("moof", box("traf", header + clock + run(offset ?? Int32(temporary.count + 8))))
        return movie + box("mdat", Data([0, 0, 0, 1, 0x65]))
    }

    private func uint(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
              UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    private func box(_ type: String, _ contents: Data) -> Data {
        uint(UInt32(contents.count + 8)) + Data(type.utf8) + contents
    }
}
