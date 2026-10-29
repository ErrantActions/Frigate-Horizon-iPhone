import SwiftUI
import HorizonCore

struct LiveView: View {
    let api: HorizonAPI
    let active: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selected: HorizonCamera?
    @State private var showCameraTour = false
    @State private var preferences = CameraDashboardPreferences()
    @State private var loadedPreferenceScope: String?
    @State private var preferencesReady = false
    @State private var preferenceError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HorizonHero(title: "Eyes on everything.",
                        subtitle: "Tap to view. Touch and hold a camera to manage favorites.",
                        systemImage: "video.fill", eyebrow: "Live")
                    HStack {
                        HorizonStatusPill(title: "\(dashboardCameras.count) cameras", systemImage: "square.grid.2x2")
                        Spacer(minLength: 8)
                        Label("Muted previews", systemImage: "speaker.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let preferenceError {
                        ErrorNotice(message: preferenceError)
                        Button("Reset camera view preferences") { resetPreferences() }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                    }
                    if dynamicTypeSize.isAccessibilitySize && currentPreferences.density != .oneColumn {
                        Text("Larger accessibility text uses a single camera column.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: cameraColumns, spacing: 18) {
                        ForEach(dashboardCameras) { camera in
                            Button { selected = camera } label: {
                                LiveVideoView(
                                    api: api, camera: camera,
                                    stream: camera.preferredStream(expanded: false),
                                    active: active && selected == nil && !showCameraTour, muted: true,
                                    isFavorite: currentPreferences.favoriteIDs.contains(camera.id),
                                    favoriteAction: canEditPreferences ? {
                                        updatePreferences { try $0.toggleFavorite(camera.id) }
                                    } : nil
                                )
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .overlay(alignment: .bottomLeading) {
                                    cameraLabel(camera)
                                }
                                .background(HorizonPalette.surface)
                                .clipShape(RoundedRectangle(cornerRadius: HorizonPalette.cardRadius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: HorizonPalette.cardRadius)
                                        .stroke(HorizonPalette.border, lineWidth: 1)
                                }
                                .shadow(color: .black.opacity(0.1), radius: 16, x: 0, y: 7)
                                .contentShape(RoundedRectangle(cornerRadius: HorizonPalette.cardRadius))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(camera.name)")
                            .accessibilityValue(currentPreferences.favoriteIDs.contains(camera.id) ? "Favorite" : "")
                            .accessibilityHint("Opens live video. Touch and hold for favorites and reconnect.")
                        }
                    }
                    if dashboardCameras.isEmpty {
                        ContentUnavailableView(currentPreferences.favoritesOnly ? "No available favorites" :
                            (model.cameras.isEmpty ? "No cameras" : "No dashboard cameras"),
                            systemImage: currentPreferences.favoritesOnly ? "star" : "video.slash",
                            description: Text(model.cameras.isEmpty
                                ? "No cameras are available for this account."
                                : (currentPreferences.favoritesOnly
                                    ? "Show all cameras, then touch and hold a video to add a favorite."
                                    : "No cameras are configured to appear on this dashboard.")))
                        if currentPreferences.favoritesOnly {
                            Button("Show all cameras") { updatePreferences { $0.favoritesOnly = false } }
                                .buttonStyle(HorizonButtonStyle(.secondary))
                        }
                    }
                }
                .padding(18)
            }
            .horizonScreen()
            .navigationTitle("Live")
            .task(id: preferenceScope) { loadPreferences() }
            .onChange(of: model.cameras.map(\.id)) { _, ids in
                if let selected, !ids.contains(selected.id) { self.selected = nil }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { dashboardOptions }
                ToolbarItem(placement: .primaryAction) {
                    Button("Camera tour", systemImage: "play.rectangle.on.rectangle") { showCameraTour = true }
                        .disabled(!dashboardCameras.contains(where: \.isTourCandidate))
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh cameras", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = model.error {
                    ErrorNotice(message: error) { Task { await model.refresh() } }.padding()
                }
            }
            .sheet(item: $selected) { camera in
                CameraDetailView(api: api, camera: camera)
            }
            .fullScreenCover(isPresented: $showCameraTour) {
                CameraTourView(api: api, active: active, preferredCameraIDs: dashboardCameras.map(\.id))
            }
        }
    }

    private var dashboardCameras: [HorizonCamera] {
        currentPreferences.cameras(from: model.cameras)
    }

    private var preferenceScope: String? {
        guard let username = model.profile?.username else { return nil }
        return "liveDashboard.v1." + HorizonAccountScope.key(server: api.address.url.absoluteString, username: username)
    }

    private var canEditPreferences: Bool {
        preferencesReady && preferenceScope != nil && loadedPreferenceScope == preferenceScope
    }

    private var currentPreferences: CameraDashboardPreferences {
        canEditPreferences ? preferences : CameraDashboardPreferences()
    }

    private var cameraColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize { return [GridItem(.flexible())] }
        switch currentPreferences.density {
        case .oneColumn: return [GridItem(.flexible())]
        case .comfortable: return [GridItem(.adaptive(minimum: 280), spacing: 18)]
        case .compact: return [GridItem(.adaptive(minimum: 170), spacing: 18)]
        }
    }

    private var dashboardOptions: some View {
        Menu {
            Picker("Camera layout", selection: Binding(
                get: { currentPreferences.density },
                set: { value in updatePreferences { $0.density = value } }
            )) {
                ForEach(CameraDashboardPreferences.Density.allCases) { density in
                    Text(density.label).tag(density)
                }
            }
            Toggle("Favorites only", isOn: Binding(
                get: { currentPreferences.favoritesOnly },
                set: { value in updatePreferences { $0.favoritesOnly = value } }
            ))
        } label: {
            Label("Camera view options", systemImage: "square.grid.2x2")
        }
        .disabled(!canEditPreferences)
    }

    private func cameraLabel(_ camera: HorizonCamera) -> some View {
        HStack(spacing: 6) {
            if currentPreferences.favoriteIDs.contains(camera.id) {
                Image(systemName: "star.fill").foregroundStyle(HorizonPalette.accent).accessibilityHidden(true)
            }
            Text(camera.name).lineLimit(1)
        }
        .font(.system(.subheadline, design: .rounded).weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.black.opacity(0.7), in: Capsule())
        .foregroundStyle(.white).padding(12)
        .allowsHitTesting(false)
    }

    private func loadPreferences() {
        selected = nil
        showCameraTour = false
        preferencesReady = false
        preferenceError = nil
        preferences = CameraDashboardPreferences()
        loadedPreferenceScope = preferenceScope
        guard let scope = preferenceScope else { return }
        do {
            if let stored = UserDefaults.standard.object(forKey: scope) {
                guard let data = stored as? Data else {
                    throw HorizonError.message("The saved camera view preferences have an invalid format.")
                }
                preferences = try JSONDecoder().decode(CameraDashboardPreferences.self, from: data)
            }
            preferencesReady = true
        } catch {
            preferenceError = "Camera view preferences could not be loaded: \(error.localizedDescription)"
        }
    }

    private func updatePreferences(_ update: (inout CameraDashboardPreferences) throws -> Void) {
        guard canEditPreferences, let scope = preferenceScope else {
            preferenceError = "Wait for this account's camera view preferences to load before changing them."
            return
        }
        do {
            var next = preferences
            try update(&next)
            let data = try JSONEncoder().encode(next)
            UserDefaults.standard.set(data, forKey: scope)
            preferences = next
            preferenceError = nil
        } catch {
            preferenceError = "Camera view preferences could not be saved: \(error.localizedDescription)"
        }
    }

    private func resetPreferences() {
        guard let scope = preferenceScope else {
            preferenceError = "Sign into an account before resetting its camera view preferences."
            return
        }
        UserDefaults.standard.removeObject(forKey: scope)
        loadPreferences()
    }
}

