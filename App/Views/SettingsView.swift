import SwiftUI
import HorizonCore

struct ServerStats: Decodable {
    let service: Service
    struct Service: Decodable {
        let version: String
        let uptime: Double
    }
}

struct SettingsView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @AppStorage("appearance") private var appearance = "system"
    @State private var confirmDisconnect = false
    @State private var stats: ServerStats?
    @State private var statsError: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Server", value: api.address.url.absoluteString)
                        .textSelection(.enabled)
                    LabeledContent("Account", value: model.profile?.username ?? "")
                    LabeledContent("Role", value: model.profile?.role ?? "")
                    LabeledContent("Allowed cameras", value: "\(model.cameras.count)")
                    Button("Refresh configuration", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    if let error = model.error { ErrorNotice(message: error) }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                }
                Section("Account") {
                    NavigationLink("Change password") { ChangePasswordView(api: api) }
                    NavigationLink("Native notifications") { NativePushSettingsView() }
                }
                Section("Server health") {
                    if let stats {
                        LabeledContent("Version", value: stats.service.version)
                        LabeledContent("Uptime", value: Duration.seconds(stats.service.uptime)
                            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                    }
                    if let statsError { ErrorNotice(message: statsError) }
                    Button {
                        Task { await loadStats() }
                    } label: {
                        HStack {
                            Label("Check server", systemImage: "waveform.path.ecg")
                            Spacer()
                            if loading { ProgressView() }
                        }
                    }
                    .disabled(loading)
                }
                Section("About") {
                    LabeledContent("App", value: "Frigate Horizon")
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    LabeledContent("Video", value: "HTTPS or WebRTC live / HLS recordings")
                    Text("No WebViews, analytics, or Horizon cloud relay. Camera and account permissions are enforced by your server.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Native push requires an updated server and push-enabled signing setup. Talkback, advanced search/export tools, face/classification management, and several server tools are still pending parity.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Button("Disconnect and forget session", role: .destructive) { confirmDisconnect = true }
                    if model.error != nil && push.cleanupPending {
                        Button("Disconnect without server push cleanup", role: .destructive) { confirmUncleanDisconnect = true }
                    }
                } footer: {
                    Text("Removes the session from this device. It does not change your server or revoke sessions on other devices.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(item: $push.route) { route in
                NativeNotificationDestinationView(api: api, route: route)
            }
            .confirmationDialog("Disconnect from this server?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { _ = await model.disconnect() } }
            }
            .confirmationDialog("Disconnect without server cleanup?", isPresented: $confirmUncleanDisconnect,
                titleVisibility: .visible) {
                Button("Disconnect anyway", role: .destructive) {
                    Task { _ = await model.disconnect(skippingPushCleanup: true) }
                }
            } message: {
                Text("Notifications are stopped locally, but the old server registration may remain. Sign back in to remove it. Already accepted Apple pushes are best-effort.")
            }
        }
    }

    @State private var confirmUncleanDisconnect = false
    private func loadStats() async {
        loading = true
        statsError = nil
        defer { loading = false }
        do { stats = try await api.get(["stats"]) }
        catch { stats = nil; statsError = error.localizedDescription }
    }
}

private struct ChangePasswordView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section("Change your Frigate password") {
                SecureField("Current password", text: $oldPassword).textContentType(.password)
                SecureField("New password", text: $newPassword).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmPassword).textContentType(.newPassword)
                Button("Change password") { Task { await save() } }
                    .disabled(busy || oldPassword.isEmpty || newPassword.isEmpty || newPassword != confirmPassword)
            } footer: {
                Text("The server enforces password strength. Passwords are discarded after the request.")
            }
            if busy { ProgressView("Updating password") }
            if let message { Text(message) }
            if let error { ErrorNotice(message: error) }
        }
        .navigationTitle("Change password")
        .modifier(DeferNotificationNavigation())
        .disabled(busy)
        .onDisappear { clearPasswords() }
    }

    private func clearPasswords() { oldPassword = ""; newPassword = ""; confirmPassword = "" }

    private func save() async {
        guard let username = model.profile?.username else { error = "Reconnect before changing your password."; return }
        busy = true; error = nil; message = nil
        defer { busy = false; clearPasswords() }
        do {
            try await api.action(["users", username, "password"], method: "PUT",
                body: ["password": newPassword, "old_password": oldPassword])
            message = "Password updated."
            await model.refresh()
            if let refreshError = model.error { error = "Password changed, but session refresh failed: \(refreshError)" }
        } catch { self.error = error.localizedDescription }
    }
}
