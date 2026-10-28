import SwiftUI
import HorizonCore

@MainActor
final class RecordingsStore: ObservableObject {
    @Published private(set) var windows: [RecordingWindow] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var generation = UUID()

    func load(api: HorizonAPI, camera: String, day: Date) async {
        let token = UUID()
        generation = token
        windows = []
        loading = true
        error = nil
        defer { if generation == token { loading = false } }
        guard !camera.isEmpty else { return }
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        let before = min(end.timeIntervalSince1970, Date().timeIntervalSince1970)
        do {
            let segments: [RecordingSegment] = try await api.get([camera, "recordings"], query: [
                URLQueryItem(name: "after", value: String(start.timeIntervalSince1970)),
                URLQueryItem(name: "before", value: String(before)),
            ])
            guard !Task.isCancelled, generation == token else { return }
            windows = RecordingWindow.available(segments, after: start.timeIntervalSince1970, before: before)
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            self.error = error.localizedDescription
        }
    }
}

struct RecordingsView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @StateObject private var store = RecordingsStore()
    @State private var camera = ""
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var selectedID: String?
    @State private var showBookmarks = false

    private var selected: RecordingWindow? { store.windows.first { $0.id == selectedID } }
    private var queryID: String { "\(camera)-\(day.timeIntervalSince1970)" }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                Section("Browse recordings") {
                    Picker("Camera", selection: $camera) {
                        if camera.isEmpty { Text("Choose a camera").tag("") }
                        ForEach(model.cameras) { Text($0.name).tag($0.id) }
                    }
                    DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                }
                if let error = store.error {
                    Section { ErrorNotice(message: error) { Task { await reload() } } }
                }
                Section {
                    if store.loading {
                        ProgressView("Checking available recordings")
                    } else if store.windows.isEmpty && store.error == nil {
                        Text(camera.isEmpty ? "Choose a camera." : "No recordings available for this day.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.windows) { window in
                        NavigationLink(value: window.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: "play.circle")
                                    Text(Date(timeIntervalSince1970: window.start), style: .time)
                                    Text("-")
                                    Text(Date(timeIntervalSince1970: window.end), style: .time)
                                }
                                Text(Duration.seconds(window.end - window.start).formatted(.time(pattern: .hourMinuteSecond)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Available footage")
                } footer: {
                    Text("Separate ranges indicate recording gaps. Playback uses original server recordings; missing footage is never filled or implied.")
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Bookmarks", systemImage: "bookmark") { showBookmarks = true }.disabled(camera.isEmpty)
                }
            }
            .refreshable { await reload() }
        } detail: {
            if let selected {
                RecordingPlaybackView(api: api, camera: camera, start: selected.start, end: selected.end)
                    .navigationTitle(model.cameras.first { $0.id == camera }?.name ?? camera)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Choose a recording", systemImage: "clock.arrow.circlepath",
                    description: Text("Select a camera, day, and available time range."))
            }
        }
        .onAppear { if camera.isEmpty { camera = model.cameras.first?.id ?? "" } }
        .onChange(of: queryID) { _, _ in selectedID = nil }
        .task(id: queryID) { await reload() }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(api: api, camera: camera, initialTimestamp: selected?.start ?? day.timeIntervalSince1970)
        }
    }

    private func reload() async { await store.load(api: api, camera: camera, day: day) }
}
