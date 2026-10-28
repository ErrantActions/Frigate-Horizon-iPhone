import SwiftUI
import HorizonCore

@MainActor
final class ExportsStore: ObservableObject {
    @Published private(set) var exports: [MediaExport] = []
    @Published private(set) var jobs: [MediaExportJob] = []
    @Published private(set) var loading = false
    @Published private(set) var finishedJobs: [MediaExportJob] = []
    @Published var error: String?
    private var generation = UUID()
    var pending: Bool { !jobs.isEmpty || exports.contains(where: \.inProgress) }

    func load(api: HorizonAPI, trackedIDs: [String]) async {
        let token = UUID()
        generation = token
        loading = true
        defer { if generation == token { loading = false } }
        do {
            async let exports: [MediaExport] = api.get(["exports"])
            async let jobs: [MediaExportJob] = api.get(["jobs", "export"])
            let result = try await (exports, jobs)
            guard !Task.isCancelled, generation == token else { return }
            self.exports = result.0
            self.jobs = result.1
            let active = Set(result.1.map(\.id))
            for id in trackedIDs where !active.contains(id) {
                let job: MediaExportJob = try await api.get(["jobs", "export", id])
                guard !Task.isCancelled, generation == token else { return }
                if !["queued", "running"].contains(job.status) && !finishedJobs.contains(where: { $0.id == job.id }) {
                    finishedJobs.append(job)
                    if finishedJobs.count > 20 { finishedJobs.removeFirst(finishedJobs.count - 20) }
                }
            }
            error = nil
        } catch {
            if !Task.isCancelled && generation == token { self.error = error.localizedDescription }
        }
    }

    func dismissFinishedJobs() { finishedJobs = [] }
}

struct ExportsView: View {
    let api: HorizonAPI
    let active: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = ExportsStore()
    @StateObject private var transfer = MediaTransfer()
    @State private var camera = "all"
    @State private var showCreate = false
    @State private var playback: MediaExport?
    @State private var deleteTarget: MediaExport?
    @State private var renameTarget: MediaExport?
    @State private var showRename = false
    @State private var name = ""
    @State private var refreshID = 0
    @State private var busy = false
    @State private var actionError: String?
    @State private var confirmForgetTracking = false

    private var visibleExports: [MediaExport] {
        let allowed = Set(model.cameras.map(\.id))
        let activeJobs = Set(store.jobs.map(\.id))
        return store.exports.filter {
            allowed.contains($0.camera) && (camera == "all" || $0.camera == camera) && !activeJobs.contains($0.id)
        }
    }

    private var visibleFinishedJobs: [MediaExportJob] {
        let allowed = Set(model.cameras.map(\.id))
        return store.finishedJobs.filter { allowed.contains($0.camera) }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Camera", selection: $camera) {
                    Text("All allowed cameras").tag("all")
                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                }
                if let error = store.error { ErrorNotice(message: error) { refreshID += 1 } }
                if store.error != nil && !model.pendingExportIDs.isEmpty {
                    Button("Dismiss local job tracking") { confirmForgetTracking = true }
                }
                if let actionError { ErrorNotice(message: actionError) }
                if let error = transfer.error { ErrorNotice(message: error) }
                if transfer.downloading { ProgressView("Downloading export") }
                Section("Export jobs") {
                    ForEach(visibleFinishedJobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(job.name ?? job.id): \(job.status)").font(.headline)
                            if let failure = job.errorMessage { Text(failure).foregroundStyle(.orange) }
                        }
                    }
                    if !store.finishedJobs.isEmpty {
                        Button("Dismiss finished job notices") { store.dismissFinishedJobs() }
                    }
                    ForEach(store.jobs.filter { job in
                        model.cameras.contains(where: { $0.id == job.camera }) && (camera == "all" || job.camera == camera)
                    }) { job in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.name ?? job.camera).font(.headline)
                            Text(job.currentStep ?? job.status).font(.caption).foregroundStyle(.secondary)
                            if let percent = job.progressPercent {
                                ProgressView(value: min(100, max(0, percent)), total: 100)
                            } else { ProgressView() }
                            if let error = job.errorMessage { Text(error).font(.caption).foregroundStyle(.orange) }
                        }
                    }
                }
                Section("Completed exports") {
                    ForEach(visibleExports) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.name).font(.headline)
                            Text("\(item.camera) - \(Date(timeIntervalSince1970: item.date).formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                            if item.inProgress { ProgressView("Export in progress") }
                            else {
                                HStack {
                                    Button("Play", systemImage: "play.circle") { playback = item }
                                    Button("Download", systemImage: "square.and.arrow.up") { download(item) }
                                        .disabled(transfer.downloading)
                                    Spacer()
                                    if model.isAdmin {
                                        Menu("Manage export", systemImage: "ellipsis.circle") {
                                            Button("Rename", systemImage: "pencil") {
                                                renameTarget = item; name = item.name; showRename = true
                                            }
                                            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = item }
                                        }
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if store.loading { ProgressView("Loading exports") }
                    if visibleExports.isEmpty && !store.loading { Text("No exports for this camera.").foregroundStyle(.secondary) }
                }
            }
            .disabled(busy)
            .navigationTitle("Exports")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Create export", systemImage: "plus") { showCreate = true }
                        .disabled(model.cameras.isEmpty)
                }
            }
            .task(id: "\(active)-\(scenePhase == .active)-\(refreshID)-\(model.pendingExportIDs.joined(separator: ","))") {
                guard active, scenePhase == .active else { return }
                repeat {
                    await store.load(api: api, trackedIDs: model.pendingExportIDs)
                    for job in store.finishedJobs { model.finishExport(job.id) }
                    guard !Task.isCancelled, store.error == nil,
                          store.pending || !model.pendingExportIDs.isEmpty else { return }
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                } while !Task.isCancelled
            }
            .refreshable { refreshID += 1 }
            .onDisappear { transfer.cancel() }
            .sheet(isPresented: $showCreate) {
                CreateExportView(api: api, initialCamera: model.cameras.first?.id ?? "") { refreshID += 1 }
            }
            .sheet(item: $playback) { ExportPlayerView(api: api, item: $0) }
            .sheet(item: $transfer.file, onDismiss: transfer.dismissShare) { NativeShareSheet(file: $0.url) }
            .alert("Rename export", isPresented: $showRename, presenting: renameTarget) { item in
                TextField("Name", text: $name)
                Button("Save") {
                    Task { await adminAction {
                        try await api.action(["export", item.id, "rename"], method: "PATCH", body: ["name": name])
                    } }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 256)
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete this export file?", isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
            ), titleVisibility: .visible) {
                if let item = deleteTarget {
                    Button("Delete export", role: .destructive) {
                        Task { await adminAction {
                            try await api.action(["exports", "delete"], body: ["ids": [item.id]])
                        } }
                    }
                }
            } message: { Text("This removes the export, not the original camera recordings.") }
            .confirmationDialog("Dismiss local export tracking?", isPresented: $confirmForgetTracking,
                titleVisibility: .visible) {
                Button("Dismiss tracking") {
                    for id in model.pendingExportIDs { model.finishExport(id) }
                }
            } message: { Text("This does not cancel server jobs or delete exported media.") }
        }
    }

    private func download(_ item: MediaExport) {
        do {
            transfer.start(api: api, url: try api.address.mediaFile(item.videoPath, root: "exports"), fileExtension: "mp4")
        } catch { transfer.error = error.localizedDescription }
    }

    private func adminAction(_ action: () async throws -> Void) async {
        guard model.isAdmin else { actionError = "Administrator access is required."; return }
        busy = true
        actionError = nil
        defer { busy = false }
        do { try await action(); refreshID += 1 }
        catch { actionError = error.localizedDescription }
    }
}

