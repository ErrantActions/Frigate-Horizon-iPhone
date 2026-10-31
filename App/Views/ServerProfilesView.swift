import SwiftUI
import HorizonCore

struct ServerProfilesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ServerProfileEditorRequest?
    @State private var deletion: ServerProfile?
    @State private var pendingSelection: ServerProfileSelection?
    @State private var confirmSwitch = false
    @State private var confirmUncleanSwitch = false
    @State private var confirmReset = false
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Text("Save primary and local HTTPS addresses. Each profile/address has its own Keychain session; passwords are never saved or automatically sent to another address.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { ErrorNotice(message: error) }
            if let notice = model.profileNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            if let failure = model.profilesError {
                Section {
                    ErrorNotice(message: failure)
                    Button("Reset saved profiles and logins", role: .destructive) { confirmReset = true }
                        .disabled(model.api != nil)
                }
            }
            if let issue = model.connectionIssue {
                ConnectionIssueNotice(issue: issue, detail: model.error)
            } else if let failure = model.error {
                ErrorNotice(message: failure)
            }
            if model.api == nil, model.serverProfiles.selection != nil {
                Button("Back to sign-in", systemImage: "person.crop.circle") { dismiss() }
            }
            ForEach(model.serverProfiles.profiles) { profile in
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profile.primaryAddress.url.absoluteString)
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let local = profile.localAddress {
                            Text("Local: \(local.url.absoluteString)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Use primary address", systemImage: "network") { request(profile, route: .primary) }
                        .disabled(isCurrent(profile, route: .primary))
                    if profile.localAddress != nil {
                        Button("Use local address", systemImage: "wifi") { request(profile, route: .local) }
                            .disabled(isCurrent(profile, route: .local))
                    }
                    Button("Edit profile", systemImage: "pencil") {
                        editor = ServerProfileEditorRequest(profile: profile)
                    }
                    Button("Delete profile", role: .destructive) { deletion = profile }
                        .disabled(model.api != nil && model.serverProfiles.selection?.profileID == profile.id)
                } header: {
                    HStack {
                        Text(profile.name)
                        if model.api != nil, model.serverProfiles.selection?.profileID == profile.id {
                            Text("Connected").foregroundStyle(HorizonPalette.accent)
                        }
                    }
                }
            }
            if model.serverProfiles.profiles.isEmpty && model.profilesError == nil {
                ContentUnavailableView("No saved servers", systemImage: "server.rack",
                    description: Text("Add a profile, or sign into a trusted HTTPS server to save your current connection."))
            }
            if model.profileSwitchCleanupPending, pendingSelection != nil {
                Section {
                    Button("Switch without server push cleanup", role: .destructive) { confirmUncleanSwitch = true }
                    Text("Local notification delivery and images stop. An old server registration may remain until you return to that account to remove it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .horizonScreen()
        .navigationTitle("Server profiles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add server profile", systemImage: "plus") {
                    editor = ServerProfileEditorRequest(profile: nil)
                }
                .disabled(model.profilesError != nil)
            }
        }
        .disabled(model.isConnecting)
        .task { model.prepareServerProfiles() }
        .sheet(item: $editor) { request in ServerProfileEditorView(profile: request.profile) }
        .confirmationDialog("Switch server or address?", isPresented: $confirmSwitch, titleVisibility: .visible) {
            Button("Switch") { usePending(skippingCleanup: false) }
        } message: {
            Text("Live playback and camera controls stop. This installation is unregistered from the old server when necessary. Saved profile logins remain in Keychain; notifications are not enabled on the new server.")
        }
        .confirmationDialog("Switch without server cleanup?", isPresented: $confirmUncleanSwitch, titleVisibility: .visible) {
            Button("Switch without cleanup", role: .destructive) { usePending(skippingCleanup: true) }
        } message: {
            Text("Only use this if the old server cannot be reached. Its registration may remain; return to that account to finish cleanup. This does not enable notifications elsewhere.")
        }
        .confirmationDialog("Delete this saved profile and its logins?", isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            if let deletion {
                Button("Delete \(deletion.name)", role: .destructive) {
                    do { try model.deleteServerProfile(deletion.id); self.deletion = nil }
                    catch { self.error = error.localizedDescription }
                }
            }
        } message: {
            Text("Server data and local camera layouts are not deleted. Deleting the selected offline profile also stops local notification/image access; an old server registration may still need cleanup.")
        }
        .confirmationDialog("Reset all saved profiles and logins?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset profiles and logins", role: .destructive) {
                do { try model.resetServerProfiles(); error = nil }
                catch { self.error = error.localizedDescription }
            }
        } message: { Text("This removes local profile metadata and saved sessions, and stops local notification/image access. Server registrations may still need cleanup. Server data and camera layouts are not deleted.") }
    }

    private func isCurrent(_ profile: ServerProfile, route: ServerConnectionRoute) -> Bool {
        model.api != nil && model.serverProfiles.selection == ServerProfileSelection(profileID: profile.id, route: route)
    }

    private func request(_ profile: ServerProfile, route: ServerConnectionRoute) {
        pendingSelection = ServerProfileSelection(profileID: profile.id, route: route)
        if model.profileSwitchNeedsConfirmation { confirmSwitch = true }
        else { usePending(skippingCleanup: false) }
    }

    private func usePending(skippingCleanup: Bool) {
        guard let selection = pendingSelection else {
            error = "Choose a profile address before switching."
            return
        }
        error = nil
        Task {
            if await model.selectServerProfile(selection, skippingPushCleanup: skippingCleanup) { dismiss() }
        }
    }
}

