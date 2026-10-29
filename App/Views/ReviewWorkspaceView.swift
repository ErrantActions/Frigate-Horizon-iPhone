import SwiftUI
import AVFoundation
import HorizonCore

@MainActor
final class ReviewPlaybackStore: ObservableObject {
    let playback = RecordingPlayer()
    @Published private(set) var coverage: RecordingCoverage?
    @Published private(set) var range: ReviewTimeRange?
    @Published private(set) var motion: [MotionSample] = []
    @Published private(set) var events: [ReviewSegment] = []
    @Published private(set) var timeline = PlaybackTimeline(spans: [])
    @Published private(set) var loading = false
    @Published private(set) var missingRecording = false
    @Published private(set) var intendsToPlay = true
    @Published var error: String?
    @Published private(set) var metadataErrors: [String] = []
    var metadataError: String? { metadataErrors.isEmpty ? nil : metadataErrors.joined(separator: "\n") }
    private var generation = UUID()
    private var clipGeneration = UUID()
    private var loadedCamera: String?

    func prepare(api: HorizonAPI, camera: String, day: Date, timestamp: Double, autoplay: Bool = true) async {
        let token = UUID()
        generation = token
        intendsToPlay = autoplay
        clipGeneration = UUID()
        playback.stop()
        loading = true
        timeline = PlaybackTimeline(spans: [])
        error = nil
        missingRecording = false
        loadedCamera = nil
        coverage = nil
        motion = []
        events = []
        metadataErrors = []
        let range: ReviewTimeRange
        do {
            if let existing = self.range { range = existing }
            else { range = try ReviewTimeRange(day: day) }
            self.range = range
        } catch {
            self.error = error.localizedDescription
            loading = false
            return
        }
        let query = [
            URLQueryItem(name: "after", value: String(range.start)),
            URLQueryItem(name: "before", value: String(range.end)),
        ]
        do {
            let result: RecordingCoverage = try await api.get([camera, "recordings", "coverage"], query: query)
            guard !Task.isCancelled, generation == token else { return }
            coverage = result
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            metadataErrors.append("Recording coverage: \(error.localizedDescription)")
        }
        await seek(api: api, camera: camera, timestamp: timestamp, autoplay: autoplay)
        guard !Task.isCancelled, generation == token else { return }
        async let motionRequest: [MotionSample] = api.get(["review", "activity", "motion"], query: query + [
            URLQueryItem(name: "cameras", value: camera), URLQueryItem(name: "scale", value: "15"),
        ])
        async let eventRequest: [ReviewSegment] = api.get(["review"], query: query + [
            URLQueryItem(name: "cameras", value: camera), URLQueryItem(name: "limit", value: "1000"),
        ])
        do {
            let result = try await motionRequest
            guard !Task.isCancelled, generation == token else { return }
            motion = result
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            metadataErrors.append("Motion timeline: \(error.localizedDescription)")
        }
        do {
            let result = try await eventRequest
            guard !Task.isCancelled, generation == token else { return }
            events = result
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            metadataErrors.append("Activity timeline: \(error.localizedDescription)")
        }
    }

    func seek(api: HorizonAPI, camera: String, timestamp: Double, autoplay: Bool = true) async {
        guard timestamp.isFinite, let range else {
            error = "The review timeline is not ready for this recording time."
            return
        }
        let token = UUID()
        clipGeneration = token
        intendsToPlay = autoplay
        error = nil
        missingRecording = false
        if loadedCamera == camera, let position = timeline.position(for: timestamp),
           playback.player.currentItem?.status == .readyToPlay {
            playback.seek(to: position, autoplay: autoplay)
            return
        }
        playback.stop()
        timeline = PlaybackTimeline(spans: [])
        loading = true
        defer { if clipGeneration == token { loading = false } }
        let start = max(range.start, floor(timestamp / 300) * 300)
        let end = min(start + 300, range.end)
        guard timestamp >= range.start, timestamp >= start, timestamp < end else { missingRecording = true; return }
        do {
            let result: RecordingCoverage = try await api.get([camera, "recordings", "coverage"], query: [
                URLQueryItem(name: "after", value: String(start)),
                URLQueryItem(name: "before", value: String(end)),
                URLQueryItem(name: "timelines", value: "true"),
            ])
            guard !Task.isCancelled, clipGeneration == token else { return }
            guard let spans = result.timelines?.auto else {
                throw HorizonError.message("The server did not provide the recording timeline needed for accurate scrubbing.")
            }
            let mapping = PlaybackTimeline(spans: spans)
            guard let position = mapping.position(for: timestamp) else { missingRecording = true; return }
            timeline = mapping
            loadedCamera = camera
            playback.open(url: try api.address.playback(camera: camera, start: start, end: end),
                api: api, initialPosition: position, autoplay: autoplay)
        } catch {
            guard !Task.isCancelled, clipGeneration == token else { return }
            self.error = error.localizedDescription
        }
    }

