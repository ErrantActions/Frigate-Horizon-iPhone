import SwiftUI
import AVFoundation
import HorizonCore

@MainActor
final class HLSLiveStream: ObservableObject {
    let player = AVPlayer()
    let playerLayer: AVPlayerLayer
    @Published private(set) var resolution: CGSize?
    @Published private(set) var error: String?
    @Published private(set) var status = "Checking live HLS"
    private(set) var lastVideoReceivedAt: Date?
    var muted = true {
        didSet { player.isMuted = muted }
    }
    private var generation = UUID()
    private var client: AuthenticatedLiveHLSClient?
    private var source: AuthenticatedLiveHLSAsset?
    private var master: LiveHLSMaster?
    private var observations: [NSKeyValueObservation] = []
    private var failureObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var startup: Task<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    private var startupPolicy: LiveHLSStartupPolicy?
    private var lastPosition: Double?
    private var lastProgress = Date()

    init() {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
    }

    func prepare(api: HorizonAPI, camera: String, configuration: LiveHLSConfiguration) async throws -> Bool {
        stop()
        let token = generation
        status = "Checking live HLS support"
        let policy = try LiveHLSResourcePolicy(address: api.address, camera: camera)
        startup = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == token, self.resolution == nil else { return }
            self.fail("Live HLS did not produce video in time. Reconnect to retry.")
        }
        do {
            let capability: LiveHLSStatus
            do { capability = try await api.get([camera, "live", "hls", "status"]) }
            catch {
                if let failure = error as? HorizonError, let code = failure.httpStatusCode,
                   LiveHLSGate.isUnsupportedHTTP(code) {
                    startup?.cancel(); startup = nil
                    status = "Live HLS is unsupported; using compatibility HTTPS"
                    return false
                }
                throw error
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            guard capability.isAvailable else {
                startup?.cancel(); startup = nil
                status = "Live HLS is unavailable; using compatibility HTTPS"
                return false
            }
            _ = try policy.masterURL(capability.playlist)
            status = "Opening authenticated live HLS"
            let client = AuthenticatedLiveHLSClient(policy: policy, cookies: api.cookies,
                maximumHeight: configuration.maximumHeight)
            self.client = client
            let master = try await client.prepareMaster()
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            self.master = master
            source = try AuthenticatedLiveHLSAsset(client: client)
            source?.onFailure = { [weak self] failure in
                guard let self, self.generation == token else { return }
                self.fail(failure.localizedDescription)
            }
            return true
        } catch {
            client?.invalidate()
            client = nil
            startup?.cancel()
            startup = nil
            throw error
        }
    }

    func run() async {
        let token = generation
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard let source, let master else {
                    error = "No authenticated live HLS source is prepared."
                    continuation.resume()
                    return
                }
                completion = continuation
                do {
                    if !CameraTalkbackController.microphoneInUse {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                        try AVAudioSession.sharedInstance().setActive(true)
                    }
                    let item = AVPlayerItem(asset: source.asset)
                    startupPolicy = LiveHLSStartupPolicy(lowestBandwidth: master.lowestBandwidth)
                    item.preferredPeakBitRate = Double(master.lowestBandwidth)
                    item.preferredForwardBufferDuration = 1
                    player.isMuted = muted
                    observations = [
                        item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                            Task { @MainActor in
                                guard let self, self.generation == token, self.player.currentItem === item else { return }
                                if item.status == .readyToPlay { self.player.play() }
                                else if item.status == .failed {
                                    self.fail(item.error?.localizedDescription ?? "Live HLS playback failed.")
                                }
                            }
                        },
                        playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                            Task { @MainActor in self?.updateVideo(token: token) }
                        },
                        item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
                            Task { @MainActor in self?.updateVideo(token: token) }
                        },
                    ]
                    failureObserver = NotificationCenter.default.addObserver(
                        forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
                    ) { [weak self] notification in
                        let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                            .localizedDescription ?? "Live HLS stopped unexpectedly."
                        Task { @MainActor in
                            guard let self, self.generation == token else { return }
                            self.fail(message)
                        }
                    }
                    player.replaceCurrentItem(with: item)
                    lastProgress = Date()
                    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                        queue: .main) { [weak self] time in
                        Task { @MainActor in
                            guard let self, self.generation == token, self.player.currentItem === item else { return }
                            self.updateVideo(token: token)
                            let playing = self.player.timeControlStatus == .playing
                            if time.seconds.isFinite, self.resolution != nil, playing,
                               self.lastPosition.map({ abs(time.seconds - $0) > 0.001 }) ?? true {
                                self.lastPosition = time.seconds
                                self.lastVideoReceivedAt = Date()
                                self.lastProgress = Date()
                            }
                            let ahead = item.loadedTimeRanges.compactMap { value -> Double? in
                                let range = value.timeRangeValue
                                guard CMTimeRangeContainsTime(range, time: time) else { return nil }
                                let remaining = CMTimeRangeGetEnd(range).seconds - time.seconds
                                return remaining.isFinite ? max(0, remaining) : nil
                            }.max() ?? 0
                            self.startupPolicy?.observe(now: ProcessInfo.processInfo.systemUptime,
                                decodedVideo: self.resolution != nil, bufferedAhead: ahead,
                                playing: playing && !item.isPlaybackBufferEmpty,
                                restrictedNetwork: LiveNetworkConditions.shared.restricted)
                            if let cap = self.startupPolicy?.preferredPeakBitRate { item.preferredPeakBitRate = cap }
                            if self.resolution != nil {
                                self.status = playing ? "Live HLS / native adaptive bitrate" : "Buffering live HLS"
                                if Date().timeIntervalSince(self.lastProgress) > 20 {
                                    self.fail("Live HLS has stalled. Reconnect to retry; playback was not restarted automatically.")
                                }
                            }
                        }
                    }
                } catch { fail(error.localizedDescription) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
            }
        }
    }

    private func updateVideo(token: UUID) {
        guard generation == token, playerLayer.isReadyForDisplay,
              let size = player.currentItem?.presentationSize,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        if resolution != size { resolution = size }
        startup?.cancel()
        startup = nil
    }

    private func fail(_ message: String) {
        stop()
        error = message
        status = "Live HLS failed"
    }

    func stop() {
        generation = UUID()
        startup?.cancel()
        startup = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.removeAll()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        player.replaceCurrentItem(with: nil)
        source?.close()
        source = nil
        client?.invalidate()
        client = nil
        master = nil
        startupPolicy = nil
        resolution = nil
        lastVideoReceivedAt = nil
        lastPosition = nil
        error = nil
        let completion = completion
        self.completion = nil
        completion?.resume()
    }
}

struct NativeLiveHLSSurface: UIViewRepresentable {
    let stream: HLSLiveStream
    var fillVideo = false
    func makeUIView(context: Context) -> LiveHLSHost { LiveHLSHost(playerLayer: stream.playerLayer) }
    func updateUIView(_ view: LiveHLSHost, context: Context) {
        stream.playerLayer.videoGravity = fillVideo ? .resizeAspectFill : .resizeAspect
    }
}

final class LiveHLSHost: UIView {
    private let playerLayer: AVPlayerLayer
    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}
