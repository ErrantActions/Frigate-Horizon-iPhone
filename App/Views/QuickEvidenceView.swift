import SwiftUI
import HorizonCore

struct QuickEvidenceView: View {
    let api: HorizonAPI
    let camera: HorizonCamera
    let anchorDate: Date?
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @StateObject private var capture = QuickEvidenceCoordinator()
    @StateObject private var transfer = MediaTransfer()
    @State private var preset = QuickEvidencePreset.lastThirtySeconds
    @State private var start: Date
    @State private var end: Date
    @State private var refresh = 0

    init(api: HorizonAPI, camera: HorizonCamera, anchorDate: Date? = nil) {
        self.api = api
        self.camera = camera
        self.anchorDate = anchorDate
        let end = anchorDate ?? Date()
        _start = State(initialValue: end.addingTimeInterval(-30))
        _end = State(initialValue: end)
    }

    private var allowed: Bool {
        model.api === api && model.cameras.contains { $0.id == camera.id }
    }

    private var accountKey: String {
        "\(ObjectIdentifier(api))-\(model.api.map { String(describing: ObjectIdentifier($0)) } ?? "none")-" +
        "\(model.profile?.username ?? "")-\(camera.id)"
    }

    private var assessment: Result<QuickEvidenceAssessment, Error>? {
        guard let coverage = capture.coverage else { return nil }
        return Result {
            try QuickEvidencePolicy.assess(coverage: coverage, preset: preset,
                selected: QuickEvidenceInterval(start: start.timeIntervalSince1970, end: end.timeIntervalSince1970),
                now: Date().timeIntervalSince1970, anchor: anchorDate?.timeIntervalSince1970)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HorizonHero(title: "Keep the evidence",
                        subtitle: "Create a persistent recording export from \(camera.name), then share or protect the finished file.",
                        systemImage: "square.and.arrow.down.on.square", eyebrow: "Quick capture")
                        .horizonHeroRow()
                }
                if !allowed {
                    Section { ErrorNotice(message: "This camera is not available for the current account.") }
                } else {
                    rangeSection
                    statusSection
                    if let message = capture.error { Section { ErrorNotice(message: message) } }
                    if let message = transfer.error { Section { ErrorNotice(message: message) } }
                }
            }
            .horizonScreen()
            .navigationTitle("Quick evidence")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(DeferNotificationNavigation())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: "\(accountKey)-\(allowed)-\(model.isAdmin)-\(scenePhase == .active)-\(refresh)") {
                guard allowed, scenePhase == .active else { capture.stop(); transfer.cancel(); return }
                let owner = model.profile?.username
                capture.activate(api: api, camera: camera.id, anchor: anchorDate,
                    context: accountKey, isAdmin: model.isAdmin,
                    access: { model.api === api && model.profile?.username == owner && model.cameras.contains { $0.id == camera.id } },
                    track: { model.trackExport($0) }, finish: { model.finishExport($0) })
            }
            .onChange(of: capture.coverage != nil) { _, available in
                if available, let result = assessment, case .success(let value) = result, preset != .selectedRange {
                    start = Date(timeIntervalSince1970: value.range.start)
                    end = Date(timeIntervalSince1970: value.range.end)
                }
            }
            .onChange(of: preset) { _, value in
                if value != .selectedRange, let result = assessment, case .success(let assessment) = result {
                    start = Date(timeIntervalSince1970: assessment.range.start)
                    end = Date(timeIntervalSince1970: assessment.range.end)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { capture.stop(); transfer.cancel() }
            }
            .onChange(of: accountKey) { _, _ in
                if !allowed { capture.stop() }
                transfer.cancel()
                transfer.dismissShare()
            }
            .onChange(of: allowed) { _, value in
                if !value { capture.stop(); transfer.cancel(); transfer.dismissShare() }
            }
            .onDisappear { capture.stop(); transfer.cancel() }
            .onChange(of: transfer.file?.id) { _, _ in
                if !allowed || scenePhase != .active { transfer.dismissShare() }
            }
            .sheet(item: Binding(get: { allowed && scenePhase == .active ? transfer.file : nil },
                set: { transfer.file = $0 }), onDismiss: transfer.dismissShare) { NativeShareSheet(file: $0.url) }
        }
    }

    private var rangeSection: some View {
        Section {
            if capture.loading { ProgressView("Checking actual recording availability") }
            Picker("Capture", selection: $preset) {
                ForEach(QuickEvidencePreset.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(capture.jobID != nil || capture.submitting || capture.submissionUncertain)
            if preset == .selectedRange {
                DatePicker("Start", selection: $start, in: ...(anchorDate ?? Date()))
                DatePicker("End", selection: $end, in: ...(anchorDate ?? Date()))
            }
            if let anchorDate {
                Text("Recording anchor: \(anchorDate.formatted(date: .abbreviated, time: .standard))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let assessment {
                switch assessment {
                case .success(let value):
                    LabeledContent("Latest recording end",
                        value: Date(timeIntervalSince1970: value.latestRecordingEnd).formatted(date: .abbreviated, time: .standard))
                    Text("\(date(value.range.start)) – \(date(value.range.end))")
                        .font(.callout.monospacedDigit())
                    if value.isStale {
                        Label("This is older footage, not the last moments of live video. Latest recording ended \(Int(value.ageSeconds / 60)) minutes ago.",
                            systemImage: "clock.badge.exclamationmark")
                            .font(.callout).foregroundStyle(HorizonPalette.warm)
                    }
                    if !value.gaps.isEmpty {
                        Label("Recording gaps — capture is unavailable for this range.", systemImage: "video.slash")
                            .foregroundStyle(HorizonPalette.warm)
                        ForEach(Array(value.gaps.prefix(5).enumerated()), id: \.offset) { _, gap in
                            Text("Missing: \(date(gap.start)) – \(date(gap.end))").font(.caption)
                        }
                        if value.gaps.count > 5 { Text("\(value.gaps.count - 5) additional gaps").font(.caption) }
                        Text("Choose a shorter fully recorded range. Missing time will not be silently stitched out.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if capture.jobID == nil {
                        Button("Save evidence export", systemImage: "film.stack") {
                            capture.queue(api: api, camera: camera, assessment: value)
                        }
                        .disabled(!value.canExport || capture.loading || capture.submitting || capture.submissionUncertain)
                    }
                case .failure(let error): ErrorNotice(message: error.localizedDescription)
                }
            }
            if capture.jobID == nil && !capture.submitting && !capture.submissionUncertain {
                Button("Refresh recording availability", systemImage: "arrow.clockwise") {
                    capture.refreshCoverage()
                    refresh += 1
                }
            }
        } header: {
            Text("Recorded range")
        } footer: {
            Text("Quick durations end at the latest indexed recording, not an assumed “now”. Selected ranges must be fully recorded and no longer than 24 hours. An export is a separate server file, independent of recording rotation; it is not automatically protected.")
        }
        .disabled(capture.jobID != nil || capture.submitting)
    }

    @ViewBuilder private var statusSection: some View {
        if capture.submitting || capture.jobID != nil || capture.submissionUncertain {
            Section("Evidence export") {
                if capture.submitting { ProgressView("Validating footage and queueing export") }
                if let range = capture.capturedRange {
                    Text("\(date(range.start)) – \(date(range.end))").font(.callout.monospacedDigit())
                }
                if let item = capture.export {
                    Label("Saved in Exports", systemImage: "checkmark.circle.fill")
                    Text(item.name).font(.headline)
                    Text("This export persists independently of the original recording retention window.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if transfer.downloading { ProgressView("Downloading authenticated export") }
                    Button("Download and share", systemImage: "square.and.arrow.up") {
                        do {
                            transfer.start(api: api, url: try api.address.mediaFile(item.videoPath, root: "exports"),
                                fileExtension: "mp4")
                        } catch { transfer.error = error.localizedDescription }
                    }
                    .disabled(transfer.downloading || scenePhase != .active)
                    if capture.protected {
                        Label("Protected", systemImage: "lock.shield.fill").foregroundStyle(HorizonPalette.accent)
                        Text("The server confirmed that this export was added to protected storage.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if capture.protecting { ProgressView("Protecting export") }
                        Button("Protect evidence", systemImage: "lock.shield") {
                            capture.protect(api: api, camera: camera.id, isAdmin: model.isAdmin)
                        }
                        .disabled(!model.isAdmin || !capture.protectionAvailable || capture.protecting || scenePhase != .active)
                        Text(capture.capabilityNotice ?? "Protection creates a server-managed protected copy. A bookmark is not protection.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if let job = capture.job {
                    Text(job.currentStep ?? job.status).font(.callout)
                    if let percent = job.progressPercent, percent.isFinite {
                        ProgressView(value: min(100, max(0, percent)), total: 100)
                            .accessibilityLabel("Evidence export progress")
                    } else if capture.polling { ProgressView("Processing export") }
                } else if capture.polling {
                    ProgressView("Waiting for export job")
                }
                if capture.jobID != nil && capture.export == nil && !capture.polling && !capture.submitting && !capture.terminalFailure {
                    Button("Check export status", systemImage: "arrow.clockwise") {
                        capture.retryPolling(api: api, camera: camera.id)
                    }
                }
                Text("Leaving this screen stops status checks, not the server export. Queued and finished files remain in Exports.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func date(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .standard)
    }
}
