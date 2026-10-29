import Foundation

public enum ReviewTimelineScale: Int, CaseIterable, Identifiable, Sendable {
    case fiveMinutes = 300
    case oneMinute = 60
    case thirtySeconds = 30
    case fifteenSeconds = 15
    case fiveSeconds = 5
    case oneSecond = 1

    public var id: Int { rawValue }
    public var secondsPerTick: Double { Double(rawValue) }
    public var label: String {
        switch self {
        case .fiveMinutes: return "5 min"
        case .oneMinute: return "1 min"
        case .thirtySeconds: return "30 s"
        case .fifteenSeconds: return "15 s"
        case .fiveSeconds: return "5 s"
        case .oneSecond: return "1 s"
        }
    }

    public var coarser: Self? { Self.allCases.last { $0.rawValue > rawValue } }
    public var finer: Self? { Self.allCases.first { $0.rawValue < rawValue } }
}

public struct ReviewTimelineViewport: Equatable, Sendable {
    public static let tickHeight = 16.0
    public let range: ReviewTimeRange
    public let scale: ReviewTimelineScale
    public let height: Double

    public init(range: ReviewTimeRange, scale: ReviewTimelineScale, height: Double) throws {
        guard height.isFinite, height > 0 else {
            throw HorizonError.message("The review timeline has an invalid viewport height.")
        }
        self.range = range
        self.scale = scale
        self.height = height
    }

    public var playheadY: Double { height / 2 }
    public var pixelsPerSecond: Double { Self.tickHeight / scale.secondsPerTick }
    public var maximumOffset: Double { (range.end - range.start) * pixelsPerSecond }
    public var contentHeight: Double { maximumOffset + height }

    public func offset(for timestamp: Double) throws -> Double {
        (range.end - (try range.clamped(timestamp))) * pixelsPerSecond
    }

    public func timestamp(atOffset offset: Double) throws -> Double {
        guard offset.isFinite else {
            throw HorizonError.message("The review timeline scroll offset is invalid.")
        }
        return try range.clamped(range.end - min(maximumOffset, max(0, offset)) / pixelsPerSecond)
    }

    public func position(for timestamp: Double, atOffset offset: Double) throws -> Double {
        guard timestamp.isFinite, offset.isFinite else {
            throw HorizonError.message("The review timeline position is invalid.")
        }
        return playheadY + (range.end - timestamp) * pixelsPerSecond - offset
    }

    public func timestamp(atViewportY y: Double, offset: Double) throws -> Double {
        guard y.isFinite else {
            throw HorizonError.message("The review timeline touch position is invalid.")
        }
        return try timestamp(atOffset: offset + y - playheadY)
    }

    public func visibleTicks(atOffset offset: Double) throws -> [Double] {
        guard offset.isFinite else {
            throw HorizonError.message("The review timeline scroll offset is invalid.")
        }
        let upper = min(range.end, range.end + (playheadY - offset) / pixelsPerSecond)
        let first = floor(upper / scale.secondsPerTick) * scale.secondsPerTick
        let count = Int(ceil(height / Self.tickHeight)) + 2
        return (0..<count).map { first - Double($0) * scale.secondsPerTick }
            .filter { $0 >= range.start && $0 <= range.end }
    }
}
