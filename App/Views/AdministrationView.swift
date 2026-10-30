import SwiftUI
import Charts
import HorizonCore

struct AdministrationView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @State private var showConfig = false
    @State private var confirmRestart = false
    @State private var restarting = false
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            if model.isAdmin {
                List {
                    Section {
                        HorizonHero(title: "Your server, thoughtfully managed",
                            subtitle: "Monitor health, manage access, and make deliberate changes.",
                            systemImage: "slider.horizontal.3", eyebrow: "Administration")
                            .horizonHeroRow()
                    }
                    Section {
                        NavigationLink { SystemDashboardView(api: api) } label: {
                            AdminDestinationLabel(title: "System health and storage",
                                subtitle: "Performance, detectors, and disk usage", systemImage: "waveform.path.ecg")
                        }
                        NavigationLink { ServerLogsView(api: api) } label: {
                            AdminDestinationLabel(title: "Service logs",
                                subtitle: "Inspect and share loaded service output", systemImage: "text.alignleft")
                        }
                    } header: {
                        HorizonSectionHeader(title: "Monitor", systemImage: "waveform.path.ecg")
                    }
                    .listRowBackground(HorizonPalette.surface)
                    Section {
                        NavigationLink { NativeServerSettingsView(api: api) } label: {
                            AdminDestinationLabel(title: "Native server settings",
                                subtitle: "Camera, recording, detection, motion, alerts and integrations", systemImage: "slider.horizontal.3")
                        }
                        NavigationLink { AdminUsersView(api: api) } label: {
                            AdminDestinationLabel(title: "Users and roles",
                                subtitle: "Account access and password management", systemImage: "person.2")
                        }
                        Button { showConfig = true } label: {
                            AdminDestinationLabel(title: "Configuration editor",
                                subtitle: "Review and edit your server configuration", systemImage: "doc.text")
                        }
                        .buttonStyle(.plain)
                    } header: {
                        HorizonSectionHeader(title: "Manage", systemImage: "gearshape")
                    }
                    .listRowBackground(HorizonPalette.surface)
                    Section {
                        Button("Restart Frigate", systemImage: "arrow.clockwise", role: .destructive) {
                            confirmRestart = true
                        }
                        .buttonStyle(HorizonButtonStyle(.secondary))
                        .disabled(restarting)
                    } header: {
                        HorizonSectionHeader(title: "Server control", systemImage: "exclamationmark.shield")
                    } footer: {
                        Text("These actions affect your real server. Saving configuration or restarting always requires confirmation. Role-to-camera mappings are managed in the server configuration.")
                    }
                    .listRowBackground(HorizonPalette.surface)
                    if restarting { ProgressView("Requesting restart") }
                    if let message { Text(message).foregroundStyle(.secondary) }
                    if let error { ErrorNotice(message: error) }
                }
                .horizonScreen()
                .navigationTitle("Administration")
                .sheet(isPresented: $showConfig) { ServerConfigurationView(api: api) }
                .confirmationDialog("Restart Frigate?", isPresented: $confirmRestart, titleVisibility: .visible) {
                    Button("Restart server", role: .destructive) { Task { await restart() } }
                } message: {
                    Text("Live video and recording may be interrupted. The server may take a minute or longer to return.")
                }
            } else {
                ContentUnavailableView("Administrator access required", systemImage: "lock.shield",
                    description: Text("Server controls are available only to administrator accounts."))
                    .horizonScreen()
            }
        }
    }

    private struct AdminDestinationLabel: View {
        let title: String
        let subtitle: String
        let systemImage: String

        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3).foregroundStyle(HorizonPalette.accent)
                    .frame(width: 44, height: 44)
                    .background(HorizonPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(.headline, design: .rounded)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
    }

    private func restart() async {
        guard model.isAdmin else { error = "Administrator access is required."; return }
        restarting = true; error = nil; message = nil
        defer { restarting = false }
        do {
            let result: APIActionResult = try await api.send(["restart"], body: [String: String]())
            try result.requireSuccess()
            message = result.message ?? "The server accepted the restart request."
        } catch { self.error = error.localizedDescription }
    }
}