struct CreateExportView: View {
    let api: HorizonAPI
    let initialCamera: String
    var initialStart = Date().addingTimeInterval(-3600)
    var initialEnd = Date()
    let queued: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var camera = ""
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var end = Date()
    @State private var name = ""
    @State private var stream = "auto"
    @State private var timestamp = "none"
    @State private var metadata: Set<String> = []
    @State private var busy = false
    @State private var error: String?
    private let categories = ["camera", "events", "identities", "geometry", "environment", "notes", "provenance"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Camera", selection: $camera) {
                        ForEach(model.cameras) { Text($0.name).tag($0.id) }
                    }
                    TextField("Export name", text: $name)
                    DatePicker("Start", selection: $start, in: ...Date())
                    DatePicker("End", selection: $end, in: ...Date())
                    Picker("Recorded stream", selection: $stream) {
                        Text("Auto (server merge)").tag("auto")
                        Text("Main only").tag("main")
                        Text("Sub only").tag("sub")
                    }
                    Picker("Capture timestamps", selection: $timestamp) {
                        Text("None").tag("none")
                        Text("Subtitle").tag("subtitle")
                        Text("Burn in").tag("burn_in")
                        Text("Both").tag("both")
                    }
                } header: {
                    Text("Recording range")
                } footer: {
                    Text("Exports do not change original recordings. Burn-in timestamps may require server-side encoding.")
                }
                Section {
                    ForEach(categories, id: \.self) { category in
                        Toggle(category.capitalized, isOn: Binding(
                            get: { metadata.contains(category) },
                            set: { if $0 { metadata.insert(category) } else { metadata.remove(category) } }
                        ))
                    }
                } header: {
                    Text("Optional investigation metadata")
                } footer: {
                    Text("Identity and contextual metadata may be sensitive. No categories are included unless you explicitly select them.")
                }
                if busy { ProgressView("Queueing export") }
                if let error { ErrorNotice(message: error) }
            }
            .disabled(busy)
            .navigationTitle("Create export")
            .modifier(DeferNotificationNavigation())
            .onAppear { camera = initialCamera; start = initialStart; end = initialEnd }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Queue export") { Task { await create() } }
                        .disabled(busy || camera.isEmpty || end <= start || name.count > 256)
                }
            }
        }
    }

    private func create() async {
        guard model.cameras.contains(where: { $0.id == camera }), end > start, end <= Date() else {
            error = "Choose an allowed camera and a completed recording range."
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result: APIActionResult = try await api.send(
                ["export", camera, "start", String(start.timeIntervalSince1970), "end", String(end.timeIntervalSince1970)],
                body: CreateExportBody(name: name, stream: stream, timestamp: timestamp,
                    metadataCategories: metadata.sorted())
            )
            try result.requireSuccess()
            guard let id = result.exportID, !id.isEmpty else {
                throw HorizonError.message("The server accepted the request without a job ID. Check Exports before retrying.")
            }
            model.trackExport(id)
            queued()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct ExportPlayerView: View {
    let api: HorizonAPI
    let item: MediaExport
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = RecordingPlayer()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack {
                NativeRecordingSurface(player: playback.player)
                    .background(.black)
                    .overlay { if playback.loading { ProgressView().tint(.white) } }
                if let message = error ?? playback.error { ErrorNotice(message: message) }
            }
            .navigationTitle(item.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                do { playback.open(url: try api.address.mediaFile(item.videoPath, root: "exports"), api: api) }
                catch { self.error = error.localizedDescription }
            }
            .onDisappear { playback.stop() }
        }
    }
}
