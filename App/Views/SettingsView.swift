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
    @State private var showReauthentication = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HorizonHero(title: "Make it yours",
                        subtitle: "Your connection, your preferences, your privacy.",
                        systemImage: "slider.horizontal.3", eyebrow: "Horizon")
                HorizonCard {
                    HorizonSectionHeader(title: "Connection", systemImage: "network")
                    HStack(spacing: 24) {
                        HorizonMetric(title: "Allowed cameras", value: "\(model.cameras.count)", systemImage: "video")
                        Spacer()
                        if let role = model.profile?.role {
                            HorizonStatusPill(title: role.capitalized, systemImage: "person.crop.circle")
                        }
                    }
                    .padding(.vertical, 6)
                    LabeledContent("Server", value: api.address.url.absoluteString)
                        .textSelection(.enabled)
                    LabeledContent("Account", value: model.profile?.username ?? "")
                    LabeledContent("Role", value: model.profile?.role ?? "")
                    LabeledContent("Allowed cameras", value: "\(model.cameras.count)")
                    if let checked = model.lastConnectionCheck {
                        LabeledContent("Last configuration check",
                            value: checked.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let issue = model.connectionIssue {
                        ConnectionIssueNotice(issue: issue, detail: model.error)
                    }
                    Button("Refresh configuration", systemImage: "arrow.clockwise") {
                        Task { await model.refresh() }
                    }
                    .buttonStyle(HorizonButtonStyle(.secondary))
                    .disabled(model.isRefreshing || model.isConnecting)
                    if model.isRefreshing { ProgressView("Checking connection") }
                    Button("Sign in again", systemImage: "person.crop.circle.badge.checkmark") {
                        showReauthentication = true
                    }
                    .buttonStyle(HorizonButtonStyle(.secondary))
                    .disabled(model.isConnecting)
                    if model.connectionIssue == nil, let error = model.error {
                        ErrorNotice(message: error)
                    }
                }
                HorizonCard {
                    HorizonSectionHeader(title: "Server settings", systemImage: "server.rack")
                    if model.isAdmin {
                        NavigationLink { NativeServerSettingsView(api: api) } label: {
                            Label("Camera and server settings", systemImage: "slider.horizontal.3")
                                .frame(minHeight: 44)
                        }
                        Text("Native controls for the server's published settings, with drafts, validation and explicit save/restart confirmation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink { NativeNotificationSetupView() } label: {
                        Label("Set up and tune notifications", systemImage: "bell.badge")
                            .frame(minHeight: 44)
                    }
                }
                HorizonCard {
                    HorizonSectionHeader(title: "Appearance", systemImage: "circle.lefthalf.filled")
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Appearance")
                }
                HorizonCard {
                    HorizonSectionHeader(title: "Account", systemImage: "person.crop.circle")
                    NavigationLink { ChangePasswordView(api: api) } label: {
                        Label("Change password", systemImage: "key.horizontal")
                            .frame(minHeight: 44)
                    }
                    NavigationLink { NativePushSettingsView() } label: {
                        Label("Native notifications", systemImage: "bell.badge")
                            .frame(minHeight: 44)
                    }
                }
                HorizonCard {
                    HorizonSectionHeader(title: "Server health", systemImage: "waveform.path.ecg")
                    NavigationLink { RecordingHealthView(api: api) } label: {
                        Label("Recording health and alerts", systemImage: "heart.text.square")
                            .frame(minHeight: 44)
                    }
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
                    .buttonStyle(HorizonButtonStyle(.secondary))
                    .disabled(loading)
                }
                HorizonCard {
                    HorizonSectionHeader(title: "About Horizon", systemImage: "sun.horizon")
                    LabeledContent("App", value: "Frigate Horizon")
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")
                    LabeledContent("Video", value: "HTTPS or WebRTC live / HLS recordings")
                    Text("No WebViews, analytics, or Horizon cloud relay. Camera and account permissions are enforced by your server.")
                        .font(.footnote).foregroundStyle(.secondary)
                    DisclosureGroup("Implementation status") {
                        Text("Live PiP, incident replay, saved groups and quick evidence are native. PTZ, talkback, protected exports and device alert controls require the matching backend capabilities and supported hardware. Advanced search/export tools, face/classification management and several server tools remain future parity work.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                HorizonCard {
                    HorizonSectionHeader(title: "This device", systemImage: "iphone")
                    Button("Disconnect and forget session", role: .destructive) { confirmDisconnect = true }
                        .buttonStyle(HorizonButtonStyle(.secondary))
                        .disabled(model.isConnecting)
                    if model.error != nil && push.cleanupPending {
                        Button("Disconnect without server push cleanup", role: .destructive) { confirmUncleanDisconnect = true }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                    }
                    Text("Removes the session from this device. It does not change your server or revoke sessions on other devices.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Settings")
            .horizonScreen()
            .sheet(isPresented: $showReauthentication) {
                if let username = model.profile?.username {
                    ReauthenticateView(username: username)
                }
            }
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
            Section {
                HorizonHero(title: "Account security", subtitle: "Update the password on your Frigate server.",
                    systemImage: "key.horizontal")
                    .horizonHeroRow()
            }
            Section {
                SecureField("Current password", text: $oldPassword).textContentType(.password)
                SecureField("New password", text: $newPassword).textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmPassword).textContentType(.newPassword)
                Button("Change password") { Task { await save() } }
                    .disabled(busy || oldPassword.isEmpty || newPassword.isEmpty || newPassword != confirmPassword)
                    .buttonStyle(HorizonButtonStyle())
            } header: {
                Text("Change your Frigate password")
            } footer: {
                Text("The server enforces password strength. Passwords are discarded after the request.")
            }
            if busy { ProgressView("Updating password") }
            if let message { Text(message) }
            if let error { ErrorNotice(message: error) }
        }
        .navigationTitle("Change password")
        .horizonScreen()
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