    func stop() {
        generation = UUID()
        clipGeneration = UUID()
        playback.stop()
    }
}

struct ReviewWorkspaceView: View {
    let api: HorizonAPI
    let cameras: [HorizonCamera]
    let day: Date
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ReviewPlaybackStore()
    @State private var foldMode: FoldMode = .flat
    @StateObject private var reflection = VideoReflection()
    @State private var camera: String
    @State private var timestamp: Double
    @State private var previewTimestamp: Double
    @State private var scrubbing = false
    @State private var seekRequest: ReviewSeekRequest?
    @State private var timelineScale = ReviewTimelineScale.thirtySeconds
    @State private var playing = true
    @State private var resumeAfterScrub: Bool?
    @State private var resumeAfterCameraChange = true
    @State private var showExport = false
    @State private var showBookmarks = false

    init(api: HorizonAPI, initialReview: ReviewSegment,
         cameras: [HorizonCamera], day: Date) {
        self.init(api: api, camera: initialReview.camera, timestamp: initialReview.startTime, cameras: cameras, day: day)
    }

    init(api: HorizonAPI, camera: String, timestamp: Double,
         cameras: [HorizonCamera], day: Date) {
        self.api = api
        self.cameras = cameras
        self.day = Calendar.current.startOfDay(for: day)
        _camera = State(initialValue: camera)
        let initialTime = max(Calendar.current.startOfDay(for: day).timeIntervalSince1970, timestamp)
        _timestamp = State(initialValue: initialTime)
        _previewTimestamp = State(initialValue: initialTime)
    }

