import SwiftUI
import HorizonCore

@MainActor
final class QuickEvidenceCoordinator: ObservableObject {
    @Published private(set) var coverage: RecordingCoverage?
    @Published private(set) var loading = false
    @Published private(set) var submitting = false
    @Published private(set) var polling = false
    @Published private(set) var protecting = false
    @Published private(set) var jobID: String?
    @Published private(set) var job: MediaExportJob?
    @Published private(set) var export: MediaExport?
    @Published private(set) var capturedRange: QuickEvidenceInterval?
    @Published private(set) var protected = false
    @Published private(set) var protectedID: String?
    @Published private(set) var protectionAvailable = false
    @Published private(set) var capabilityNotice: String?
    @Published private(set) var error: String?
    @Published private(set) var submissionUncertain = false
    @Published private(set) var terminalFailure = false
    private var exportsStore = ExportsStore()
    private var context: String?
    private var generation = UUID()
    private var work: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var active = false
    private var access: (() -> Bool)?
    private var track: ((String) -> Void)?
    private var finish: ((String) -> Void)?

    func activate(
        api: HorizonAPI, camera: String, anchor: Date?, context: String, isAdmin: Bool,
        access: @escaping () -> Bool, track: @escaping (String) -> Void, finish: @escaping (String) -> Void
    ) {
        stop()
        if self.context != context {
            exportsStore = ExportsStore()
            coverage = nil
            jobID = nil
            job = nil
            export = nil
            capturedRange = nil
            protected = false
            protectedID = nil
            terminalFailure = false
            submissionUncertain = false
            error = nil
        }
        self.context = context
        self.access = access
        self.track = track
        self.finish = finish
        guard access() else { error = "This camera is no longer available for the current account."; return }
        active = true
        let token = generation
        loading = true
        protectionAvailable = false
        if jobID == nil && !submissionUncertain {
            coverage = nil
            error = nil
        } else if jobID != nil && export == nil && !terminalFailure { error = nil }
        work = Task { [weak self] in
            guard let self else { return }
            if self.coverage == nil {
                do {
                    let result: RecordingCoverage = try await api.get([camera, "recordings", "coverage"], query: [
                        URLQueryItem(name: "after", value: "0"),
                        URLQueryItem(name: "before", value: String(min(Date().timeIntervalSince1970,
                            anchor?.timeIntervalSince1970 ?? Date().timeIntervalSince1970))),
                    ])
                    guard self.valid(token) else { return }
                    self.coverage = result
                } catch {
                    guard self.valid(token) else { return }
                    self.error = "Recording availability could not be checked: \(error.localizedDescription)"
                }
            }
            guard self.valid(token) else { return }
            do {
                let features: QuickEvidenceNativeFeatures = try await api.get(["native", "features"])
                guard self.valid(token) else { return }
                self.protectionAvailable = isAdmin && features.exportProtection
                self.capabilityNotice = !isAdmin ? "Only administrators can protect exports." :
                    features.exportProtection ? nil : "This server does not advertise export protection."
            } catch {
                guard self.valid(token) else { return }
                self.protectionAvailable = false
                self.capabilityNotice = "Export protection is unavailable: \(error.localizedDescription)"
            }
            self.loading = false
            if self.valid(token), self.jobID != nil, self.export == nil, !self.terminalFailure {
                await self.poll(api: api, camera: camera, token: token)
            }
        }
    }

