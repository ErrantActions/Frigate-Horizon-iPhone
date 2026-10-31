import SwiftUI
import HorizonCore

struct LiveCameraOrderView: View {
    let initialPreferences: CameraDashboardPreferences
    let onSave: (CameraDashboardPreferences) throws -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var order: [String]
    @State private var showDiscard = false
    @State private var error: String?
    private let initialOrder: [String]

    init(cameras: [HorizonCamera], preferences: CameraDashboardPreferences,
         onSave: @escaping (CameraDashboardPreferences) throws -> Void) {
        initialPreferences = preferences
        self.onSave = onSave
        let ids = preferences.cameras(from: cameras).map(\.id)
        initialOrder = ids
        _order = State(initialValue: ids)
    }

    private var available: [HorizonCamera] { initialPreferences.cameras(from: model.cameras) }
    private var rows: [HorizonCamera] { order.compactMap { id in available.first { $0.id == id } } }
    private var modified: Bool { order != initialOrder }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { camera in
                        HStack {
                            Label(camera.name, systemImage: "video")
                            Spacer()
                            if initialPreferences.favoriteIDs.contains(camera.id) {
                                Image(systemName: "star.fill").foregroundStyle(HorizonPalette.accent)
                                    .accessibilityLabel("Favorite")
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .onMove { offsets, destination in
                        var ids = rows.map(\.id)
                        ids.move(fromOffsets: offsets, toOffset: destination)
                        order = ids
                    }
                    if rows.isEmpty { Text("No enabled dashboard cameras are available.") }
                } header: {
                    Text(initialPreferences.selectedGroup?.name ?? "All dashboard cameras")
                } footer: {
                    Text("Drag the handles to change Live and Camera Tour order. Disabled, hidden and unavailable cameras are never shown. Their saved positions are retained if they return.")
                }
                Section {
                    Button("Use server order") {
                        let visible = Set(rows.map(\.id))
                        order = model.cameras.filter { visible.contains($0.id) }.map(\.id)
                    }
                    Text(initialPreferences.favoritesOnly
                        ? "Only favorites in this view are being reordered; other saved positions stay unchanged."
                        : "A custom order takes precedence over favorites-first sorting.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Saved only on this iPhone for this server/account. No server, camera or recording setting changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { ErrorNotice(message: error) } }
            }
            .environment(\.editMode, .constant(.active))
            .horizonScreen()
            .navigationTitle("Reorder cameras")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if modified { showDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            var next = initialPreferences
                            try next.setCurrentCameraOrder(rows.map(\.id), available: model.cameras)
                            try onSave(next)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(rows.count < 2)
                }
            }
            .interactiveDismissDisabled(modified)
            .confirmationDialog("Discard camera order changes?", isPresented: $showDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .onChange(of: available.map(\.id)) { _, ids in
                let allowed = Set(ids)
                order = order.filter { allowed.contains($0) } + ids.filter { !order.contains($0) }
            }
        }
    }
}
