import SwiftUI
import HorizonCore

@MainActor
final class NativeServerSettingsStore: ObservableObject {
    let api: HorizonAPI
    @Published private(set) var draft: NativeSettingsDraft?
    @Published private(set) var schema: NativeSettingsSchema?
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published var error: String?
    @Published private(set) var message: String?
    private var originalRaw: String?
    private var generation = UUID()
    private let navigationBlock = UUID()

    init(api: HorizonAPI) {
        self.api = api
        NativePushController.shared.blockNavigation(navigationBlock)
    }
    deinit {
        let id = navigationBlock
        Task { @MainActor in NativePushController.shared.unblockNavigation(id) }
    }
    var changes: [NativeSettingChange] { draft?.changes ?? [] }

    func load(scope: () -> Bool) async {
        guard scope(), !loading, !saving else { return }
        let token = UUID()
        generation = token
        loading = true
        error = nil
        defer { if generation == token { loading = false } }
        do {
            async let config: NativeSettingValue = api.get(["config"])
            async let schema: NativeSettingValue = api.get(["config", "schema.json"])
            async let raw = api.text(["config", "raw"])
            let (values, document, snapshot) = try await (config, schema, raw)
            try Task.checkCancellation()
            guard generation == token, scope() else { return }
            self.schema = NativeSettingsSchema(document: document)
            draft = NativeSettingsDraft(document: values)
            originalRaw = snapshot
        } catch {
            if generation == token, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func set(_ value: NativeSettingValue, path: [String], authorized: Bool) {
        guard authorized, !saving, !loading, var draft, let schema else {
            error = "Administrator access and loaded settings are required."
            return
        }
        do {
            let node = try schema.node(at: path, values: draft.document)
            try schema.validate(value, schema: node)
            try draft.set(value, at: path)
            self.draft = draft
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func append(_ value: NativeSettingValue, path: [String], authorized: Bool) {
        var values = draft?.document.value(at: path)?.array ?? []
        values.append(value)
        set(.array(values), path: path, authorized: authorized)
    }

    func removeItems(_ indices: IndexSet, path: [String], authorized: Bool) {
        guard var values = draft?.document.value(at: path)?.array else {
            error = "Reload this list before removing items."
            return
        }
        for index in indices.sorted(by: >) where values.indices.contains(index) { values.remove(at: index) }
        set(.array(values), path: path, authorized: authorized)
    }

    func addEntry(name: String, path: [String], authorized: Bool) {
        guard !name.isEmpty, !name.contains("."), !name.contains("/"), !name.contains("\\"),
              draft?.document.value(at: path + [name]) == nil else {
            error = "Choose a unique, nonempty name without dots or slashes."
            return
        }
        guard let draft, let schema else { error = "Load settings before adding an entry."; return }
        do {
            let parent = try schema.node(at: path, values: draft.document)
            guard let additional = parent["additionalProperties"], additional != .bool(false),
                  path != ["cameras"] else {
                throw HorizonError.message("This settings map does not support new entries here.")
            }
            let entry = try schema.resolved(additional, value: nil)
            let value: NativeSettingValue
            switch entry["type"]?.string {
            case "object": value = .object([:])
            case "array": value = .array([])
            case "boolean": value = .bool(false)
            case "integer":
                guard let minimum = Int64(exactly: entry["minimum"]?.numeric ?? 0) else {
                    throw HorizonError.message("The server's integer bound is not supported on this device.")
                }
                value = .integer(minimum)
            case "number": value = .number(entry["minimum"]?.numeric ?? 0)
            default: value = .string("")
            }
            set(value, path: path + [name], authorized: authorized)
        } catch { self.error = error.localizedDescription }
    }

    func discard() {
        if let draft { self.draft = NativeSettingsDraft(document: draft.original) }
        error = nil
    }

    func removeEntry(path: [String], authorized: Bool) {
        guard authorized, !saving, !loading, path.count > 1, var draft, let schema else {
            error = "Administrator access and loaded settings are required."
            return
        }
        do {
            let parentPath = Array(path.dropLast())
            let parent = try schema.node(at: parentPath, values: draft.document)
            guard parentPath != ["cameras"], let additional = parent["additionalProperties"],
                  additional != .bool(false), parent["properties"]?[path.last ?? ""] == nil else {
                throw HorizonError.message("This entry cannot be removed here.")
            }
            try draft.set(.null, at: path)
            self.draft = draft
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func clear() {
        generation = UUID()
        draft = nil
        schema = nil
        originalRaw = nil
        loading = false
        error = nil
    }

    func save(restart: Bool, scope: () -> Bool) async {
        guard scope(), !saving, let draft, let originalRaw else {
            error = "Administrator access and loaded settings are required."
            return
        }
        saving = true
        error = nil
        message = nil
        defer { saving = false }
        var persisted = false
        do {
            let update = try draft.update()
            let latest = try await api.text(["config", "raw"])
            guard scope(), latest == originalRaw else {
                throw HorizonError.message("Server configuration or account scope changed. Reload and merge your edits before saving.")
            }
            try await api.action(["config", "set"], method: "PUT", body: update)
            persisted = true
            message = "Settings saved and validated. A restart is required to apply these saved values."
            self.draft = nil
            self.originalRaw = nil
            if restart {
                guard scope() else { throw HorizonError.message("Account access changed after saving; no restart was requested.") }
                try await api.action(["restart"], body: [String: String]())
                message = "Settings saved; the server accepted the restart request. Check server health before assuming the new settings are active."
            }
        } catch {
            self.error = persisted
                ? "Settings were saved, but restart/apply could not be confirmed: \(error.localizedDescription)"
                : error.localizedDescription
        }
    }
}
