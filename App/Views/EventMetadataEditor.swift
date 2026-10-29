import SwiftUI
import HorizonCore

struct EventMetadataEditor: View {
    let api: HorizonAPI
    let changed: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: EventMetadataSnapshot
    @State private var subLabel: String
    @State private var descriptionText: String
    @State private var ready = false
    @State private var busy = false
    @State private var operation = "Loading current metadata"
    @State private var pending: [EventMetadataField: String] = [:]
    @State private var message: String?
    @State private var error: String?
    @State private var confirmClose = false

    init(api: HorizonAPI, event: SearchEvent, changed: @escaping () -> Void) {
        self.api = api
        self.changed = changed
        let snapshot = EventMetadataSnapshot(event)
        _snapshot = State(initialValue: snapshot)
        _subLabel = State(initialValue: snapshot.subLabel)
        _descriptionText = State(initialValue: snapshot.description)
    }

    private var canEdit: Bool {
        model.isAdmin && model.cameras.contains { $0.id == snapshot.camera }
    }
    private var normalizedSubLabel: String { subLabel.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var unsavedLabel: Bool { pending[.subLabel] == nil && normalizedSubLabel != snapshot.subLabel }
    private var unsavedDescription: Bool { pending[.description] == nil && descriptionText != snapshot.description }
    private var needsCloseConfirmation: Bool { unsavedLabel || unsavedDescription || !pending.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HorizonHero(title: "Refine this event",
                        subtitle: "Edit its display label and description without changing the original detection.",
                        systemImage: "square.and.pencil", eyebrow: "Event metadata")
                        .horizonHeroRow()
                }
                if !canEdit {
                    ErrorNotice(message: "Administrator access and permission for this camera are required.")
                }
                labelSection
                descriptionSection
                if busy { ProgressView(operation) }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                if let error { ErrorNotice(message: error) }
                if !pending.isEmpty {
                    Section {
                        HorizonStatusPill(title: "Awaiting server confirmation",
                            systemImage: "clock", tint: HorizonPalette.warm)
                        Button("Check update status", systemImage: "arrow.clockwise") {
                            Task { await checkPending() }
                        }
                        .buttonStyle(HorizonButtonStyle(.secondary))
                        .disabled(busy || !canEdit)
                        Text("An accepted update may still finish if you close this editor. Checking status does not submit it again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .listRowBackground(HorizonPalette.surface)
                }
                if !ready && !busy {
                    Button("Load current metadata", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                    .buttonStyle(HorizonButtonStyle(.secondary))
                    .disabled(!canEdit)
                }
                Section {
                    Text("Each field saves separately. The app checks for changes before saving, but the server does not provide an atomic revision check for these fields. Simultaneous edits can still race.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    HorizonSectionHeader(title: "Shared event metadata", systemImage: "person.2")
                }
                .listRowBackground(HorizonPalette.surface)
            }
            .horizonScreen()
            .navigationTitle("Edit event")
            .modifier(DeferNotificationNavigation())
            .interactiveDismissDisabled(busy || needsCloseConfirmation)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if needsCloseConfirmation { confirmClose = true }
                        else { dismiss() }
                    }
                    .disabled(busy)
                }
            }
            .task { await load() }
            .confirmationDialog("Close the metadata editor?", isPresented: $confirmClose,
                titleVisibility: .visible) {
                Button("Close editor", role: .destructive) {
                    if !pending.isEmpty { changed() }
                    dismiss()
                }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text(pending.isEmpty
                    ? "Unsaved edits will be discarded. Saved fields are not reverted."
                    : "Accepted server updates may still finish. Other unsaved edits will be discarded; closing does not cancel accepted updates.")
            }
        }
    }

    private var labelSection: some View {
        Section {
            TextField("Optional sub-label", text: $subLabel)
                .textInputAutocapitalization(.words)
                .disabled(busy || !ready || !canEdit || pending[.subLabel] != nil)
            Text("\(normalizedSubLabel.unicodeScalars.count)/100 characters")
                .font(.caption).foregroundStyle(.secondary)
            Button("Save sub-label", systemImage: "checkmark") { Task { await save(.subLabel) } }
                .buttonStyle(HorizonButtonStyle())
                .disabled(busy || !ready || !canEdit || !unsavedLabel
                    || normalizedSubLabel.unicodeScalars.count > 100)
        } header: {
            HorizonSectionHeader(title: "Display sub-label", systemImage: "tag")
        } footer: {
            Text("Leave blank to remove the sub-label. The original object label stays unchanged. Manual sub-labels do not assert a recognition confidence.")
        }
        .listRowBackground(HorizonPalette.surface)
    }

    private var descriptionSection: some View {
        Section {
            TextEditor(text: $descriptionText)
                .frame(minHeight: 160)
                .accessibilityLabel("Event description")
                .disabled(busy || !ready || !canEdit || pending[.description] != nil)
            Button("Save description", systemImage: "checkmark") { Task { await save(.description) } }
                .buttonStyle(HorizonButtonStyle())
                .disabled(busy || !ready || !canEdit || !unsavedDescription)
        } header: {
            HorizonSectionHeader(title: "Description", systemImage: "text.alignleft")
        } footer: {
            Text("Leave blank to clear the description. Formatting is preserved. The server manages any semantic-search index updates.")
        }
        .listRowBackground(HorizonPalette.surface)
    }

    private func requirePermission() throws {
        guard canEdit else {
            throw HorizonError.message("Administrator access and permission for this camera are required.")
        }
    }

    private func load() async {
        guard !busy, !ready else { return }
        busy = true; error = nil; operation = "Loading current metadata"
        defer { busy = false }
        do {
            try requirePermission()
            let latest: SearchEvent = try await api.get(["events", snapshot.eventID])
            try Task.checkCancellation()
            try snapshot.requireSameEvent(latest)
            snapshot = EventMetadataSnapshot(latest)
            subLabel = snapshot.subLabel
            descriptionText = snapshot.description
            ready = true
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func save(_ field: EventMetadataField) async {
        guard !busy, ready, pending[field] == nil else { return }
        busy = true; error = nil; message = nil
        operation = "Saving \(field.title.lowercased())"
        defer { busy = false }
        do {
            try requirePermission()
            let latest: SearchEvent = try await api.get(["events", snapshot.eventID])
            try Task.checkCancellation()
            try requirePermission()
            try snapshot.requireUnchanged(latest, field: field)
            let value: String
            switch field {
            case .subLabel:
                let body = try EventSubLabelUpdate(subLabel)
                value = body.subLabel
                try await api.action(["events", snapshot.eventID, field.endpoint], body: body)
            case .description:
                value = descriptionText
                try await api.action(["events", snapshot.eventID, field.endpoint],
                    body: EventDescriptionUpdate(value))
            }
            pending[field] = value
            if try await confirm(field) {
                message = "\(field.title) saved."
            } else {
                error = "The server accepted the \(field.title.lowercased()) update, but it has not appeared yet. Check its status before retrying."
            }
        } catch {
            let prefix = pending[field] == nil ? "" : "Update accepted, but confirmation failed. "
            self.error = prefix + error.localizedDescription
        }
    }

    private func confirm(_ field: EventMetadataField) async throws -> Bool {
        guard let expected = pending[field] else { return true }
        for attempt in 0..<(field == .subLabel ? 8 : 1) {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(300)) }
            try requirePermission()
            let latest: SearchEvent = try await api.get(["events", snapshot.eventID])
            try Task.checkCancellation()
            try snapshot.requireSameEvent(latest)
            if EventMetadataSnapshot(latest).value(for: field) == expected {
                try snapshot.confirm(latest, field: field)
                pending.removeValue(forKey: field)
                switch field {
                case .subLabel: subLabel = snapshot.subLabel
                case .description: descriptionText = snapshot.description
                }
                changed()
                return true
            }
        }
        return false
    }

    private func checkPending() async {
        guard !busy else { return }
        busy = true; error = nil; message = nil; operation = "Checking accepted updates"
        defer { busy = false }
        do {
            for field in EventMetadataField.allCases where pending[field] != nil {
                _ = try await confirm(field)
            }
            if pending.isEmpty { message = "Accepted updates are confirmed on the server." }
            else { error = "Some accepted updates are still unconfirmed. No update was submitted again." }
        } catch { self.error = "Could not confirm the accepted updates: \(error.localizedDescription)" }
    }
}
