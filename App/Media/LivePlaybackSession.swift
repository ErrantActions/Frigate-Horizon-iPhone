import Combine
import AVFoundation
import Foundation
import HorizonCore

struct LivePictureInPictureSelection: Equatable {
    let cameraID: String
    let stream: String
    let transport: String
    let muted: Bool
}

@MainActor
final class LivePlaybackAttachment: ObservableObject {
    @Published private(set) var session = LivePlaybackSession()
    private var observation: AnyCancellable?

    init() { observeSession() }

    func adoptRetainedSession(
        api: HorizonAPI, cameraID: String, stream: String?, transport: String,
        enabled: Bool, viewer: UUID
    ) {
        guard enabled, let retained = LivePictureInPictureController.shared.retainedSession(
            api: api, cameraID: cameraID, stream: stream, transport: transport
        ), retained !== session else { return }
        session.detach(viewer)
        observation = nil
        session = retained
        observeSession()
        retained.attach(viewer)
    }

    private func observeSession() {
        observation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}

@MainActor
final class LivePlaybackSession: ObservableObject {
    let live = LiveStream()
    let httpsLive = HTTPSLiveStream()
    let webRTCPiPRenderer = LivePiPVideoRenderer(displayLayer: AVSampleBufferDisplayLayer())
    @Published var pictureInPictureError: String?
    @Published private(set) var failure: String?
    @Published private(set) var paused = false
    @Published private(set) var selection: LivePictureInPictureSelection?
    private var apiIdentity: ObjectIdentifier?
    private var playback: Task<Void, Never>?
    private var generation = UUID()
    private var viewers: [UUID: Bool] = [:]
    private var observations: Set<AnyCancellable> = []
    private var requestedSelection: LivePictureInPictureSelection?
    private var qualityPlan: LiveAdaptiveQualityPlan?
    private var qualityState: LiveAdaptiveQualityState?
    private var adaptation: Task<Void, Never>?

