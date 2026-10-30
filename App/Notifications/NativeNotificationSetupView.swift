import SwiftUI
import UserNotifications
import HorizonCore

struct NativeNotificationSetupView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @State private var configuration: NativeSettingValue?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                HorizonHero(title: "Make alerts intentional",
                    subtitle: "Server rules decide what matters. This iPhone decides what it receives.",
                    systemImage: "bell.badge", eyebrow: "Notification setup")
                    .horizonHeroRow()
            }
            Section {
                step("1. Server Apple provider",
                    detail: "The server needs its APNs authentication key mounted privately, the correct app topic and provider enabled.",
                    complete: push.capabilities.map(\.enabled))
                step("2. Camera alert rules",
                    detail: "Enable notifications for the intended cameras and tune review alert labels, required zones and cooldowns. Device registration does not turn these on.",
                    complete: rulesEnabled)
                step("3. Allow iPhone notifications",
                    detail: "Allow notifications when enabling them, or use iOS Settings if permission was denied.",
                    complete: permissionGranted)
                step("4. Register this installation",
                    detail: "Return to Native notifications, choose cameras, then tap Enable native notifications or Save camera choices.",
                    complete: push.registered)
                Text("Neither this checklist nor refreshing support enables alerts, changes provider credentials or sends a test push.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("iOS Focus and Notification Summary can delay presentation. Banner style, sounds and preview visibility are controlled in iOS notification settings.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HorizonSectionHeader(title: "Delivery checklist", systemImage: "checklist")
            }
            if model.isAdmin, let api = model.api {
                Section {
                    NavigationLink { NativeServerSettingsView(api: api, initialPath: ["apns"]) } label: {
                        Label("Apple push provider settings", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    NavigationLink { NativeServerSettingsView(api: api, initialPath: ["notifications"]) } label: {
                        Label("Global notification defaults and cooldown", systemImage: "bell")
                    }
                    Text("Use an APNs provider key, not the App Store Connect upload key. Keep the .p8 contents on the server; only public IDs and the mounted key-file path belong in configuration. Review saves explicitly; a server restart may be needed to apply them.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    HorizonSectionHeader(title: "Server setup", systemImage: "server.rack")
                }
            } else {
                Text("An administrator must configure the server provider and camera rules. Phone permission cannot repair a disabled server provider.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if loading { ProgressView("Reading running camera rules") }
            if let error { ErrorNotice(message: error) }
            if let configuration {
                Section {
                    LabeledContent("Global cooldown",
                        value: configuration["notifications"]?["cooldown"]?.numeric.map { "\($0.formatted()) seconds" } ?? "Not reported")
                    Text("Global and camera cooldowns both apply. Camera settings can override the global enabled default. Existing suspension, zones, review severity and account permissions still apply.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Review alert labels and required zones determine alert severity. Detection-only review items are not a guarantee of push delivery.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    HorizonSectionHeader(title: "Running rules", systemImage: "line.3.horizontal.decrease")
                }
                ForEach(model.cameras) { camera in
                    let rules = NativeCameraNotificationRules(camera: camera.id, configuration: configuration)
                    Section(camera.name) {
                        LabeledContent("Camera", value: rules.cameraEnabled.map { $0 ? "Enabled" : "Disabled" } ?? "Not reported")
                        LabeledContent("Notification rule",
                            value: rules.notificationsEnabled.map { $0 ? "Enabled" : "Off" } ?? "Not reported")
                        LabeledContent("Camera cooldown", value: rules.cooldown.map { "\($0.formatted()) seconds" } ?? "Not reported")
                        LabeledContent("Alert labels", value: rules.alertLabels.map { $0.joined(separator: ", ") } ?? "Not reported")
                        LabeledContent("Required zones",
                            value: rules.requiredZones.map { $0.isEmpty ? "Any zone" : $0.joined(separator: ", ") } ?? "Not reported")
                        if model.isAdmin, let api = model.api {
                            NavigationLink { NativeServerSettingsView(api: api,
                                initialPath: ["cameras", camera.id, "notifications"]) } label: {
                                Label("Tune camera notifications", systemImage: "bell")
                            }
                            NavigationLink { NativeServerSettingsView(api: api,
                                initialPath: ["cameras", camera.id, "review"]) } label: {
                                Label("Tune alert labels, detections and zones", systemImage: "rectangle.stack")
                            }
                        }
                    }
                }
            }
            Section {
                if push.registered, push.capabilities?.devicePreferences == true {
                    NavigationLink { NativeNotificationPreferencesView() } label: {
                        Label("Quiet hours, camera snooze and health opt-in", systemImage: "moon.zzz")
                    }
                } else {
                    Text("Per-device quiet hours, snooze and health opt-in require registration and the corresponding backend capability. They are not assumed available on older servers.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("Camera images are a separate Lock Screen privacy opt-in on the previous screen. A real test push still requires your explicit confirmation.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HorizonSectionHeader(title: "Tune this device", systemImage: "iphone")
            }
            Button("Refresh setup", systemImage: "arrow.clockwise") {
                Task { await push.refreshServerSupport(); await loadRules() }
            }
            .disabled(loading || push.busy || push.checkingSupport)
        }
        .horizonScreen()
        .navigationTitle("Setup and tune alerts")
        .task { await loadRules() }
        .onChange(of: model.api.map(ObjectIdentifier.init)) { _, _ in configuration = nil }
    }

    private var rulesEnabled: Bool? {
        guard let configuration else { return nil }
        let rules = model.cameras.map { NativeCameraNotificationRules(camera: $0.id, configuration: configuration) }
        if rules.contains(where: { $0.eligible == true }) { return true }
        return rules.allSatisfy({ $0.eligible != nil }) ? false : nil
    }

    private var permissionGranted: Bool {
        [.authorized, .provisional, .ephemeral].contains(push.permission)
    }

    private func step(_ title: String, detail: String, complete: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: complete == true ? "checkmark.circle.fill" :
                (complete == false ? "circle" : "questionmark.circle"))
                .font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    private func loadRules() async {
        guard let api = model.api, !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let value: NativeSettingValue = try await api.get(["config"])
            guard model.api === api, !Task.isCancelled else { return }
            configuration = value
        } catch {
            configuration = nil
            self.error = "Running notification rules could not be verified: \(error.localizedDescription)"
        }
    }
}