struct LiveVideoView: View {
    let api: HorizonAPI
    let camera: HorizonCamera
    let stream: String?
    let active: Bool
    let muted: Bool
    var reflection: VideoReflection? = nil
    var onVideoReady: ((Bool) -> Void)? = nil
    var onPlaybackFailure: ((String?) -> Void)? = nil
    var fillVideo = false
    var showsVideoHUD = true
    var isFavorite = false
    var favoriteAction: (() -> Void)? = nil
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var live = LiveStream()
    @StateObject private var httpsLive = HTTPSLiveStream()
    @AppStorage("liveTransport") private var transport = "https"
    @State private var retry = 0
    @State private var visible = false

    var body: some View {
        ZStack {
            Color.black
            if transport == "webrtc" {
                NativeVideoSurface(track: live.videoTrack, fillVideo: fillVideo) { live.receivedVideo(size: $0) }
            } else {
                HTTPSVideoSurface(stream: httpsLive, fillVideo: fillVideo)
            }
            if !camera.settings.enabled {
                Label("Camera disabled", systemImage: "video.slash")
                    .foregroundStyle(.white)
            } else if stream == nil {
                Text("Choose a live stream in the camera view.")
                    .font(.callout).foregroundStyle(.white).padding()
            } else if let error = transport == "webrtc" ? live.error : httpsLive.error {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                    Text(error).font(.caption).multilineTextAlignment(.center).lineLimit(5)
                }
                .foregroundStyle(.white).padding()
                .accessibilityLabel(error)
            } else if resolution == nil {
                ProgressView(active && scenePhase == .active
                    ? (transport == "webrtc" ? "Connecting WebRTC" : httpsLive.status) : "Paused")
                    .tint(.white).foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topLeading) {
            if showsVideoHUD, let resolution {
                Text("LIVE  \(Int(resolution.width)) x \(Int(resolution.height))")
                    .font(.caption2.monospaced().bold())
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(reduceTransparency ? Color.black : Color.black.opacity(0.78), in: Capsule())
                    .foregroundStyle(.white).padding(12)
            }
        }
        .contextMenu {
            Button("Reconnect", systemImage: "arrow.clockwise") { retry += 1 }
            if let favoriteAction {
                Button(isFavorite ? "Remove from favorites" : "Add to favorites",
                    systemImage: isFavorite ? "star.slash" : "star") { favoriteAction() }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if (transport == "webrtc" ? live.error : httpsLive.error) != nil {
                Button("Reconnect", systemImage: "arrow.clockwise") { retry += 1 }
                    .buttonStyle(HorizonButtonStyle(.secondary)).padding(8)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; reflection?.clearSource(); live.stop(); httpsLive.stop() }
        .onChange(of: muted, initial: true) { _, value in live.muted = value; httpsLive.muted = value }
        .onChange(of: resolution != nil, initial: true) { _, value in onVideoReady?(value) }
        .onChange(of: playbackError, initial: true) { _, value in onPlaybackFailure?(value) }
        .onReceive(live.$videoTrack) { track in
            guard transport == "webrtc" else { return }
            reflection?.follow(track: track)
        }
        .onReceive(httpsLive.$presentation) { presentation in
            guard transport != "webrtc" else { return }
            if presentation.resolution != nil { reflection?.follow(https: httpsLive) }
            else { reflection?.clearSource() }
        }
        .task(id: "\(camera.id)-\(stream ?? "")-\(transport)-\(active)-\(visible)-\(scenePhase == .active)-\(retry)-\(transport == "webrtc" ? false : muted)") {
            reflection?.clearSource()
            live.stop()
            httpsLive.stop()
            guard active, visible, scenePhase == .active, camera.settings.enabled, let stream else {
                live.stop()
                return
            }
            if transport == "webrtc" {
                await live.run(api: api, stream: stream, iceServers: model.iceServers)
            } else {
                await httpsLive.run(api: api, stream: stream)
            }
        }
    }

    private var resolution: CGSize? { transport == "webrtc" ? live.resolution : httpsLive.resolution }
    private var playbackError: String? { transport == "webrtc" ? live.error : httpsLive.error }
}

struct CameraDetailView: View {
    let api: HorizonAPI
    let camera: HorizonCamera
    @Environment(\.dismiss) private var dismiss
    @State private var stream = ""
    @State private var muted = true
    @State private var retry = UUID()
    @State private var foldMode: FoldMode = .flat
    @StateObject private var reflection = VideoReflection()
    @AppStorage("liveTransport") private var transport = "https"

    var body: some View {
        NavigationStack {
            DuoWorkspace(foldMode: $foldMode) {
                LiveVideoView(
                    api: api, camera: camera, stream: stream.isEmpty ? nil : stream,
                    active: true, muted: muted, reflection: reflection
                )
                .id(retry)
                .clipShape(RoundedRectangle(cornerRadius: foldMode == .flat ? 0 : HorizonPalette.controlRadius))
                .overlay {
                    if foldMode != .flat {
                        RoundedRectangle(cornerRadius: HorizonPalette.controlRadius)
                            .stroke(HorizonPalette.accent.opacity(0.3), lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(foldMode == .flat ? 0 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            } secondary: {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HorizonPlaybackModeBadge(foldMode: foldMode)
                        HorizonHero(title: camera.name,
                            subtitle: "A closer look. Tune the live view without changing what your camera records.",
                            systemImage: "viewfinder", eyebrow: "Live camera")
                        HorizonCard {
                            HorizonSectionHeader(title: "Viewing controls", systemImage: "slider.horizontal.3")
                            Menu {
                                Picker("Transport", selection: $transport) {
                                    Text("HTTPS (reverse-proxy friendly)").tag("https")
                                    Text("WebRTC (requires reachable ICE)").tag("webrtc")
                                }
                            } label: {
                                controlLabel("Transport", value: transport == "webrtc" ? "WebRTC" : "HTTPS")
                            }
                            Divider()
                            Menu {
                                Picker("Stream", selection: $stream) {
                                    Text("Choose a stream").tag("")
                                    ForEach(camera.settings.live.streams.keys.sorted(), id: \.self) { label in
                                        Text(label).tag(camera.settings.live.streams[label]!)
                                    }
                                }
                            } label: {
                                controlLabel("Stream", value: camera.settings.live.streams
                                    .first { $0.value == stream }?.key ?? (stream.isEmpty ? "Choose a stream" : stream))
                            }
                            Divider()
                            Toggle("Mute audio", systemImage: muted ? "speaker.slash" : "speaker.wave.2",
                                isOn: $muted)
                                .frame(minHeight: 44)
                            Button("Reconnect", systemImage: "arrow.clockwise") { retry = UUID() }
                                .buttonStyle(HorizonButtonStyle(.secondary))
                        }
                        HorizonCard {
                            HorizonSectionHeader(title: "Camera connection", systemImage: "video")
                            LabeledContent("Camera", value: camera.name)
                            LabeledContent("Transport", value: transport == "webrtc" ? "Native WebRTC" : "Native HTTPS / fMP4")
                            HorizonStatusPill(title: camera.settings.enabled ? "Camera enabled" : "Camera disabled",
                                systemImage: camera.settings.enabled ? "checkmark.circle" : "video.slash",
                                tint: camera.settings.enabled ? HorizonPalette.accent : HorizonPalette.warm)
                            Text("Automatic selection uses configured main-derived renditions at 720p or higher. Stream choices affect viewing only, never recordings or detection.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                }
                .tabletopReflection(reflection, foldMode: foldMode)
            }
            .horizonScreen()
            .navigationTitle(camera.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .onAppear {
                if stream.isEmpty { stream = camera.preferredStream(expanded: true) ?? "" }
            }
        }
    }

    private func controlLabel(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
