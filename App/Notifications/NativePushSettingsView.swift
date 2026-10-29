import SwiftUI
import UserNotifications
import HorizonCore

struct NativePushSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @Environment(\.scenePhase) private var scenePhase
    @State private var allCameras = true
    @State private var selectedCameras: Set<String> = []
    @State private var confirmImages = false
    @State private var confirmTest = false

    var body: some View {
        Form {
            Section {
                HorizonHero(title: "Stay close to what matters",
                    subtitle: "Choose camera alerts for this installation and manage native Apple notifications.",
                    systemImage: "bell.badge", eyebrow: "Notifications")
                    .horizonHeroRow()
            }
            Section {
                HorizonStatusPill(title: push.registered ? "Installation registered" : "Installation not registered",
                    systemImage: push.registered ? "checkmark.shield" : "bell.slash",
                    tint: push.registered ? HorizonPalette.accent : HorizonPalette.warm)
                LabeledContent("Build support", value: push.supportedBuild ? "Enabled" : "Not enabled in this build")
                LabeledContent("Server provider", value: push.capabilities?.enabled == true ? "Enabled" : "Not configured / unavailable")
                LabeledContent("iOS permission", value: permissionText)
                Text(push.status).font(.footnote).foregroundStyle(.secondary)
                if push.checkingSupport { ProgressView("Checking server notification support") }
                if push.busy { ProgressView("Updating notification registration") }
                if let error = push.error { ErrorNotice(message: error) }
                Button("Refresh notification support", systemImage: "arrow.clockwise") {
                    Task { await push.refreshServerSupport() }
                }
                .disabled(push.busy || push.checkingSupport || !push.supportedBuild)
                if push.cleanupPending {
                    HorizonStatusPill(title: "Server registration cleanup is pending",
                        systemImage: "exclamationmark.triangle", tint: HorizonPalette.warm)
                }
            } header: {
                HorizonSectionHeader(title: "Native Apple notifications", systemImage: "antenna.radiowaves.left.and.right")
            }
            .listRowBackground(HorizonPalette.surface)
            Section {
                Toggle("All cameras allowed by my account", isOn: $allCameras)
                if !allCameras {
                    ForEach(model.cameras) { camera in
                        Toggle(camera.name, isOn: Binding(
                            get: { selectedCameras.contains(camera.id) },
                            set: { if $0 { selectedCameras.insert(camera.id) } else { selectedCameras.remove(camera.id) } }
                        ))
                    }
                    if selectedCameras.isEmpty {
                        Text("No cameras selected: this installation will not receive camera alerts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                HorizonSectionHeader(title: "Camera choices", systemImage: "video")
            }
            .listRowBackground(HorizonPalette.surface)
            .disabled(push.busy)
            Section {
                Toggle("Include camera images on the lock screen", isOn: Binding(
                    get: { push.imageNotifications },
                    set: { if $0 { confirmImages = true } else { push.setImageNotifications(false) } }
                ))
                .disabled(!push.imageNotifications && (push.busy || push.checkingSupport
                    || !push.registered || !push.supportedImageBuild
                    || push.capabilities?.imageNotifications != true))
                LabeledContent("Protected server image service",
                    value: push.capabilities?.imageNotifications == true ? "Available" : "Not enabled / unavailable")
                if push.imageNotifications {
                    LabeledContent("Secure image session", value: push.imageSessionReady ? "Ready" : "Needs attention")
                }
            } header: {
                HorizonSectionHeader(title: "Private notification images", systemImage: "photo")
            } footer: {
                Text("Off by default. Images can expose private camera footage on the lock screen. Thumbnails are fetched over authenticated HTTPS from your saved server, not sent through APNs. Unavailable authentication, connectivity, or time falls back to text. Turning images off removes delivered notifications from this device.")
            }
            .listRowBackground(HorizonPalette.surface)
            Section {
                Button(push.registered ? "Save camera choices / renew registration" : "Enable native notifications") {
                    Task { await push.enable(cameraIDs: allCameras ? nil : selectedCameras.sorted()) }
                }
                .buttonStyle(HorizonButtonStyle(.primary))
                .disabled(push.busy || push.checkingSupport || !push.supportedBuild || push.capabilities?.enabled != true)
                Button("Send a test to this installation") { confirmTest = true }
                    .buttonStyle(HorizonButtonStyle(.secondary))
                    .disabled(push.busy || !push.registered)
                if push.wantsPush || push.cleanupPending || push.registered {
                    Button("Disable and unregister", role: .destructive) { Task { _ = await push.disable() } }
                        .buttonStyle(HorizonButtonStyle(.secondary))
                        .disabled(push.busy)
                }
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) {
                        Label("Open iOS notification settings", systemImage: "arrow.up.forward.app")
                            .frame(minHeight: 44, alignment: .leading)
                    }
                }
            } header: {
                HorizonSectionHeader(title: "Registration & delivery", systemImage: "paperplane")
            } footer: {
                Text("Camera alert rules, suspension, cooldowns, and server permissions still apply. Registering this device does not enable server camera alerts. APNs uses Apple's service; generic text is the server default, but routing identifiers are sent. Apple acceptance does not guarantee delivery.")
            }
            .listRowBackground(HorizonPalette.surface)
        }
        .horizonScreen()
        .navigationTitle("Notifications")
        .confirmationDialog("Allow camera images on your lock screen?", isPresented: $confirmImages,
            titleVisibility: .visible) {
            Button("Enable private camera images") { push.setImageNotifications(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone who can see your lock screen may see these images. A limited session copy is shared securely with the notification extension and revoked on logout or account changes.")
        }
        .confirmationDialog("Send a real Apple push notification?", isPresented: $confirmTest,
            titleVisibility: .visible) {
            Button("Send test") { Task { await push.sendTest() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This contacts the server and Apple for this installation only. A test without an event or review reference is text-only; it does not verify image delivery.")
        }
        .task(id: scenePhase == .active) {
            if scenePhase == .active { await push.refreshServerSupport() }
        }
        .refreshable { await push.refreshServerSupport() }
        .onChange(of: model.cameras.map(\.id)) { _, ids in
            selectedCameras.formIntersection(Set(ids))
        }
        .onAppear {
            if let cameras = push.savedCameraIDs {
                allCameras = false
                selectedCameras = Set(cameras).intersection(Set(model.cameras.map(\.id)))
            }
        }
    }

    private var permissionText: String {
        switch push.permission {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .provisional: return "Provisional"
        case .ephemeral: return "Temporary"
        case .notDetermined: return "Not requested"
        @unknown default: return "Unknown"
        }
    }
}

struct NativeNotificationDestinationView: View {
    let api: HorizonAPI
    let route: NativeNotificationRoute
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @State private var review: ReviewSegment?
    @State private var event: SearchEvent?
    @State private var camera: HorizonCamera?
    @State private var error: String?
    @State private var retry = 0

    var body: some View {
        Group {
            if let error {
                VStack {
                    HorizonCard { ErrorNotice(message: error) { retry += 1 } }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .horizonScreen()
            } else if route.kind == .test {
                ContentUnavailableView("Test notification received", systemImage: "checkmark.bubble",
                    description: Text("This device received an Apple push notification."))
                    .horizonScreen()
            } else if let review {
                ReviewWorkspaceView(api: api, initialReview: review, cameras: model.cameras,
                    day: Date(timeIntervalSince1970: review.startTime))
            } else if let event {
                EventDetailView(api: api, initialEvent: event) {}
            } else if let camera {
                CameraDetailView(api: api, camera: camera)
            } else {
                ProgressView("Opening notification")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .horizonScreen()
            }
        }
        .task(id: "\(route.id)-\(retry)") {
            review = nil; event = nil; camera = nil; error = nil
            guard push.capabilities?.serverID == route.serverID else {
                error = "This notification belongs to a different server."
                return
            }
            guard route.kind != .test, let identifier = route.identifier else { return }
            do {
                switch route.kind {
                case .review:
                    let rows: [ReviewSegment] = try await api.get(["review_ids"], query: [
                        URLQueryItem(name: "ids", value: identifier),
                    ])
                    try Task.checkCancellation()
                    guard let row = rows.first(where: { $0.id == identifier }),
                          model.cameras.contains(where: { $0.id == row.camera }) else {
                        throw HorizonError.message("The review item is unavailable or access was removed.")
                    }
                    review = row
                case .event:
                    let value: SearchEvent = try await api.get(["events", identifier])
                    try Task.checkCancellation()
                    guard model.cameras.contains(where: { $0.id == value.camera }) else {
                        throw HorizonError.message("This event is no longer available to your account.")
                    }
                    event = value
                case .camera:
                    guard let value = model.cameras.first(where: { $0.id == identifier }) else {
                        throw HorizonError.message("This camera is no longer available to your account.")
                    }
                    camera = value
                case .test: break
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
