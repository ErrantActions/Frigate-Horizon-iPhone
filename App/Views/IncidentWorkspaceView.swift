import SwiftUI
import AVKit
import HorizonCore

struct IncidentWorkspaceView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = IncidentPlaybackCoordinator()
    @StateObject private var reflection = VideoReflection()
    @State private var cameraIDs: [String]
    @State private var day: Date
    @State private var selectedTime: Double
    @State private var foldMode: FoldMode = .flat
    @State private var scrubbing = false
    @State private var scrubWasPlaying = false
    @State private var scale = ReviewTimelineScale.thirtySeconds
    @State private var retry = 0
    @State private var accessNotice: String?

    init(api: HorizonAPI, cameraIDs: [String], initialDate: Date = Date()) {
        self.api = api
        var seen = Set<String>()
        _cameraIDs = State(initialValue: cameraIDs.filter { seen.insert($0).inserted })
        _day = State(initialValue: initialDate)
        _selectedTime = State(initialValue: initialDate.timeIntervalSince1970)
    }

    private var selectedCameras: [HorizonCamera] {
        cameraIDs.compactMap { id in model.cameras.first { $0.id == id } }
    }

    private var reflectionPlayer: AVPlayer? {
        guard scenePhase == .active, model.api === api else { return nil }
        for id in [playback.audibleCamera, playback.masterCamera].compactMap({ $0 }) {
            if selectedCameras.contains(where: { $0.id == id }), playback.states[id] == .ready {
                return playback.players[id]
            }
        }
        return nil
    }

    private var sessionKey: String {
        "\(ObjectIdentifier(api))-\(model.api.map { String(describing: ObjectIdentifier($0)) } ?? "none")-" +
        "\(model.profile?.username ?? "")-\(model.profile?.role ?? "")-" +
        "\(model.cameras.map(\.id).sorted().joined(separator: ","))"
    }

    var body: some View {
        NavigationStack {
            DuoWorkspace(foldMode: $foldMode) {
                cameraWall
                    .padding(8)
                    .background(.black)
            } secondary: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("Incident replay", systemImage: "rectangle.split.2x2")
                                .font(.headline)
                            Spacer()
                            HorizonPlaybackModeBadge(foldMode: foldMode)
                        }
                        Text("Original recordings • one shared clock")
                            .font(.subheadline).foregroundStyle(.secondary)
                        cameraPicker
                        DatePicker("Recording day", selection: Binding(get: { day }, set: { value in
                            selectedTime = min(Date().timeIntervalSince1970 - 1,
                                Calendar.current.startOfDay(for: value).timeIntervalSince1970)
                            day = value
                        }), in: ...Date(), displayedComponents: .date)
                        if let range = playback.range {
                            NativeReviewTimeline(range: range, time: $selectedTime, scrubbing: $scrubbing,
                                scale: scale, coverage: nil, events: [], motion: [],
                                beginScrub: {
                                    scrubWasPlaying = playback.intendsToPlay
                                    playback.setPlaying(false)
                                }, commit: { time in
                                    playback.seek(to: time)
                                    playback.setPlaying(scrubWasPlaying)
                                })
                                .frame(height: 126)
                                .accessibilityLabel("Shared incident recording timeline")
                            Picker("Timeline scale", selection: $scale) {
                                ForEach(ReviewTimelineScale.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.menu)
                        }
                        HorizonPlaybackDock(time: Date(timeIntervalSince1970: selectedTime),
                            status: playback.synchronizing ? "Waiting for recordings" :
                                (playback.intendsToPlay ? "Synchronized replay" : "Paused"),
                            playing: playback.intendsToPlay, playEnabled: playback.range != nil,
                            back: { jump(-15) },
                            togglePlayback: { playback.setPlaying(!playback.intendsToPlay) },
                            forward: { jump(15) })
                        if playback.synchronizing { ProgressView("Synchronizing all available cameras") }
                        if let accessNotice { ErrorNotice(message: accessNotice) }
                        if let error = playback.error { ErrorNotice(message: error) { retry += 1 } }
                        if !playback.cameraErrors.isEmpty {
                            ForEach(playback.cameraErrors.keys.sorted(), id: \.self) { id in
                                ErrorNotice(message: "\(cameraName(id)): \(playback.cameraErrors[id] ?? "Recording unavailable.")")
                            }
                            Button("Retry recordings", systemImage: "arrow.clockwise") { retry += 1 }
                                .buttonStyle(HorizonButtonStyle(.secondary))
                        }
                        Label("Tap a speaker to select the only audible camera, or mute all.", systemImage: "speaker.wave.2")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("Missing footage stays unavailable. The shared clock continues through known gaps; no camera ever switches to live video. Replay stops when this workspace is not in the foreground.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(16)
                }
                .background(HorizonPalette.background)
                .tabletopReflection(reflection, foldMode: foldMode, player: reflectionPlayer)
            }
            .horizonScreen()
            .navigationTitle("Incident")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { LivePictureInPictureController.shared.stop() }
            .task(id: "\(sessionKey)-\(scenePhase == .active)-\(day.timeIntervalSince1970)-\(cameraIDs.joined(separator: ","))-\(retry)") {
                guard scenePhase == .active, model.api === api else { playback.stop(); return }
                let allowed = Set(model.cameras.map(\.id))
                if !Set(cameraIDs).isSubset(of: allowed) {
                    playback.stop()
                    cameraIDs.removeAll { !allowed.contains($0) }
                    accessNotice = "Cameras that are no longer allowed were removed from this workspace."
                    return
                }
                playback.prepare(api: api, cameraIDs: cameraIDs, allowed: allowed,
                    day: day, at: selectedTime)
            }
            .onChange(of: playback.timestamp) { _, value in
                if !scrubbing { selectedTime = value }
            }
            .onChange(of: reflectionPlayer.map { ObjectIdentifier($0) }, initial: true) { _, _ in
                if let player = reflectionPlayer { reflection.follow(player: player) }
                else { reflection.clearSource() }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { playback.stop() } }
            .onChange(of: sessionKey) { _, _ in
                if model.api !== api || !Set(cameraIDs).isSubset(of: Set(model.cameras.map(\.id))) {
                    playback.stop()
                }
            }
            .onDisappear {
                reflection.setEnabled(false)
                reflection.clearSource()
                playback.stop()
            }
        }
    }

    private var cameraPicker: some View {
        Menu {
            ForEach(model.cameras) { camera in
                Button {
                    if cameraIDs.contains(camera.id) {
                        guard cameraIDs.count > 2 else { return }
                        cameraIDs.removeAll { $0 == camera.id }
                    }
                    else if cameraIDs.count < IncidentReplayPolicy.maximumCameras { cameraIDs.append(camera.id) }
                } label: {
                    Label(camera.name, systemImage: cameraIDs.contains(camera.id) ? "checkmark.circle.fill" : "circle")
                }
                .disabled(cameraIDs.contains(camera.id)
                    ? cameraIDs.count <= 2
                    : cameraIDs.count >= IncidentReplayPolicy.maximumCameras)
            }
        } label: {
            Label("Choose cameras (\(cameraIDs.count)/4)", systemImage: "camera.on.rectangle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(HorizonButtonStyle(.secondary))
    }

    private var cameraWall: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width >= 600 || selectedCameras.count > 2 ? 2 : 1
            let rows = max(1, Int(ceil(Double(selectedCameras.count) / Double(columns))))
            let height = max(120, (geometry.size.height - CGFloat(rows - 1) * 10) / CGFloat(rows))
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                    ForEach(selectedCameras) { camera in
                        cameraTile(camera)
                            .frame(height: height)
                    }
                }
            }
            .overlay {
                if selectedCameras.count < 2 {
                    ContentUnavailableView("Choose two to four cameras", systemImage: "rectangle.split.2x2",
                        description: Text("Use the camera selector to build a synchronized incident workspace."))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func cameraTile(_ camera: HorizonCamera) -> some View {
        ZStack {
            Color.black
            if let player = playback.players[camera.id], playback.states[camera.id] == .ready {
                IncidentRecordingSurface(player: player)
            } else {
                VStack(spacing: 10) {
                    if playback.states[camera.id] == .loading { ProgressView().tint(.white) }
                    else { Image(systemName: "video.slash").font(.title2) }
                    Text(playback.states[camera.id] == .gap ? "Recording unavailable at this time" :
                        playback.states[camera.id] == .failed ? "Recording failed — see details" : "Preparing recording")
                        .font(.callout).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .overlay(alignment: .top) {
            HStack(spacing: 8) {
                Text(camera.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 0)
                Button { playback.selectAudio(camera.id) } label: {
                    Image(systemName: playback.audibleCamera == camera.id ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(playback.audibleCamera == camera.id ? "Mute \(camera.name)" : "Listen to \(camera.name)")
            }
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .background(.black.opacity(0.65))
        }
        .clipShape(RoundedRectangle(cornerRadius: HorizonPalette.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                .stroke(playback.audibleCamera == camera.id ? HorizonPalette.accent : HorizonPalette.border, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private func cameraName(_ id: String) -> String { model.cameras.first { $0.id == id }?.name ?? id }
    private func jump(_ seconds: Double) { playback.seek(to: selectedTime + seconds) }
}

private struct IncidentRecordingSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.videoGravity = .resizeAspect
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) { controller.player = nil }
}
