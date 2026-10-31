import SwiftUI
import HorizonCore

struct SavedCameraGroupsView: View {
    let cameras: [HorizonCamera]
    let initialPreferences: CameraDashboardPreferences
    let onSave: (CameraDashboardPreferences) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CameraDashboardPreferences
    @State private var editor: GroupEditorRequest?
    @State private var pendingDeletion: SavedCameraGroup?
    @State private var showDiscard = false
    @State private var error: String?

    init(cameras: [HorizonCamera], preferences: CameraDashboardPreferences,
         onSave: @escaping (CameraDashboardPreferences) throws -> Void) {
        self.cameras = cameras
        initialPreferences = preferences
        self.onSave = onSave
        _draft = State(initialValue: preferences)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HorizonHero(title: "Your camera workspaces",
                        subtitle: "Save the order and layout for entrances, outside views or overnight checks.",
                        systemImage: "square.grid.3x2", eyebrow: "Camera groups")
                        .horizonHeroRow()
                }
                if let error { Section { ErrorNotice(message: error) } }
                Section {
                    Button("All dashboard cameras") { select(nil) }
                    ForEach(draft.groups) { group in
                        Button { editor = GroupEditorRequest(group: group) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(group.name).font(.headline)
                                    Text("\(availableCount(group)) available - \(group.density.label)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if draft.selectedGroupID == group.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(HorizonPalette.accent)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDeletion = group }
                            Button("Use") { select(group.id) }.tint(HorizonPalette.accent)
                        }
                    }
                    Button("Create camera group", systemImage: "plus") {
                        editor = GroupEditorRequest(group: nil)
                    }
                    .disabled(!cameras.contains(where: \.isLiveDashboardCamera))
                } header: {
                    Text("Saved on this device for this account")
                } footer: {
                    Text("Groups never change server configuration or camera permissions. Unavailable saved cameras are retained but never shown or played. A group's own order takes precedence over favorites-first ordering.")
                }
            }
            .horizonScreen()
            .navigationTitle("Camera groups")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if draft == initialPreferences { dismiss() }
                        else { showDiscard = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try onSave(draft); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            .interactiveDismissDisabled(draft != initialPreferences)
            .confirmationDialog("Discard group changes?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .confirmationDialog("Delete this saved group?",
                isPresented: Binding(get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }),
                titleVisibility: .visible, presenting: pendingDeletion) { group in
                Button("Delete \(group.name)", role: .destructive) {
                    do { try draft.removeGroup(group.id); pendingDeletion = nil }
                    catch { self.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
            } message: { _ in
                Text("Only this local layout is removed. No camera, recording or favorite is deleted.")
            }
            .sheet(item: $editor) { request in
                CameraGroupEditorView(cameras: cameras, group: request.group, defaultDensity: draft.density) { group in
                    try draft.saveGroup(group)
                }
            }
        }
    }

    private func select(_ id: UUID?) {
        do { try draft.selectGroup(id) }
        catch { self.error = error.localizedDescription }
    }

    private func availableCount(_ group: SavedCameraGroup) -> Int {
        let allowed = Set(cameras.filter(\.isLiveDashboardCamera).map(\.id))
        return group.cameraIDs.filter { allowed.contains($0) }.count
    }
}

private struct GroupEditorRequest: Identifiable {
    let id = UUID()
    let group: SavedCameraGroup?
}

private struct CameraGroupEditorView: View {
    let cameras: [HorizonCamera]
    let original: SavedCameraGroup?
    let onSave: (SavedCameraGroup) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var cameraIDs: [String]
    @State private var density: CameraDashboardPreferences.Density
    @State private var error: String?
    @State private var showDiscard = false
    private let initialDensity: CameraDashboardPreferences.Density

    init(cameras: [HorizonCamera], group: SavedCameraGroup?,
         defaultDensity: CameraDashboardPreferences.Density,
         onSave: @escaping (SavedCameraGroup) throws -> Void) {
        self.cameras = cameras
        original = group
        self.onSave = onSave
        initialDensity = group?.density ?? defaultDensity
        _name = State(initialValue: group?.name ?? "")
        _cameraIDs = State(initialValue: group?.cameraIDs ?? [])
        _density = State(initialValue: group?.density ?? defaultDensity)
    }

    private var available: [HorizonCamera] { cameras.filter(\.isLiveDashboardCamera) }
    private var selected: [HorizonCamera] {
        cameraIDs.compactMap { id in available.first { $0.id == id } }
    }
    private var modified: Bool {
        name != (original?.name ?? "") || cameraIDs != (original?.cameraIDs ?? []) || density != initialDensity
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { ErrorNotice(message: error) } }
                Section("Group") {
                    TextField("Name", text: $name)
                    Picker("Layout", selection: $density) {
                        ForEach(CameraDashboardPreferences.Density.allCases) { value in
                            Text(value.label).tag(value)
                        }
                    }
                }
                Section {
                    ForEach(selected) { camera in Text(camera.name) }
                        .onMove { offsets, destination in
                            var ordered = selected.map(\.id)
                            ordered.move(fromOffsets: offsets, toOffset: destination)
                            let allowed = Set(available.map(\.id))
                            cameraIDs = ordered + cameraIDs.filter { !allowed.contains($0) }
                        }
                } header: {
                    Text("Playback order")
                } footer: {
                    Text("Use Edit to reorder selected cameras. This order also applies to Camera Tour.")
                }
                Section {
                    ForEach(available) { camera in
                        Toggle(camera.name, isOn: Binding(
                            get: { cameraIDs.contains(camera.id) },
                            set: { enabled in
                                if enabled && !cameraIDs.contains(camera.id) { cameraIDs.append(camera.id) }
                                else if !enabled { cameraIDs.removeAll { $0 == camera.id } }
                            }
                        ))
                    }
                    if cameraIDs.count > selected.count {
                        Text("\(cameraIDs.count - selected.count) unavailable saved cameras are retained without granting access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: { Text("Cameras") }
            }
            .horizonScreen()
            .navigationTitle(original == nil ? "New camera group" : "Edit camera group")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if modified { showDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            let group = try SavedCameraGroup(id: original?.id ?? UUID(), name: name,
                                cameraIDs: cameraIDs, density: density)
                            try onSave(group)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || cameraIDs.isEmpty)
                }
            }
            .interactiveDismissDisabled(modified)
            .confirmationDialog("Discard these edits?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
    }
}
