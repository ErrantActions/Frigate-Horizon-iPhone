import CoreGraphics

public struct HTTPSVideoPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case connecting, waiting, live
    }

    public private(set) var phase: Phase = .connecting
    public private(set) var resolution: CGSize?

    public init() {}

    public var status: String {
        switch phase {
        case .connecting: return "Connecting over HTTPS"
        case .waiting: return "Waiting for video"
        case .live: return "Live over HTTPS"
        }
    }

    public mutating func waitingForVideo() {
        if phase == .connecting { phase = .waiting }
    }

    public mutating func confirmDisplayedVideo(
        displayedSize: CGSize?, readyForDisplay: Bool, streamSize: CGSize
    ) {
        let size: CGSize
        if let displayedSize, Self.valid(displayedSize) { size = displayedSize }
        else if readyForDisplay, Self.valid(streamSize) { size = streamSize }
        else { return }
        resolution = size
        phase = .live
    }

    public mutating func reset() { self = Self() }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
