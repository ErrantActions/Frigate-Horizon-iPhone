import SwiftUI
import HorizonCore

struct NativeReviewTimeline: UIViewRepresentable {
    let range: ReviewTimeRange
    @Binding var time: Double
    @Binding var scrubbing: Bool
    let scale: ReviewTimelineScale
    let coverage: [CoverageSpan]?
    let events: [ReviewSegment]
    let motion: [MotionSample]
    let beginScrub: () -> Void
    let commit: (Double) -> Void

    func makeUIView(context: Context) -> ReviewTimelineScrollView {
        ReviewTimelineScrollView(frame: .zero)
    }

    func updateUIView(_ view: ReviewTimelineScrollView, context: Context) {
        view.onBeginScrub = {
            scrubbing = true
            beginScrub()
        }
        view.onTimeChange = { time = $0 }
        view.onCommit = {
            scrubbing = false
            commit($0)
        }
        view.configure(range: range, scale: scale, time: time, coverage: coverage,
            events: events, motion: motion)
    }

    static func dismantleUIView(_ view: ReviewTimelineScrollView, coordinator: ()) {
        view.onBeginScrub = nil
        view.onTimeChange = nil
        view.onCommit = nil
        view.scrollView.delegate = nil
    }
}

@MainActor
final class ReviewTimelineScrollView: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let playhead = UIView()
    private let ruler = ReviewTimelineRuler()
    private let failure = UILabel()
    private var range: ReviewTimeRange?
    private var scale = ReviewTimelineScale.thirtySeconds
    private var viewport: ReviewTimelineViewport?
    private var selectedTime = 0.0
    private var offsetCorrection = 0.0
    private var updating = false
    private var userScrubbing = false
    var onBeginScrub: (() -> Void)?
    var onTimeChange: ((Double) -> Void)?
    var onCommit: ((Double) -> Void)?
    var timelineOffset: Double { Double(scrollView.contentOffset.x) + offsetCorrection }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        clipsToBounds = true
        scrollView.delegate = self
        scrollView.bounces = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isDirectionalLockEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        addSubview(scrollView)
        ruler.isOpaque = false
        ruler.isUserInteractionEnabled = false
        addSubview(ruler)
        playhead.backgroundColor = .systemRed
        playhead.layer.cornerRadius = 1
        playhead.layer.shadowColor = UIColor.systemRed.cgColor
        playhead.layer.shadowOpacity = 0.3
        playhead.layer.shadowRadius = 4
        playhead.layer.shadowOffset = .zero
        playhead.isUserInteractionEnabled = false
        playhead.accessibilityIdentifier = "reviewFixedPlayhead"
        addSubview(playhead)
        failure.numberOfLines = 0
        failure.font = .preferredFont(forTextStyle: .caption1)
        failure.adjustsFontForContentSizeCategory = true
        failure.textColor = .systemOrange
        failure.backgroundColor = UIColor(HorizonPalette.surface)
        failure.isHidden = true
        addSubview(failure)
        scrollView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        accessibilityLabel = "Recording timeline"
        accessibilityHint = "Drag the timeline left or right beneath the fixed red playhead. Time increases to the right. Swipe up or down to adjust the selected time."
        accessibilityIdentifier = "reviewTimeline"
    }

    func configure(range: ReviewTimeRange, scale: ReviewTimelineScale, time: Double,
                   coverage: [CoverageSpan]?, events: [ReviewSegment], motion: [MotionSample]) {
        self.range = range
        self.scale = scale
        selectedTime = time
        ruler.coverage = coverage
        ruler.events = events
        ruler.motion = motion
        updateViewport()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updating = true
        scrollView.frame = bounds
        ruler.frame = bounds
        let rulerTop = CGFloat(ruler.labelBottom)
        playhead.frame = CGRect(x: bounds.midX - 1, y: rulerTop, width: 2, height: max(0, bounds.height - rulerTop))
        failure.frame = bounds.insetBy(dx: 4, dy: 4)
        updating = false
        updateViewport()
    }

    private func updateViewport() {
        guard let range, bounds.width > 0 else { return }
        updating = true
        defer { updating = false }
        do {
            let geometry = try ReviewTimelineViewport(range: range, scale: scale, width: Double(bounds.width))
            viewport = geometry
            ruler.viewport = geometry
            scrollView.contentSize = CGSize(width: geometry.contentWidth, height: bounds.height)
            if !userScrubbing {
                let offset = try geometry.offset(for: selectedTime)
                scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
                // UIScrollView rounds to display pixels; retain the fractional time instead.
                offsetCorrection = offset - Double(scrollView.contentOffset.x)
            }
            failure.isHidden = true
            updateRuler()
        } catch { showFailure(error) }
    }

    private func updateRuler() {
        ruler.offset = timelineOffset
        ruler.setNeedsDisplay()
        accessibilityValue = "\(Date(timeIntervalSince1970: selectedTime).formatted(date: .omitted, time: .standard)), \(scale.label) per tick"
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        startScrub()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !updating else { return }
        updateRuler()
        guard userScrubbing, let viewport else { return }
        do {
            selectedTime = try viewport.timestamp(atOffset: timelineOffset)
            onTimeChange?(selectedTime)
            updateRuler()
        } catch { showFailure(error) }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishScrub() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        finishScrub()
    }

    private func startScrub() {
        guard viewport != nil, !userScrubbing else { return }
        userScrubbing = true
        onBeginScrub?()
    }

    private func finishScrub() {
        guard userScrubbing, !updating else { return }
        userScrubbing = false
        onCommit?(selectedTime)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard let viewport else { return }
        do {
            let time = try viewport.timestamp(atViewportX: Double(gesture.location(in: self).x),
                offset: timelineOffset)
            seek(to: time)
        } catch { showFailure(error) }
    }

    private func seek(to timestamp: Double) {
        guard let viewport else { return }
        do {
            let offset = try viewport.offset(for: timestamp)
            startScrub()
            updating = true
            scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
            offsetCorrection = offset - Double(scrollView.contentOffset.x)
            selectedTime = try viewport.timestamp(atOffset: offset)
            updating = false
            onTimeChange?(selectedTime)
            updateRuler()
            finishScrub()
        } catch {
            updating = false
            showFailure(error)
        }
    }

    override func accessibilityIncrement() { seek(to: selectedTime + scale.secondsPerTick) }
    override func accessibilityDecrement() { seek(to: selectedTime - scale.secondsPerTick) }

    private func showFailure(_ error: Error) {
        failure.text = error.localizedDescription
        failure.isHidden = false
        accessibilityValue = error.localizedDescription
    }
}

