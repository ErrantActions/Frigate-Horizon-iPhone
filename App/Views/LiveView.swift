import SwiftUI
import HorizonCore

struct LiveView: View {
    let api: HorizonAPI
    let active: Bool
    @EnvironmentObject private var model: AppModel
    @State private var selected: HorizonCamera?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HorizonHero(title: "Eyes on everything.",
                        subtitle: "Your cameras, together. Open a view to focus on the details.",
                        systemImage: "video.fill", eyebrow: "Live")
                    HStack {
                        HorizonStatusPill(title: "\(dashboardCameras.count) cameras", systemImage: "square.grid.2x2")
                        Spacer(minLength: 8)
                        Label("Muted previews", systemImage: "speaker.slash")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 18)], spacing: 18) {
                        ForEach(dashboardCameras) { camera in
                            Button { selected = camera } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    LiveVideoView(
                                        api: api, camera: camera,
                                        stream: camera.preferredStream(expanded: false),
                                        active: active && selected == nil, muted: true
                                    )
                                    .aspectRatio(16 / 9, contentMode: .fit)
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                                            Text(camera.name)
                                                .font(.system(.headline, design: .rounded))
                                                .foregroundStyle(.primary)
                                                .multilineTextAlignment(.leading)
                                            Spacer(minLength: 0)
                                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                                .foregroundStyle(HorizonPalette.accent)
                                                .accessibilityHidden(true)
                                        }
                                        HorizonStatusPill(
                                            title: camera.settings.enabled ? "Enabled" : "Disabled",
                                            systemImage: camera.settings.enabled ? "video" : "video.slash",
                                            tint: camera.settings.enabled ? HorizonPalette.accent : HorizonPalette.warm)
                                    }
                                    .padding(16)
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
                            .accessibilityHint("Opens live video and camera viewing controls.")
                        }
                    }
                    if dashboardCameras.isEmpty {
                        ContentUnavailableView(model.cameras.isEmpty ? "No cameras" : "No dashboard cameras",
                            systemImage: "video.slash",
                            description: Text(model.cameras.isEmpty
                                ? "No cameras are available for this account."
                                : "No cameras are configured to appear on this dashboard."))
                    }
                }
                .padding(18)
            }
            .horizonScreen()
            .navigationTitle("Live")
            .toolbar {
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
        }
    }

    private var dashboardCameras: [HorizonCamera] {
        model.cameras.filter { $0.settings.ui?.dashboard != false }
    }
}

struct LiveVideoView: View {
    let api: HorizonAPI
    let camera: HorizonCamera
    let stream: String?
    let active: Bool
    let muted: Bool
    var reflection: VideoReflection? = nil
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
                NativeVideoSurface(track: live.videoTrack) { live.receivedVideo(size: $0) }
            } else {
                HTTPSVideoSurface(stream: httpsLive)
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
            if let resolution {
                Text("LIVE  \(Int(resolution.width)) x \(Int(resolution.height))")
                    .font(.caption2.monospaced().bold())
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(reduceTransparency ? Color.black : Color.black.opacity(0.78), in: Capsule())
                    .foregroundStyle(.white).padding(12)
            }
        }
        .contextMenu {
            Button("Reconnect", systemImage: "arrow.clockwise") { retry += 1 }
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
        .onReceive(live.$videoTrack) { track in
            guard transport == "webrtc" else { return }
            reflection?.follow(track: track)
        }
        .onReceive(httpsLive.$resolution) { resolution in
            guard transport != "webrtc" else { return }
            if resolution != nil { reflection?.follow(https: httpsLive) }
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
