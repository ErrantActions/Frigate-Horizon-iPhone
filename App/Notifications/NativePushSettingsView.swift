import SwiftUI
import UserNotifications
import HorizonCore

struct NativePushSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @Environment(\.scenePhase) private var scenePhase
    @State private var allCameras = true
    @State private var selectedCameras: Set<String> = []

    var body: some View {
        Form {
            Section("Native Apple notifications") {
                LabeledContent("Build support", value: push.supportedBuild ? "Enabled" : "Not enabled in this build")
                LabeledContent("Server provider", value: push.capabilities?.enabled == true ? "Enabled" : "Not configured / unavailable")
                LabeledContent("iOS permission", value: permissionText)
                Text(push.status).font(.footnote).foregroundStyle(.secondary)
                if push.busy { ProgressView("Updating notification registration") }
                if let error = push.error { ErrorNotice(message: error) }
                if push.cleanupPending {
                    Label("Server registration cleanup is pending", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section("Camera choices") {
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
            }
            .disabled(push.busy)
            Section {
                Button(push.registered ? "Save camera choices / renew registration" : "Enable native notifications") {
                    Task { await push.enable(cameraIDs: allCameras ? nil : selectedCameras.sorted()) }
                }
                .disabled(push.busy || !push.supportedBuild || push.capabilities?.enabled != true)
                Button("Send a test to this installation") { Task { await push.sendTest() } }
                    .disabled(push.busy || !push.registered)
                if push.wantsPush || push.cleanupPending || push.registered {
                    Button("Disable and unregister", role: .destructive) { Task { _ = await push.disable() } }
                        .disabled(push.busy)
                }
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open iOS notification settings", destination: url)
                }
            } footer: {
                Text("Camera alert rules, suspension, cooldowns, and server permissions still apply. APNs uses Apple's service; generic text is the server default, but routing identifiers are sent. Apple acceptance does not guarantee delivery.")
            }
        }
        .navigationTitle("Notifications")
        .task(id: scenePhase == .active) {
            if scenePhase == .active { await push.refreshAuthorization() }
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
                ErrorNotice(message: error) { retry += 1 }
            } else if route.kind == .test {
                ContentUnavailableView("Test notification received", systemImage: "checkmark.bubble",
                    description: Text("This device received an Apple push notification."))
            } else if let review {
                ReviewWorkspaceView(api: api, initialReview: review, cameras: model.cameras,
                    day: Date(timeIntervalSince1970: review.startTime))
            } else if let event {
                EventDetailView(api: api, initialEvent: event) {}
            } else if let camera {
                CameraDetailView(api: api, camera: camera)
            } else { ProgressView("Opening notification") }
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
