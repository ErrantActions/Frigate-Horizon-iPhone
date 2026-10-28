import SwiftUI
import HorizonCore

@MainActor
final class EventSearchStore: ObservableObject {
    @Published private(set) var rows: [SearchEvent] = []
    @Published private(set) var loading = false
    @Published private(set) var hasMore = false
    @Published var error: String?
    private var generation = UUID()
    private var nextOffset = 0

    func load(api: HorizonAPI, query: EventSearchQuery, append: Bool = false) async {
        let token = UUID()
        generation = token
        loading = true
        error = nil
        if !append { rows = []; nextOffset = 0 }
        defer { if generation == token { loading = false } }
        do {
            let page: [SearchEvent] = try await api.get(query.path, query: query.items(offset: nextOffset))
            guard !Task.isCancelled, generation == token else { return }
            if append {
                let existing = Set(rows.map(\.id))
                rows += page.filter { !existing.contains($0.id) }
            } else { rows = page }
            nextOffset += page.count
            hasMore = page.count == query.pageSize
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            self.error = error.localizedDescription
        }
    }
}

struct EventSearchView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @StateObject private var store = EventSearchStore()
    @State private var query = EventSearchQuery(
        after: Date().addingTimeInterval(-86400).timeIntervalSince1970,
        before: Date().timeIntervalSince1970
    )
    @State private var text = ""
    @State private var showFilters = false
    @State private var selected: SearchEvent?
    @State private var refreshID = 0

    var body: some View {
        NavigationStack {
            List {
                if let error = store.error {
                    ErrorNotice(message: error) { refreshID += 1 }
                }
                if query.similarityEventID != nil {
                    Button("Clear similar-event search", systemImage: "xmark.circle") {
                        query.similarityEventID = nil
                    }
                }
                ForEach(store.rows.filter { event in model.cameras.contains { $0.id == event.camera } }) { event in
                    Button { selected = event } label: {
                        HStack(spacing: 12) {
                            ServerImage(api: api, url: api.address.endpoint(["api", "events", event.id, "thumbnail.jpg"]))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.subLabel ?? event.label.capitalized).font(.headline)
                                Text(cameraName(event.camera)).font(.subheadline).foregroundStyle(.secondary)
                                Text(Date(timeIntervalSince1970: event.startTime), format: .dateTime)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if event.retainIndefinitely {
                                Image(systemName: "lock.shield").foregroundStyle(.cyan)
                                    .accessibilityLabel("Permanently protected")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if model.semanticSearchEnabled {
                            Button("Find similar events", systemImage: "sparkle.magnifyingglass") {
                                text = ""
                                query.text = ""
                                query.similarityEventID = event.id
                            }
                        }
                    }
                }
                if store.loading { ProgressView("Searching events") }
                else if store.hasMore {
                    Button("Load more events") { Task { await store.load(api: api, query: query, append: true) } }
                } else if store.rows.isEmpty && store.error == nil {
                    ContentUnavailableView("No matching events", systemImage: "magnifyingglass",
                        description: Text("Try a different camera, label, or time range."))
                }
            }
            .navigationTitle("Search")
            .searchable(text: $text, prompt: model.semanticSearchEnabled ? "Describe an event" : "Semantic search unavailable")
            .onSubmit(of: .search) {
                guard model.semanticSearchEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    store.error = "Semantic search is disabled on this server. Use the event filters instead."
                    return
                }
                query.similarityEventID = nil
                query.text = text
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Event filters", systemImage: "line.3.horizontal.decrease") { showFilters = true }
                }
            }
            .refreshable { refreshID += 1 }
            .task(id: query) { await store.load(api: api, query: query) }
            .task(id: refreshID) {
                guard refreshID > 0 else { return }
                await store.load(api: api, query: query)
            }
            .sheet(isPresented: $showFilters) {
                EventFiltersView(query: query, cameras: model.cameras) { query = $0 }
            }
            .sheet(item: $selected) { event in
                EventDetailView(api: api, initialEvent: event) { refreshID += 1 }
            }
        }
    }

    private func cameraName(_ id: String) -> String { model.cameras.first { $0.id == id }?.name ?? id }
}

private struct EventFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @State var query: EventSearchQuery
    let cameras: [HorizonCamera]
    let apply: (EventSearchQuery) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Picker("Camera", selection: $query.camera) {
                    Text("All allowed cameras").tag("all")
                    ForEach(cameras) { Text($0.name).tag($0.id) }
                }
                TextField("Labels, comma separated", text: $query.label)
                TextField("Zones, comma separated", text: $query.zone)
                TextField("Sub-labels, comma separated", text: $query.subLabel)
                DatePicker("After", selection: Binding(
                    get: { Date(timeIntervalSince1970: query.after) },
                    set: { query.after = $0.timeIntervalSince1970 }
                ), in: ...Date())
                DatePicker("Before", selection: Binding(
                    get: { Date(timeIntervalSince1970: query.before) },
                    set: { query.before = $0.timeIntervalSince1970 }
                ), in: ...Date())
                Toggle("With recordings", isOn: $query.clipsOnly)
                Toggle("With snapshots", isOn: $query.snapshotsOnly)
            }
            .navigationTitle("Event filters")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply(query); dismiss() }.disabled(query.before <= query.after)
                }
            }
        }
    }
}

