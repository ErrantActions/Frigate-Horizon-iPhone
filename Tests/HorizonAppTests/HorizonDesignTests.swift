import XCTest
import SwiftUI
@testable import FrigateHorizon

@MainActor
final class HorizonDesignTests: XCTestCase {
    func testAccentActionsHaveReadableContrastInBothAppearances() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let background = UIColor(HorizonPalette.accent).resolvedColor(with: traits)
            let foreground = UIColor(HorizonPalette.onAccent).resolvedColor(with: traits)
            XCTAssertGreaterThanOrEqual(try contrast(foreground, background), 4.5)
        }
    }

    func testCustomActionsRetainMinimumTouchHeight() throws {
        for variant in [HorizonButtonStyle.Variant.primary, .secondary, .quiet] {
            let image = try render(
                Button("Play") {}.buttonStyle(HorizonButtonStyle(variant))
                    .frame(width: 180), width: 180
            )
            XCTAssertGreaterThanOrEqual(image.size.height, 44)
        }
    }

    func testDesignComponentsRenderInCompactAndExpandedAppearances() throws {
        for (width, scheme, name) in [
            (320.0, ColorScheme.light, "components-compact-light"),
            (390.0, ColorScheme.dark, "components-compact-dark"),
            (820.0, ColorScheme.dark, "components-expanded-dark"),
        ] {
            let image = try render(componentPreview.environment(\.colorScheme, scheme), width: width)
            XCTAssertEqual(image.size.width, width, accuracy: 1)
            XCTAssertGreaterThan(image.size.height, 300)
            try record(image, name: name)
        }
    }

    func testAccessibilityTextCanExpandCardsRatherThanBeingClippedToFixedHeight() throws {
        let standard = try render(componentPreview.environment(\.dynamicTypeSize, .large), width: 320)
        let accessible = try render(componentPreview.environment(\.dynamicTypeSize, .accessibility3), width: 320)
        XCTAssertGreaterThan(accessible.size.height, standard.size.height)
        try record(accessible, name: "components-accessibility-text")
    }

    func testConnectionScreenRendersWithoutAnySavedSessionOrCredentials() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for (width, style, name) in [
            (390.0, UIUserInterfaceStyle.dark, "connection-compact-dark"),
            (820.0, UIUserInterfaceStyle.light, "connection-expanded-light"),
        ] {
            let model = AppModel()
            XCTAssertNil(model.api)
            XCTAssertTrue(model.serverText.isEmpty)
            let controller = UIHostingController(rootView: ConnectionView().environmentObject(model))
            let window = UIWindow(windowScene: scene)
            let bounds = CGRect(x: 0, y: 0, width: width, height: 900)
            window.frame = bounds
            window.overrideUserInterfaceStyle = style
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                rendered = controller.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            previous?.makeKeyAndVisible()
            XCTAssertEqual(image.size.width, width)
            XCTAssertTrue(rendered, "The onboarding preview must capture the rendered native view hierarchy.")
            try record(image, name: name)
        }
    }

    private var componentPreview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                HorizonMark()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Horizon").font(.system(.largeTitle, design: .rounded).bold())
                    Text("Synthetic design preview").font(.caption).foregroundStyle(.secondary)
                }
            }
            HorizonCard {
                HorizonHero(title: "Your horizon, in focus",
                    subtitle: "A component preview, not a connected camera.",
                    systemImage: "video", eyebrow: "Made for your space")
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [.black, HorizonPalette.raised],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 160)
                    .overlay { Image(systemName: "video").font(.largeTitle).foregroundStyle(.white.opacity(0.7)) }
                HStack(spacing: 24) {
                    HorizonMetric(title: "Source", value: "Demo", systemImage: "video")
                    Spacer(minLength: 0)
                    HorizonStatusPill(title: "Preview", systemImage: "sparkles")
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("Play", systemImage: "play.fill") {}.buttonStyle(HorizonButtonStyle())
                        Button("Library", systemImage: "square.stack") {}.buttonStyle(HorizonButtonStyle(.secondary))
                    }
                    VStack(alignment: .leading) {
                        Button("Play", systemImage: "play.fill") {}.buttonStyle(HorizonButtonStyle())
                        Button("Library", systemImage: "square.stack") {}.buttonStyle(HorizonButtonStyle(.secondary))
                    }
                }
            }
        }
        .padding(20)
        .background(HorizonPalette.background)
    }

    private func render<Content: View>(_ content: Content, width: Double) throws -> UIImage {
        let renderer = ImageRenderer(content: content.frame(width: width).fixedSize(horizontal: false, vertical: true))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try XCTUnwrap(renderer.uiImage, "Native design components must produce an actual rendered image.")
    }

    private func record(_ image: UIImage, name: String) throws {
        let attachment = XCTAttachment(data: try XCTUnwrap(image.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = name + ".png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func contrast(_ first: UIColor, _ second: UIColor) throws -> Double {
        func luminance(_ color: UIColor) throws -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                throw NSError(domain: "HorizonDesignTests", code: 1)
            }
            let channels = [red, green, blue].map { component -> Double in
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let left = try luminance(first), right = try luminance(second)
        return (max(left, right) + 0.05) / (min(left, right) + 0.05)
    }
}
