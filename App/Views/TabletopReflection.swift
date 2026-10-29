import AVFoundation
import SwiftUI
import HorizonCore

private struct TabletopReflection: ViewModifier {
    @ObservedObject var reflection: VideoReflection
    let foldMode: FoldMode
    let player: AVPlayer?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var visible = false

    private var eligible: Bool {
        VideoReflectionPolicy.isEligible(
            foldMode: foldMode, foreground: scenePhase == .active, visible: visible,
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency
        )
    }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { HorizonBackdrop() }
            .overlay {
                if eligible, let image = reflection.image {
                    GeometryReader { geometry in
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .opacity(0.10)
                            .mask(LinearGradient(stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black.opacity(0.7), location: 0.5),
                                .init(color: .black.opacity(0.35), location: 1),
                            ], startPoint: .top, endPoint: .bottom))
                            .clipped()
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .clipped()
            .onAppear { visible = true }
            .onChange(of: eligible, initial: true) { _, value in
                if let player { reflection.follow(player: player) }
                reflection.setEnabled(value)
            }
            .onDisappear {
                visible = false
                reflection.setEnabled(false)
            }
    }
}

extension View {
    func tabletopReflection(_ reflection: VideoReflection, foldMode: FoldMode, player: AVPlayer? = nil) -> some View {
        modifier(TabletopReflection(reflection: reflection, foldMode: foldMode, player: player))
    }
}
