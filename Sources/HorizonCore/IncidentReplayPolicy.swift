import Foundation

public enum IncidentReplayReadiness: Equatable, Sendable {
    case loading, ready, gap, failed
}

public enum IncidentReplayCorrection: Equatable, Sendable {
    case none
    case rate(Double)
    case seek
}

public struct IncidentReplaySeek: Equatable, Sendable {
    public let id = UUID()
    public let timestamp: Double
    public let autoplay: Bool

    public init(timestamp: Double, autoplay: Bool, range: ReviewTimeRange) throws {
        self.timestamp = try range.clamped(timestamp)
        self.autoplay = autoplay
    }
}

public enum IncidentReplayPolicy {
    public static let maximumCameras = 4
    public static let chunkSeconds = 300.0
    public static let readinessTimeout = 20.0
    public static let correctionCooldown = 2.0
    public static let maximumHardCorrections = 3

    public static func cameras(_ requested: [String], allowed: Set<String>) throws -> [String] {
        var seen = Set<String>()
        let unique = requested.filter { seen.insert($0).inserted }
        guard unique.count >= 2, unique.count <= maximumCameras else {
            throw HorizonError.message("Choose two to four allowed cameras for incident replay.")
        }
        guard unique.allSatisfy({ allowed.contains($0) }) else {
            throw HorizonError.message("One or more incident cameras are no longer allowed for this account.")
        }
        return unique
    }

    public static func chunk(at timestamp: Double, range: ReviewTimeRange) throws -> ClosedRange<Double> {
        let time = try range.clamped(timestamp)
        let start = max(range.start, floor(time / chunkSeconds) * chunkSeconds)
        return start...min(range.end, start + chunkSeconds)
    }

    // Missing footage is not an unready player. It stays visibly unavailable while the clock advances.
    public static func barrierOpen(_ states: [String: IncidentReplayReadiness]) -> Bool {
        !states.isEmpty && !states.values.contains(.loading)
            && states.values.contains(where: { $0 == .ready || $0 == .gap })
    }

    public static func master(
        orderedCameras: [String], states: [String: IncidentReplayReadiness], previous: String?
    ) -> String? {
        if let previous, orderedCameras.contains(previous), states[previous] == .ready { return previous }
        return orderedCameras.first { states[$0] == .ready }
    }

    public static func correction(drift: Double, secondsSinceSeek: Double) -> IncidentReplayCorrection {
        guard drift.isFinite, secondsSinceSeek.isFinite, secondsSinceSeek >= correctionCooldown else { return .none }
        if abs(drift) <= 0.08 { return .none }
        if abs(drift) > 0.35 { return .seek }
        return .rate(drift > 0 ? 0.97 : 1.03)
    }

    public static func recordedRunEnd(at timestamp: Double, coverage: RecordingCoverage, timeline: PlaybackTimeline) -> Double? {
        guard timestamp.isFinite, coverage.contains(timestamp), timeline.position(for: timestamp) != nil else { return nil }
        func endOfRun(_ intervals: [(Double, Double)]) -> Double? {
            var end: Double?
            let valid = intervals.filter { $0.0.isFinite && $0.1.isFinite && $0.1 > $0.0 }
            for (start, stop) in valid.sorted(by: { $0.0 < $1.0 }) {
                if let current = end {
                    if start <= current { end = max(current, stop) }
                    else { break }
                } else if start <= timestamp && timestamp < stop { end = stop }
            }
            return end
        }
        guard let indexedEnd = endOfRun(coverage.spans.map { ($0.startTime, $0.endTime) }),
              let realizedEnd = endOfRun(timeline.spans.filter { $0.duration.isFinite && $0.duration > 0 }
                .map { ($0.startTime, $0.endTime) }) else { return nil }
        return min(indexedEnd, realizedEnd)
    }

    public static func timestamp(anchor: Double, hostElapsed: Double, range: ReviewTimeRange) throws -> Double {
        guard hostElapsed.isFinite else { throw HorizonError.message("The incident clock is invalid.") }
        return try range.clamped(anchor + max(0, hostElapsed))
    }
}
