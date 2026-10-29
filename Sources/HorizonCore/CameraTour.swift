import Foundation

public extension HorizonCamera {
    var isTourCandidate: Bool {
        settings.enabled && settings.ui?.dashboard != false && preferredStream(expanded: true) != nil
    }
}

public enum CameraTourInterval: Int, CaseIterable, Identifiable, Sendable {
    case five = 5, ten = 10, fifteen = 15, thirty = 30, sixty = 60
    public var id: Int { rawValue }
    public var label: String { "\(rawValue) sec" }
}

public struct CameraTourState: Equatable, Sendable {
    public private(set) var cameraIDs: [String] = []
    public private(set) var currentID: String?

    public init(cameraIDs: [String] = []) { update(cameraIDs: cameraIDs) }
    public var position: Int? { currentID.flatMap { cameraIDs.firstIndex(of: $0).map { $0 + 1 } } }

    public mutating func update(cameraIDs: [String]) {
        var seen: Set<String> = []
        self.cameraIDs = cameraIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        if currentID.map({ self.cameraIDs.contains($0) }) != true { currentID = self.cameraIDs.first }
    }

    public mutating func next() { move(by: 1) }
    public mutating func previous() { move(by: -1) }

    private mutating func move(by offset: Int) {
        guard let currentID, let index = cameraIDs.firstIndex(of: currentID), !cameraIDs.isEmpty else { return }
        self.currentID = cameraIDs[(index + offset + cameraIDs.count) % cameraIDs.count]
    }
}

public struct CameraTourSchedule: Equatable, Sendable {
    public let cameraID: String?
    public let cameraCount: Int
    public let interval: CameraTourInterval
    public let cycling: Bool
    public let foreground: Bool
    public let ready: Bool
    public let failed: Bool

    public init(cameraID: String?, cameraCount: Int, interval: CameraTourInterval,
                cycling: Bool, foreground: Bool, ready: Bool, failed: Bool) {
        self.cameraID = cameraID
        self.cameraCount = cameraCount
        self.interval = interval
        self.cycling = cycling
        self.foreground = foreground
        self.ready = ready
        self.failed = failed
    }

    public var advanceAfterSeconds: Int? {
        guard cameraID != nil, cameraCount > 1, cycling, foreground else { return nil }
        if failed { return 3 }
        return ready ? interval.rawValue : nil
    }

    public static func keepAwake(active: Bool, visible: Bool, foreground: Bool, hasCamera: Bool) -> Bool {
        active && visible && foreground && hasCamera
    }
}
