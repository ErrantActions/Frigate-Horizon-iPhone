import SwiftUI
import AVFoundation
import HorizonCore

@MainActor
final class HTTPSLiveStream: ObservableObject {
    let videoLayer = AVSampleBufferDisplayLayer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    @Published private(set) var presentation = HTTPSVideoPresentation()
    @Published private(set) var error: String?
    var resolution: CGSize? { presentation.resolution }
    var status: String { presentation.status }
    var lastVideoReceivedAt: Date? { started ? lastVideo : nil }
    private(set) var lastVideoReceivedUptime: TimeInterval?
    private(set) var capacityLimited = false
    private var lastVideoPresentationTime: TimeInterval?
    var bufferedVideoDuration: TimeInterval? {
        guard started, let latest = lastVideoPresentationTime else { return nil }
        let current = CMTimeGetSeconds(synchronizer.currentTime())
        guard current.isFinite, latest.isFinite else { return nil }
        return max(0, latest - current)
    }
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private var readyObservation: NSKeyValueObservation?
    private var watchdog: Task<Void, Never>?
    private var lastVideo = Date()
    private var started = false
    private var videoSize = CGSize.zero
    private var formats: [Int: CMFormatDescription] = [:]
    var muted = true {
        didSet { audioRenderer.isMuted = muted }
    }

    init() {
        videoLayer.videoGravity = .resizeAspect
        synchronizer.addRenderer(videoLayer)
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        audioRenderer.isMuted = true
    }

