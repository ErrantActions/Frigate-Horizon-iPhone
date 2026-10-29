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
                Section {
                    HorizonHero(title: "Your activity, in focus",
                        subtitle: "Move from an alert to the moments that matter.",
                        systemImage: "rectangle.stack", eyebrow: "Review")
                        .horizonHeroRow()
                }
                Section {
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
                } header: {
                    HorizonSectionHeader(title: "Activity filters", systemImage: "line.3.horizontal.decrease")
                }
                .listRowBackground(HorizonPalette.surface)
                if let error = store.error {
                    Section { ErrorNotice(message: error) { Task { await reload() } } }
                        .listRowBackground(HorizonPalette.surface)
                }
                Section {
                    if store.rows.isEmpty {
                        if store.loading {
                            ProgressView("Loading activity").padding(.vertical, 16)
                        } else if store.error == nil {
                            ContentUnavailableView("A quiet view", systemImage: "checkmark.shield",
                                description: Text("No activity matches this day and camera. Try another filter."))
                        }
                    }
                    ForEach(store.rows) { row in
                        NavigationLink(value: row.id) {
                            ReviewRow(api: api, row: row, cameraName: cameraName(row.camera))
                        }
                        .swipeActions {
                            Button(row.hasBeenReviewed ? "Unreview" : "Reviewed",
                                   systemImage: row.hasBeenReviewed ? "circle" : "checkmark.circle") {
                                Task { await store.toggleReviewed(row, api: api) }
                            }
                            .tint(HorizonPalette.accent)
                            .disabled(store.updating.contains(row.id))
                        }
                    }
                    if store.rows.count >= query.limit {
                        Button("Load more activity") { query.limit += 100 }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                            .disabled(store.loading)
                    }
                } header: {
                    HStack {
                        HorizonSectionHeader(title: "Activity",
                            subtitle: "\(store.rows.count) loaded", systemImage: "timeline.selection")
                        Spacer()
                        if store.loading { ProgressView() }
                    }
                } footer: {
                    Text("Camera-native alarms do not provide confidence scores. Activity categories come from your server.")
                }
                .listRowBackground(HorizonPalette.surface)
            }
            .horizonScreen()
            .navigationTitle("Review")
            .refreshable { await reload() }
        } detail: {
            if let selected {
                ScrollView {
                    HorizonCard {
                        HorizonHero(title: selected.title, subtitle: cameraName(selected.camera),
                            systemImage: "timeline.selection", eyebrow: "Activity")
                        HorizonStatusPill(title: selected.hasBeenReviewed ? "Reviewed" : "Not reviewed",
                            systemImage: selected.hasBeenReviewed ? "checkmark.circle" : "circle")
                        Button("Open review timeline", systemImage: "timeline.selection") { workspace = selected }
                            .buttonStyle(HorizonButtonStyle(.primary))
                    }
                    .padding(20)
                }
                .horizonScreen()
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
                    .horizonScreen()
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
        HStack(alignment: .top, spacing: 12) {
            ServerImage(api: api, path: row.thumbPath)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(row.title).font(.system(.headline, design: .rounded))
                Text(cameraName).font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(Date(timeIntervalSince1970: row.startTime), style: .time)
                    if row.endTime == nil { Text("Ongoing") }
                }
                .font(.caption).foregroundStyle(.secondary)
                HorizonStatusPill(title: row.hasBeenReviewed ? "Reviewed" : "Not reviewed",
                    systemImage: row.hasBeenReviewed ? "checkmark.circle" : "circle",
                    tint: row.severity == "alert" ? HorizonPalette.warm : HorizonPalette.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}
