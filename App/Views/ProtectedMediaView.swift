import SwiftUI
import HorizonCore

struct ProtectedMediaView: View {
    let api: HorizonAPI
    @Binding var camera: String
    var librarySection: Binding<LibrarySection>? = nil
    @EnvironmentObject private var model: AppModel
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
                Section {
                    Picker("Camera", selection: $camera) {
                        Text("All allowed cameras").tag("all")
                        ForEach(model.cameras) { Text($0.name).tag($0.id) }
                    }
                } header: {
                    HorizonSectionHeader(title: "Library filter", systemImage: "camera")
                }
                .listRowBackground(HorizonPalette.surface)
                if let error {
                    ErrorNotice(message: error) { refreshID += 1 }
                        .listRowBackground(HorizonPalette.surface)
                }
                if let page { storageSection(page) }
                Section {
                    ForEach(visibleItems) { item in
                        Button { selected = item } label: {
                            protectedRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                    if loading { ProgressView("Loading protected media").padding(.vertical, 16) }
                    else if let page, offset + page.items.count < page.total {
                        Button("Load more saved events") { offset += page.limit }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                    } else if visibleItems.isEmpty && error == nil {
                        ContentUnavailableView("No saved events in this view", systemImage: "lock.shield",
                            description: Text("Choose another camera or protect an event to keep it here."))
                    }
                } header: {
                    HorizonSectionHeader(title: "Saved events", subtitle: "\(visibleItems.count) loaded",
                        systemImage: "rectangle.stack")
                } footer: {
                    Text("Availability comes from the server index and cached archive health, not a fresh check of every file. Missing or unavailable media is never presented as recovered.")
                }
                .listRowBackground(HorizonPalette.surface)
            }
            .horizonScreen()
            .navigationTitle("Protected")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if let librarySection { LibrarySectionPicker(selection: librarySection) }
                }
            }
            .refreshable { offset = 0; refreshID += 1 }
            .onChange(of: camera) { _, _ in offset = 0; items = []; page = nil }
            .task(id: "\(camera)-\(offset)-\(refreshID)") { await load() }
            .sheet(item: $selected) { item in
                ProtectedMediaDetail(api: api, item: item) { offset = 0; refreshID += 1 }
            }
        }
    }

    private var visibleItems: [ProtectedMediaItem] {
        items.filter { item in model.cameras.contains { $0.id == item.camera } }
    }

    private func storageSection(_ page: ProtectedMediaPage) -> some View {
        Section {
            HorizonMetric(title: "Saved events in filtered history", value: String(page.total),
                systemImage: "lock.shield")
                .padding(.vertical, 6)
            LabeledContent("Archive state") {
                Text(page.archiveState).foregroundStyle(.secondary)
            }
            ForEach(page.storage.keys.sorted(), id: \.self) { tier in
                if let usage = page.storage[tier] {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(tier.capitalized).font(.system(.headline, design: .rounded))
                        if let total = usage.totalBytes {
                            Text(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                                .font(.title3.weight(.semibold))
                        } else {
                            Text("\(ByteCountFormatter.string(fromByteCount: usage.knownBytes, countStyle: .file)) known; \(usage.unknownSizeRecordings) recording sizes unknown")
                                .font(.subheadline)
                        }
                        Text("\(usage.recordings) distinct recording files")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        } header: {
            HorizonSectionHeader(title: "Protected storage",
                subtitle: "Across the filtered history", systemImage: "externaldrive")
        }
        .listRowBackground(HorizonPalette.surface)
    }

    private func protectedRow(_ item: ProtectedMediaItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ServerImage(api: api, url: api.address.endpoint(["api", "events", item.id, "thumbnail.jpg"]))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(item.label.capitalized).font(.system(.headline, design: .rounded)).foregroundStyle(.primary)
                Text(model.cameras.first { $0.id == item.camera }?.name ?? item.camera)
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(Date(timeIntervalSince1970: item.startTime), format: .dateTime)
                    .font(.caption).foregroundStyle(.secondary)
                HorizonStatusPill(title: item.availability.replacingOccurrences(of: "_", with: " ").capitalized,
                    systemImage: "lock.shield",
                    tint: item.canReadOriginal ? HorizonPalette.accent : HorizonPalette.warm)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
                    HorizonHero(title: item.label.capitalized,
                        subtitle: Date(timeIntervalSince1970: item.startTime).formatted(),
                        systemImage: "lock.shield", eyebrow: "Protected evidence")
                        .horizonHeroRow()
                }
                Section {
                    if item.canReadOriginal, let end = item.endTime {
                        RecordingPlaybackView(api: api, camera: item.camera, start: item.startTime, end: end)
                            .frame(height: 280)
                        Button("Download original recording", systemImage: "arrow.down.to.line") {
                            transfer.start(api: api, url: api.address.endpoint([
                                "api", item.camera, "start", String(item.startTime), "end", String(end), "clip.mp4",
                            ]), fileExtension: "mp4")
                        }
                        .disabled(transfer.downloading)
                    } else {
                        ContentUnavailableView("Original recording unavailable", systemImage: "video.slash",
                            description: Text(item.availability.replacingOccurrences(of: "_", with: " ").capitalized))
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
                } header: {
                    HorizonSectionHeader(title: "Original media", systemImage: "play.rectangle")
                }
                .buttonStyle(HorizonButtonStyle(.secondary))
                .listRowBackground(HorizonPalette.surface)
                Section {
                    LabeledContent("Camera", value: item.camera)
                    LabeledContent("Label", value: item.label)
                    LabeledContent("Recording files", value: String(item.recordings))
                    LabeledContent("Storage tiers", value: item.tiers.joined(separator: ", "))
                    if model.isAdmin {
                        Button("Remove permanent protection", role: .destructive) { confirmUnprotect = true }
                            .buttonStyle(HorizonButtonStyle(.secondary))
                            .disabled(busy)
                    }
                } header: {
                    HorizonSectionHeader(title: "Permanent protection", systemImage: "lock.shield")
                }
                .listRowBackground(HorizonPalette.surface)
                if busy { ProgressView("Removing protection") }
                if let error { ErrorNotice(message: error) }
            }
            .horizonScreen()
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
