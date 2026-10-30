import SwiftUI
import HorizonCore

struct NativeServerSettingsView: View {
    let api: HorizonAPI
    let initialPath: [String]
    @EnvironmentObject private var model: AppModel
    @StateObject private var store: NativeServerSettingsStore
    @State private var confirmReload = false

    init(api: HorizonAPI, initialPath: [String] = []) {
        self.api = api
        self.initialPath = initialPath
        _store = StateObject(wrappedValue: NativeServerSettingsStore(api: api))
    }

    private var authorized: Bool { model.isAdmin && model.api === api }

    var body: some View {
        Group {
            if authorized {
                NativeSettingsNode(path: initialPath, title: initialPath.isEmpty ? "Server settings" : Self.title(initialPath.last ?? ""),
                    isRoot: true)
                    .environmentObject(store)
            } else {
                ContentUnavailableView("Administrator access required", systemImage: "lock.shield")
            }
        }
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Reload running settings", systemImage: "arrow.clockwise") {
                    if store.changes.isEmpty { Task { await store.load(scope: { authorized }) } }
                    else { confirmReload = true }
                }
                .disabled(store.saving || store.loading || !authorized)
            }
        }
        .interactiveDismissDisabled(!store.changes.isEmpty || store.saving)
        .task {
            if store.schema == nil { await store.load(scope: { authorized }) }
        }
        .onChange(of: model.api.map(ObjectIdentifier.init)) { _, _ in
            if !authorized { store.clear() }
        }
        .onChange(of: model.isAdmin) { _, admin in if !admin { store.clear() } }
        .confirmationDialog("Discard unsaved settings and reload?", isPresented: $confirmReload, titleVisibility: .visible) {
            Button("Discard and reload", role: .destructive) {
                store.discard()
                Task { await store.load(scope: { authorized }) }
            }
        }
    }

    static func title(_ key: String) -> String {
        switch key {
        case "apns": return "Apple push provider"
        case "ffmpeg": return "Camera streams and decoding"
        case "record": return "Recording and retention"
        case "detect": return "Object detection"
        case "objects": return "Object labels and filters"
        case "review": return "Review alerts and detections"
        case "motion": return "Motion and adaptive filtering"
        case "notifications": return "Server notification rules"
        case "ui": return "Camera display"
        case "onvif": return "ONVIF and camera control"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct NativeSettingsNode: View {
    let path: [String]
    let title: String
    var isRoot = false
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: NativeServerSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false
    @State private var entryName = ""
    @State private var confirmRemove = false
    @State private var confirmClose = false
    private var authorized: Bool { model.isAdmin && model.api === store.api }

    var body: some View {
        List {
            Section {
                Text("Native controls for the server's published settings. Values below are running configuration; changes stay in this draft until you review and save.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.loading { ProgressView("Loading settings and schema") }
            if store.saving { ProgressView("Validating and saving") }
            if let error = store.error { ErrorNotice(message: error) }
            if let message = store.message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if let draft = store.draft, let schema = store.schema {
                switch Result(catching: { try schema.node(at: path, values: draft.document) }) {
                case .failure(let error): ErrorNotice(message: error.localizedDescription)
                case .success(let node):
                    nodeContent(node, value: draft.document.value(at: path), schema: schema, document: draft.document)
                }
                if path.count > 1, Array(path.dropLast()) != ["cameras"],
                   let parent = try? schema.node(at: Array(path.dropLast()), values: draft.document),
                   let additional = parent["additionalProperties"], additional != .bool(false),
                   parent["properties"]?[path.last ?? ""] == nil {
                    Button("Remove this entry from draft", role: .destructive) { confirmRemove = true }
                }
            } else if !store.loading {
                Button("Load running settings", systemImage: "arrow.clockwise") {
                    Task { await store.load(scope: { authorized }) }
                }
            }
        }
        .navigationTitle(title)
        .horizonScreen()
        .navigationBarBackButtonHidden(isRoot && !store.changes.isEmpty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if isRoot && !store.changes.isEmpty {
                    Button("Back") { confirmClose = true }.disabled(store.saving)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { NativeSettingsReview() } label: {
                    Text("Review (\(store.changes.count))")
                }
                .disabled(store.changes.isEmpty || store.saving || !authorized)
            }
        }
        .disabled(store.saving || !authorized)
        .alert("Add a settings entry", isPresented: $showAdd) {
            TextField("Name", text: $entryName)
            Button("Add") { store.addEntry(name: entryName, path: path, authorized: authorized); entryName = "" }
            Button("Cancel", role: .cancel) { entryName = "" }
        } message: { Text("Creates a draft entry only. The server validates it when you save.") }
        .confirmationDialog("Remove this settings entry?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove from draft", role: .destructive) { store.removeEntry(path: path, authorized: authorized) }
        } message: { Text("This is not sent until you review and save the draft.") }
        .confirmationDialog("Discard unsaved settings?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard and close", role: .destructive) { store.discard(); dismiss() }
        }
    }

    @ViewBuilder
    private func nodeContent(_ node: NativeSettingValue, value: NativeSettingValue?,
                             schema: NativeSettingsSchema, document: NativeSettingValue) -> some View {
        let kind = node["type"]?.string ?? value?.kind ?? "object"
        if let description = node["description"]?.string {
            Text(description).font(.footnote).foregroundStyle(.secondary)
        }
        if path == ["cameras"] {
            Section("Camera settings") {
                ForEach(model.cameras) { camera in
                    NavigationLink {
                        NativeSettingsNode(path: path + [camera.id], title: camera.name)
                    } label: {
                        HStack {
                            Label(camera.name, systemImage: camera.settings.enabled ? "video" : "video.slash")
                            Spacer()
                            if !camera.settings.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        } else if kind == "object" {
            switch Result(catching: { try schema.keys(at: path, values: document) }) {
            case .failure(let error): ErrorNotice(message: error.localizedDescription)
            case .success(let keys):
                Section {
                    ForEach(keys, id: \.self) { key in
                        NativeSettingRow(path: path + [key], key: key)
                    }
                }
                if keys.isEmpty { Text("No entries configured.").foregroundStyle(.secondary) }
                if let additional = node["additionalProperties"], additional != .bool(false), !path.isEmpty {
                    Button("Add entry", systemImage: "plus") { showAdd = true }
                }
            }
        } else if kind == "array" {
            let values = value?.array ?? []
            Section {
                ForEach(values.indices, id: \.self) { index in
                    NativeSettingRow(path: path + [String(index)], key: "Item \(index + 1)")
                }
                .onDelete { store.removeItems($0, path: path, authorized: authorized) }
                if let item = node["items"] {
                    switch Result(catching: { try schema.resolved(item, value: nil) }) {
                    case .failure(let error): ErrorNotice(message: error.localizedDescription)
                    case .success(let item):
                        NavigationLink {
                            NativeSettingValueEditor(path: path, schema: item, value: nil, addingToList: true)
                        } label: { Label("Add item", systemImage: "plus") }
                    }
                }
            } footer: {
                Text("Lists are saved as complete lists. Hidden credentials cannot be safely resent; protected list edits are rejected rather than overwritten.")
            }
        } else {
            NativeSettingValueEditor(path: path, schema: node, value: value)
        }
    }
}

private struct NativeSettingRow: View {
    let path: [String]
    let key: String
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: NativeServerSettingsStore
    private var authorized: Bool { model.isAdmin && model.api === store.api }

    var body: some View {
        if let draft = store.draft, let schema = store.schema {
            let value = draft.document.value(at: path)
            switch Result(catching: { try schema.node(at: path, values: draft.document) }) {
            case .failure(let error): ErrorNotice(message: error.localizedDescription)
            case .success(let node):
                let title = node["title"]?.string ?? NativeServerSettingsView.title(key)
                let readOnly = node["readOnly"]?.bool == true || path.contains("enabled_in_config")
                let kind = node["type"]?.string ?? value?.kind ?? "string"
                if readOnly {
                    LabeledContent(title, value: value?.fieldText ?? "Not reported")
                        .foregroundStyle(.secondary)
                } else if kind == "boolean" {
                    Toggle(isOn: Binding(
                        get: { value?.bool ?? node["default"]?.bool ?? false },
                        set: { store.set(.bool($0), path: path, authorized: authorized) }
                    )) {
                        fieldLabel(title, detail: node["description"]?.string)
                    }
                } else if kind == "object" || kind == "array" {
                    NavigationLink {
                        NativeSettingsNode(path: path, title: title)
                    } label: { fieldLabel(title, detail: value?.fieldText ?? "Configure") }
                } else {
                    NavigationLink {
                        NativeSettingValueEditor(path: path, schema: node, value: value)
                    } label: {
                        let change = NativeSettingChange(path: path, before: value, after: value ?? .null)
                        fieldLabel(title, detail: change.sensitive || node["writeOnly"]?.bool == true ? "Private value / unchanged until edited" :
                            String((value?.fieldText ?? node["default"]?.fieldText ?? "Inherited / default").prefix(100)))
                    }
                }
            }
        }
    }

    private func fieldLabel(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
        }
        .padding(.vertical, 4)
    }
}

private struct NativeSettingValueEditor: View {
    let path: [String]
    let schema: NativeSettingValue
    let value: NativeSettingValue?
    var addingToList = false
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: NativeServerSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selected = 0
    @State private var inherit = false
    @State private var boolValue = false
    @State private var error: String?
    private var sensitive: Bool {
        schema["writeOnly"]?.bool == true || NativeSettingChange(path: path, before: value, after: value ?? .null).sensitive
    }

    var body: some View {
        Form {
            Section {
                Text(schema["description"]?.string ?? "Edit this setting in the local draft.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let choices = schema["enum"]?.array {
                    Picker("Value", selection: $selected) {
                        ForEach(choices.indices, id: \.self) { Text(choices[$0].fieldText).tag($0) }
                    }
                } else if schema["type"]?.string == "boolean" {
                    Toggle("Value", isOn: $boolValue)
                } else if sensitive {
                    SecureField("New private value (leave unchanged by cancelling)", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                } else if ["object", "array"].contains(schema["type"]?.string ?? "") && addingToList {
                    Text("Add an empty draft item, then open it to fill in its settings. The server will reject incomplete required fields.")
                } else {
                    TextField("Value", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...12)
                        .privacySensitive()
                }
                if schema["_nativeNullable"]?.bool == true { Toggle("Use inherited / default value", isOn: $inherit) }
                if let min = schema["minimum"]?.numeric { LabeledContent("Minimum", value: String(min)) }
                if let max = schema["maximum"]?.numeric { LabeledContent("Maximum", value: String(max)) }
            }
            if let error { ErrorNotice(message: error) }
            Section {
                Button(addingToList ? "Add to draft" : "Use in draft", systemImage: "checkmark") { apply() }
                    .buttonStyle(HorizonButtonStyle())
                Text("This changes only your draft. Review and confirm before anything is sent to the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .horizonScreen()
        .navigationTitle(schema["title"]?.string ?? NativeServerSettingsView.title(path.last ?? "Setting"))
        .navigationBarBackButtonHidden(false)
        .onAppear {
            if !sensitive { text = value?.fieldText ?? schema["default"]?.fieldText ?? "" }
            boolValue = value?.bool ?? schema["default"]?.bool ?? false
            inherit = value == .null && schema["_nativeNullable"]?.bool == true
            if let choices = schema["enum"]?.array { selected = choices.firstIndex(of: value ?? .null) ?? 0 }
        }
        .onDisappear { text = "" }
    }

    private func apply() {
        do {
            guard model.isAdmin, model.api === store.api, store.draft != nil,
                  let resolver = store.schema else { throw HorizonError.message("The account changed. Reload settings.") }
            let schema = try resolver.resolved(schema, value: value)
            let candidate: NativeSettingValue
            if inherit { candidate = .null }
            else if let choices = schema["enum"]?.array {
                guard choices.indices.contains(selected) else { throw HorizonError.message("Choose a supported value.") }
                candidate = choices[selected]
            } else {
                switch schema["type"]?.string ?? value?.kind ?? "string" {
                case "integer":
                    guard let number = Int64(text) else { throw HorizonError.message("Enter a whole number.") }
                    candidate = .integer(number)
                case "number":
                    guard let number = Double(text), number.isFinite else { throw HorizonError.message("Enter a finite number.") }
                    candidate = .number(number)
                case "boolean": candidate = .bool(boolValue)
                case "object": candidate = .object([:])
                case "array": candidate = .array([])
                default:
                    guard !sensitive || !text.isEmpty else { throw HorizonError.message("Enter a new value or cancel to keep the current one.") }
                    candidate = .string(text)
                }
            }
            try resolver.validate(candidate, schema: schema)
            if addingToList { store.append(candidate, path: path, authorized: true) }
            else { store.set(candidate, path: path, authorized: true) }
            guard store.error == nil else { throw HorizonError.message(store.error ?? "Could not stage this setting.") }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct NativeSettingsReview: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: NativeServerSettingsStore
    @State private var confirmSave = false
    @State private var restart = false
    private var authorized: Bool { model.isAdmin && model.api === store.api }

    var body: some View {
        List {
            Section {
                Text("Only the changed fields below are sent. The server validates and merges them; unrelated settings and hidden credentials are not rewritten. Existing source is checked again before saving.")
                    .font(.footnote)
                Text("This is a client-side conflict check, not an atomic server revision/CAS guarantee.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.changes) { change in
                Section(change.id) {
                    LabeledContent("Running value", value: hideValue(change) ? "Hidden" : change.beforeSummary)
                    LabeledContent("New value", value: hideValue(change) ? "Hidden" : change.afterSummary)
                }
            }
            if let error = store.error { ErrorNotice(message: error) }
            if let message = store.message { Text(message) }
            Section {
                Button("Validate and save only") { restart = false; confirmSave = true }
                Button("Save and request server restart", role: .destructive) { restart = true; confirmSave = true }
                Button("Discard draft", role: .destructive) { store.discard() }
            }
            .disabled(store.changes.isEmpty || store.saving || !authorized)
            if store.saving { ProgressView("Saving reviewed changes") }
        }
        .navigationTitle("Review settings")
        .navigationBarBackButtonHidden(false)
        .horizonScreen()
        .confirmationDialog(restart ? "Save and restart the real server?" : "Save these server settings?",
            isPresented: $confirmSave, titleVisibility: .visible) {
            Button(restart ? "Save and restart" : "Validate and save", role: restart ? .destructive : nil) {
                Task { await store.save(restart: restart, scope: { authorized }) }
            }
        } message: {
            Text(restart ? "Live video and recordings may be interrupted. No other changes are included."
                : "This saves the configuration file. Running settings can remain unchanged until a restart.")
        }
    }

    private func hideValue(_ change: NativeSettingChange) -> Bool {
        guard !change.sensitive, let document = store.draft?.document, let schema = store.schema else { return true }
        do { return try schema.node(at: change.path, values: document)["writeOnly"]?.bool == true }
        catch { return true }
    }
}