struct EventDetailView: View {
    let api: HorizonAPI
    let initialEvent: SearchEvent
    let changed: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var event: SearchEvent?
    @State private var error: String?
    @State private var busy = false
    @State private var confirmDelete = false
    @State private var confirmUnprotect = false
    @State private var showExport = false
    @StateObject private var transfer = MediaTransfer()

    private var current: SearchEvent { event ?? initialEvent }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if current.hasClip, let end = current.endTime, end > current.startTime {
                        RecordingPlaybackView(api: api, camera: current.camera, start: current.startTime, end: end)
                            .frame(height: 280)
                    } else {
                        ServerImage(api: api, url: api.address.endpoint([
                            "api", "events", current.id, current.hasSnapshot ? "snapshot.jpg" : "thumbnail.jpg",
                        ]), width: 300, height: 170)
                        if current.endTime == nil { Label("Event ongoing", systemImage: "record.circle") }
                    }
                }
                Section("Event") {
                    LabeledContent("Label", value: current.label)
                    if let subLabel = current.subLabel { LabeledContent("Sub-label", value: subLabel) }
                    LabeledContent("Camera", value: model.cameras.first { $0.id == current.camera }?.name ?? current.camera)
                    LabeledContent("Started", value: Date(timeIntervalSince1970: current.startTime).formatted())
                    LabeledContent("Confidence", value: current.data.topScore.map {
                        $0.formatted(.percent.precision(.fractionLength(1)))
                    } ?? "Not supplied by this event source")
                    if let type = current.data.type { LabeledContent("Source", value: type) }
                    if !current.zones.isEmpty { LabeledContent("Zones", value: current.zones.joined(separator: ", ")) }
                    if let plate = current.data.recognizedLicensePlate { LabeledContent("License plate", value: plate) }
                    if let description = current.data.description { Text(description) }
                }
                Section("Download and share") {
                    if current.hasSnapshot {
                        Button("Snapshot", systemImage: "photo") {
                            transfer.start(api: api, url: api.address.endpoint(["api", "events", current.id, "snapshot.jpg"]),
                                fileExtension: "jpg")
                        }
                    }
                    if current.hasClip && current.endTime != nil {
                        Button("Clip", systemImage: "square.and.arrow.up") {
                            transfer.start(api: api, url: api.address.endpoint(["api", "events", current.id, "clip.mp4"]),
                                fileExtension: "mp4")
                        }
                        Button("Create export", systemImage: "film.stack") { showExport = true }
                    }
                    if transfer.downloading { ProgressView("Downloading media") }
                    if let error = transfer.error { ErrorNotice(message: error) }
                }
                .disabled(transfer.downloading)
                if model.isAdmin {
                    Section("Administrator actions") {
                        if current.retainIndefinitely {
                            Button("Remove permanent protection", role: .destructive) { confirmUnprotect = true }
                        } else {
                            Button("Protect event indefinitely", systemImage: "lock.shield") {
                                Task { await perform {
                                    try await api.action(["events", current.id, "retain"], body: [String: String]())
                                } }
                            }
                        }
                        Button("Delete event", role: .destructive) { confirmDelete = true }
                            .disabled(current.retainIndefinitely)
                    }
                    .disabled(busy)
                }
                if busy { ProgressView("Updating event") }
                if let error { ErrorNotice(message: error) }
            }
            .navigationTitle("Event details")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await reload() }
            .onDisappear { transfer.cancel() }
            .sheet(item: $transfer.file, onDismiss: transfer.dismissShare) { NativeShareSheet(file: $0.url) }
            .sheet(isPresented: $showExport) {
                CreateExportView(api: api, initialCamera: current.camera,
                    initialStart: Date(timeIntervalSince1970: current.startTime),
                    initialEnd: Date(timeIntervalSince1970: current.endTime ?? current.startTime)) {}
            }
            .confirmationDialog("Delete this event and its associated event media?", isPresented: $confirmDelete,
                titleVisibility: .visible) {
                Button("Delete event", role: .destructive) {
                    Task { await perform(delete: true) {
                        try await api.action(["events", current.id], method: "DELETE", body: [String: String]())
                    } }
                }
            }
            .confirmationDialog(
                "Remove permanent protection? Normal retention, quota eviction, and lossy compression may become eligible. This does not immediately delete media.",
                isPresented: $confirmUnprotect, titleVisibility: .visible
            ) {
                Button("Remove protection", role: .destructive) {
                    Task { await perform {
                        try await api.action(["events", current.id, "retain"], method: "DELETE",
                            body: ["confirm": true, "acknowledge_retention": true])
                    } }
                }
            }
        }
    }

    private func reload() async {
        do { event = try await api.get(["events", initialEvent.id]) }
        catch { self.error = error.localizedDescription }
    }

    private func perform(delete: Bool = false, action: () async throws -> Void) async {
        guard model.isAdmin else { error = "Administrator access is required."; return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await action()
            changed()
            if delete { dismiss() } else { await reload() }
        } catch { self.error = error.localizedDescription }
    }
}