private final class ReviewTimelineRuler: UIView {
    var viewport: ReviewTimelineViewport?
    var offset = 0.0
    var coverage: [CoverageSpan]?
    var events: [ReviewSegment] = []
    var motion: [MotionSample] = []
    private var labelFont: UIFont {
        UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 10, weight: .medium), compatibleWith: traitCollection)
    }
    var labelBottom: Double { max(24, Double(labelFont.lineHeight) + 8) }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let viewport else { return }
        do {
            let rulerTop = labelBottom
            let start = try viewport.position(for: viewport.range.start, atOffset: offset)
            let end = try viewport.position(for: viewport.range.end, atOffset: offset)
            let lane = CGRect(x: max(0, start), y: rulerTop + 12,
                width: max(0, min(Double(bounds.width), end) - max(0, start)), height: 6)
            if let coverage {
                context.saveGState()
                context.clip(to: lane)
                context.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.45).cgColor)
                for x in stride(from: lane.minX - 6, through: lane.maxX, by: 9) {
                    context.move(to: CGPoint(x: x, y: rulerTop + 12))
                    context.addLine(to: CGPoint(x: x + 6, y: rulerTop + 18))
                }
                context.strokePath()
                context.restoreGState()
                for span in coverage {
                    try band(context, from: span.startTime, to: span.endTime, y: rulerTop + 12, height: 6,
                        color: .systemGray, viewport: viewport)
                }
            }
            for severity in ["detection", "alert"] {
                for event in events where event.severity == severity {
                    try band(context, from: event.startTime, to: event.endTime ?? viewport.range.end,
                        y: rulerTop + 24, height: 8, color: severity == "alert" ? .systemOrange : .systemBlue, viewport: viewport)
                }
            }
            for sample in motion {
                let height = min(12, max(0, sample.motion ?? 0) * 0.12)
                try band(context, from: sample.startTime, to: sample.startTime + 15,
                    y: rulerTop + 48 - height, height: height,
                    color: UIColor(HorizonPalette.accent), viewport: viewport)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let font = labelFont
            let labelWidth = max(72, Double(font.pointSize) * 8)
            let labelEvery = ceil(labelWidth / ReviewTimelineViewport.tickSpacing)
            for timestamp in try viewport.visibleTicks(atOffset: offset) {
                let x = try viewport.position(for: timestamp, atOffset: offset)
                let major = timestamp.truncatingRemainder(dividingBy: viewport.scale.secondsPerTick * labelEvery) == 0
                context.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.5).cgColor)
                context.move(to: CGPoint(x: x, y: rulerTop + (major ? 0 : 4)))
                context.addLine(to: CGPoint(x: x, y: rulerTop + 8))
                context.strokePath()
                if major {
                    let date = Date(timeIntervalSince1970: timestamp)
                    let label = viewport.scale.secondsPerTick <= 5
                        ? date.formatted(.dateTime.hour().minute().second())
                        : date.formatted(.dateTime.hour().minute())
                    (label as NSString).draw(in: CGRect(x: x - labelWidth / 2, y: 4,
                        width: labelWidth, height: Double(font.lineHeight)),
                        withAttributes: [.font: font,
                            .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
                }
            }
        } catch {
            (error.localizedDescription as NSString).draw(in: bounds,
                withAttributes: [.font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: UIColor.systemOrange])
        }
    }

    private func band(_ context: CGContext, from start: Double, to end: Double,
                      y: Double, height: Double, color: UIColor, viewport: ReviewTimelineViewport) throws {
        let upper = min(viewport.range.end, end)
        let lower = max(viewport.range.start, start)
        guard upper > lower, height > 0 else { return }
        let start = try viewport.position(for: lower, atOffset: offset)
        let end = try viewport.position(for: upper, atOffset: offset)
        let left = max(0, start)
        let width = min(Double(bounds.width), end) - left
        guard width > 0 else { return }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: left, y: y, width: width, height: height))
    }
}
