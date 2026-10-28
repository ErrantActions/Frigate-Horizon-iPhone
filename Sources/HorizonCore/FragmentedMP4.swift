import Foundation

public struct MP4Track: Sendable {
    public let id: Int
    public let codec: String
    public let timescale: Double
    public let width: Int
    public let height: Int
    public let channels: Int
    public let configuration: Data
    public var isVideo: Bool { codec == "avc1" || codec == "hvc1" || codec == "hev1" }
}

public struct MP4Sample: Sendable {
    public let trackID: Int
    public let presentationTime: Double
    public let decodeTime: Double
    public let duration: Double
    public let keyframe: Bool
    public let data: Data
}

/// Reads the fragmented MP4 carried by go2rtc's authenticated MSE WebSocket.
public struct FragmentedMP4: Sendable {
    public private(set) var tracks: [Int: MP4Track] = [:]
    public init() {}

    public mutating func append(_ data: Data) throws -> [MP4Sample] {
        guard data.count <= 16 * 1024 * 1024 else { throw malformed() }
        let reader = MP4Reader(bytes: Array(data))
        let boxes = try reader.boxes(in: 0..<data.count)
        if let movie = boxes.first(where: { $0.type == "moov" }) {
            tracks = try parseTracks(reader, movie: movie)
        }
        var result: [MP4Sample] = []
        for fragment in boxes.filter({ $0.type == "moof" }) {
            guard !tracks.isEmpty else { throw malformed() }
            let media = boxes.first { $0.type == "mdat" && $0.start >= fragment.end }
            guard let media else { throw malformed() }
            for traf in try reader.children(fragment).filter({ $0.type == "traf" }) {
                let children = try reader.children(traf)
                guard let header = children.first(where: { $0.type == "tfhd" }),
                      let clock = children.first(where: { $0.type == "tfdt" })
                else { throw malformed() }
                let headerFlags = try reader.uint(header.payload, count: 4) & 0xFFFFFF
                let id = try reader.uint(header.payload + 4, count: 4)
                guard let track = tracks[id] else { throw malformed() }
                var cursor = header.payload + 8
                if headerFlags & 1 != 0 { throw HorizonError.message("Absolute MP4 data offsets are unsupported.") }
                if headerFlags & 2 != 0 { cursor += 4 }
                var defaultDuration = 0
                var defaultSize = 0
                var defaultFlags = 0
                if headerFlags & 8 != 0 { defaultDuration = try reader.uint(cursor, count: 4); cursor += 4 }
                if headerFlags & 16 != 0 { defaultSize = try reader.uint(cursor, count: 4); cursor += 4 }
                if headerFlags & 32 != 0 { defaultFlags = try reader.uint(cursor, count: 4); cursor += 4 }
                guard cursor <= header.end else { throw malformed() }
                let clockVersion = try reader.uint(clock.payload, count: 1)
                var decode = Double(try reader.uint(clock.payload + 4, count: clockVersion == 1 ? 8 : 4))
                var dataCursor = media.payload
                for run in children.filter({ $0.type == "trun" }) {
                    let version = try reader.uint(run.payload, count: 1)
                    let flags = try reader.uint(run.payload, count: 4) & 0xFFFFFF
                    let count = try reader.uint(run.payload + 4, count: 4)
                    guard count <= 4096 else { throw malformed() }
                    var at = run.payload + 8
                    if flags & 1 != 0 {
                        let offset = Int(Int32(bitPattern: UInt32(try reader.uint(at, count: 4))))
                        dataCursor = fragment.start + offset
                        at += 4
                    }
                    var firstFlags = defaultFlags
                    if flags & 4 != 0 { firstFlags = try reader.uint(at, count: 4); at += 4 }
                    for index in 0..<count {
                        var duration = defaultDuration
                        var size = defaultSize
                        var sampleFlags = index == 0 ? firstFlags : defaultFlags
                        var composition = 0
                        if flags & 0x100 != 0 { duration = try reader.uint(at, count: 4); at += 4 }
                        if flags & 0x200 != 0 { size = try reader.uint(at, count: 4); at += 4 }
                        if flags & 0x400 != 0 { sampleFlags = try reader.uint(at, count: 4); at += 4 }
                        if flags & 0x800 != 0 {
                            let value = try reader.uint(at, count: 4)
                            composition = version == 1 ? Int(Int32(bitPattern: UInt32(value))) : value
                            at += 4
                        }
                        guard at <= run.end, size > 0, duration > 0,
                              dataCursor >= media.payload, dataCursor <= media.end,
                              size <= media.end - dataCursor else { throw malformed() }
                        result.append(MP4Sample(
                            trackID: id, presentationTime: (decode + Double(composition)) / track.timescale,
                            decodeTime: decode / track.timescale, duration: Double(duration) / track.timescale,
                            keyframe: sampleFlags & 0x10000 == 0,
                            data: Data(reader.bytes[dataCursor..<(dataCursor + size)])
                        ))
                        dataCursor += size
                        decode += Double(duration)
                    }
                }
            }
        }
        return result
    }

