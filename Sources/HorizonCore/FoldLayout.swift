import CoreGraphics

public enum FoldMode: String, Equatable, Sendable {
    case flat
    case tabletop
    case book

    public static func detect(activeDivisions: [CGRect], in bounds: CGRect) -> FoldMode {
        guard bounds.width > 0, bounds.height > 0 else { return .flat }
        var largestArea: CGFloat = 0
        var mode: FoldMode = .flat
        for region in activeDivisions {
            let division = region.intersection(bounds)
            guard !division.isNull, division.width > 0, division.height > 0 else { continue }
            let area = division.width * division.height
            if area > largestArea {
                largestArea = area
                mode = division.width >= division.height ? .tabletop : .book
            }
        }
        return mode
    }

    public var title: String {
        switch self {
        case .flat: return "Adaptive layout"
        case .tabletop: return "Tabletop layout"
        case .book: return "Book layout"
        }
    }
}
