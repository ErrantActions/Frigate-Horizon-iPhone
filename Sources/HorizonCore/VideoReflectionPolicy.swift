import CoreGraphics

public enum VideoReflectionPolicy {
    public static let maximumFramesPerSecond: Double = 6
    public static let maximumDimension: CGFloat = 320
    public static let staleInterval: Double = 1

    public static func isEligible(
        foldMode: FoldMode, foreground: Bool, visible: Bool,
        reduceMotion: Bool, reduceTransparency: Bool
    ) -> Bool {
        foldMode == .tabletop && foreground && visible && !reduceMotion && !reduceTransparency
    }

    public static func downsampledSize(_ size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maximumDimension / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * scale).rounded(.down)),
                      height: max(1, (size.height * scale).rounded(.down)))
    }
}

public struct ReflectionSamplingGate: Sendable {
    private var lastSample: Double?

    public init() {}

    public mutating func take(at time: Double) -> Bool {
        guard time.isFinite else { return false }
        if let lastSample, time - lastSample < 1 / VideoReflectionPolicy.maximumFramesPerSecond {
            return false
        }
        lastSample = time
        return true
    }
}