    init() {
        live.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
        httpsLive.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    var resolution: CGSize? { selection?.transport == "webrtc" ? live.resolution : httpsLive.resolution }
    var error: String? { failure ?? (selection?.transport == "webrtc" ? live.error : httpsLive.error) }
    var hasInlineViewer: Bool { viewers.values.contains(true) }
    var isRunning: Bool { playback != nil }

    func matches(api: HorizonAPI, cameraID: String, stream: String?, transport: String) -> Bool {
        apiIdentity == ObjectIdentifier(api) && selection?.cameraID == cameraID &&
            selection?.stream == stream && selection?.transport == transport
    }

    func belongs(to api: HorizonAPI, allowedCameraIDs: Set<String>) -> Bool {
        apiIdentity == ObjectIdentifier(api) && selection.map { allowedCameraIDs.contains($0.cameraID) } == true
    }

    func attach(_ viewer: UUID) {
        if viewers[viewer] == nil { viewers[viewer] = false }
    }

    func detach(_ viewer: UUID) {
        viewers.removeValue(forKey: viewer)
        stopIfNoOwner()
    }

    func deactivateInlineViewer(_ viewer: UUID) {
        viewers[viewer] = false
        stopIfNoOwner()
    }

    private func stopIfNoOwner() {
        if !hasInlineViewer && !LivePictureInPictureController.shared.isPlaying(self) {
            if LivePictureInPictureController.shared.owns(self) {
                LivePictureInPictureController.shared.stop()
            } else {
                suspend()
            }
        }
    }

    func configure(
        api: HorizonAPI, cameraID: String, stream: String?, transport: String,
        muted: Bool, cameraEnabled: Bool, active: Bool, visible: Bool, foreground: Bool,
        viewer: UUID, iceServers: [ICEServer], adaptiveQuality: LiveAdaptiveQualityPlan? = nil
    ) {
        let pip = LivePictureInPictureController.shared
        let authorized = pip.permitsInlinePlayback(api: api, cameraID: cameraID)
        viewers[viewer] = active && visible && foreground && authorized && cameraEnabled
        guard authorized, cameraEnabled, let stream else {
            if pip.owns(self) { pip.stop() }
            suspend()
            return
        }
        let requested = LivePictureInPictureSelection(
            cameraID: cameraID, stream: stream, transport: transport, muted: muted
        )
        let retainedPiP = pip.owns(self) && apiIdentity == ObjectIdentifier(api)
            && selection?.cameraID == cameraID && selection?.transport == transport
            && (selection?.stream == stream || requestedSelection?.stream == stream)
        let changedSource = (transport != "webrtc" && selection?.muted != muted) ||
            (!retainedPiP && (apiIdentity != ObjectIdentifier(api)
                || requestedSelection?.cameraID != cameraID || requestedSelection?.stream != stream
                || requestedSelection?.transport != transport || qualityPlan != adaptiveQuality))
        if changedSource {
            if pip.owns(self) { pip.stop() }
            suspend()
            apiIdentity = ObjectIdentifier(api)
            failure = nil
            paused = false
        }
        if !retainedPiP {
            requestedSelection = requested
            qualityPlan = adaptiveQuality
        }
        let selectedStream = changedSource ? (qualityPlan?.startupStream ?? stream) : (selection?.stream ?? stream)
        selection = LivePictureInPictureSelection(
            cameraID: cameraID, stream: selectedStream, transport: transport, muted: muted
        )
        live.muted = muted
        httpsLive.muted = muted
        let mayPlay = LivePiPPlaybackPolicy.mayKeepPlaying(
            accountAuthorized: authorized, cameraEnabled: cameraEnabled, hasStream: true,
            foreground: hasInlineViewer, visible: hasInlineViewer, active: hasInlineViewer,
            pictureInPictureActive: pip.isPlaying(self)
        )
        guard mayPlay else {
            if pip.owns(self) { pip.stop() }
            else { suspend() }
            return
        }
        guard playback == nil, !paused, failure == nil else { return }
        if let qualityPlan, qualityState == nil {
            qualityState = LiveAdaptiveQualityState(plan: qualityPlan, now: ProcessInfo.processInfo.systemUptime)
            selection = LivePictureInPictureSelection(
                cameraID: cameraID, stream: qualityPlan.startupStream, transport: transport, muted: muted
            )
        }
        startPlayback(api: api, iceServers: iceServers)
    }

    private func startPlayback(api: HorizonAPI, iceServers: [ICEServer]) {
        guard let selection else { return }
        let stream = selection.stream, transport = selection.transport
        let token = UUID()
        generation = token
        let live = self.live, httpsLive = self.httpsLive
        let trackActivity = qualityPlan != nil
        // SwiftUI owns inline eligibility, not this task: cancelling/reparenting a view must not
        // cancel an explicitly authorized PiP session.
        playback = Task { [weak self] in
            if transport == "webrtc" {
                await live.run(api: api, stream: stream, iceServers: iceServers, trackActivity: trackActivity)
            } else {
                await httpsLive.run(api: api, stream: stream)
            }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            if transport != "webrtc", httpsLive.capacityLimited, self.hasInlineViewer,
               !LivePictureInPictureController.shared.owns(self),
               LivePictureInPictureController.shared.permitsInlinePlayback(api: api, cameraID: selection.cameraID),
               let stream = self.qualityState?.reduceQuality(now: ProcessInfo.processInfo.systemUptime) {
                self.switchQuality(to: stream, api: api, iceServers: iceServers)
                return
            }
            let message = (transport == "webrtc" ? live.error : httpsLive.error) ??
                "The live stream ended. Reconnect to resume playback."
            self.sourceFailed(message)
        }
        guard qualityPlan != nil else { return }
        adaptation = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard let self, self.generation == token else { return }
                let pip = LivePictureInPictureController.shared
                let now = ProcessInfo.processInfo.systemUptime
                let lastFrame = transport == "webrtc" ? live.lastVideoReceivedUptime : httpsLive.lastVideoReceivedUptime
                let frozen = !self.hasInlineViewer || pip.owns(self)
                    || !pip.permitsInlinePlayback(api: api, cameraID: selection.cameraID)
                if let stream = self.qualityState?.observe(now: now, frameAge: lastFrame.map { now - $0 },
                    videoReady: self.resolution != nil,
                    bufferedVideoDuration: transport == "webrtc" ? nil : httpsLive.bufferedVideoDuration,
                    restrictedNetwork: LiveNetworkConditions.shared.restricted,
                    frozen: frozen) {
                    self.switchQuality(to: stream, api: api, iceServers: iceServers)
                    return
                }
            }
        }
    }

    private func switchQuality(to stream: String, api: HorizonAPI, iceServers: [ICEServer]) {
        guard let current = selection, stream != current.stream else { return }
        suspend(preservingQuality: true)
        selection = LivePictureInPictureSelection(
            cameraID: current.cameraID, stream: stream, transport: current.transport, muted: current.muted
        )
        failure = nil
        startPlayback(api: api, iceServers: iceServers)
    }

    func reconnect() {
        if LivePictureInPictureController.shared.owns(self) { LivePictureInPictureController.shared.stop() }
        suspend()
        failure = nil
        paused = false
        pictureInPictureError = nil
    }

    func sourceFailed(_ message: String) {
        failure = message
        if LivePictureInPictureController.shared.owns(self) {
            LivePictureInPictureController.shared.sourceFailed(self, message: message)
        } else {
            suspend()
        }
    }

    func pictureInPictureEnded(keepInlinePlayback: Bool) {
        guard keepInlinePlayback, hasInlineViewer else {
            paused = true
            suspend()
            return
        }
    }

    private func suspend(preservingQuality: Bool = false) {
        generation = UUID()
        adaptation?.cancel()
        adaptation = nil
        if !preservingQuality { qualityState = nil }
        playback?.cancel()
        playback = nil
        live.stop()
        httpsLive.stop()
    }
}
