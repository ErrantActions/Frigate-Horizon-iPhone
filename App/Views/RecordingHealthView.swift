import SwiftUI
import HorizonCore

struct RecordingHealthView: View {
    let api: HorizonAPI
    var focusedIssueID: String? = nil
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: NativeHealthSnapshot?
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var retry = 0
    @State private var loadedScope: String?

    private var scope: String {
        "\(model.profile?.username ?? "")-\(model.profile?.role ?? "")-\(model.cameras.map(\.id).joined(separator: ","))"
    }

    private var visibleSnapshot: NativeHealthSnapshot? { loadedScope == scope ? snapshot : nil }

    private var context: String {
        "\(scenePhase == .active)-\(model.profile?.username ?? "")-\(model.profile?.role ?? "")-\(model.cameras.map(\.id).joined(separator: ","))-\(retry)"
    }

    private var verified: Bool {
        guard error == nil, let snapshot = visibleSnapshot else { return false }
        let age = Date().timeIntervalSince1970 - snapshot.sampledAt
        return snapshot.checksComplete && age >= -300 && age < 120
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HorizonHero(title: "Know when recording needs you",
                    subtitle: "Camera, recording, storage and detector health from your NVR. Idle detection is not treated as an outage.",
                    systemImage: "waveform.path.ecg", eyebrow: "Recording health")
                HorizonCard {
                    if let snapshot = visibleSnapshot {
                        HorizonStatusPill(
                            title: verified ? (snapshot.issues.isEmpty ? "No current issues" : "\(snapshot.issues.count) active issues") : "Health is not fully verified",
                            systemImage: verified && snapshot.issues.isEmpty ? "checkmark.shield" : "exclamationmark.triangle",
                            tint: verified && snapshot.issues.isEmpty ? HorizonPalette.accent : HorizonPalette.warm)
                        LabeledContent("Sampled", value: Date(timeIntervalSince1970: snapshot.sampledAt)
                            .formatted(date: .abbreviated, time: .standard))
                        if !snapshot.checksComplete {
                            Text("Some checks are unavailable. An empty issue list does not mean every recorder is healthy.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !verified {
                            Text("Showing the last received state. Refresh before relying on it.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if loading { ProgressView("Checking recording health") }
                    if let error { ErrorNotice(message: error) { retry += 1 } }
                    Button("Refresh health", systemImage: "arrow.clockwise") { retry += 1 }
                        .buttonStyle(HorizonButtonStyle(.secondary)).disabled(loading)
                }
                if let snapshot = visibleSnapshot {
                    if let focusedIssueID, !snapshot.issues.contains(where: { $0.id == focusedIssueID }) {
                        HorizonCard {
                            Text("The issue from this notification is no longer active or is no longer visible to this account.")
                                .font(.callout)
                        }
                    }
                    ForEach(snapshot.issues) { issue in
                        issueCard(issue)
                    }
                }
                HorizonCard {
                    HorizonSectionHeader(title: "Health notifications", systemImage: "bell.badge")
                    Text("Health alerts require a registered installation, supported server and explicit opt-in. Camera activity rules and your device's quiet hours still apply; opening this page enables nothing.")
                        .font(.footnote).foregroundStyle(.secondary)
                    NavigationLink { NativeNotificationPreferencesView() } label: {
                        Label("Device alert controls", systemImage: "slider.horizontal.3")
                            .frame(minHeight: 44)
                    }
                    .disabled(!push.registered || push.capabilities?.devicePreferences != true)
                }
            }
            .padding(18)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .horizonScreen()
        .navigationTitle("Recording health")
        .task(id: context) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
        .refreshable { await load() }
        .onDisappear { generation = UUID() }
    }

    private func issueCard(_ issue: NativeHealthIssue) -> some View {
        HorizonCard {
            HorizonStatusPill(title: issue.severity.rawValue.capitalized,
                systemImage: issue.severity == .critical ? "exclamationmark.octagon" : "exclamationmark.triangle",
                tint: issue.severity == .critical ? .red : HorizonPalette.warm)
            Text(issue.title).font(.headline)
            Text(issue.detail).font(.callout).textSelection(.enabled)
            Text("First seen \(Date(timeIntervalSince1970: issue.firstSeen).formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if let cameraID = issue.camera, let camera = model.cameras.first(where: { $0.id == cameraID }) {
                NavigationLink { CameraDetailView(api: api, camera: camera) } label: {
                    Label("Open \(camera.name)", systemImage: "video")
                        .frame(minHeight: 44)
                }
            }
        }
    }

    @MainActor
    private func load() async {
        let token = UUID()
        let accountScope = scope
        generation = token
        if loadedScope != accountScope { snapshot = nil; error = nil }
        loading = true
        defer { if generation == token { loading = false } }
        do {
            let value: NativeHealthSnapshot = try await api.get(["notifications", "apns", "health"])
            guard !Task.isCancelled, generation == token, scope == accountScope else { return }
            let allowed = Set(model.cameras.map(\.id))
            guard value.issues.allSatisfy({ issue in
                if let camera = issue.camera { return allowed.contains(camera) }
                return model.isAdmin
            }) else {
                throw HorizonError.message("The server returned health data outside this account's camera access.")
            }
            snapshot = value
            loadedScope = accountScope
            error = nil
        } catch {
            guard !Task.isCancelled, generation == token, scope == accountScope else { return }
            self.error = "Recording health could not be verified: \(error.localizedDescription)"
        }
    }
}
