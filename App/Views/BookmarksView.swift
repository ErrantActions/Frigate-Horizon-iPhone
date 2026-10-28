import SwiftUI
import HorizonCore

struct BookmarksView: View {
    let api: HorizonAPI
    let camera: String
    let initialTimestamp: Double
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [RecordingBookmark] = []
    @State private var page: BookmarkPage?
    @State private var offset = 0
    @State private var refreshID = 0
    @State private var generation = UUID()
    @State private var loading = false
    @State private var error: String?
    @State private var editing: RecordingBookmark?
    @State private var playback: RecordingBookmark?
    @State private var deleteTarget: RecordingBookmark?
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Bookmarks are shared annotations for this camera. They do not permanently protect footage or prevent normal retention.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error { ErrorNotice(message: error) { offset = 0; refreshID += 1 } }
                ForEach(rows) { bookmark in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(bookmark.title).font(.headline)
                        Text(Date(timeIntervalSince1970: bookmark.timestamp), format: .dateTime)
                            .font(.caption).foregroundStyle(.secondary)
                        if let end = bookmark.endTime {
                            Text("Range ends \(Date(timeIntervalSince1970: end).formatted())")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !bookmark.notes.isEmpty { Text(bookmark.notes).font(.callout).textSelection(.enabled) }
                        Text("Created by \(bookmark.owner); revision \(bookmark.revision)")
                            .font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("Open timeline", systemImage: "timeline.selection") { playback = bookmark }
                                .disabled(!bookmark.availableAtAnchor)
                            if bookmark.canEdit {
                                Spacer()
                                Button("Edit", systemImage: "pencil") { editing = bookmark }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = bookmark }
                            }
                        }
                        .buttonStyle(.borderless)
                        if !bookmark.availableAtAnchor {
                            Label("No indexed recording at the bookmark time", systemImage: "video.slash")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if loading { ProgressView("Loading bookmarks") }
                else if page?.hasMore == true { Button("Load more bookmarks") { offset += 25 } }
                else if rows.isEmpty && error == nil { Text("No bookmarks for this camera.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Bookmarks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Add bookmark", systemImage: "plus") { showCreate = true } }
            }
            .refreshable { offset = 0; refreshID += 1 }
            .task(id: "\(offset)-\(refreshID)") { await load() }
            .sheet(isPresented: $showCreate) {
                BookmarkEditor(api: api, camera: camera, bookmark: nil, initialTimestamp: initialTimestamp) {
                    offset = 0; refreshID += 1
                }
            }
            .sheet(item: $editing) { bookmark in
                BookmarkEditor(api: api, camera: camera, bookmark: bookmark, initialTimestamp: bookmark.timestamp) {
                    offset = 0; refreshID += 1
                }
            }
            .fullScreenCover(item: $playback) { bookmark in
                ReviewWorkspaceView(api: api, camera: camera, timestamp: bookmark.timestamp,
                    cameras: model.cameras, day: Date(timeIntervalSince1970: bookmark.timestamp))
            }
            .confirmationDialog("Delete this bookmark annotation?", isPresented: Binding(
                get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }
            ), titleVisibility: .visible) {
                if let bookmark = deleteTarget {
                    Button("Delete bookmark", role: .destructive) { Task { await delete(bookmark) } }
                }
            } message: { Text("This does not delete recordings or remove permanent footage protection.") }
        }
    }

    private func load() async {
        guard model.cameras.contains(where: { $0.id == camera }) else {
            error = "This camera is not available to your account."
            return
        }
        let token = UUID()
        generation = token
        loading = true; error = nil
        defer { if generation == token { loading = false } }
        do {
            let result: BookmarkPage = try await api.get([camera, "recordings", "bookmarks"], query: [
                URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "offset", value: String(offset)),
            ])
            try Task.checkCancellation()
            guard generation == token else { return }
            page = result
            if offset == 0 { rows = result.items }
            else {
                let existing = Set(rows.map(\.id))
                rows += result.items.filter { !existing.contains($0.id) }
            }
        } catch { if !Task.isCancelled && generation == token { self.error = error.localizedDescription } }
    }

    private func delete(_ bookmark: RecordingBookmark) async {
        guard bookmark.canEdit else { error = "Only the creator or an administrator can edit this bookmark."; return }
        do {
            try await api.deleteBookmark(camera: camera, id: bookmark.id, revision: bookmark.revision)
            offset = 0; refreshID += 1
        } catch { error = error.localizedDescription }
    }
}

private struct BookmarkEditor: View {
    let api: HorizonAPI
    let camera: String
    let bookmark: RecordingBookmark?
    let initialTimestamp: Double
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var notes = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var range = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Annotation") {
                    TextField("Title", text: $title)
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(4...12)
                    Text("\(title.count)/128 title; \(notes.count)/4000 notes")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Recording time") {
                    DatePicker("Start", selection: $start, in: ...Date())
                    Toggle("Annotate a time range", isOn: $range)
                    if range { DatePicker("End", selection: $end, in: ...Date()) }
                }
                .disabled(bookmark != nil)
                Section {
                    Text("This saves a note only, not a protected copy of the footage. Existing notes use revision checks; if another user changes the note, close and refresh before retrying.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if busy { ProgressView("Saving bookmark") }
                if let error { ErrorNotice(message: error) }
            }
            .disabled(busy)
            .navigationTitle(bookmark == nil ? "Create bookmark" : "Edit bookmark")
            .modifier(DeferNotificationNavigation())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || title.count > 128 || notes.count > 4000 || (range && end <= start))
                }
            }
            .onAppear {
                title = bookmark?.title ?? ""
                notes = bookmark?.notes ?? ""
                start = Date(timeIntervalSince1970: bookmark?.timestamp ?? initialTimestamp)
                range = bookmark?.endTime != nil
                end = Date(timeIntervalSince1970: bookmark?.endTime ?? initialTimestamp)
            }
        }
    }

    private func save() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            if let bookmark {
                guard bookmark.canEdit else {
                    throw HorizonError.message("Only the creator or an administrator can edit this bookmark.")
                }
                let _: RecordingBookmark = try await api.send(
                    [camera, "recordings", "bookmarks", bookmark.id], method: "PATCH",
                    body: EditBookmarkBody(title: title, notes: notes, revision: bookmark.revision)
                )
            } else {
                let _: RecordingBookmark = try await api.send(
                    [camera, "recordings", "bookmarks"],
                    body: CreateBookmarkBody(timestamp: start.timeIntervalSince1970,
                        endTime: range ? end.timeIntervalSince1970 : nil, title: title, notes: notes)
                )
            }
            saved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