private struct FPSPoint: Identifiable {
    let id = UUID()
    let time: Date
    let fps: Double
}

private struct SystemDashboardView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var stats: SystemStats?
    @State private var samples: [FPSPoint] = []
    @State private var error: String?
    @State private var refreshID = 0

    var body: some View {
        List {
            Section {
                HorizonHero(title: "A pulse on your server",
                    subtitle: "Server-reported health, performance, and storage.",
                    systemImage: "waveform.path.ecg", eyebrow: "System")
                    .horizonHeroRow()
            }
            if let error { ErrorNotice(message: error) { refreshID += 1 } }
            if let stats {
                Section {
                    LabeledContent("Version", value: stats.service.version)
                    LabeledContent("Uptime", value: Duration.seconds(stats.service.uptime)
                        .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                    if stats.service.retentionUnmet == true {
                        HorizonStatusPill(title: "Configured retention is not being met",
                            systemImage: "exclamationmark.triangle", tint: HorizonPalette.warm)
                    }
                } header: {
                    HorizonSectionHeader(title: "Server", systemImage: "server.rack")
                }
                .listRowBackground(HorizonPalette.surface)
                if !samples.isEmpty {
                    Section {
                        Chart(samples) { point in
                            LineMark(x: .value("Time", point.time), y: .value("FPS", point.fps))
                                .foregroundStyle(HorizonPalette.accent)
                        }
                        .frame(height: 160)
                        .padding(.vertical, 8)
                    } header: {
                        HorizonSectionHeader(title: "Camera FPS", subtitle: "Server-reported samples",
                            systemImage: "chart.xyaxis.line")
                    }
                    .listRowBackground(HorizonPalette.surface)
                }
                cameraSection(stats)
                detectorSection(stats)
                storageSection(stats)
            } else if error == nil { ProgressView("Loading system status").padding(.vertical, 16) }
        }
        .horizonScreen()
        .navigationTitle("System")
        .refreshable { refreshID += 1 }
        .task(id: "\(scenePhase == .active)-\(refreshID)-\(model.isAdmin)") {
            guard model.isAdmin, scenePhase == .active else { return }
            repeat {
                do {
                    let result: SystemStats = try await api.get(["stats"])
                    try Task.checkCancellation()
                    stats = result; error = nil
                    if let fps = result.cameraFPS {
                        samples.append(FPSPoint(time: Date(), fps: fps))
                        if samples.count > 60 { samples.removeFirst(samples.count - 60) }
                    }
                } catch {
                    if !Task.isCancelled { self.error = error.localizedDescription }
                    return
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private func cameraSection(_ stats: SystemStats) -> some View {
        Section {
            ForEach(model.cameras) { camera in
                if let value = stats.cameras?[camera.id] {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(camera.name, systemImage: "video")
                            .font(.system(.headline, design: .rounded))
                        LabeledContent("Camera FPS", value: number(value.cameraFPS))
                        LabeledContent("Detection FPS", value: number(value.detectionFPS))
                        LabeledContent("Skipped FPS", value: number(value.skippedFPS))
                        LabeledContent("Connection", value: value.connectionQuality ?? "Not reported")
                    }
                    .font(.subheadline.monospacedDigit())
                    .padding(.vertical, 8)
                }
            }
        } header: {
            HorizonSectionHeader(title: "Allowed cameras", systemImage: "video")
        }
        .listRowBackground(HorizonPalette.surface)
    }

    private func detectorSection(_ stats: SystemStats) -> some View {
        Section {
            ForEach((stats.detectors ?? [:]).keys.sorted(), id: \.self) { name in
                if let detector = stats.detectors?[name] {
                    LabeledContent(name, value: "\(number(detector.inferenceSpeed)) ms")
                    if let temperature = detector.temperature {
                        LabeledContent("Temperature", value: "\(number(temperature)) C")
                    }
                }
            }
        } header: {
            HorizonSectionHeader(title: "Detectors", systemImage: "cpu")
        }
        .listRowBackground(HorizonPalette.surface)
    }

    private func storageSection(_ stats: SystemStats) -> some View {
        Section {
            ForEach((stats.service.storage ?? [:]).keys.sorted(), id: \.self) { name in
                if let storage = stats.service.storage?[name] {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(name).font(.subheadline.weight(.semibold)).textSelection(.enabled)
                        LabeledContent("Used", value: number(storage.used))
                        LabeledContent("Total", value: number(storage.total))
                        LabeledContent("Free", value: number(storage.free))
                        if storage.total > 0 {
                            ProgressView(value: min(storage.total, max(0, storage.used)), total: storage.total)
                                .accessibilityLabel("Storage used")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .padding(.vertical, 8)
                }
            }
        } header: {
            HorizonSectionHeader(title: "Storage", subtitle: "Values in server-reported MB",
                systemImage: "externaldrive")
        }
        .listRowBackground(HorizonPalette.surface)
    }

    private func number(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "Not reported"
    }
}

private struct ServerLogsView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var service = "frigate"
    @State private var logs: ServiceLogs?
    @State private var limit = 200
    @State private var follow = false
    @State private var search = ""
    @State private var error: String?
    @State private var refreshID = 0
    @State private var liveLines: [String] = []
    private var loadedLines: [String] { (logs?.lines ?? []) + liveLines }

    var body: some View {
        List {
            Section {
                HorizonHero(title: "Read the signal",
                    subtitle: "Inspect loaded service output or follow new log lines.",
                    systemImage: "text.alignleft", eyebrow: "Service logs")
                    .horizonHeroRow()
            }
            Section {
                Picker("Service", selection: $service) {
                    Text("Frigate").tag("frigate")
                    Text("go2rtc").tag("go2rtc")
                    Text("Nginx").tag("nginx")
                }
                Toggle("Follow live logs", isOn: $follow)
                Text("Logs may contain sensitive server details. Review them before sharing.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HorizonSectionHeader(title: "Log source", systemImage: "terminal")
            }
            .listRowBackground(HorizonPalette.surface)
            if let error { ErrorNotice(message: error) { refreshID += 1 } }
            if let logs {
                Section {
                    ForEach(Array(loadedLines.enumerated()).filter {
                        search.isEmpty || $0.element.localizedCaseInsensitiveContains(search)
                    }, id: \.offset) { line in
                        Text(line.element).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                    }
                    if loadedLines.isEmpty {
                        ContentUnavailableView("No loaded log lines", systemImage: "text.alignleft",
                            description: Text("Try refreshing or choose another service."))
                    } else if !search.isEmpty && !loadedLines.contains(where: {
                        $0.localizedCaseInsensitiveContains(search)
                    }) {
                        ContentUnavailableView.search(text: search)
                    }
                    if logs.lines.count < logs.totalLines {
                        Button("Load 200 more lines") { limit += 200 }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                    }
                } header: {
                    HorizonSectionHeader(title: "\(loadedLines.count) loaded lines",
                        subtitle: "\(logs.totalLines) processed lines at initial fetch", systemImage: "text.justify.left")
                }
                .listRowBackground(HorizonPalette.raised)
                ShareLink(item: loadedLines.joined(separator: "\n")) {
                    Label("Share loaded lines", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(HorizonButtonStyle(.secondary))
                .listRowBackground(HorizonPalette.surface)
            } else if error == nil { ProgressView("Loading logs").padding(.vertical, 16) }
        }
        .horizonScreen()
        .privacySensitive()
        .navigationTitle("Logs")
        .searchable(text: $search, prompt: "Filter loaded lines")
        .refreshable { refreshID += 1 }
        .task(id: "\(service)-\(limit)-\(follow)-\(scenePhase == .active)-\(refreshID)-\(model.isAdmin)") {
            guard model.isAdmin, scenePhase == .active else { return }
            do {
                let result: ServiceLogs = try await api.get(["logs", service], query: [
                    URLQueryItem(name: "start", value: String(-limit)),
                ])
                try Task.checkCancellation()
                logs = result; liveLines = []; error = nil
                if follow {
                    try await api.streamLogs(service: service) { line in
                        guard !Task.isCancelled, model.isAdmin, scenePhase == .active else { return }
                        liveLines.append(line)
                        if liveLines.count > 5000 { liveLines.removeFirst(liveLines.count - 5000) }
                    }
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onChange(of: service) { _, _ in logs = nil; limit = 200 }
    }
}

private struct ServerConfigurationView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: String?
    @State private var draft = ""
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @State private var message: String?
    @State private var restartAfterSave = false
    @State private var confirmSave = false
    @State private var confirmDiscard = false
    private var modified: Bool { original.map { draft != $0 } ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HorizonHero(title: "Make a deliberate change",
                        subtitle: "Edit the raw configuration with server-side validation.",
                        systemImage: "doc.text", eyebrow: "Configuration")
                        .horizonHeroRow()
                } header: {
                    EmptyView()
                } footer: {
                    Text("Raw configuration can contain credentials. It stays in memory here and is sent only to your server.")
                }
                if loading || saving { ProgressView(loading ? "Loading configuration" : "Validating and saving") }
                if let error { ErrorNotice(message: error) }
                if let message {
                    Label(message, systemImage: "checkmark.circle").font(.callout).foregroundStyle(HorizonPalette.accent)
                }
                Section {
                    TextEditor(text: $draft)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 360)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .accessibilityLabel("Raw server configuration")
                        .disabled(original == nil || saving)
                } header: {
                    HorizonSectionHeader(title: "Raw configuration",
                        subtitle: modified ? "Unsaved changes" : "Edit only after configuration has loaded",
                        systemImage: "curlybraces")
                }
                .listRowBackground(HorizonPalette.surface)
                Section {
                    Button("Reload") {
                        if modified { confirmDiscard = true }
                        else { Task { await load() } }
                    }
                    .buttonStyle(HorizonButtonStyle(.secondary))
                    .disabled(loading || saving)
                    Menu("Save configuration", systemImage: "square.and.arrow.down") {
                        Button("Save only (server validates)") { restartAfterSave = false; confirmSave = true }
                        Button("Save and restart", role: .destructive) { restartAfterSave = true; confirmSave = true }
                    }
                    .buttonStyle(HorizonButtonStyle(.primary))
                    .disabled(!modified || draft.isEmpty || saving || !model.isAdmin)
                } header: {
                    HorizonSectionHeader(title: "Apply changes", systemImage: "checkmark.shield")
                }
                .listRowBackground(HorizonPalette.surface)
            }
            .horizonScreen()
            .navigationTitle("Configuration")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if modified { confirmClose = true } else { dismiss() } }.disabled(saving)
                }
            }
            .interactiveDismissDisabled(modified || saving)
            .modifier(DeferNotificationNavigation())
            .task { await load() }
            .onChange(of: model.isAdmin) { _, isAdmin in
                if !isAdmin { draft = ""; original = nil; dismiss() }
            }
            .confirmationDialog("Save this configuration to the server?", isPresented: $confirmSave, titleVisibility: .visible) {
                Button(restartAfterSave ? "Save and restart server" : "Validate and save") { Task { await save() } }
            } message: {
                Text(restartAfterSave
                    ? "The server validates before writing. Restarting may interrupt live video and recordings."
                    : "This writes the real configuration file after server-side validation. A restart may be needed to apply changes.")
            }
            .confirmationDialog("Discard edits and reload?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard and reload", role: .destructive) { Task { await load() } }
            }
            .confirmationDialog("Discard unsaved configuration edits?", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Discard and close", role: .destructive) { dismiss() }
            }
        }
    }

    @State private var confirmClose = false

    private func load() async {
        guard model.isAdmin else { error = "Administrator access is required."; return }
        loading = true; error = nil; message = nil
        defer { loading = false }
        do {
            let raw = try await api.text(["config", "raw"])
            try Task.checkCancellation()
            original = raw; draft = raw
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func save() async {
        guard model.isAdmin, let original else { error = "Administrator access and loaded configuration are required."; return }
        saving = true; error = nil; message = nil
        defer { saving = false }
        do {
            let latest = try await api.text(["config", "raw"])
            guard latest == original else {
                throw HorizonError.message("The server configuration changed elsewhere. Reload and merge your edits before saving.")
            }
            let result = try await api.saveConfiguration(draft, restart: restartAfterSave)
            self.original = draft
            message = result.message ?? "Configuration saved."
        } catch { self.error = error.localizedDescription }
    }
}

private struct AdminUsersView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @State private var users: [AdminUser] = []
    @State private var selected: AdminUser?
    @State private var showCreate = false
    @State private var error: String?
    @State private var refreshID = 0
    @State private var loading = true

    var body: some View {
        List {
            Section {
                HorizonHero(title: "Access with intention",
                    subtitle: "Manage server accounts and the roles that define their access.",
                    systemImage: "person.2", eyebrow: "Users & roles")
                    .horizonHeroRow()
            }
            if let error { ErrorNotice(message: error) { refreshID += 1 } }
            Section {
                ForEach(users) { user in
                    Button { selected = user } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "person.crop.circle")
                                .font(.title2).foregroundStyle(HorizonPalette.accent).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(user.username).font(.system(.headline, design: .rounded)).foregroundStyle(.primary)
                                HorizonStatusPill(title: user.role, systemImage: "key")
                                if user.username == model.profile?.username {
                                    Text("Currently signed in").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary).accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if loading { ProgressView("Loading accounts").padding(.vertical, 16) }
                else if users.isEmpty && error == nil {
                    ContentUnavailableView("No accounts returned", systemImage: "person.2",
                        description: Text("Refresh to check the server's account list."))
                }
            } header: {
                HorizonSectionHeader(title: "Server accounts", subtitle: "\(users.count) loaded",
                    systemImage: "person.2")
            }
            .listRowBackground(HorizonPalette.surface)
        }
        .horizonScreen()
        .navigationTitle("Users and roles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Create user", systemImage: "person.badge.plus") { showCreate = true }
                    .disabled(model.roles.isEmpty)
            }
        }
        .task(id: "\(refreshID)-\(model.isAdmin)") {
            guard model.isAdmin else { loading = false; return }
            loading = true
            defer { loading = false }
            do { users = try await api.get(["users"]); error = nil }
            catch { self.error = error.localizedDescription }
        }
        .refreshable { refreshID += 1 }
        .sheet(item: $selected) { user in
            AdminUserEditor(api: api, user: user) { refreshID += 1 }
        }
        .sheet(isPresented: $showCreate) { AdminUserEditor(api: api, user: nil) { refreshID += 1 } }
    }
}

