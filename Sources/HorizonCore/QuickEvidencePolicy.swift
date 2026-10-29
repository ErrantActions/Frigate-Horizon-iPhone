import Foundation

public struct QuickEvidenceInterval: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
}

public struct QuickEvidenceAssessment: Equatable, Sendable {
    public let range: QuickEvidenceInterval
    public let gaps: [QuickEvidenceInterval]
    public let latestRecordingEnd: Double
    public let ageSeconds: Double
    public var isStale: Bool { ageSeconds > 60 }
    public var canExport: Bool { gaps.isEmpty }
}

public enum QuickEvidencePreset: String, CaseIterable, Sendable {
    case lastThirtySeconds, lastTwoMinutes, selectedRange
    public var title: String {
        switch self {
        case .lastThirtySeconds: return "Last 30 seconds"
        case .lastTwoMinutes: return "Last 2 minutes"
        case .selectedRange: return "Selected range"
        }
    }
    public var seconds: Double? {
        switch self {
        case .lastThirtySeconds: return 30
        case .lastTwoMinutes: return 120
        case .selectedRange: return nil
        }
    }
}

public enum QuickEvidencePolicy {
    public static let maximumDuration = 24 * 3600.0

    public static func intervals(_ spans: [CoverageSpan], before: Double) -> [QuickEvidenceInterval] {
        guard before.isFinite, before > 0 else { return [] }
        let valid = spans.compactMap { span -> QuickEvidenceInterval? in
            let start = max(0, span.startTime)
            let end = min(before, span.endTime)
            guard span.startTime.isFinite, span.endTime.isFinite, end > start else { return nil }
            return QuickEvidenceInterval(start: start, end: end)
        }.sorted { $0.start < $1.start }
        var merged: [QuickEvidenceInterval] = []
        for value in valid {
            if let last = merged.last, value.start <= last.end {
                merged[merged.count - 1] = QuickEvidenceInterval(start: last.start, end: max(last.end, value.end))
            } else { merged.append(value) }
        }
        return merged
    }

    public static func gaps(in range: QuickEvidenceInterval, intervals: [QuickEvidenceInterval]) -> [QuickEvidenceInterval] {
        var cursor = range.start
        var gaps: [QuickEvidenceInterval] = []
        let valid = intervals.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
        for interval in valid.sorted(by: { $0.start < $1.start }) {
            guard interval.end > cursor, interval.start < range.end else { continue }
            if interval.start > cursor {
                gaps.append(QuickEvidenceInterval(start: cursor, end: min(interval.start, range.end)))
            }
            cursor = max(cursor, min(range.end, interval.end))
        }
        if cursor < range.end { gaps.append(QuickEvidenceInterval(start: cursor, end: range.end)) }
        return gaps
    }

    public static func assess(
        coverage: RecordingCoverage, preset: QuickEvidencePreset, selected: QuickEvidenceInterval?,
        now: Double, anchor: Double? = nil
    ) throws -> QuickEvidenceAssessment {
        guard now.isFinite, now > 0, anchor.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw HorizonError.message("The evidence time is invalid.")
        }
        let cutoff = min(now, anchor ?? now)
        let available = intervals(coverage.spans, before: cutoff)
        guard let latest = available.last?.end else {
            throw HorizonError.message("No indexed recordings are available on or before the selected time.")
        }
        let range: QuickEvidenceInterval
        if let seconds = preset.seconds {
            range = QuickEvidenceInterval(start: latest - seconds, end: latest)
        } else if let selected {
            range = selected
        } else { throw HorizonError.message("Choose a recorded start and end time.") }
        guard range.start.isFinite, range.end.isFinite, range.start >= 0,
              range.end > range.start, range.end <= cutoff, range.duration <= maximumDuration else {
            throw HorizonError.message("Choose an elapsed recording range of up to 24 hours, ending on or before the anchor time.")
        }
        return QuickEvidenceAssessment(range: range, gaps: gaps(in: range, intervals: available),
            latestRecordingEnd: latest, ageSeconds: max(0, now - latest))
    }

    public static func canProtect(isAdmin: Bool, capability: Bool, readyExport: Bool) -> Bool {
        isAdmin && capability && readyExport
    }
}

public struct QuickEvidenceNativeFeatures: Decodable, Sendable {
    public let exportProtection: Bool
    enum CodingKeys: String, CodingKey { case exportProtection = "export_protection" }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        exportProtection = try values.decodeIfPresent(Bool.self, forKey: .exportProtection) ?? false
    }
}

public struct QuickEvidenceProtectionResult: Decodable, Sendable {
    public let success: Bool
    public let message: String?
    public let protectedID: String?
    enum CodingKeys: String, CodingKey {
        case success, message
        case protectedID = "protected_id"
    }
    public func requireSuccess() throws {
        guard success else { throw HorizonError.message(message ?? "The server did not protect this export.") }
    }
}