    var body: some View {
        NavigationStack {
            DuoWorkspace(foldMode: $foldMode) {
                ReviewPlayerPane(playback: store.playback, loading: store.loading,
                    missing: store.missingRecording, error: store.error) {
                    requestSeek(timestamp)
                }
            } secondary: {
                VStack(spacing: 8) {
                    playbackControls
                    timelineScaleControls
                    if let metadataError = store.metadataError {
                        Text(metadataError).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        if let range = store.range {
                            NativeReviewTimeline(
                                range: range, time: $timestamp, scrubbing: $scrubbing, scale: timelineScale,
                                coverage: store.coverage?.spans,
                                events: store.events, motion: store.motion,
                                beginScrub: {
                                    resumeAfterScrub = playbackRequested
                                    store.playback.player.pause()
                                },
                                commit: { requestSeek($0) }
                            )
                            .frame(width: 128)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        }
                        cameraPreviews
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabletopReflection(reflection, foldMode: foldMode, player: store.playback.player)
            }
            .navigationTitle(cameras.first { $0.id == camera }?.name ?? camera)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Export selected time", systemImage: "film.stack") { showExport = true }
                        .disabled(store.range == nil)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Bookmarks", systemImage: "bookmark") { showBookmarks = true }
                }
            }
            .task(id: camera) {
                await store.prepare(api: api, camera: camera, day: day, timestamp: timestamp,
                    autoplay: resumeAfterCameraChange)
            }
            .task(id: seekRequest) {
                guard let seekRequest else { return }
                await store.seek(api: api, camera: camera, timestamp: seekRequest.timestamp,
                    autoplay: seekRequest.autoplay)
            }
            .onReceive(store.playback.$position) { position in
                guard !scrubbing, !store.loading, !store.playback.isSeeking,
                      let value = store.timeline.timestamp(for: position) else { return }
                timestamp = value
            }
            .onReceive(store.playback.player.publisher(for: \.timeControlStatus)) { playing = $0 != .paused }
            .onDisappear { store.stop() }
            .sheet(isPresented: $showExport) {
                CreateExportView(api: api, initialCamera: camera,
                    initialStart: Date(timeIntervalSince1970: max(day.timeIntervalSince1970, timestamp - 30)),
                    initialEnd: Date(timeIntervalSince1970: min(timestamp + 30, store.range?.end ?? timestamp))) {}
            }
            .sheet(isPresented: $showBookmarks) {
                BookmarksView(api: api, camera: camera, initialTimestamp: timestamp)
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 14) {
            Button("Back 15 seconds", systemImage: "gobackward.15") { requestSeek(timestamp - 15) }
            Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                if playbackRequested { store.playback.player.pause() }
                else { store.playback.player.play() }
            }
            .disabled(store.loading || store.missingRecording || store.error != nil || store.playback.player.currentItem == nil)
            Button("Forward 15 seconds", systemImage: "goforward.15") { requestSeek(timestamp + 15) }
            Spacer(minLength: 0)
            Text(Date(timeIntervalSince1970: timestamp), format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .accessibilityElement(children: .contain)
    }

    private var timelineScaleControls: some View {
        HStack {
            Text("Timeline scale").font(.caption)
            Spacer(minLength: 4)
            Button("Zoom out", systemImage: "minus.magnifyingglass") {
                if let scale = timelineScale.coarser { timelineScale = scale }
            }
            .disabled(timelineScale.coarser == nil)
            Picker("Time per tick", selection: $timelineScale) {
                ForEach(ReviewTimelineScale.allCases) { scale in
                    Text("\(scale.label) per tick").tag(scale)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Timeline time per tick")
            Button("Zoom in", systemImage: "plus.magnifyingglass") {
                if let scale = timelineScale.finer { timelineScale = scale }
            }
            .disabled(timelineScale.finer == nil)
        }
        .buttonStyle(.borderless)
        .disabled(scrubbing)
        .accessibilityElement(children: .contain)
    }

    private var cameraPreviews: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135))], spacing: 12) {
                ForEach(cameras) { candidate in
                    Button {
                        guard candidate.id != camera else { return }
                        resumeAfterCameraChange = resumeAfterScrub ?? playbackRequested
                        resumeAfterScrub = nil
                        previewTimestamp = timestamp
                        seekRequest = nil
                        camera = candidate.id
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            RecordedCameraPreview(api: api, camera: candidate.id, timestamp: previewTimestamp)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Label(candidate.name, systemImage: candidate.id == camera ? "checkmark.circle.fill" : "video")
                                .font(.caption).lineLimit(2)
                        }
                        .padding(5)
                        .background(candidate.id == camera ? Color.cyan.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View \(candidate.name) at the selected recording time")
                }
            }
            Text("Recorded previews at \(Date(timeIntervalSince1970: previewTimestamp).formatted(date: .omitted, time: .standard)). Switching cameras keeps the selected time.")
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
            if foldMode == .tabletop {
                Label("Tabletop: video above, timeline and cameras below", systemImage: "laptopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Orange: alert. Blue: detection. Gray: recording. Stripes: no recording. Motion bars follow the web timeline.")
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
            if store.events.count == 1000 {
                Text("Showing the latest 1,000 activity markers for this camera and day.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var playbackRequested: Bool {
        if store.loading || store.missingRecording || store.error != nil || store.playback.error != nil {
            return store.intendsToPlay
        }
        return store.playback.player.timeControlStatus != .paused
    }

    private func requestSeek(_ time: Double) {
        guard let range = store.range else {
            store.error = "The review timeline is not ready yet."
            return
        }
        do {
            let request = try ReviewSeekRequest(timestamp: time,
                autoplay: resumeAfterScrub ?? playbackRequested, range: range)
            resumeAfterScrub = nil
            timestamp = request.timestamp
            previewTimestamp = request.timestamp
            seekRequest = request
        } catch {
            store.error = error.localizedDescription
        }
    }
}

private struct ReviewPlayerPane: View {
    @ObservedObject var playback: RecordingPlayer
    let loading: Bool
    let missing: Bool
    let error: String?
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if missing {
                ContentUnavailableView("No recording at this time", systemImage: "video.slash",
                    description: Text("Scrub to a recorded section or choose another camera."))
                    .foregroundStyle(.white)
            } else {
                NativeRecordingSurface(player: playback.player)
                if loading || playback.loading {
                    ProgressView("Opening recording").tint(.white).foregroundStyle(.white)
                }
            }
            if let message = error ?? playback.error {
                VStack { Spacer(); ErrorNotice(message: message, retry: retry).background(.black.opacity(0.85)) }
            }
        }
    }
}

private struct RecordedCameraPreview: View {
    let api: HorizonAPI
    let camera: String
    let timestamp: Double
    @State private var image: UIImage?
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.black
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if let error {
                VStack(spacing: 4) {
                    Image(systemName: "video.slash")
                    Text(error).font(.caption2).multilineTextAlignment(.center).lineLimit(3)
                }
                .foregroundStyle(.white).padding(5)
            } else { ProgressView().tint(.white) }
        }
        .task(id: "\(camera)-\(timestamp)") {
            image = nil
            error = nil
            do {
                try await Task.sleep(for: .milliseconds(350))
                let url = api.address.endpoint(
                    ["api", camera, "recordings", String(timestamp), "snapshot.jpg"],
                    query: [URLQueryItem(name: "height", value: "180")]
                )
                let data = try await api.image(url)
                try Task.checkCancellation()
                guard let decoded = UIImage(data: data) else { throw HorizonError.unexpectedResponse }
                image = decoded
            } catch HorizonError.http(404) {
                if !Task.isCancelled { error = "No recording" }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
