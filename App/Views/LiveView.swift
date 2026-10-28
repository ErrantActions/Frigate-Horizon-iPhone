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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(model.cameras.filter { $0.settings.ui?.dashboard != false }) { camera in
                        Button { selected = camera } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                LiveVideoView(
                                    api: api, camera: camera,
                                    stream: camera.preferredStream(expanded: false),
                                    active: active && selected == nil, muted: true
                                )
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                HStack {
                                    Text(camera.name).font(.headline)
                                    Spacer()
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(camera.name)")
                    }
                }
                .padding()
            }
            .overlay {
                if model.cameras.isEmpty {
                    ContentUnavailableView("No cameras", systemImage: "video.slash",
                        description: Text("No cameras are available for this account."))
                }
            }
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
}

struct LiveVideoView: View {
    let api: HorizonAPI
    let camera: HorizonCamera
    let stream: String?
    let active: Bool
    let muted: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
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
                    .padding(6).background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white).padding(8)
            }
        }
        .contextMenu {
            Button("Reconnect", systemImage: "arrow.clockwise") { retry += 1 }
        }
        .overlay(alignment: .bottomTrailing) {
            if (transport == "webrtc" ? live.error : httpsLive.error) != nil {
                Button("Reconnect", systemImage: "arrow.clockwise") { retry += 1 }
                    .font(.caption).buttonStyle(.borderedProminent).padding(8)
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false; live.stop(); httpsLive.stop() }
        .onChange(of: muted, initial: true) { _, value in live.muted = value; httpsLive.muted = value }
        .task(id: "\(stream ?? "")-\(transport)-\(active)-\(visible)-\(scenePhase == .active)-\(retry)-\(transport == "webrtc" ? false : muted)") {
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
    @AppStorage("liveTransport") private var transport = "https"

    var body: some View {
        NavigationStack {
            DuoWorkspace(foldMode: $foldMode) {
                LiveVideoView(
                    api: api, camera: camera, stream: stream.isEmpty ? nil : stream,
                    active: true, muted: muted
                )
                .id(retry)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding()
            } secondary: {
                Form {
                    if foldMode != .flat {
                        Section {
                            Label(foldMode.title, systemImage: foldMode == .tabletop ? "laptopcomputer" : "book")
                            Text("Video and controls stay on separate sides of the fold.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("Live video") {
                        Picker("Transport", selection: $transport) {
                            Text("HTTPS (reverse-proxy friendly)").tag("https")
                            Text("WebRTC (requires reachable ICE)").tag("webrtc")
                        }
                        Picker("Stream", selection: $stream) {
                            Text("Choose a stream").tag("")
                            ForEach(camera.settings.live.streams.keys.sorted(), id: \.self) { label in
                                Text(label).tag(camera.settings.live.streams[label]!)
                            }
                        }
                        Toggle("Mute audio", isOn: $muted)
                        Button("Reconnect", systemImage: "arrow.clockwise") { retry = UUID() }
                    }
                    Section {
                        LabeledContent("Camera", value: camera.name)
                        LabeledContent("Transport", value: transport == "webrtc" ? "Native WebRTC" : "Native HTTPS / fMP4")
                        LabeledContent("Status", value: camera.settings.enabled ? "Enabled" : "Disabled")
                    } footer: {
                        Text("Automatic selection uses configured main-derived renditions at 720p or higher. Stream choices affect viewing only, never recordings or detection.")
                    }
                }
                .safeAreaPadding(.bottom)
            }
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
}
