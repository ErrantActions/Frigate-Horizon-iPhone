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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                selectedTime
                Spacer(minLength: 0)
                transportButtons
            }
            VStack(alignment: .leading, spacing: 4) {
                selectedTime
                transportButtons
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(HorizonPalette.surface, in: RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                .stroke(HorizonPalette.border, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 4) {
            transportButton("Back 15 seconds", systemImage: "gobackward.15", action: back)
            transportButton(playing ? "Pause" : "Play",
                systemImage: playing ? "pause.fill" : "play.fill", primary: true,
                enabled: playEnabled, action: togglePlayback)
            transportButton("Forward 15 seconds", systemImage: "goforward.15", action: forward)
        }
        .accessibilityElement(children: .contain)
    }

    private func transportButton(_ title: String, systemImage: String, primary: Bool = false,
                                 enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.headline)
                .frame(width: 44, height: 44)
                .foregroundStyle(primary ? HorizonPalette.onAccent : HorizonPalette.accent)
                .background(primary ? HorizonPalette.accent : HorizonPalette.raised,
                    in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }

    private var selectedTime: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(status).font(.caption2).foregroundStyle(.secondary)
            Text(time, format: .dateTime.hour().minute().second())
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(timeTitle), \(time.formatted(date: .omitted, time: .standard)), \(status)")
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