    func queue(api: HorizonAPI, camera: HorizonCamera, assessment: QuickEvidenceAssessment) {
        guard active, access?() == true, !loading, !submitting, jobID == nil, !submissionUncertain else { return }
        guard assessment.canExport else {
            error = "The selected range contains recording gaps. Choose a fully recorded range before exporting."
            return
        }
        work?.cancel()
        error = nil
        submitting = true
        let token = generation
        let selected = assessment.range
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.submitting = false } }
            do {
                // Rotation may have removed footage since the availability screen was loaded.
                let fresh: RecordingCoverage = try await api.get([camera.id, "recordings", "coverage"], query: [
                    URLQueryItem(name: "after", value: String(selected.start)),
                    URLQueryItem(name: "before", value: String(selected.end)),
                ])
                guard self.valid(token) else { return }
                let checked = try QuickEvidencePolicy.assess(coverage: fresh, preset: .selectedRange,
                    selected: selected, now: Date().timeIntervalSince1970)
                guard checked.canExport else {
                    throw HorizonError.message("Some selected recordings are now unavailable. Refresh availability and choose a complete range.")
                }
                self.submissionUncertain = true
                let name = String("\(camera.name) evidence \(Date(timeIntervalSince1970: selected.start).formatted(date: .numeric, time: .standard))".prefix(256))
                let result: APIActionResult = try await api.send(
                    ["export", camera.id, "start", String(selected.start), "end", String(selected.end)],
                    body: CreateExportBody(name: name, stream: "auto", timestamp: "none", metadataCategories: [])
                )
                guard self.valid(token) else { return }
                if !result.success {
                    self.submissionUncertain = false
                    try result.requireSuccess()
                }
                guard let id = result.exportID, !id.isEmpty else {
                    throw HorizonError.message("The server accepted the request without a job ID. Check Exports before creating another capture.")
                }
                self.submissionUncertain = false
                self.jobID = id
                self.capturedRange = selected
                self.track?(id)
                self.submitting = false
                await self.poll(api: api, camera: camera.id, token: token)
            } catch {
                guard self.valid(token) else { return }
                self.error = error.localizedDescription + (self.submissionUncertain
                    ? " The server may still have queued this export. Check Exports before retrying." : "")
            }
        }
    }

    func protect(api: HorizonAPI, camera: String, isAdmin: Bool) {
        guard valid(generation), !protecting, !protected,
              QuickEvidencePolicy.canProtect(isAdmin: isAdmin, capability: protectionAvailable, readyExport: export != nil),
              let export, export.camera == camera else { return }
        protecting = true
        error = nil
        let token = generation
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.protecting = false } }
            do {
                let features: QuickEvidenceNativeFeatures = try await api.get(["native", "features"])
                guard self.valid(token) else { return }
                guard features.exportProtection else {
                    self.protectionAvailable = false
                    throw HorizonError.message("This server no longer permits export protection.")
                }
                let result: QuickEvidenceProtectionResult = try await api.send(
                    ["exports", export.id, "protect"], body: [String: String]())
                guard self.valid(token) else { return }
                try result.requireSuccess()
                self.protected = true
                self.protectedID = result.protectedID
            } catch {
                guard self.valid(token) else { return }
                self.error = "Protection was not confirmed: \(error.localizedDescription)"
            }
        }
    }

    func retryPolling(api: HorizonAPI, camera: String) {
        guard valid(generation), jobID != nil, export == nil, !terminalFailure, !polling else { return }
        error = nil
        let token = generation
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            await self.poll(api: api, camera: camera, token: token)
        }
    }

    func refreshCoverage() {
        coverage = nil
        error = nil
    }

    func stop() {
        if protecting && !protected {
            error = "Protection confirmation was interrupted. Check protected media or retry; protection has not been confirmed on this screen."
        }
        active = false
        generation = UUID()
        work?.cancel()
        operation?.cancel()
        work = nil
        operation = nil
        loading = false
        submitting = false
        polling = false
        protecting = false
        protectionAvailable = false
        if submissionUncertain {
            error = "Export submission was interrupted. The server may still be processing it; check Exports before creating another capture."
        }
        access = nil
        track = nil
        finish = nil
    }

    private func valid(_ token: UUID) -> Bool {
        active && generation == token && !Task.isCancelled && access?() == true
    }

    private func poll(api: HorizonAPI, camera: String, token: UUID) async {
        guard let id = jobID, valid(token) else { return }
        polling = true
        defer { if generation == token { polling = false } }
        let deadline = Date().addingTimeInterval(40 * 60)
        var terminalSince: Date?
        repeat {
            await exportsStore.load(api: api, trackedIDs: [id])
            guard valid(token) else { return }
            if let item = exportsStore.exports.first(where: { $0.id == id && $0.camera == camera && !$0.inProgress }) {
                export = item
                finish?(id)
                error = nil
                return
            }
            if let failure = exportsStore.error { error = failure; return }
            let current = exportsStore.jobs.first { $0.id == id }
                ?? exportsStore.finishedJobs.first { $0.id == id }
            if let current {
                guard current.camera == camera else {
                    error = "The export job no longer belongs to this camera."
                    return
                }
                job = current
                if !["queued", "running"].contains(current.status) {
                    if current.errorMessage != nil || ["failed", "cancelled", "canceled"].contains(current.status) {
                        terminalFailure = true
                        error = current.errorMessage ?? "The export \(current.status). No evidence file was confirmed."
                        finish?(id)
                        return
                    }
                    if terminalSince == nil { terminalSince = Date() }
                }
            }
            if let terminalSince, Date().timeIntervalSince(terminalSince) > 30 {
                error = "The job finished but its export file is not available yet. Check Exports or retry the status check."
                return
            }
            if Date() > deadline {
                error = "The export is taking longer than expected. It remains on the server; retry the status check or open Exports."
                return
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        } while valid(token)
    }
}