    func run(api: HorizonAPI, stream: String) async {
        stop()
        let token = generation
        readyObservation = videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.refreshPresentation()
            }
        }
        await withTaskCancellationHandler {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                var request = URLRequest(url: api.address.webSocket(stream: stream, transport: "mse"))
                for (key, value) in HTTPCookie.requestHeaderFields(with: api.cookies) {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                let socket = api.session.webSocketTask(with: request)
                socket.maximumMessageSize = 16 * 1024 * 1024
                self.socket = socket
                socket.resume()
                let negotiation = muted
                    ? #"{"type":"mse","value":"avc1.640029,avc1.64002A,avc1.640033,hvc1.1.6.L153.B0"}"#
                    : #"{"type":"mse","value":"avc1.640029,avc1.64002A,avc1.640033,hvc1.1.6.L153.B0,mp4a.40.2"}"#
                try await socket.send(.string(negotiation))
                guard generation == token else { return }
                presentation.waitingForVideo()
                lastVideo = Date()
                let startup = Date()
                watchdog = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let delay: Duration = self?.resolution == nil ? .milliseconds(200) : .seconds(2)
                            try await Task.sleep(for: delay)
                            guard let self, self.generation == token else { return }
                            self.refreshPresentation()
                            let timedOut = self.resolution == nil
                                ? Date().timeIntervalSince(startup) > 25
                                : Date().timeIntervalSince(self.lastVideo) > 10
                            if timedOut {
                                self.fail("No video arrived over HTTPS. Check that the selected live stream is available, then reconnect.")
                                return
                            }
                        }
                    } catch { return }
                }
                var demuxer = FragmentedMP4()
                while !Task.isCancelled && generation == token {
                    let message = try await socket.receive()
                    guard generation == token else { return }
                    switch message {
                    case .string(let text):
                        struct Signal: Decodable { let type: String; let value: String? }
                        let signal = try JSONDecoder().decode(Signal.self, from: Data(text.utf8))
                        if signal.type == "error" {
                            throw HorizonError.message("The live server rejected playback: \(signal.value ?? "Unknown error")")
                        }
                    case .data(let data):
                        let samples = try demuxer.append(data)
                        if formats.isEmpty && !demuxer.tracks.isEmpty {
                            for track in demuxer.tracks.values { formats[track.id] = try format(track) }
                        }
                        for sample in samples {
                            guard let track = demuxer.tracks[sample.trackID],
                                  let format = formats[sample.trackID] else { throw HorizonError.unexpectedResponse }
                            let buffer = try makeBuffer(sample, format: format)
                            if track.isVideo {
                                videoSize = CGSize(width: track.width, height: track.height)
                                if videoLayer.status == .failed {
                                    throw videoLayer.error ?? HorizonError.message("Apple's video decoder rejected this live stream.")
                                }
                                let deadline = Date().addingTimeInterval(2)
                                while !videoLayer.isReadyForMoreMediaData {
                                    guard Date() < deadline else {
                                        capacityLimited = true
                                        throw HorizonError.message("Live video cannot keep up. Choose a lower main-derived stream and reconnect.")
                                    }
                                    try await Task.sleep(for: .milliseconds(10))
                                    guard generation == token else { return }
                                }
                                videoLayer.enqueue(buffer)
                                lastVideoPresentationTime = sample.presentationTime
                                lastVideo = Date()
                                lastVideoReceivedUptime = ProcessInfo.processInfo.systemUptime
                                if !started {
                                    synchronizer.setRate(1, time: CMTime(seconds: sample.presentationTime, preferredTimescale: 90000))
                                    started = true
                                }
                                refreshPresentation()
                            } else {
                                if audioRenderer.status == .failed {
                                    throw audioRenderer.error ?? HorizonError.message("The live audio decoder failed.")
                                }
                                let deadline = Date().addingTimeInterval(2)
                                while !audioRenderer.isReadyForMoreMediaData {
                                    guard Date() < deadline else {
                                        throw HorizonError.message("Live audio buffering exceeded the playback capacity.")
                                    }
                                    try await Task.sleep(for: .milliseconds(10))
                                    guard generation == token else { return }
                                }
                                audioRenderer.enqueue(buffer)
                            }
                        }
                    @unknown default:
                        throw HorizonError.unexpectedResponse
                    }
                }
            } catch {
                if generation == token && !Task.isCancelled && self.error == nil {
                    fail(error.localizedDescription)
                }
            }
            if generation == token { close() }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
            }
        }
    }

    func stop() {
        generation = UUID()
        close()
        error = nil
        capacityLimited = false
    }

    private func refreshPresentation() {
        guard socket != nil, started, error == nil, resolution == nil else { return }
        let frame = videoLayer.sampleBufferRenderer.displayedPixelBuffer()
        let displayedSize = frame.map {
            CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
        }
        var updated = presentation
        updated.confirmDisplayedVideo(displayedSize: displayedSize,
            readyForDisplay: videoLayer.isReadyForDisplay, streamSize: videoSize)
        if updated != presentation { presentation = updated }
    }

    func reflectionPixelBuffer() -> CVPixelBuffer? {
        guard socket != nil, resolution != nil,
              Date().timeIntervalSince(lastVideo) < VideoReflectionPolicy.staleInterval else { return nil }
        return videoLayer.sampleBufferRenderer.displayedPixelBuffer()
    }

    private func close() {
        readyObservation?.invalidate()
        readyObservation = nil
        watchdog?.cancel()
        watchdog = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        synchronizer.setRate(0, time: .zero)
        videoLayer.flushAndRemoveImage()
        audioRenderer.flush()
        formats.removeAll()
        started = false
        lastVideoReceivedUptime = nil
        lastVideoPresentationTime = nil
        videoSize = .zero
        presentation.reset()
    }

    private func fail(_ message: String) {
        error = message
        close()
    }

    func format(_ track: MP4Track) throws -> CMFormatDescription {
        var result: CMFormatDescription?
        let status: OSStatus
        if track.isVideo {
            let atom = track.codec == "avc1" ? "avcC" : "hvcC"
            let extensions: [String: Any] = [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: [atom: track.configuration],
            ]
            status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: track.codec == "avc1" ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                width: Int32(track.width), height: Int32(track.height),
                extensions: extensions as CFDictionary, formatDescriptionOut: &result
            )
        } else {
            var description = AudioStreamBasicDescription(
                mSampleRate: track.timescale, mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                mBytesPerFrame: 0, mChannelsPerFrame: UInt32(track.channels),
                mBitsPerChannel: 0, mReserved: 0
            )
            status = track.configuration.withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault, asbd: &description,
                    layoutSize: 0, layout: nil, magicCookieSize: bytes.count,
                    magicCookie: bytes.baseAddress, extensions: nil, formatDescriptionOut: &result
                )
            }
        }
        guard status == noErr, let result else {
            throw HorizonError.message("Unsupported native live format (\(status)). Choose H.264 video with AAC audio.")
        }
        return result
    }

    func makeBuffer(_ sample: MP4Sample, format: CMFormatDescription) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var result: CMSampleBuffer?
        var size = sample.data.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block
        )
        guard status == noErr, let block else { throw HorizonError.message("Live media buffer allocation failed (\(status)).") }
        status = sample.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: size)
        }
        guard status == noErr else { throw HorizonError.message("Live media copy failed (\(status)).") }
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: sample.duration, preferredTimescale: 90000),
            presentationTimeStamp: CMTime(seconds: sample.presentationTime, preferredTimescale: 90000),
            decodeTimeStamp: CMTime(seconds: sample.decodeTime, preferredTimescale: 90000)
        )
        if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio {
            var packet = AudioStreamPacketDescription(mStartOffset: 0,
                mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1024, presentationTimeStamp: timing.presentationTimeStamp,
                packetDescriptions: &packet, sampleBufferOut: &result
            )
        } else {
            status = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &result
            )
        }
        guard status == noErr, let result else { throw HorizonError.message("Live sample creation failed (\(status)).") }
        return result
    }
}

struct HTTPSVideoSurface: UIViewRepresentable {
    let stream: HTTPSLiveStream
    var fillVideo = false
    func makeUIView(context: Context) -> HTTPSVideoHost {
        let view = HTTPSVideoHost(displayLayer: stream.videoLayer)
        view.fillVideo = fillVideo
        return view
    }
    func updateUIView(_ view: HTTPSVideoHost, context: Context) { view.fillVideo = fillVideo }
    static func dismantleUIView(_ view: HTTPSVideoHost, coordinator: ()) {
        if view.displayLayer.superlayer === view.layer { view.displayLayer.removeFromSuperlayer() }
    }
}

final class HTTPSVideoHost: UIView {
    let displayLayer: AVSampleBufferDisplayLayer
    var fillVideo = false {
        didSet {
            displayLayer.videoGravity = fillVideo ? .resizeAspectFill : .resizeAspect
            clipsToBounds = fillVideo
        }
    }
    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        layer.addSublayer(displayLayer)
    }
    required init?(coder: NSCoder) { fatalError("Storyboard initialization is unsupported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard displayLayer.superlayer === layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}
