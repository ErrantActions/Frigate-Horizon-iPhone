import SwiftUI
import HorizonCore

@MainActor
struct CameraTourView: View {
    let api: HorizonAPI
    let active: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("cameraTourInterval") private var interval = CameraTourInterval.fifteen
    @State private var tour = CameraTourState()
    @State private var cycling = true
    @State private var ready = false
    @State private var failure: String?
    @State private var visible = false
    @State private var previousIdleTimerSetting: Bool?

    private var cameras: [HorizonCamera] {
        model.cameras.filter(\.isTourCandidate)
    }
    private var camera: HorizonCamera? { cameras.first { $0.id == tour.currentID } }
    private var foreground: Bool { active && visible && scenePhase == .active }
    private var schedule: CameraTourSchedule {
        CameraTourSchedule(cameraID: camera?.id, cameraCount: cameras.count,
            interval: interval, cycling: cycling, foreground: foreground,
            ready: ready, failed: failure != nil)
    }
    private var keepAwake: Bool {
        CameraTourSchedule.keepAwake(active: active, visible: visible,
            foreground: scenePhase == .active, hasCamera: camera != nil)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let camera {
                LiveVideoView(api: api, camera: camera, stream: camera.preferredStream(expanded: true),
                    active: foreground, muted: true,
                    onVideoReady: { value in
                        guard tour.currentID == camera.id else { return }
                        ready = value
                    },
                    onPlaybackFailure: { value in
                        guard tour.currentID == camera.id else { return }
                        failure = value
                    })
                    .id(camera.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No tour cameras", systemImage: "video.slash",
                    description: Text("Enable a dashboard camera with a configured live stream. Only cameras allowed by your account can appear."))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .preferredColorScheme(.dark)
        .onAppear { visible = true }
        .onDisappear {
            visible = false
            restoreIdleTimer()
        }
        .onChange(of: cameras.map(\.id), initial: true) { _, ids in
            tour.update(cameraIDs: ids)
        }
        .onChange(of: tour.currentID) { _, _ in
            ready = false
            failure = nil
        }
        .onChange(of: keepAwake, initial: true) { _, value in
            if value {
                if previousIdleTimerSetting == nil {
                    previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
                }
                UIApplication.shared.isIdleTimerDisabled = true
            } else { restoreIdleTimer() }
        }
        .onChange(of: active) { _, value in
            if !value { closeTour() }
        }
        .task(id: schedule) {
            let current = schedule
            guard let seconds = current.advanceAfterSeconds else { return }
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard !Task.isCancelled, schedule == current else { return }
            tour.next()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("CAMERA TOUR").font(.caption2.weight(.bold)).tracking(1.5)
                    .foregroundStyle(HorizonPalette.accent)
                Text(camera?.name ?? "Horizon").font(.headline)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if let position = tour.position {
                Text("\(position) / \(tour.cameraIDs.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("Done", action: closeTour).frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Close camera tour")
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(HorizonPalette.surface)
    }

    private var controls: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                tourButton("Previous camera", symbol: "backward.end.fill") { tour.previous() }
                tourButton(cycling ? "Pause camera cycling" : "Resume camera cycling",
                    symbol: cycling ? "pause.fill" : "play.fill", primary: true) {
                    cycling.toggle()
                }
                tourButton("Next camera", symbol: "forward.end.fill") { tour.next() }
                Spacer(minLength: 4)
                Menu {
                    Picker("Camera interval", selection: $interval) {
                        ForEach(CameraTourInterval.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                } label: {
                    Label(interval.label, systemImage: "timer")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).frame(minHeight: 44)
                        .background(HorizonPalette.raised, in: RoundedRectangle(cornerRadius: 12))
                }
                .accessibilityLabel("Camera tour interval")
            }
            .disabled(cameras.count < 2)
            HStack(spacing: 8) {
                Label("Muted", systemImage: "speaker.slash")
                Text(status)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(HorizonPalette.surface)
    }

    private var status: String {
        if cameras.isEmpty { return "No available live cameras" }
        if failure != nil {
            return cycling && cameras.count > 1
                ? "Camera unavailable; advancing after 3 seconds"
                : "Camera unavailable; use Reconnect to retry"
        }
        if !cycling { return ready ? "Tour paused; this camera stays live" : "Tour paused; waiting for this camera" }
        if !ready { return "Waiting for video before starting the interval" }
        if cameras.count == 1 { return "One camera; live view continues" }
        return "Next camera after \(interval.label) of live video"
    }

    private func tourButton(_ title: String, symbol: String, primary: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.headline)
                .frame(width: 44, height: 44)
                .foregroundStyle(primary ? HorizonPalette.onAccent : HorizonPalette.accent)
                .background(primary ? HorizonPalette.accent : HorizonPalette.raised,
                    in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func restoreIdleTimer() {
        if let previousIdleTimerSetting {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
            self.previousIdleTimerSetting = nil
        }
    }

    private func closeTour() {
        visible = false
        restoreIdleTimer()
        dismiss()
    }
}
