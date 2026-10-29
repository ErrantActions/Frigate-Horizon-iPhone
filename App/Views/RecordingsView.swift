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
                Section {
                    HorizonHero(title: "Revisit the whole story",
                        subtitle: "Browse original footage by camera and day.",
                        systemImage: "clock.arrow.circlepath", eyebrow: "Recordings")
                        .horizonHeroRow()
                }
                Section {
                    Picker("Camera", selection: $camera) {
                        if camera.isEmpty { Text("Choose a camera").tag("") }
                        ForEach(model.cameras) { Text($0.name).tag($0.id) }
                    }
                    DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                } header: {
                    HorizonSectionHeader(title: "Browse footage", systemImage: "calendar")
                }
                .listRowBackground(HorizonPalette.surface)
                if let error = store.error {
                    Section { ErrorNotice(message: error) { Task { await reload() } } }
                        .listRowBackground(HorizonPalette.surface)
                }
                Section {
                    if store.loading {
                        ProgressView("Checking available recordings").padding(.vertical, 16)
                    } else if store.windows.isEmpty && store.error == nil {
                        ContentUnavailableView(camera.isEmpty ? "Choose a camera" : "No footage for this day",
                            systemImage: "video.slash",
                            description: Text(camera.isEmpty
                                ? "Select a camera above to explore its recordings."
                                : "Try another day or camera. Only indexed recording ranges appear here."))
                    }
                    ForEach(store.windows) { window in
                        NavigationLink(value: window.id) {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "play.fill")
                                    .foregroundStyle(HorizonPalette.accent)
                                    .frame(width: 44, height: 44)
                                    .background(HorizonPalette.accent.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 14))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Recording range").font(.system(.headline, design: .rounded))
                                    timeRange(window)
                                    Text(Duration.seconds(window.end - window.start).formatted(.time(pattern: .hourMinuteSecond)))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                } header: {
                    HorizonSectionHeader(title: "Available footage",
                        subtitle: "\(store.windows.count) indexed ranges", systemImage: "film")
                } footer: {
                    Text("Separate ranges indicate recording gaps. Playback uses original server recordings; missing footage is never filled or implied.")
                }
                .listRowBackground(HorizonPalette.surface)
            }
            .horizonScreen()
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
                    .horizonScreen()
            }
        }
        .onAppear { if camera.isEmpty { camera = model.cameras.first?.id ?? "" } }
        .onChange(of: queryID) { _, _ in selectedID = nil }
        .task(id: queryID) { await reload() }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(api: api, camera: camera, initialTimestamp: selected?.start ?? day.timeIntervalSince1970)
        }
    }

    private func timeRange(_ window: RecordingWindow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                Text(Date(timeIntervalSince1970: window.start), style: .time)
                Text("–")
                Text(Date(timeIntervalSince1970: window.end), style: .time)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(Date(timeIntervalSince1970: window.start), style: .time)
                Text(Date(timeIntervalSince1970: window.end), style: .time)
            }
        }
        .font(.subheadline.monospacedDigit())
    }

    private func reload() async { await store.load(api: api, camera: camera, day: day) }
}
