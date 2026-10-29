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
    var timelineOffset: Double { Double(scrollView.contentOffset.y) + offsetCorrection }

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
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.decelerationRate = .fast
        addSubview(scrollView)
        ruler.isOpaque = false
        ruler.isUserInteractionEnabled = false
        addSubview(ruler)
        playhead.backgroundColor = .systemRed
        playhead.isUserInteractionEnabled = false
        playhead.accessibilityIdentifier = "reviewFixedPlayhead"
        addSubview(playhead)
        failure.numberOfLines = 0
        failure.font = .preferredFont(forTextStyle: .caption1)
        failure.textColor = .systemOrange
        failure.backgroundColor = .secondarySystemBackground
        failure.isHidden = true
        addSubview(failure)
        scrollView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        isAccessibilityElement = true
        accessibilityTraits = [.adjustable]
        accessibilityLabel = "Recording timeline"
        accessibilityHint = "Drag the timeline beneath the fixed red playhead, or swipe up or down to adjust the selected time."
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
        playhead.frame = CGRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
        failure.frame = bounds.insetBy(dx: 4, dy: 4)
        updating = false
        updateViewport()
    }

    private func updateViewport() {
        guard let range, bounds.height > 0 else { return }
        updating = true
        defer { updating = false }
        do {
            let geometry = try ReviewTimelineViewport(range: range, scale: scale, height: Double(bounds.height))
            viewport = geometry
            ruler.viewport = geometry
            scrollView.contentSize = CGSize(width: bounds.width, height: geometry.contentHeight)
            if !userScrubbing {
                let offset = try geometry.offset(for: selectedTime)
                scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                // UIScrollView rounds to display pixels; retain the fractional time instead.
                offsetCorrection = offset - Double(scrollView.contentOffset.y)
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
            let time = try viewport.timestamp(atViewportY: Double(gesture.location(in: self).y),
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
            scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            offsetCorrection = offset - Double(scrollView.contentOffset.y)
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

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let viewport else { return }
        do {
            let top = try viewport.position(for: viewport.range.end, atOffset: offset)
            let bottom = try viewport.position(for: viewport.range.start, atOffset: offset)
            let lane = CGRect(x: 82, y: max(0, top), width: 9, height: max(0, min(Double(bounds.height), bottom) - max(0, top)))
            if let coverage {
                context.saveGState()
                context.clip(to: lane)
                context.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.45).cgColor)
                for y in stride(from: lane.minY - 9, through: lane.maxY, by: 9) {
                    context.move(to: CGPoint(x: 82, y: y))
                    context.addLine(to: CGPoint(x: 91, y: y + 9))
                }
                context.strokePath()
                context.restoreGState()
                for span in coverage {
                    try band(context, from: span.startTime, to: span.endTime, x: 82, width: 9,
                        color: .systemGray, viewport: viewport)
                }
            }
            for severity in ["detection", "alert"] {
                for event in events where event.severity == severity {
                    try band(context, from: event.startTime, to: event.endTime ?? viewport.range.end,
                        x: 96, width: 8, color: severity == "alert" ? .systemOrange : .systemBlue, viewport: viewport)
                }
            }
            for sample in motion {
                try band(context, from: sample.startTime, to: sample.startTime + 15,
                    x: 108, width: min(16, max(0, sample.motion ?? 0) * 0.16),
                    color: .systemCyan, viewport: viewport)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            for timestamp in try viewport.visibleTicks(atOffset: offset) {
                let y = try viewport.position(for: timestamp, atOffset: offset)
                let major = timestamp.truncatingRemainder(dividingBy: viewport.scale.secondsPerTick * 4) == 0
                context.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.5).cgColor)
                context.move(to: CGPoint(x: 64, y: y))
                context.addLine(to: CGPoint(x: major ? 78 : 70, y: y))
                context.strokePath()
                if major {
                    let date = Date(timeIntervalSince1970: timestamp)
                    let label = viewport.scale.secondsPerTick <= 5
                        ? date.formatted(.dateTime.hour().minute().second())
                        : date.formatted(.dateTime.hour().minute())
                    (label as NSString).draw(in: CGRect(x: 0, y: y - 7, width: 60, height: 16),
                        withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                            .foregroundColor: UIColor.secondaryLabel, .paragraphStyle: paragraph])
                }
            }
        } catch {
            (error.localizedDescription as NSString).draw(in: bounds,
                withAttributes: [.font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: UIColor.systemOrange])
        }
    }

    private func band(_ context: CGContext, from start: Double, to end: Double,
                      x: Double, width: Double, color: UIColor, viewport: ReviewTimelineViewport) throws {
        let upper = min(viewport.range.end, end)
        let lower = max(viewport.range.start, start)
        guard upper > lower, width > 0 else { return }
        let y = try viewport.position(for: upper, atOffset: offset)
        let bottom = try viewport.position(for: lower, atOffset: offset)
        let top = max(0, y)
        let height = min(Double(bounds.height), bottom) - top
        guard height > 0 else { return }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: x, y: top, width: width, height: height))
    }
}
