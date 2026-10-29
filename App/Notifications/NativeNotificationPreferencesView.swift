import SwiftUI
import HorizonCore

struct NativeNotificationPreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: NativePushController
    @Environment(\.dismiss) private var dismiss
    @State private var preferences: NativeDevicePreferences?
    @State private var quietEnabled = false
    @State private var startMinute = 22 * 60
    @State private var endMinute = 7 * 60
    @State private var timezone = TimeZone.current.identifier
    @State private var days = Set(1...7)
    @State private var healthAlerts = false
    @State private var baseline = ""
    @State private var loading = false
    @State private var error: String?
    @State private var message: String?
    @State private var showDiscard = false
    @State private var reloadAfterDiscard = false
    @State private var confirmHealth = false

    private var signature: String {
        "\(quietEnabled)-\(startMinute)-\(endMinute)-\(timezone)-\(days.sorted())-\(healthAlerts)"
    }
    private var dirty: Bool { preferences != nil && signature != baseline }
    private var busy: Bool { loading || push.preferencesBusy || push.busy }
    private var cameras: [HorizonCamera] {
        let selected = push.savedCameraIDs.map { Set($0) }
        return model.cameras.filter { selected?.contains($0.id) ?? true }
    }

    var body: some View {
        Form {
            Section {
                HorizonHero(title: "Alerts on your terms",
                    subtitle: "Snoozes and quiet hours affect only this installation. They never enable server camera rules.",
                    systemImage: "bell.and.waves.left.and.right", eyebrow: "Device alert controls")
                    .horizonHeroRow()
            }
            if loading { Section { ProgressView("Loading device alert preferences") } }
            if let error {
                Section {
                    ErrorNotice(message: error) {
                        if dirty { reloadAfterDiscard = true; showDiscard = true }
                        else { Task { await load() } }
                    }
                }
            }
            if let message { Section { Text(message).font(.callout) } }
            if preferences != nil {
                quietHoursSection
                snoozeSection
                healthSection
            }
        }
        .horizonScreen()
        .navigationTitle("Device alert controls")
        .navigationBarBackButtonHidden(dirty)
        .toolbar {
            if dirty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { reloadAfterDiscard = false; showDiscard = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if healthAlerts && preferences?.healthAlerts != true { confirmHealth = true }
                    else { Task { await save() } }
                }
                .disabled(!dirty || busy)
            }
        }
        .task { await load() }
        .refreshable {
            if dirty { reloadAfterDiscard = true; showDiscard = true }
            else { await load() }
        }
        .interactiveDismissDisabled(dirty)
        .modifier(DeferNotificationNavigation())
        .confirmationDialog("Discard unsaved alert changes?", isPresented: $showDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) {
                if reloadAfterDiscard { Task { await load() } } else { dismiss() }
            }
            Button("Keep editing", role: .cancel) {}
        }
        .confirmationDialog("Enable health notifications for this installation?",
            isPresented: $confirmHealth, titleVisibility: .visible) {
            Button("Enable and save") { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only health issues permitted for your current account may be sent. Quiet hours and server delivery policy still apply. Camera activity rules are not enabled.")
        }
    }

    private var quietHoursSection: some View {
        Section {
            Toggle("Quiet hours", isOn: $quietEnabled)
            if quietEnabled {
                DatePicker("Start", selection: clockBinding(start: true), displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, .gmt)
                DatePicker("End", selection: clockBinding(start: false), displayedComponents: .hourAndMinute)
                    .environment(\.timeZone, .gmt)
                TextField("IANA time zone", text: $timezone)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Use this device's time zone") { timezone = TimeZone.current.identifier }
                ForEach(1...7, id: \.self) { day in
                    Toggle(weekday(day), isOn: Binding(
                        get: { days.contains(day) },
                        set: { if $0 { days.insert(day) } else { days.remove(day) } }
                    ))
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            Text("Times are wall-clock times in the named time zone, including daylight-saving changes. Overnight quiet hours belong to the selected starting day. Saving Off explicitly clears the schedule.")
        }
        .disabled(busy)
    }

    private var snoozeSection: some View {
        Section {
            ForEach(cameras) { camera in
                VStack(alignment: .leading, spacing: 8) {
                    Text(camera.name).font(.headline)
                    if let until = preferences?.cameraSnoozeUntil[camera.id], until > Date().timeIntervalSince1970 {
                        Text("Snoozed until \(Date(timeIntervalSince1970: until).formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Menu("Camera snooze", systemImage: "bell.slash") {
                        Button("15 minutes") { Task { await snooze(camera.id, seconds: 900) } }
                        Button("1 hour") { Task { await snooze(camera.id, seconds: 3600) } }
                        Button("Resume camera alerts") { Task { await snooze(camera.id, seconds: 0) } }
                    }
                    .frame(minHeight: 44)
                }
            }
            if cameras.isEmpty {
                Text("No cameras are selected for alerts on this installation.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Per-camera snooze")
        } footer: {
            Text(dirty ? "Save or discard schedule changes before changing a camera snooze."
                : "Snoozing is immediate and affects only this installation. Resuming does not override disabled server camera rules.")
        }
        .disabled(busy || dirty)
    }

    private var healthSection: some View {
        Section {
            Toggle("Health notifications", isOn: $healthAlerts)
                .disabled(busy || (!healthAlerts && push.capabilities?.healthNotifications != true))
            Text("Camera outages, stalled recording, storage pressure and detector failures are assessed by the server, not inferred from idle detection FPS. Global system details require the appropriate account role.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: { Text("Recording health") }
    }

    private func clockBinding(start: Bool) -> Binding<Date> {
        Binding(get: {
            Date(timeIntervalSinceReferenceDate: Double((start ? startMinute : endMinute) * 60))
        }, set: { value in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let parts = calendar.dateComponents([.hour, .minute], from: value)
            guard let hour = parts.hour, let minute = parts.minute else {
                error = "The selected clock time could not be read."
                return
            }
            if start { startMinute = hour * 60 + minute } else { endMinute = hour * 60 + minute }
        })
    }

    private func weekday(_ day: Int) -> String {
        Calendar(identifier: .gregorian).weekdaySymbols[day % 7]
    }

    @MainActor
    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let value = try await push.loadAlertPreferences()
            guard !Task.isCancelled else { return }
            apply(value)
            error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func apply(_ value: NativeDevicePreferences) {
        preferences = value
        quietEnabled = value.quietHours?.enabled == true
        startMinute = value.quietHours?.startMinute ?? 1320
        endMinute = value.quietHours?.endMinute ?? 420
        timezone = value.quietHours?.timezone ?? TimeZone.current.identifier
        days = Set(value.quietHours?.days ?? Array(1...7))
        healthAlerts = value.healthAlerts
        baseline = signature
    }

    @MainActor
    private func save() async {
        guard var value = preferences else {
            error = "Reload device alert preferences before saving."
            return
        }
        do {
            value.quietHours = quietEnabled ? try NativeQuietHours(enabled: true, startMinute: startMinute,
                endMinute: endMinute, timezone: timezone, days: days.sorted()) : nil
            value.healthAlerts = healthAlerts
            let saved = try await push.saveAlertPreferences(value)
            guard !Task.isCancelled else { return }
            apply(saved)
            error = nil
            message = "Device alert preferences saved."
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    @MainActor
    private func snooze(_ camera: String, seconds: Int) async {
        do {
            let saved = try await push.snoozeCamera(camera, seconds: seconds)
            guard !Task.isCancelled else { return }
            apply(saved)
            error = nil
            message = seconds == 0 ? "Camera snooze cleared." : "Camera snooze saved for this installation."
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
