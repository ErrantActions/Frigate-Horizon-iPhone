import SwiftUI
import UIKit

enum HorizonPalette {
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.045, blue: 0.085, alpha: 1)
            : UIColor(red: 0.94, green: 0.96, blue: 0.985, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.085, blue: 0.14, alpha: 1)
            : .white
    })
    static let raised = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.085, green: 0.125, blue: 0.20, alpha: 1)
            : UIColor(red: 0.975, green: 0.985, blue: 1, alpha: 1)
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.20, green: 0.85, blue: 0.98, alpha: 1)
            : UIColor(red: 0, green: 0.38, blue: 0.62, alpha: 1)
    })
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.045, blue: 0.085, alpha: 1)
            : .white
    })
    static let border = Color(uiColor: .separator).opacity(0.25)
    static let warm = Color(uiColor: .systemOrange)
    static let cardRadius: CGFloat = 24
    static let controlRadius: CGFloat = 16
}

struct HorizonBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            HorizonPalette.background
            if !reduceTransparency {
                LinearGradient(colors: [HorizonPalette.accent.opacity(0.09), .clear, .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct HorizonMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [HorizonPalette.accent, .blue],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: 4) {
                Circle().trim(from: 0.5, to: 1).stroke(.white, lineWidth: 3)
                    .frame(width: 30, height: 15)
                Capsule().fill(.white).frame(width: 39, height: 3)
                Capsule().fill(.white.opacity(0.8)).frame(width: 28, height: 3)
                Capsule().fill(.white.opacity(0.55)).frame(width: 16, height: 2)
            }
            .offset(y: 2)
        }
        .frame(width: 68, height: 68)
        .accessibilityHidden(true)
    }
}

struct HorizonCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HorizonPalette.surface, in: RoundedRectangle(cornerRadius: HorizonPalette.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HorizonPalette.cardRadius)
                    .stroke(HorizonPalette.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.06), radius: 16, x: 0, y: 6)
    }
}

struct HorizonHero: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var eyebrow: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.caption2.weight(.bold)).tracking(1.6)
                        .foregroundStyle(HorizonPalette.accent)
                }
                Text(title).font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(.primary)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: systemImage)
                .font(.title2.weight(.medium))
                .foregroundStyle(HorizonPalette.accent)
                .frame(width: 52, height: 52)
                .background(HorizonPalette.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 17))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct HorizonSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(HorizonPalette.accent).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .textCase(nil)
    }
}

struct HorizonStatusPill: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = HorizonPalette.accent

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(tint).accessibilityHidden(true)
            }
            Text(title).foregroundStyle(.primary)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct HorizonMetric: View {
    let title: String
    let value: String
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
                .foregroundStyle(.primary)
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct HorizonButtonStyle: ButtonStyle {
    enum Variant: Equatable { case primary, secondary, quiet }
    let variant: Variant
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ variant: Variant = .primary) { self.variant = variant }

    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        let accent = destructive ? Color.red : HorizonPalette.accent
        let fill = variant == .primary ? accent : variant == .secondary ? HorizonPalette.raised : .clear
        let foreground = variant == .primary
            ? (destructive ? Color.white : HorizonPalette.onAccent) : accent
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 44)
            .foregroundStyle(foreground)
            .background(fill, in: RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                    .stroke(variant == .secondary ? HorizonPalette.border : .clear, lineWidth: 1)
            }
            .opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct HorizonScreenStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .listRowSpacing(8)
            .scrollContentBackground(.hidden)
            .background { HorizonBackdrop() }
            .tint(HorizonPalette.accent)
            .toolbarBackground(HorizonPalette.background, for: .navigationBar)
    }
}

extension View {
    func horizonScreen() -> some View { modifier(HorizonScreenStyle()) }

    func horizonHeroRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 12, trailing: 0))
    }
}
