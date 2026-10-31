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

public struct LivePlaybackQuality: Equatable, Sendable {
    public let requestedStream: String
    public let adaptivePlan: LiveAdaptiveQualityPlan?
    public var startupStream: String { adaptivePlan?.startupStream ?? requestedStream }
}

extension HorizonCamera {
    var advertisedLiveProfiles: [LiveAdaptiveQualityPlan.Rendition] {
        // Generation can be disabled while manually provisioned aliases remain usable.
        guard settings.enabled, let transcode = settings.live.transcode else { return [] }
        let advertised = Set(settings.live.streams.values)
        let heights = Set(transcode.qualities.map(\.height)).filter { $0 > 0 }
        return advertised.compactMap { stream -> LiveAdaptiveQualityPlan.Rendition? in
                guard let height = heights.first(where: { stream == "\(id)_transcode_\($0)p" }) else { return nil }
                return .init(stream: stream, height: height)
            }
            .sorted { $0.height < $1.height }
    }

    public var advertisedLiveRenditions: [LiveAdaptiveQualityPlan.Rendition] {
        advertisedLiveProfiles.filter { $0.height >= 720 }
    }

    public func adaptiveQualityPlan(expanded: Bool, maximumHeight: Int? = nil) -> LiveAdaptiveQualityPlan? {
        guard let target = preferredStream(expanded: expanded, maximumHeight: maximumHeight) else { return nil }
        let choices = advertisedLiveRenditions
        guard let targetIndex = choices.firstIndex(where: { $0.stream == target }),
              targetIndex > 0 else { return nil }
        return LiveAdaptiveQualityPlan(renditions: Array(choices[...targetIndex]))
    }

    public func playbackQuality(expanded: Bool, pinnedStream: String? = nil,
                                maximumHeight: Int? = nil) -> LivePlaybackQuality? {
        guard settings.enabled else { return nil }
        if let pinnedStream {
            guard settings.live.streams.values.contains(pinnedStream) else { return nil }
            return LivePlaybackQuality(requestedStream: pinnedStream, adaptivePlan: nil)
        }
        guard let stream = preferredStream(expanded: expanded, maximumHeight: maximumHeight) else { return nil }
        return LivePlaybackQuality(requestedStream: stream,
            adaptivePlan: adaptiveQualityPlan(expanded: expanded, maximumHeight: maximumHeight))
    }

    public func hlsMaximumHeight(pinnedStream: String?, selectedMaximum: Int?) -> Int? {
        guard let pinnedStream,
              let height = advertisedLiveRenditions.first(where: { $0.stream == pinnedStream })?.height else {
            return selectedMaximum
        }
        return min(selectedMaximum ?? height, height)
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
    private var pressureSince: TimeInterval?

    public var stream: String { plan.renditions[index].stream }

    public init(plan: LiveAdaptiveQualityPlan, now: TimeInterval) {
        self.plan = plan
        lastSwitch = now
        lastObservation = now
        upgradeAfter = now
    }

    public mutating func observe(
        now: TimeInterval, frameAge: TimeInterval?, videoReady: Bool,
        bufferedVideoDuration: TimeInterval? = nil,
        restrictedNetwork: Bool, frozen: Bool
    ) -> String? {
        guard now.isFinite, now >= lastObservation else {
            stableSince = nil
            pressureSince = nil
            return nil
        }
        lastObservation = now
        guard !frozen else { stableSince = nil; pressureSince = nil; return nil }
        if restrictedNetwork {
            stableSince = nil
            pressureSince = nil
            if index > 0, now - lastSwitch >= 8 { return reduceQuality(now: now) }
            return nil
        }
        guard videoReady, let frameAge else {
            stableSince = nil
            pressureSince = nil
            if index > 0, now - lastSwitch >= 8 { return reduceQuality(now: now) }
            return nil
        }
        guard frameAge.isFinite, frameAge >= 0 else {
            stableSince = nil
            pressureSince = nil
            return nil
        }
        if frameAge > 3 {
            stableSince = nil
            pressureSince = nil
            if index > 0, now - lastSwitch >= 8 { return reduceQuality(now: now) }
            return nil
        }
        if let bufferedVideoDuration {
            guard bufferedVideoDuration.isFinite, bufferedVideoDuration >= 0 else {
                stableSince = nil
                pressureSince = nil
                return nil
            }
            if bufferedVideoDuration > 2 {
                stableSince = nil
                if pressureSince == nil { pressureSince = now }
                if let pressureSince, now - pressureSince >= 3, index > 0, now - lastSwitch >= 8 {
                    return reduceQuality(now: now)
                }
                return nil
            }
        }
        pressureSince = nil
        guard frameAge <= 1 else { stableSince = nil; return nil }
        if stableSince == nil { stableSince = now }
        guard let stableSince, now - stableSince >= 15, now - lastSwitch >= 8,
              now >= upgradeAfter, upgrades < 2, index + 1 < plan.renditions.count else { return nil }
        index += 1
        upgrades += 1
        lastSwitch = now
        self.stableSince = nil
        pressureSince = nil
        return stream
    }

    public mutating func reduceQuality(now: TimeInterval) -> String? {
        guard now.isFinite, now >= lastSwitch, index > 0 else { return nil }
        index -= 1
        lastSwitch = now
        stableSince = nil
        pressureSince = nil
        upgradeAfter = now + 60
        return stream
    }
}