private struct AdminUserEditor: View {
    let api: HorizonAPI
    let user: AdminUser?
    let changed: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var role = "viewer"
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    @State private var confirmRole = false
    @State private var confirmPassword = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HorizonHero(title: user == nil ? "Create an account" : "Manage this account",
                        subtitle: user?.username ?? "Choose a username, role, and initial password.",
                        systemImage: "person.crop.circle.badge.checkmark", eyebrow: "Account access")
                        .horizonHeroRow()
                }
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(user != nil)
                    Picker("Role", selection: $role) {
                        ForEach(model.roles, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(user?.username == "admin" || (user != nil && username == model.profile?.username))
                    if let mapping = model.configuration?.auth?.roles[role] {
                        Text(mapping.isEmpty ? "This role has access to all cameras." : "Allowed cameras: \(mapping.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if user != nil {
                        Button("Update role") { confirmRole = true }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                            .disabled(role == user?.role || user?.username == "admin" || username == model.profile?.username)
                        if username == model.profile?.username {
                            Text("Use another administrator session to change this account's role or delete it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HorizonSectionHeader(title: "Account & role", systemImage: "person.crop.circle")
                }
                .listRowBackground(HorizonPalette.surface)
                Section {
                    SecureField("New password", text: $password).textContentType(.newPassword)
                    if user != nil {
                        Button("Reset password") { confirmPassword = true }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                            .disabled(password.isEmpty)
                    }
                    Text("The server enforces password strength. Passwords are never saved in app preferences.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    HorizonSectionHeader(title: user == nil ? "Initial password" : "Reset password",
                        systemImage: "key")
                }
                .listRowBackground(HorizonPalette.surface)
                Section {
                    if user == nil {
                        Button("Create user") { Task { await create() } }
                            .buttonStyle(HorizonButtonStyle(.primary))
                            .disabled(username.isEmpty || password.isEmpty || !model.roles.contains(role))
                    } else {
                        Button("Delete user", role: .destructive) { confirmDelete = true }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                            .disabled(username == "admin" || username == model.profile?.username)
                    }
                    if busy { ProgressView("Updating account") }
                    if let message { Text(message) }
                    if let error { ErrorNotice(message: error) }
                } header: {
                    HorizonSectionHeader(title: "Account actions", systemImage: "checkmark.shield")
                }
                .listRowBackground(HorizonPalette.surface)
            }
            .horizonScreen()
            .disabled(busy || !model.isAdmin)
            .modifier(DeferNotificationNavigation())
            .navigationTitle(user == nil ? "Create user" : username)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .onAppear { username = user?.username ?? ""; role = user?.role ?? "viewer" }
            .onDisappear { password = "" }
            .onChange(of: model.isAdmin) { _, isAdmin in
                if !isAdmin { password = ""; dismiss() }
            }
            .confirmationDialog("Change this account's role?", isPresented: $confirmRole, titleVisibility: .visible) {
                Button("Update role") { Task { await updateRole() } }
            }
            .confirmationDialog("Reset this account's password?", isPresented: $confirmPassword, titleVisibility: .visible) {
                Button("Reset password", role: .destructive) { Task { await resetPassword() } }
            }
            .confirmationDialog("Delete this account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete user", role: .destructive) { Task { await delete() } }
            }
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard model.isAdmin else { error = "Administrator access is required."; return }
        busy = true; error = nil; message = nil
        defer { busy = false }
        do { try await action(); changed() }
        catch { self.error = error.localizedDescription }
    }

    private func create() async {
        struct Body: Encodable { let username: String; let password: String; let role: String }
        struct Result: Decodable { let username: String }
        await perform {
            let _: Result = try await api.send(["users"], body: Body(username: username, password: password, role: role))
            password = ""
            dismiss()
        }
        password = ""
    }

    private func updateRole() async {
        guard username != model.profile?.username else {
            error = "Use another administrator session to change the currently signed-in account's role."
            return
        }
        await perform {
            try await api.action(["users", username, "role"], method: "PUT", body: ["role": role])
            message = "Role updated. Existing sessions may need to sign in again."
        }
    }

    private func resetPassword() async {
        await perform {
            try await api.action(["users", username, "password"], method: "PUT", body: ["password": password])
            if username == model.profile?.username { await model.refresh() }
            message = "Password updated."
            if let refreshError = model.error {
                error = "Password changed, but session refresh failed: \(refreshError)"
            }
        }
        password = ""
    }

    private func delete() async {
        guard username != "admin", username != model.profile?.username else {
            error = "The built-in admin and the currently signed-in account cannot be deleted here."
            return
        }
        await perform {
            try await api.action(["users", username], method: "DELETE", body: [String: String]())
            dismiss()
        }
    }
}
