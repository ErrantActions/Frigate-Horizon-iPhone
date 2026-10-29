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
    private(set) var selection: LivePictureInPictureSelection?
    private var apiIdentity: ObjectIdentifier?
    private var playback: Task<Void, Never>?
    private var generation = UUID()
    private var viewers: [UUID: Bool] = [:]
    private var observations: Set<AnyCancellable> = []

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
        viewer: UUID, iceServers: [ICEServer]
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
        let changedSource = !matches(api: api, cameraID: cameraID, stream: stream, transport: transport) ||
            (transport != "webrtc" && selection?.muted != muted)
        if changedSource {
            if pip.owns(self) { pip.stop() }
            suspend()
            apiIdentity = ObjectIdentifier(api)
            failure = nil
            paused = false
        }
        selection = requested
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
        let token = UUID()
        generation = token
        let live = self.live, httpsLive = self.httpsLive
        // SwiftUI owns inline eligibility, not this task: cancelling/reparenting a view must not
        // cancel an explicitly authorized PiP session.
        playback = Task { [weak self] in
            if transport == "webrtc" {
                await live.run(api: api, stream: stream, iceServers: iceServers)
            } else {
                await httpsLive.run(api: api, stream: stream)
            }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            let message = (transport == "webrtc" ? live.error : httpsLive.error) ??
                "The live stream ended. Reconnect to resume playback."
            self.sourceFailed(message)
        }
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

    private func suspend() {
        generation = UUID()
        playback?.cancel()
        playback = nil
        live.stop()
        httpsLive.stop()
    }
}
