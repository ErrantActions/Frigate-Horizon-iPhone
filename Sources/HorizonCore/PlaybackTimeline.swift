import Foundation

public struct ReviewTimeRange: Equatable, Sendable {
    public let start: Double
    public let end: Double

    public init(day: Date, now: Date = Date(), calendar: Calendar = .current) throws {
        guard day.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite,
              let interval = calendar.dateInterval(of: .day, for: day) else {
            throw HorizonError.message("The selected review day is invalid.")
        }
        let start = interval.start.timeIntervalSince1970
        let end = min(interval.end.timeIntervalSince1970, now.timeIntervalSince1970)
        guard end > start else {
            throw HorizonError.message("The selected review day has no elapsed time yet.")
        }
        self.start = start
        self.end = end
    }

    public func clamped(_ timestamp: Double) throws -> Double {
        guard timestamp.isFinite else { throw HorizonError.message("The selected recording time is invalid.") }
        return min(end.nextDown, max(start, timestamp))
    }
}

public struct ReviewSeekRequest: Equatable, Sendable {
    public let id = UUID()
    public let timestamp: Double
    public let autoplay: Bool

    public init(timestamp: Double, autoplay: Bool, range: ReviewTimeRange) throws {
        self.timestamp = try range.clamped(timestamp)
        self.autoplay = autoplay
    }
}

public struct RecordingCoverage: Decodable, Sendable {
    public let spans: [CoverageSpan]
    public let timelines: RealizedTimelines?

    public func contains(_ timestamp: Double) -> Bool {
        spans.contains { $0.startTime <= timestamp && timestamp < $0.endTime }
    }
}

public struct CoverageSpan: Decodable, Sendable {
    public let startTime: Double
    public let endTime: Double
    public let streams: [String]
    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case streams
    }
}

public struct RealizedTimelines: Decodable, Sendable {
    public let auto: [PlaybackSpan]
}

public struct PlaybackSpan: Decodable, Sendable {
    public let startTime: Double
    public let endTime: Double
    public let duration: Double
    public let leadInMilliseconds: Double?
    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case endTime = "end_time"
        case duration
        case leadInMilliseconds = "lead_in_ms"
    }
}

public struct PlaybackTimeline: Sendable {
    public let spans: [PlaybackSpan]
    public init(spans: [PlaybackSpan]) { self.spans = spans }

    public func position(for timestamp: Double) -> Double? {
        guard timestamp.isFinite else { return nil }
        var offset = 0.0
        for span in spans {
            let duration = span.duration / 1000
            guard duration.isFinite, duration > 0 else { continue }
            if span.startTime <= timestamp && timestamp < span.endTime {
                let lead = max(0, span.leadInMilliseconds.map { $0 / 1000 }
                    ?? (duration - (span.endTime - span.startTime)))
                return offset + min(duration, lead + timestamp - span.startTime)
            }
            offset += duration
        }
        return nil
    }

    public func timestamp(for position: Double) -> Double? {
        guard position.isFinite, position >= 0 else { return nil }
        var offset = 0.0
        for span in spans {
            let duration = span.duration / 1000
            guard duration.isFinite, duration > 0 else { continue }
            if position < offset + duration {
                let lead = max(0, span.leadInMilliseconds.map { $0 / 1000 }
                    ?? (duration - (span.endTime - span.startTime)))
                return min(span.endTime, max(span.startTime, span.startTime + position - offset - lead))
            }
            offset += duration
        }
        return nil
    }
}

public struct MotionSample: Decodable, Hashable, Sendable {
    public let startTime: Double
    public let motion: Double?
    enum CodingKeys: String, CodingKey {
        case startTime = "start_time"
        case motion
    }
}