    private func parseTracks(_ reader: MP4Reader, movie: MP4Box) throws -> [Int: MP4Track] {
        var result: [Int: MP4Track] = [:]
        for trak in try reader.children(movie).filter({ $0.type == "trak" }) {
            let children = try reader.children(trak)
            guard let tkhd = children.first(where: { $0.type == "tkhd" }),
                  let mdia = children.first(where: { $0.type == "mdia" }) else { throw malformed() }
            let version = try reader.uint(tkhd.payload, count: 1)
            let id = try reader.uint(tkhd.payload + (version == 1 ? 20 : 12), count: 4)
            let media = try reader.children(mdia)
            guard let mdhd = media.first(where: { $0.type == "mdhd" }),
                  let minf = media.first(where: { $0.type == "minf" }),
                  let stbl = try reader.children(minf).first(where: { $0.type == "stbl" }),
                  let stsd = try reader.children(stbl).first(where: { $0.type == "stsd" })
            else { throw malformed() }
            guard stsd.end - stsd.payload >= 8,
                  let entry = try reader.boxes(in: (stsd.payload + 8)..<stsd.end).first
            else { throw malformed() }
            let mediaVersion = try reader.uint(mdhd.payload, count: 1)
            let scale = try reader.uint(mdhd.payload + (mediaVersion == 1 ? 20 : 12), count: 4)
            guard scale > 0 else { throw malformed() }
            let video = ["avc1", "hvc1", "hev1"].contains(entry.type)
            guard video || entry.type == "mp4a" else {
                throw HorizonError.message("Unsupported live codec: \(entry.type). Select H.264/H.265 with AAC audio.")
            }
            let headerSize = video ? 78 : 28
            guard entry.end - entry.payload >= headerSize else { throw malformed() }
            let atoms = try reader.boxes(in: (entry.payload + headerSize)..<entry.end)
            let configName = video ? (entry.type == "avc1" ? "avcC" : "hvcC") : "esds"
            guard let config = atoms.first(where: { $0.type == configName }) else { throw malformed() }
            var configuration = Data(reader.bytes[config.payload..<config.end])
            if !video { configuration = try audioConfiguration(Array(configuration)) }
            let width = video ? try reader.uint(entry.payload + 24, count: 2) : 0
            let height = video ? try reader.uint(entry.payload + 26, count: 2) : 0
            let channels = video ? 0 : try reader.uint(entry.payload + 16, count: 2)
            result[id] = MP4Track(id: id, codec: entry.type, timescale: Double(scale),
                width: width, height: height, channels: channels, configuration: configuration)
        }
        guard result.values.contains(where: \.isVideo) else {
            throw HorizonError.message("The live stream has no video track.")
        }
        return result
    }

    private func audioConfiguration(_ bytes: [UInt8]) throws -> Data {
        func descriptor(at offset: Int) throws -> (tag: UInt8, start: Int, end: Int) {
            guard offset < bytes.count else { throw malformed() }
            var cursor = offset + 1
            var length = 0
            var complete = false
            for _ in 0..<4 {
                guard cursor < bytes.count else { throw malformed() }
                let value = bytes[cursor]
                cursor += 1
                length = length * 128 + Int(value & 127)
                if value & 128 == 0 { complete = true; break }
            }
            guard complete, length <= bytes.count - cursor else { throw malformed() }
            return (bytes[offset], cursor, cursor + length)
        }
        let es = try descriptor(at: 4)
        guard es.tag == 3, es.start + 3 <= es.end else { throw malformed() }
        let flags = bytes[es.start + 2]
        var cursor = es.start + 3
        if flags & 128 != 0 { cursor += 2 }
        if flags & 64 != 0 {
            guard cursor < es.end else { throw malformed() }
            cursor += 1 + Int(bytes[cursor])
        }
        if flags & 32 != 0 { cursor += 2 }
        let decoder = try descriptor(at: cursor)
        guard decoder.tag == 4, decoder.end <= es.end else { throw malformed() }
        let config = try descriptor(at: decoder.start + 13)
        guard config.tag == 5, config.end <= decoder.end else { throw malformed() }
        return Data(bytes[config.start..<config.end])
    }
}

private func malformed() -> HorizonError { .message("The live server sent an invalid fragmented MP4 stream.") }

private struct MP4Box {
    let type: String
    let start: Int
    let payload: Int
    let end: Int
}

private struct MP4Reader {
    let bytes: [UInt8]

    func uint(_ offset: Int, count: Int) throws -> Int {
        guard offset >= 0, count > 0, count <= 8, offset <= bytes.count,
              count <= bytes.count - offset else { throw malformed() }
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + count)] { value = (value << 8) | UInt64(byte) }
        guard value <= UInt64(Int.max) else { throw malformed() }
        return Int(value)
    }

    func boxes(in range: Range<Int>) throws -> [MP4Box] {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { throw malformed() }
        var cursor = range.lowerBound
        var result: [MP4Box] = []
        while cursor < range.upperBound {
            guard range.upperBound - cursor >= 8 else { throw malformed() }
            let raw = try uint(cursor, count: 4)
            let header = raw == 1 ? 16 : 8
            let size = raw == 0 ? range.upperBound - cursor : raw == 1 ? try uint(cursor + 8, count: 8) : raw
            guard size >= header, size <= range.upperBound - cursor else { throw malformed() }
            result.append(MP4Box(type: String(decoding: bytes[(cursor + 4)..<(cursor + 8)], as: UTF8.self),
                start: cursor, payload: cursor + header, end: cursor + size))
            cursor += size
        }
        return result
    }

    func children(_ box: MP4Box) throws -> [MP4Box] { try boxes(in: box.payload..<box.end) }
}
