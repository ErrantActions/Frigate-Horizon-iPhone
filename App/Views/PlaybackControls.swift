import SwiftUI
import HorizonCore

struct HorizonPlaybackDock: View {
    let time: Date
    var timeTitle = "Selected time"
    let status: String
    let playing: Bool
    var playEnabled = true
    var compact = false
    let back: () -> Void
    let togglePlayback: () -> Void
    let forward: () -> Void

    var body: some View {
        if compact {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(status).font(.caption).foregroundStyle(HorizonPalette.accent)
                    Text(time, format: .dateTime.hour().minute().second())
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .accessibilityLabel("\(timeTitle), \(time.formatted(date: .omitted, time: .standard))")
                }
                Spacer(minLength: 0)
                transportButtons
            }
            .padding(12)
            .background(HorizonPalette.surface, in: RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                    .stroke(HorizonPalette.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        } else {
            HorizonCard {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        selectedTime
                        Spacer(minLength: 12)
                        HorizonStatusPill(title: status)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        selectedTime
                        HorizonStatusPill(title: status)
                    }
                }
                transportButtons
            }
        }
    }

    private var transportButtons: some View {
        HStack(spacing: compact ? 6 : 12) {
            Button("Back 15 seconds", systemImage: "gobackward.15", action: back)
                .frame(maxWidth: compact ? nil : .infinity)
                .buttonStyle(HorizonButtonStyle(.secondary))
            Button(playing ? "Pause" : "Play",
                systemImage: playing ? "pause.fill" : "play.fill", action: togglePlayback)
                .frame(maxWidth: compact ? nil : .infinity)
                .buttonStyle(HorizonButtonStyle(.primary))
                .disabled(!playEnabled)
            Button("Forward 15 seconds", systemImage: "goforward.15", action: forward)
                .frame(maxWidth: compact ? nil : .infinity)
                .buttonStyle(HorizonButtonStyle(.secondary))
        }
        .labelStyle(.iconOnly)
        .accessibilityElement(children: .contain)
    }

    private var selectedTime: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timeTitle).font(.caption).foregroundStyle(.secondary)
            Text(time, format: .dateTime.hour().minute().second())
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HorizonPlaybackModeBadge: View {
    let foldMode: FoldMode

    var body: some View {
        HorizonStatusPill(title: foldMode.title, systemImage: symbol)
            .accessibilityHint(foldMode == .tabletop
                ? "Video above, controls below."
                : foldMode == .book ? "Video and controls on separate panels." : "Layout adapts to the available space.")
    }

    private var symbol: String {
        switch foldMode {
        case .tabletop: return "laptopcomputer"
        case .book: return "book"
        case .flat: return "rectangle.split.2x1"
        }
    }
}
