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
    let hlsLive = HLSLiveStream()
    let webRTCPiPRenderer = LivePiPVideoRenderer(displayLayer: AVSampleBufferDisplayLayer())
    @Published var pictureInPictureError: String?
    @Published private(set) var failure: String?
    @Published private(set) var paused = false
    @Published private(set) var selection: LivePictureInPictureSelection?
    @Published private(set) var usesLiveHLS = false
    @Published private(set) var compatibilityNotice: String?
    @Published private(set) var needsReauthentication = false
    private(set) var liveHLSConfiguration: LiveHLSConfiguration?
    private var apiIdentity: ObjectIdentifier?
    private var playback: Task<Void, Never>?
    private var generation = UUID()
    private var viewers: [UUID: Bool] = [:]
    private var observations: Set<AnyCancellable> = []
    private var requestedSelection: LivePictureInPictureSelection?
    private var qualityPlan: LiveAdaptiveQualityPlan?
    private var qualityState: LiveAdaptiveQualityState?
    private var adaptation: Task<Void, Never>?
    private var hlsUnsupported = false

    init() {
        live.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
        httpsLive.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
        hlsLive.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    var resolution: CGSize? {
        usesLiveHLS ? hlsLive.resolution : (selection?.transport == "webrtc" ? live.resolution : httpsLive.resolution)
    }
    var error: String? {
        failure ?? (usesLiveHLS ? hlsLive.error : (selection?.transport == "webrtc" ? live.error : httpsLive.error))
    }
    var status: String {
        liveHLSConfiguration != nil && compatibilityNotice == nil ? hlsLive.status : httpsLive.status
    }
    var hasInlineViewer: Bool { viewers.values.contains(true) }
    var isRunning: Bool { playback != nil }

    func matches(api: HorizonAPI, cameraID: String, stream: String?, transport: String) -> Bool {
        apiIdentity == ObjectIdentifier(api) && selection?.cameraID == cameraID &&
            (selection?.stream == (stream ?? "") || (usesLiveHLS && requestedSelection?.stream == (stream ?? "")))
            && selection?.transport == transport
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
        viewer: UUID, iceServers: [ICEServer], adaptiveQuality: LiveAdaptiveQualityPlan? = nil,
        liveHLS: LiveHLSConfiguration? = nil
    ) {
        let pip = LivePictureInPictureController.shared
        let authorized = pip.permitsInlinePlayback(api: api, cameraID: cameraID)
        viewers[viewer] = active && visible && foreground && authorized && cameraEnabled
        guard authorized, cameraEnabled, stream != nil || liveHLS != nil else {
            if pip.owns(self) { pip.stop() }
            suspend()
            return
        }
        let stream = stream ?? ""
        let requested = LivePictureInPictureSelection(
            cameraID: cameraID, stream: stream, transport: transport, muted: muted
        )
        let retainedPiP = pip.owns(self) && apiIdentity == ObjectIdentifier(api)
            && selection?.cameraID == cameraID && selection?.transport == transport
            && (selection?.stream == stream || requestedSelection?.stream == stream)
        let changedSource = (transport != "webrtc" && !usesLiveHLS && selection?.muted != muted)
            || liveHLSConfiguration != liveHLS ||
            (!retainedPiP && (apiIdentity != ObjectIdentifier(api)
                || requestedSelection?.cameraID != cameraID || requestedSelection?.stream != stream
                || requestedSelection?.transport != transport || qualityPlan != adaptiveQuality))
        if changedSource {
            if pip.owns(self) { pip.stop() }
            suspend()
            apiIdentity = ObjectIdentifier(api)
            failure = nil
            needsReauthentication = false
            paused = false
            compatibilityNotice = nil
        }
        if !retainedPiP {
            requestedSelection = requested
            qualityPlan = adaptiveQuality
            liveHLSConfiguration = liveHLS
        }
        let selectedStream = changedSource ? stream : (selection?.stream ?? stream)
        selection = LivePictureInPictureSelection(
            cameraID: cameraID, stream: selectedStream, transport: transport, muted: muted
        )
        live.muted = muted
        httpsLive.muted = muted
        hlsLive.muted = muted
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
        startPlayback(api: api, iceServers: iceServers)
    }

    private func startPlayback(api: HorizonAPI, iceServers: [ICEServer]) {
        guard let selection else { return }
        let transport = selection.transport
        let token = UUID()
        generation = token
        let live = self.live, httpsLive = self.httpsLive
        // SwiftUI owns inline eligibility, not this task: cancelling/reparenting a view must not
        // cancel an explicitly authorized PiP session.
        playback = Task { [weak self] in
            guard let self else { return }
            if transport == "https", !self.hlsUnsupported, let configuration = self.liveHLSConfiguration {
                do {
                    if try await self.hlsLive.prepare(api: api, camera: selection.cameraID, configuration: configuration) {
                        guard self.generation == token, !Task.isCancelled else { self.hlsLive.stop(); return }
                        self.usesLiveHLS = true
                        await self.hlsLive.run()
                        guard self.generation == token, !Task.isCancelled else { return }
                        self.sourceFailed(self.hlsLive.error ?? "Live HLS ended. Reconnect to retry.",
                            authenticationRequired: self.hlsLive.needsReauthentication)
                        return
                    }
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.hlsUnsupported = true
                    self.compatibilityNotice = self.hlsLive.status
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.sourceFailed(self.hlsLive.error ?? error.localizedDescription,
                        authenticationRequired: LiveHLSGate.requiresReauthentication(error))
                    return
                }
            }
            guard !selection.stream.isEmpty else {
                self.sourceFailed("Live HLS is unavailable and no compatibility stream is configured.")
                return
            }
            if let plan = self.qualityPlan, self.qualityState == nil {
                self.qualityState = LiveAdaptiveQualityState(plan: plan, now: ProcessInfo.processInfo.systemUptime)
                self.selection = LivePictureInPictureSelection(cameraID: selection.cameraID,
                    stream: plan.startupStream, transport: transport, muted: selection.muted)
            }
            let stream = self.selection?.stream ?? selection.stream
            self.startCompatibilityAdaptation(api: api, iceServers: iceServers, token: token)
            if transport == "webrtc" {
                await live.run(api: api, stream: stream, iceServers: iceServers, trackActivity: self.qualityPlan != nil)
            } else {
                await httpsLive.run(api: api, stream: stream)
            }
            guard self.generation == token, !Task.isCancelled else { return }
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
    }

    private func startCompatibilityAdaptation(api: HorizonAPI, iceServers: [ICEServer], token: UUID) {
        guard let selection else { return }
        let transport = selection.transport
        let live = self.live, httpsLive = self.httpsLive
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
        needsReauthentication = false
        paused = false
        pictureInPictureError = nil
    }

    func sourceFailed(_ message: String, authenticationRequired: Bool = false) {
        failure = message
        needsReauthentication = authenticationRequired
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
        if !preservingQuality {
            qualityState = nil
            hlsUnsupported = false
            compatibilityNotice = nil
        }
        playback?.cancel()
        playback = nil
        live.stop()
        httpsLive.stop()
        hlsLive.stop()
        usesLiveHLS = false
    }
}
