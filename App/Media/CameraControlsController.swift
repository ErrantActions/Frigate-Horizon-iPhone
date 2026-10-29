import Foundation
import Combine
import HorizonCore

@MainActor
final class CameraControlsController: ObservableObject {
    @Published private(set) var capabilities: CameraControlCapabilities?
    @Published private(set) var error: String?
    @Published private(set) var holdingCommand: CameraPTZCommand?
    @Published private(set) var isLoading = false

    private var api: HorizonAPI?
    private var cameraID: String?
    private var context = UUID()
    private var lease = CameraPTZLease()
    private var heartbeat: Task<Void, Never>?
    private var requests: [UUID: Task<Void, Never>] = [:]
    @Published private var stoppingLeases = Set<UUID>()
    @Published private var stopFailed = false

    var canStart: Bool { capabilities != nil && error == nil && stoppingLeases.isEmpty && !stopFailed }
    var isStopping: Bool { !stoppingLeases.isEmpty }

    func run(api: HorizonAPI, cameraID: String) async {
        invalidate()
        self.api = api
        self.cameraID = cameraID
        let token = context
        isLoading = true
        defer { if context == token { isLoading = false } }
        await withTaskCancellationHandler {
            do {
                let path = try CameraControlRoute.prefix(cameraID: cameraID)
                while !Task.isCancelled && context == token {
                    let result: CameraControlCapabilities = try await api.get(path)
                    try Task.checkCancellation()
                    guard context == token else { return }
                    try result.validate(cameraID: cameraID)
                    if let capabilities, result != capabilities { stopMotion() }
                    capabilities = result
                    isLoading = false
                    try await Task.sleep(for: .seconds(10))
                }
            } catch {
                guard context == token, !Task.isCancelled else { return }
                fail("Camera controls unavailable: \(error.localizedDescription)")
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.context == token else { return }
                self.invalidate()
            }
        }
    }

    func begin(_ command: CameraPTZCommand, preset: String? = nil) {
        guard canStart, lease.id == nil, let api, let cameraID, let capabilities else { return }
        let token = lease.begin(now: ProcessInfo.processInfo.systemUptime)
        do {
            let request = try CameraPTZRequest(command: command, leaseID: token, preset: preset,
                capabilities: capabilities, cameraID: cameraID)
            holdingCommand = command
            send(request, api: api, cameraID: cameraID)
            heartbeat = Task { [weak self] in
                var lastRenewal = ProcessInfo.processInfo.systemUptime
                var nextRenewal = lastRenewal + CameraPTZLease.renewalInterval
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let self, self.lease.id == token else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard self.lease.canRenew(token, now: now) else {
                        self.fail("PTZ stopped because the server did not acknowledge the hold lease in time.")
                        return
                    }
                    if now >= nextRenewal {
                        guard now - lastRenewal <= 0.25 else {
                            self.fail("PTZ stopped because the hold heartbeat was interrupted. Release and reload controls.")
                            return
                        }
                        guard self.requests.count < 3 else {
                            self.fail("PTZ stopped because control requests were delayed. Check your connection and reload controls.")
                            return
                        }
                        self.send(request, api: api, cameraID: cameraID)
                        lastRenewal = now
                        nextRenewal = now + CameraPTZLease.renewalInterval
                    }
                }
            }
        } catch {
            lease.end()
            self.error = error.localizedDescription
        }
    }

    func end(_ command: CameraPTZCommand) {
        if holdingCommand == command { stopMotion() }
    }

    func stopMotion() {
        heartbeat?.cancel()
        heartbeat = nil
        holdingCommand = nil
        for task in requests.values { task.cancel() }
        requests.removeAll()
        guard let token = lease.end(), let api, let cameraID else { return }
        let stopContext = context
        stoppingLeases.insert(token)
        // This bounded cleanup deliberately outlives the initiating view's task.
        Task { [weak self] in
            do {
                let result: APIActionResult = try await api.send(
                    CameraControlRoute.ptz(cameraID: cameraID),
                    body: CameraPTZRequest.stop(leaseID: token))
                try result.requireSuccess()
                self?.stoppingLeases.remove(token)
            } catch {
                self?.stoppingLeases.remove(token)
                guard let self, self.context == stopContext else { return }
                self.stopFailed = true
                self.error = "Could not confirm PTZ stop. The server's 500 ms deadman must stop the camera. \(error.localizedDescription)"
            }
        }
    }

    func invalidate() {
        stopMotion()
        context = UUID()
        api = nil
        cameraID = nil
        capabilities = nil
        error = nil
        isLoading = false
        // A failed STOP requires a fresh capabilities request before another hold.
        stopFailed = false
    }

    private func send(_ body: CameraPTZRequest, api: HorizonAPI, cameraID: String) {
        let requestID = UUID()
        requests[requestID] = Task { [weak self] in
            do {
                let result: APIActionResult = try await api.send(
                    CameraControlRoute.ptz(cameraID: cameraID), body: body)
                try result.requireSuccess()
                guard let self, self.lease.id == body.leaseID, !Task.isCancelled else { return }
                self.requests.removeValue(forKey: requestID)
                guard self.lease.acknowledge(body.leaseID, now: ProcessInfo.processInfo.systemUptime) else {
                    self.fail("PTZ stopped after a late server acknowledgement. Release and reload controls.")
                    return
                }
            } catch {
                guard let self, self.lease.id == body.leaseID, !Task.isCancelled else { return }
                self.requests.removeValue(forKey: requestID)
                self.fail("PTZ stopped: \(error.localizedDescription)")
            }
        }
    }

    private func fail(_ message: String) {
        stopMotion()
        capabilities = nil
        error = message
    }
}
