import SwiftUI
import HorizonCore

struct ReviewQuery: Hashable {
    var camera = "all"
    var severity = ""
    var day = Calendar.current.startOfDay(for: Date())
    var limit = 100

    var items: [URLQueryItem] {
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        var items = [
            URLQueryItem(name: "cameras", value: camera),
            URLQueryItem(name: "after", value: String(day.timeIntervalSince1970)),
            URLQueryItem(name: "before", value: String(nextDay.timeIntervalSince1970)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if !severity.isEmpty { items.append(URLQueryItem(name: "severity", value: severity)) }
        return items
    }
}

@MainActor
final class ReviewStore: ObservableObject {
    @Published private(set) var rows: [ReviewSegment] = []
    @Published private(set) var loading = false
    @Published private(set) var updating: Set<String> = []
    @Published var error: String?
    private var generation = UUID()

    func load(api: HorizonAPI, query: ReviewQuery) async {
        let token = UUID()
        generation = token
        loading = true
        error = nil
        defer { if generation == token { loading = false } }
        do {
            let rows: [ReviewSegment] = try await api.get(["review"], query: query.items)
            guard !Task.isCancelled, generation == token else { return }
            self.rows = rows
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            self.rows = []
            self.error = error.localizedDescription
        }
    }

    func toggleReviewed(_ row: ReviewSegment, api: HorizonAPI) async {
        guard !updating.contains(row.id) else { return }
        updating.insert(row.id)
        defer { updating.remove(row.id) }
        do {
            try await api.markReviewed(row.id, reviewed: !row.hasBeenReviewed)
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index].hasBeenReviewed = !row.hasBeenReviewed
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ReviewView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @StateObject private var store = ReviewStore()
    @State private var query = ReviewQuery()
    @State private var selectedID: String?

    private var selected: ReviewSegment? { store.rows.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("Filter") {
                    DatePicker("Day", selection: $query.day, in: ...Date(), displayedComponents: .date)
                    Picker("Camera", selection: $query.camera) {
                        Text("All cameras").tag("all")
                        ForEach(model.cameras) { Text($0.name).tag($0.id) }
                    }
                    Picker("Activity", selection: $query.severity) {
                        Text("All activity").tag("")
                        Text("Alerts").tag("alert")
                        Text("Detections").tag("detection")
                    }
                }
                if let error = store.error {
                    Section { ErrorNotice(message: error) { Task { await reload() } } }
                }
                Section {
                    ForEach(store.rows) { row in
                        NavigationLink(value: row.id) {
                            ReviewRow(api: api, row: row, cameraName: cameraName(row.camera))
                        }
                        .swipeActions {
                            Button(row.hasBeenReviewed ? "Unreview" : "Reviewed",
                                   systemImage: row.hasBeenReviewed ? "circle" : "checkmark.circle") {
                                Task { await store.toggleReviewed(row, api: api) }
                            }
                            .tint(.cyan)
                            .disabled(store.updating.contains(row.id))
                        }
                    }
                    if store.rows.count >= query.limit {
                        Button("Load more activity") { query.limit += 100 }
                            .disabled(store.loading)
                    }
                } header: {
                    HStack {
                        Text("Activity")
                        Spacer()
                        if store.loading { ProgressView() }
                    }
                } footer: {
                    Text("Camera-native alarms do not provide confidence scores. Activity categories come from your server.")
                }
            }
            .overlay {
                if !store.loading && store.error == nil && store.rows.isEmpty {
                    VStack {
                        Spacer()
                        ContentUnavailableView("No activity", systemImage: "checkmark.shield",
                            description: Text("Try another day or camera."))
                            .frame(maxHeight: 220)
                    }
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("Review")
            .refreshable { await reload() }
        } detail: {
            if let selected {
                VStack(spacing: 16) {
                    Text(selected.title).font(.title2.bold())
                    Text(cameraName(selected.camera)).foregroundStyle(.secondary)
                    Button("Open review timeline", systemImage: "timeline.selection") { workspace = selected }
                        .buttonStyle(.borderedProminent)
                }
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button(
                                selected.hasBeenReviewed ? "Mark unreviewed" : "Mark reviewed",
                                systemImage: selected.hasBeenReviewed ? "circle" : "checkmark.circle"
                            ) {
                                Task { await store.toggleReviewed(selected, api: api) }
                            }
                            .disabled(store.updating.contains(selected.id))
                        }
                        ToolbarItem(placement: .secondaryAction) {
                            Button("Timeline workspace", systemImage: "timeline.selection") { workspace = selected }
                        }
                    }
            } else {
                ContentUnavailableView("Select activity", systemImage: "rectangle.stack",
                    description: Text("Choose an alert or detection to watch its recording."))
            }
        }
        .task(id: query) { await reload() }
        .onChange(of: query) { _, _ in selectedID = nil }
        .onChange(of: selectedID) { _, _ in
            if let selected { workspace = selected }
        }
        .fullScreenCover(item: $workspace) { row in
            ReviewWorkspaceView(api: api, initialReview: row,
                cameras: model.cameras, day: query.day)
        }
    }

    @State private var workspace: ReviewSegment?
    private func reload() async { await store.load(api: api, query: query) }
    private func cameraName(_ id: String) -> String { model.cameras.first { $0.id == id }?.name ?? id }
}

private struct ReviewRow: View {
    let api: HorizonAPI
    let row: ReviewSegment
    let cameraName: String

    var body: some View {
        HStack(spacing: 12) {
            ServerImage(api: api, path: row.thumbPath)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.headline)
                Text(cameraName).font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Text(Date(timeIntervalSince1970: row.startTime), style: .time)
                    if row.endTime == nil { Text("Ongoing") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: row.hasBeenReviewed ? "checkmark.circle" : "circle.fill")
                .foregroundStyle(row.severity == "alert" ? .orange : .cyan)
                .font(.caption)
                .accessibilityLabel(row.hasBeenReviewed ? "Reviewed" : "Not reviewed")
        }
        .padding(.vertical, 4)
    }
}
