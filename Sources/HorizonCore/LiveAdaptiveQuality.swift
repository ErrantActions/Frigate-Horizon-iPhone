import Foundation

public struct LiveAdaptiveQualityPlan: Equatable, Sendable {
    public struct Rendition: Equatable, Sendable {
        public let stream: String
        public let height: Int
    }

    public let renditions: [Rendition]
    public var startupStream: String { renditions[0].stream }
    public var identity: String { renditions.map { "\($0.height):\($0.stream)" }.joined(separator: "|") }

    fileprivate init(renditions: [Rendition]) { self.renditions = renditions }
}

extension HorizonCamera {
    public func adaptiveQualityPlan(expanded: Bool) -> LiveAdaptiveQualityPlan? {
        guard settings.enabled, let transcode = settings.live.transcode, transcode.enabled,
              let target = preferredStream(expanded: expanded) else { return nil }
        let advertised = Set(settings.live.streams.values)
        let choices = Set(transcode.qualities.map(\.height)).filter { $0 >= 720 }.sorted()
            .compactMap { height -> LiveAdaptiveQualityPlan.Rendition? in
                let stream = "\(id)_transcode_\(height)p"
                guard advertised.contains(stream) else { return nil }
                return .init(stream: stream, height: height)
            }
        guard let targetIndex = choices.firstIndex(where: { $0.stream == target }),
              targetIndex > 0 else { return nil }
        return LiveAdaptiveQualityPlan(renditions: Array(choices[...targetIndex]))
    }
}

public struct LiveAdaptiveQualityState: Sendable {
    private let plan: LiveAdaptiveQualityPlan
    private var index = 0
    private var lastSwitch: TimeInterval
    private var lastObservation: TimeInterval
    private var stableSince: TimeInterval?
    private var upgradeAfter: TimeInterval
    private var upgrades = 0

    public var stream: String { plan.renditions[index].stream }

    public init(plan: LiveAdaptiveQualityPlan, now: TimeInterval) {
        self.plan = plan
        lastSwitch = now
        lastObservation = now
        upgradeAfter = now
    }

    public mutating func observe(
        now: TimeInterval, frameAge: TimeInterval?, videoReady: Bool,
        restrictedNetwork: Bool, frozen: Bool
    ) -> String? {
        guard now.isFinite, now >= lastObservation else {
            stableSince = nil
            return nil
        }
        lastObservation = now
        guard !frozen else { stableSince = nil; return nil }
        if restrictedNetwork {
            stableSince = nil
            if index > 0, now - lastSwitch >= 8 { return reduceQuality(now: now) }
            return nil
        }
        guard videoReady, let frameAge else {
            stableSince = nil
            if index > 0, now - lastSwitch >= 8 { return reduceQuality(now: now) }
            return nil
        }
        guard frameAge.isFinite, frameAge >= 0 else {
            stableSince = nil
            return nil
        }
        if frameAge > 3 {
            stableSince = nil
            if index > 0, now - lastSwitch >= 8 { return reduceQuality(now: now) }
            return nil
        }
        if stableSince == nil { stableSince = now }
        guard let stableSince, now - stableSince >= 15, now - lastSwitch >= 8,
              now >= upgradeAfter, upgrades < 2, index + 1 < plan.renditions.count else { return nil }
        index += 1
        upgrades += 1
        lastSwitch = now
        self.stableSince = nil
        return stream
    }

    public mutating func reduceQuality(now: TimeInterval) -> String? {
        guard now.isFinite, now >= lastSwitch, index > 0 else { return nil }
        index -= 1
        lastSwitch = now
        stableSince = nil
        upgradeAfter = now + 60
        return stream
    }
}