private struct ServerProfileEditorRequest: Identifiable {
    let id = UUID()
    let profile: ServerProfile?
}

private struct ServerProfileEditorView: View {
    let profile: ServerProfile?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var primary: String
    @State private var local: String
    @State private var error: String?
    @State private var lookupError: String?
    @State private var candidates: [String] = []
    @State private var looking = false
    @State private var lookupID = UUID()
    @State private var lookup: Task<Void, Never>?
    @State private var confirmDiscard = false

    init(profile: ServerProfile?) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _primary = State(initialValue: profile?.primaryAddress.url.absoluteString ?? "")
        _local = State(initialValue: profile?.localAddress?.url.absoluteString ?? "")
    }

    private var active: Bool {
        model.api != nil && profile != nil && model.serverProfiles.selection?.profileID == profile?.id
    }
    private var modified: Bool {
        name != (profile?.name ?? "") || primary != (profile?.primaryAddress.url.absoluteString ?? "")
            || local != (profile?.localAddress?.url.absoluteString ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    TextField("https://dvr.example.com", text: $primary)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(active)
                    if active { Text("Disconnect before editing addresses. Renaming is allowed.").font(.caption) }
                }
                Section {
                    TextField("Optional local IP or HTTPS URL", text: $local)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(active)
                    Text("A bare private IP inherits the primary port and proxy base path. A full HTTPS URL uses its own port/path. You choose Primary or Local explicitly; there is no silent fallback.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Find private IP from hostname", systemImage: "network") { findLocalAddress() }
                        .disabled(active || looking || primary.isEmpty)
                    if looking { ProgressView("Looking up this hostname on your current network") }
                    if let lookupError { ErrorNotice(message: lookupError) }
                    ForEach(candidates, id: \.self) { ip in
                        Button("Use \(ip) as local address") { local = ip }
                            .disabled(active)
                    }
                    Text("Lookup reads DNS only; it does not scan your LAN or read server configuration. A DNS result is not proof of server identity.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Local connection") }
                Section {
                    Text("HTTPS IP connections require a trusted certificate that includes that IP. Otherwise keep a trusted hostname that resolves locally. Self-signed IP certificates and browser exceptions are not bypassed.")
                    Text("Allow Horizon's Local Network permission in iOS Settings. Different addresses require separate sign-ins; cookies are not copied between origins. Server/account camera layouts remain scoped to their existing address.")
                } header: { Text("Trust and privacy") }
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Section { ErrorNotice(message: error) } }
            }
            .horizonScreen()
            .navigationTitle(profile == nil ? "Add server" : "Edit server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if modified { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            let value = try ServerProfile(id: profile?.id ?? UUID(), name: name,
                                primary: primary, local: local)
                            try model.saveServerProfile(value)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || primary.isEmpty || model.isConnecting)
                }
            }
            .interactiveDismissDisabled(modified)
            .confirmationDialog("Discard profile edits?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .onChange(of: primary) { _, _ in cancelLookup(); candidates = [] }
            .onDisappear { cancelLookup() }
        }
    }

    private func cancelLookup() {
        lookup?.cancel()
        lookupID = UUID()
        looking = false
        lookupError = nil
    }

    private func findLocalAddress() {
        cancelLookup()
        let token = lookupID
        looking = true
        candidates = []
        lookup = Task {
            defer { if lookupID == token { looking = false } }
            do {
                let address = try ServerAddress(primary)
                let result = try await LocalServerAddressLookup.resolve(address)
                guard !Task.isCancelled, lookupID == token else { return }
                candidates = result
            } catch {
                if !Task.isCancelled, lookupID == token { lookupError = error.localizedDescription }
            }
        }
    }
}
