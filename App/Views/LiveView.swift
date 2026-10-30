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
    @State private var showCameraGroups = false
    @State private var cameraGroupScope: String?
    @State private var showIncidentReplay = false

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
                    if let group = currentPreferences.selectedGroup {
                        Text(group.name).font(.headline).lineLimit(2)
                    }
                    if let preferenceError {
                        ErrorNotice(message: preferenceError)
                        Button("Reset camera view preferences") { resetPreferences() }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                    }
                    if dynamicTypeSize.isAccessibilitySize && currentPreferences.effectiveDensity != .oneColumn {
                        Text("Larger accessibility text uses a single camera column.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: cameraColumns, spacing: 18) {
                        ForEach(dashboardCameras) { camera in
                            Button { selected = camera } label: {
                                LiveVideoView(
                                    api: api, camera: camera,
                                    stream: camera.preferredStream(expanded: false),
                                    active: active && selected == nil && !showCameraTour
                                        && !showCameraGroups && !showIncidentReplay, muted: true,
                                    isFavorite: currentPreferences.favoriteIDs.contains(camera.id),
                                    favoriteAction: canEditPreferences ? {
                                        updatePreferences { try $0.toggleFavorite(camera.id) }
                                    } : nil,
                                    adaptiveQuality: true
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
                            (currentPreferences.selectedGroup != nil ? "No available group cameras" :
                                (model.cameras.isEmpty ? "No cameras" : "No dashboard cameras")),
                            systemImage: currentPreferences.favoritesOnly ? "star" : "video.slash",
                            description: Text(model.cameras.isEmpty
                                ? "No cameras are available for this account."
                                : (currentPreferences.favoritesOnly
                                    ? "Show all cameras, then touch and hold a video to add a favorite."
                                    : (currentPreferences.selectedGroup != nil
                                        ? "Choose another group or all dashboard cameras. Camera access is always checked for this account."
                                        : "No cameras are configured to appear on this dashboard."))))
                        if currentPreferences.favoritesOnly {
                            Button("Show all cameras") { updatePreferences { $0.favoritesOnly = false } }
                                .buttonStyle(HorizonButtonStyle(.secondary))
                        }
                        if currentPreferences.selectedGroup != nil {
                            Button("Show all dashboard cameras") {
                                updatePreferences { value in
                                    try value.selectGroup(nil)
                                    value.favoritesOnly = false
                                }
                            }
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
                    Menu("Camera tools", systemImage: "ellipsis.circle") {
                        Button("Incident replay", systemImage: "square.split.2x2") { showIncidentReplay = true }
                            .disabled(dashboardCameras.count < 2)
                        Button("Camera tour", systemImage: "play.rectangle.on.rectangle") { showCameraTour = true }
                            .disabled(!dashboardCameras.contains(where: \.isTourCandidate))
                        Button("Refresh cameras", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    }
                }
            }
            .refreshable { await model.refresh() }
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
            .sheet(isPresented: $showCameraGroups, onDismiss: { cameraGroupScope = nil }) {
                SavedCameraGroupsView(cameras: model.cameras, preferences: currentPreferences) { value in
                    guard cameraGroupScope != nil, cameraGroupScope == preferenceScope else {
                        throw HorizonError.message("The account changed while these camera groups were being edited.")
                    }
                    try persistPreferences(value)
                }
                .id(cameraGroupScope)
            }
            .fullScreenCover(isPresented: $showIncidentReplay) {
                IncidentCameraPickerView(api: api, cameras: dashboardCameras)
            }
        }
    }

    private var dashboardCameras: [HorizonCamera] {
        currentPreferences.cameras(from: model.cameras)
    }

    private var preferenceScope: String? {
        guard let username = model.profile?.username else { return nil }
        return "liveDashboard.v2." + HorizonAccountScope.key(server: api.address.url.absoluteString, username: username)
    }

    private var legacyPreferenceScope: String? {
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
        switch currentPreferences.effectiveDensity {
        case .oneColumn: return [GridItem(.flexible())]
        case .comfortable: return [GridItem(.adaptive(minimum: 280), spacing: 18)]
        case .compact: return [GridItem(.adaptive(minimum: 170), spacing: 18)]
        }
    }

    private var dashboardOptions: some View {
        Menu {
            Picker("Camera group", selection: Binding(
                get: { currentPreferences.selectedGroupID },
                set: { value in updatePreferences { try $0.selectGroup(value) } }
            )) {
                Text("All cameras").tag(Optional<UUID>.none)
                ForEach(currentPreferences.groups) { group in Text(group.name).tag(Optional(group.id)) }
            }
            Button("Manage camera groups", systemImage: "square.grid.3x2") {
                cameraGroupScope = preferenceScope
                showCameraGroups = true
            }
            Picker("Camera layout", selection: Binding(
                get: { currentPreferences.effectiveDensity },
                set: { value in updatePreferences { try $0.setCurrentDensity(value) } }
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
        showCameraGroups = false
        cameraGroupScope = nil
        showIncidentReplay = false
        preferencesReady = false
        preferenceError = nil
        preferences = CameraDashboardPreferences()
        loadedPreferenceScope = preferenceScope
        guard let scope = preferenceScope else { return }
        do {
            let stored = UserDefaults.standard.object(forKey: scope)
                ?? legacyPreferenceScope.flatMap { UserDefaults.standard.object(forKey: $0) }
            if let stored {
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
        guard canEditPreferences else {
            preferenceError = "Wait for this account's camera view preferences to load before changing them."
            return
        }
        do {
            var next = preferences
            try update(&next)
            try persistPreferences(next)
            preferenceError = nil
        } catch {
            preferenceError = "Camera view preferences could not be saved: \(error.localizedDescription)"
        }
    }

    private func persistPreferences(_ value: CameraDashboardPreferences) throws {
        guard canEditPreferences, let scope = preferenceScope else {
            throw HorizonError.message("The account changed before these camera preferences could be saved.")
        }
        let data = try JSONEncoder().encode(value)
        UserDefaults.standard.set(data, forKey: scope)
        preferences = value
        preferenceError = nil
    }

    private func resetPreferences() {
        guard let scope = preferenceScope else {
            preferenceError = "Sign into an account before resetting its camera view preferences."
            return
        }
        UserDefaults.standard.removeObject(forKey: scope)
        if let legacyPreferenceScope { UserDefaults.standard.removeObject(forKey: legacyPreferenceScope) }
        loadPreferences()
    }
}

@MainActor
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
    var showsPiPControl = false
    var adaptiveQuality = false
    var expandedQuality = false
    var maximumQualityHeight: Int? = nil
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var attachment = LivePlaybackAttachment()
    @ObservedObject private var pictureInPicture = LivePictureInPictureController.shared
    @AppStorage("liveTransport") private var transport = "https"
    @State private var retry = 0
    @State private var visible = false
    @State private var viewer = UUID()
    @State private var showReauthentication = false

    private var playback: LivePlaybackSession { attachment.session }
    private var live: LiveStream { playback.live }
    private var httpsLive: HTTPSLiveStream { playback.httpsLive }
    private var hlsLive: HLSLiveStream { playback.hlsLive }
    private var allowedCamera: HorizonCamera? { model.cameras.first { $0.id == camera.id } }
    private var playbackEnabled: Bool { allowedCamera?.settings.enabled == true }
    private var playbackQuality: LivePlaybackQuality? {
        guard let current = allowedCamera else { return nil }
        if !adaptiveQuality, stream == nil { return nil }
        return current.playbackQuality(expanded: expandedQuality,
            pinnedStream: adaptiveQuality ? nil : stream, maximumHeight: maximumQualityHeight)
    }
    private var effectiveStream: String? { playbackQuality?.requestedStream }
    private var qualityPlan: LiveAdaptiveQualityPlan? { playbackQuality?.adaptivePlan }
    private var hlsConfiguration: LiveHLSConfiguration? {
        guard LiveHLSGate.shouldProbe(cameraEnabled: playbackEnabled, optedIn: allowedCamera?.settings.ui?.liveHLS == true,
            automatic: adaptiveQuality, transport: transport) else { return nil }
        return LiveHLSConfiguration(maximumHeight: maximumQualityHeight)
    }

    var body: some View {
        ZStack {
            Color.black
            if playback.usesLiveHLS {
                NativeLiveHLSSurface(stream: hlsLive, fillVideo: fillVideo)
                    .id(ObjectIdentifier(playback))
            } else if transport == "webrtc" {
                if showsPiPControl {
                    LivePiPVideoSurface(displayLayer: playback.webRTCPiPRenderer.displayLayer)
                        .id(ObjectIdentifier(playback))
                }
                NativeVideoSurface(track: live.videoTrack, fillVideo: fillVideo) { live.receivedVideo(size: $0) }
            } else {
                HTTPSVideoSurface(stream: httpsLive, fillVideo: fillVideo)
                    .id(ObjectIdentifier(playback))
            }
            if !playbackEnabled {
                Label("Camera disabled", systemImage: "video.slash")
                    .foregroundStyle(.white)
            } else if effectiveStream == nil && hlsConfiguration == nil {
                Text("Choose a live stream in the camera view.")
                    .font(.callout).foregroundStyle(.white).padding()
            } else if let error = playbackError {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                    Text(error).font(.caption).multilineTextAlignment(.center).lineLimit(5)
                }
                .foregroundStyle(.white).padding()
                .accessibilityLabel(error)
            } else if resolution == nil {
                if playback.paused {
                    Text("Paused — reconnect to resume").font(.callout).foregroundStyle(.white).padding()
                } else {
                    ProgressView(active && scenePhase == .active
                        ? (transport == "webrtc" ? "Connecting WebRTC" : playback.status) : "Paused")
                        .tint(.white).foregroundStyle(.white)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if showsVideoHUD, let resolution {
                Text("\(playback.usesLiveHLS ? "HLS ABR" : (adaptiveQuality ? "AUTO" : "LIVE"))  \(Int(resolution.width)) x \(Int(resolution.height))")
                    .font(.caption2.monospaced().bold())
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(reduceTransparency ? Color.black : Color.black.opacity(0.78), in: Capsule())
                    .foregroundStyle(.white).padding(12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsPiPControl, playbackEnabled, effectiveStream != nil || hlsConfiguration != nil {
                Button {
                    if pictureInPicture.owns(playback), pictureInPicture.isStarting {
                        pictureInPicture.stop()
                    } else if pictureInPicture.isPlaying(playback) {
                        pictureInPicture.returnToInline(playback)
                    } else {
                        pictureInPicture.start(playback)
                    }
                } label: {
                    Image(systemName: pictureInPicture.isPlaying(playback) ? "pip.exit" : "pip.enter")
                        .font(.title3).frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(reduceTransparency ? Color.black : Color.black.opacity(0.78), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(pictureInPicture.owns(playback) && pictureInPicture.isStarting
                    ? "Cancel Picture in Picture"
                    : (pictureInPicture.isPlaying(playback) ? "Return live video to app" : "Start live Picture in Picture"))
                .padding(8)
            }
        }
        .contextMenu {
            Button("Reconnect", systemImage: "arrow.clockwise") { reconnect() }
            if let favoriteAction {
                Button(isFavorite ? "Remove from favorites" : "Add to favorites",
                    systemImage: isFavorite ? "star.slash" : "star") { favoriteAction() }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if playback.needsReauthentication, model.profile != nil {
                Button("Sign in again", systemImage: "person.crop.circle.badge.checkmark") {
                    showReauthentication = true
                }
                .buttonStyle(HorizonButtonStyle(.secondary)).padding(8)
            } else if playbackError != nil || playback.paused {
                Button("Reconnect", systemImage: "arrow.clockwise") { reconnect() }
                    .buttonStyle(HorizonButtonStyle(.secondary)).padding(8)
            } else if let notice = playback.compatibilityNotice {
                Text(notice).font(.caption2).foregroundStyle(.white)
                    .padding(8).background(.black.opacity(0.75), in: Capsule()).padding(8)
            }
        }
        .alert("Live Picture in Picture", isPresented: Binding(
            get: { playback.pictureInPictureError != nil },
            set: { if !$0 { playback.pictureInPictureError = nil } }
        )) {
            Button("OK", role: .cancel) { playback.pictureInPictureError = nil }
        } message: {
            Text(playback.pictureInPictureError ?? "")
        }
        .onAppear { visible = true; playback.attach(viewer) }
        .onDisappear {
            visible = false
            playback.detach(viewer)
            if !playback.hasInlineViewer { reflection?.clearSource() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.deactivateInlineViewer(viewer) }
        }
        .onChange(of: active) { _, value in
            if !value { playback.deactivateInlineViewer(viewer) }
        }
        .onChange(of: muted, initial: true) { _, value in
            live.muted = value; httpsLive.muted = value; hlsLive.muted = value
        }
        .onChange(of: resolution != nil, initial: true) { _, value in onVideoReady?(value) }
        .onChange(of: playbackError, initial: true) { _, value in onPlaybackFailure?(value) }
        .onChange(of: playback.needsReauthentication, initial: true) { _, needed in
            if needed { model.reportSessionExpiry(from: api) }
        }
        .sheet(isPresented: $showReauthentication) {
            if let username = model.profile?.username { ReauthenticateView(username: username) }
        }
        .onReceive(live.$videoTrack) { track in
            guard transport == "webrtc" else { return }
            reflection?.follow(track: track)
        }
        .onReceive(httpsLive.$presentation) { presentation in
            guard transport != "webrtc", !playback.usesLiveHLS else { return }
            if presentation.resolution != nil { reflection?.follow(https: httpsLive) }
            else { reflection?.clearSource() }
        }
        .onReceive(hlsLive.$resolution) { resolution in
            guard playback.usesLiveHLS else { return }
            if resolution != nil { reflection?.follow(player: hlsLive.player) }
            else { reflection?.clearSource() }
        }
        .task(id: "\(ObjectIdentifier(api))-\(camera.id)-\(playbackEnabled)-\(effectiveStream ?? "")-\(qualityPlan?.identity ?? "")-\(hlsConfiguration != nil)-\(maximumQualityHeight ?? 0)-\(transport)-\(active)-\(visible)-\(scenePhase == .active)-\(retry)-\(muted)-\(pictureInPicture.scopeRevision)") {
            attachment.adoptRetainedSession(
                api: api, cameraID: camera.id, stream: effectiveStream, transport: transport,
                enabled: showsPiPControl, viewer: viewer
            )
            playback.configure(
                api: api, cameraID: camera.id, stream: effectiveStream, transport: transport,
                muted: muted, cameraEnabled: playbackEnabled,
                active: active, visible: visible, foreground: scenePhase == .active,
                viewer: viewer, iceServers: model.iceServers, adaptiveQuality: qualityPlan,
                liveHLS: hlsConfiguration
            )
            if active, visible, scenePhase == .active {
                if playback.usesLiveHLS { reflection?.follow(player: hlsLive.player) }
                else if transport == "webrtc" { reflection?.follow(track: live.videoTrack) }
                else if httpsLive.resolution != nil { reflection?.follow(https: httpsLive) }
                else { reflection?.clearSource() }
            } else {
                reflection?.clearSource()
            }
        }
    }

    private var resolution: CGSize? { playback.resolution }
    private var playbackError: String? { playback.error }

    private func reconnect() {
        reflection?.clearSource()
        playback.reconnect()
        retry += 1
    }
}

struct CameraDetailView: View {
    let api: HorizonAPI
    let camera: HorizonCamera
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var stream = ""
    @State private var muted = true
    @State private var retry = UUID()
    @State private var foldMode: FoldMode = .flat
    @StateObject private var reflection = VideoReflection()
    @AppStorage("liveTransport") private var transport = "https"
    @State private var showQuickEvidence = false
    @State private var automaticMaximumHeight = 0
    @State private var history: CameraHistoryContext?
    @State private var showHistory = false
    @State private var historyError: String?

    init(api: HorizonAPI, camera: HorizonCamera) {
        self.api = api
        self.camera = camera
        let retained = LivePictureInPictureController.shared.retainedSelection(api: api, cameraID: camera.id)
        let hls = LivePictureInPictureController.shared.retainedLiveHLSConfiguration(api: api, cameraID: camera.id)
        _stream = State(initialValue: hls == nil ? (retained?.stream ?? "") : "")
        _automaticMaximumHeight = State(initialValue: hls?.maximumHeight ?? 0)
        _muted = State(initialValue: retained?.muted ?? true)
    }

    private var allowed: Bool {
        model.api === api && model.cameras.contains { $0.id == camera.id && $0.settings.enabled }
    }
    private var currentCamera: HorizonCamera { model.cameras.first { $0.id == camera.id } ?? camera }
    private var maximumHeight: Int? { automaticMaximumHeight == 0 ? nil : automaticMaximumHeight }

    var body: some View {
        NavigationStack {
            DuoWorkspace(foldMode: $foldMode) {
                LiveVideoView(
                    api: api, camera: currentCamera, stream: stream.isEmpty
                        ? currentCamera.preferredStream(expanded: true, maximumHeight: maximumHeight) : stream,
                    active: allowed && !showQuickEvidence && !showHistory, muted: muted, reflection: reflection,
                    showsPiPControl: true, adaptiveQuality: stream.isEmpty, expandedQuality: true,
                    maximumQualityHeight: maximumHeight
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
                        HStack {
                            Toggle("Mute", systemImage: muted ? "speaker.slash" : "speaker.wave.2", isOn: $muted)
                                .toggleStyle(.button).frame(minHeight: 44)
                            Spacer()
                            Button("Recordings", systemImage: "clock.arrow.circlepath") { openHistory() }
                                .frame(minHeight: 44).disabled(!allowed)
                        }
                        if let historyError { ErrorNotice(message: historyError) }
                        CameraControlsView(api: api, camera: camera,
                            active: allowed && scenePhase == .active && !showQuickEvidence && !showHistory)
                        HorizonCard {
                            DisclosureGroup("Quality and connection") {
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
                                    Text("Automatic (main-derived)").tag("")
                                    ForEach(currentCamera.settings.live.streams.keys.sorted(), id: \.self) { label in
                                        Text(label).tag(currentCamera.settings.live.streams[label]!)
                                    }
                                }
                            } label: {
                                controlLabel("Stream", value: stream.isEmpty ? "Automatic" :
                                    (currentCamera.settings.live.streams.first { $0.value == stream }?.key ?? stream))
                            }
                            if stream.isEmpty, !currentCamera.advertisedLiveRenditions.isEmpty {
                                Menu {
                                    Picker("Automatic maximum", selection: $automaticMaximumHeight) {
                                        Text("Default (1080p target)").tag(0)
                                        ForEach(currentCamera.advertisedLiveRenditions, id: \.height) { rendition in
                                            Text("\(rendition.height)p").tag(rendition.height)
                                        }
                                        if automaticMaximumHeight != 0,
                                           !currentCamera.advertisedLiveRenditions.contains(where: {
                                               $0.height == automaticMaximumHeight
                                           }) {
                                            Text("\(automaticMaximumHeight)p (unavailable)").tag(automaticMaximumHeight)
                                        }
                                    }
                                } label: {
                                    controlLabel("Automatic maximum", value: automaticMaximumHeight == 0
                                        ? "Default" : "\(automaticMaximumHeight)p")
                                }
                                if maximumHeight != nil,
                                   currentCamera.preferredStream(expanded: true, maximumHeight: maximumHeight) == nil {
                                    ErrorNotice(message: "No advertised profile fits this automatic maximum. Choose another maximum or an explicit stream.")
                                }
                            }
                            Divider()
                            Button("Reconnect", systemImage: "arrow.clockwise") {
                                LivePictureInPictureController.shared.stop()
                                retry = UUID()
                            }
                                .buttonStyle(HorizonButtonStyle(.secondary))
                            }
                        }
                        HorizonCard {
                            DisclosureGroup("Camera information") {
                            LabeledContent("Camera", value: camera.name)
                            LabeledContent("Transport", value: transport == "webrtc" ? "Native WebRTC" : "Native HTTPS / fMP4")
                            HorizonStatusPill(title: camera.settings.enabled ? "Camera enabled" : "Camera disabled",
                                systemImage: camera.settings.enabled ? "checkmark.circle" : "video.slash",
                                tint: camera.settings.enabled ? HorizonPalette.accent : HorizonPalette.warm)
                            Text(currentCamera.settings.ui?.liveHLS == true
                                ? "Automatic uses authenticated live HLS when this camera reports it ready. AVPlayer adapts within your maximum using throughput and buffering. Unsupported cameras keep compatibility HTTPS; manual stream choices keep the original player. Recording, detection and server settings never change."
                                : "Automatic viewing starts at the lowest advertised main-derived profile of at least 720p, including manually configured profiles, then adjusts up to your maximum using playback and network health. Manual choices and Picture in Picture stay pinned. Recordings, detection and server-side stream generation never change.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
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
                ToolbarItem(placement: .secondaryAction) {
                    Button("Save quick evidence", systemImage: "square.and.arrow.down") {
                        showQuickEvidence = true
                    }
                    .disabled(!model.cameras.contains(where: { $0.id == camera.id }))
                }
            }
            .onAppear {
                if let retained = LivePictureInPictureController.shared.retainedSelection(api: api, cameraID: camera.id) {
                    transport = retained.transport
                    if let hls = LivePictureInPictureController.shared.retainedLiveHLSConfiguration(api: api, cameraID: camera.id) {
                        stream = ""
                        automaticMaximumHeight = hls.maximumHeight ?? 0
                    } else { stream = retained.stream }
                    muted = retained.muted
                }
            }
            .sheet(isPresented: $showQuickEvidence) { QuickEvidenceView(api: api, camera: camera) }
            .fullScreenCover(isPresented: $showHistory) {
                if let history {
                    RecordingsView(api: api, context: history, standalone: true)
                }
            }
        }
    }

    private func openHistory() {
        do {
            let now = Date()
            history = try CameraHistoryContext(camera: camera.id, at: now,
                allowedCameraIDs: Set(model.cameras.map(\.id)), now: now)
            historyError = nil
            showHistory = true
        } catch { historyError = error.localizedDescription }
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
