import SwiftUI
import HorizonCore

struct ProtectedMediaView: View {
    let api: HorizonAPI
    @EnvironmentObject private var model: AppModel
    @State private var camera = "all"
    @State private var page: ProtectedMediaPage?
    @State private var items: [ProtectedMediaItem] = []
    @State private var offset = 0
    @State private var loading = false
    @State private var error: String?
    @State private var selected: ProtectedMediaItem?
    @State private var refreshID = 0
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            List {
                Picker("Camera", selection: $camera) {
                    Text("All allowed cameras").tag("all")
                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                }
                if let error { ErrorNotice(message: error) { refreshID += 1 } }
                if let page {
                    Section("Protected storage across the filtered history") {
                        LabeledContent("Saved events", value: String(page.total))
                        LabeledContent("Archive state", value: page.archiveState)
                        ForEach(page.storage.keys.sorted(), id: \.self) { tier in
                            if let usage = page.storage[tier] {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tier.capitalized).font(.headline)
                                    if let total = usage.totalBytes {
                                        Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                                    } else {
                                        Text("\(ByteCountFormatter.string(fromByteCount: usage.knownBytes, countStyle: .file)) known; \(usage.unknownSizeRecordings) recording sizes unknown")
                                    }
                                    Text("\(usage.recordings) distinct recording files")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section {
                    ForEach(items.filter { item in model.cameras.contains { $0.id == item.camera } }) { item in
                        Button { selected = item } label: {
                            HStack {
                                ServerImage(api: api, url: api.address.endpoint(["api", "events", item.id, "thumbnail.jpg"]))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.label.capitalized).font(.headline)
                                    Text(item.camera).font(.subheadline)
                                    Text(Date(timeIntervalSince1970: item.startTime), format: .dateTime)
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(item.availability.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.caption).foregroundStyle(item.canReadOriginal ? Color.secondary : Color.orange)
                                }
                                Spacer()
                                Image(systemName: "lock.shield")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if loading { ProgressView("Loading protected media") }
                    else if let page, offset + page.items.count < page.total {
                        Button("Load more saved events") { offset += page.limit }
                    }
                } header: {
                    Text("Saved events")
                } footer: {
                    Text("Availability comes from the server index and cached archive health, not a fresh check of every file. Missing or unavailable media is never presented as recovered.")
                }
            }
            .navigationTitle("Protected")
            .refreshable { offset = 0; refreshID += 1 }
            .onChange(of: camera) { _, _ in offset = 0; items = []; page = nil }
            .task(id: "\(camera)-\(offset)-\(refreshID)") { await load() }
            .sheet(item: $selected) { item in
                ProtectedMediaDetail(api: api, item: item) { offset = 0; refreshID += 1 }
            }
        }
    }

    private func load() async {
        let token = UUID()
        generation = token
        loading = true; error = nil
        defer { if generation == token { loading = false } }
        var query = [URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "offset", value: String(offset))]
        if camera != "all" { query.append(URLQueryItem(name: "camera", value: camera)) }
        do {
            let result: ProtectedMediaPage = try await api.get(["protected-media"], query: query)
            try Task.checkCancellation()
            guard generation == token else { return }
            page = result
            if offset == 0 { items = result.items }
            else {
                let existing = Set(items.map(\.id))
                items += result.items.filter { !existing.contains($0.id) }
            }
        } catch { if !Task.isCancelled && generation == token { self.error = error.localizedDescription } }
    }
}

private struct ProtectedMediaDetail: View {
    let api: HorizonAPI
    let item: ProtectedMediaItem
    let changed: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var transfer = MediaTransfer()
    @State private var confirmUnprotect = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if item.canReadOriginal, let end = item.endTime {
                        RecordingPlaybackView(api: api, camera: item.camera, start: item.startTime, end: end)
                            .frame(height: 280)
                        Button("Download original recording", systemImage: "square.and.arrow.up") {
                            transfer.start(api: api, url: api.address.endpoint([
                                "api", item.camera, "start", String(item.startTime), "end", String(end), "clip.mp4",
                            ]), fileExtension: "mp4")
                        }
                        .disabled(transfer.downloading)
                    } else {
                        Label("Original recording unavailable", systemImage: "video.slash")
                        Text(item.availability.replacingOccurrences(of: "_", with: " ").capitalized)
                    }
                    if item.hasSnapshot {
                        Button("Download snapshot", systemImage: "photo") {
                            transfer.start(api: api, url: api.address.endpoint(["api", "events", item.id, "snapshot.jpg"]),
                                fileExtension: "jpg")
                        }
                        .disabled(transfer.downloading)
                    }
                    if transfer.downloading { ProgressView("Downloading evidence") }
                    if let error = transfer.error { ErrorNotice(message: error) }
                }
                Section("Permanent protection") {
                    LabeledContent("Camera", value: item.camera)
                    LabeledContent("Label", value: item.label)
                    LabeledContent("Recording files", value: String(item.recordings))
                    LabeledContent("Storage tiers", value: item.tiers.joined(separator: ", "))
                    if model.isAdmin {
                        Button("Remove permanent protection", role: .destructive) { confirmUnprotect = true }
                            .disabled(busy)
                    }
                }
                if busy { ProgressView("Removing protection") }
                if let error { ErrorNotice(message: error) }
            }
            .navigationTitle("Protected evidence")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onDisappear { transfer.cancel() }
            .sheet(item: $transfer.file, onDismiss: transfer.dismissShare) { NativeShareSheet(file: $0.url) }
            .confirmationDialog(
                "Remove permanent protection? Normal retention, quota eviction, and lossy compression may become eligible. Media is not immediately deleted.",
                isPresented: $confirmUnprotect, titleVisibility: .visible
            ) {
                Button("Remove protection", role: .destructive) { Task { await unprotect() } }
            }
        }
    }

    private func unprotect() async {
        guard model.isAdmin else { error = "Administrator access is required."; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await api.action(["events", item.id, "retain"], method: "DELETE",
                body: ["confirm": true, "acknowledge_retention": true])
            changed()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
