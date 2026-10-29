import SwiftUI
import HorizonCore
@preconcurrency import WebRTC

@MainActor
final class LiveStream: NSObject, ObservableObject {
    @Published private(set) var videoTrack: RTCVideoTrack?
    @Published private(set) var resolution: CGSize?
    @Published private(set) var error: String?
    var muted = true {
        didSet { applyAudioPreference() }
    }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()
    private var peer: RTCPeerConnection?
    private var socket: URLSessionWebSocketTask?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var offerSent = false
    private var localCandidates: [String] = []

    private struct Signal: Codable {
        let type: String
        let value: String
    }

    func run(api: HorizonAPI, stream: String, iceServers: [ICEServer]) async {
        stop()
        let token = generation
        await withTaskCancellationHandler {
            do {
                let config = RTCConfiguration()
                config.sdpSemantics = .unifiedPlan
                config.bundlePolicy = .maxBundle
                config.iceServers = iceServers.map {
                    RTCIceServer(
                        urlStrings: $0.urls, username: $0.username, credential: $0.credential
                    )
                }
                guard let peer = Self.factory.peerConnection(
                    with: config,
                    constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
                    delegate: self
                ) else { throw HorizonError.message("The native video connection could not be created.") }
                self.peer = peer
                let receiveOnly = RTCRtpTransceiverInit()
                receiveOnly.direction = .recvOnly
                guard peer.addTransceiver(of: .video, init: receiveOnly) != nil,
                      peer.addTransceiver(of: .audio, init: receiveOnly) != nil
                else { throw HorizonError.message("The stream's native media receivers could not be created.") }
                applyAudioPreference()

                var request = URLRequest(url: api.address.webSocket(stream: stream))
                let headers = HTTPCookie.requestHeaderFields(with: api.cookies)
                for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
                let socket = api.session.webSocketTask(with: request)
                self.socket = socket
                socket.resume()
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    guard let self, self.generation == token, self.resolution == nil else { return }
                    self.fail("No video arrived. Check camera availability, H.264 support, and the server's WebRTC ICE/TURN configuration.")
                }

                let offer = try await createOffer(peer)
                try Task.checkCancellation()
                guard generation == token else { return }
                try await setDescription(offer, on: peer, remote: false)
                try await send(Signal(type: "webrtc/offer", value: offer.sdp), on: socket)
                guard generation == token else { return }
                offerSent = true
                for candidate in localCandidates {
                    try await send(Signal(type: "webrtc/candidate", value: candidate), on: socket)
                }
                localCandidates.removeAll()

                var pending: [RTCIceCandidate] = []
                var hasAnswer = false
                while !Task.isCancelled && generation == token {
                    let message = try await socket.receive()
                    guard generation == token else { return }
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw HorizonError.unexpectedResponse
                    }
                    let signal = try JSONDecoder().decode(Signal.self, from: data)
                    switch signal.type {
                    case "webrtc/answer":
                        try await setDescription(
                            RTCSessionDescription(type: .answer, sdp: signal.value), on: peer, remote: true
                        )
                        guard generation == token else { return }
                        hasAnswer = true
                        for candidate in pending { try await add(candidate, to: peer) }
                        pending.removeAll()
                        videoTrack = peer.transceivers.compactMap { $0.receiver.track as? RTCVideoTrack }.first
                        applyAudioPreference()
                    case "webrtc/candidate":
                        let candidate = RTCIceCandidate(sdp: signal.value, sdpMLineIndex: 0, sdpMid: "0")
                        if hasAnswer { try await add(candidate, to: peer) } else { pending.append(candidate) }
                    case "error":
                        throw HorizonError.message("The live stream was rejected: \(signal.value)")
                    default:
                        break
                    }
                }
            } catch {
                if generation == token && !Task.isCancelled && self.error == nil {
                    fail(error.localizedDescription)
                }
            }
            if generation == token { tearDown() }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.stop()
            }
        }
    }

    func stop() {
        generation = UUID()
        tearDown()
        resolution = nil
        error = nil
    }

    func receivedVideo(size: CGSize) {
        guard peer != nil, size.width > 0, size.height > 0 else { return }
        resolution = size
        timeout?.cancel()
    }

    private func tearDown() {
        timeout?.cancel()
        timeout = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        peer?.delegate = nil
        peer?.close()
        peer = nil
        videoTrack = nil
        localCandidates.removeAll()
        offerSent = false
    }

    private func fail(_ message: String) {
        error = message
        resolution = nil
        tearDown()
    }

    private func applyAudioPreference() {
        peer?.transceivers.forEach {
            ($0.receiver.track as? RTCAudioTrack)?.isEnabled = !muted
        }
    }

    private func send(_ signal: Signal, on socket: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(signal)
        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
    }

    private func createOffer(_ peer: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let error { continuation.resume(throwing: error) }
                else if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: HorizonError.unexpectedResponse) }
            }
        }
    }

    private func setDescription(
        _ description: RTCSessionDescription, on peer: RTCPeerConnection, remote: Bool
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion: @Sendable (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            if remote { peer.setRemoteDescription(description, completionHandler: completion) }
            else { peer.setLocalDescription(description, completionHandler: completion) }
        }
    }

    private func add(_ candidate: RTCIceCandidate, to peer: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.add(candidate) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

extension LiveStream: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            if let track = transceiver.receiver.track as? RTCVideoTrack { self.videoTrack = track }
            self.applyAudioPreference()
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            if !self.offerSent {
                self.localCandidates.append(candidate.sdp)
                return
            }
            guard let socket = self.socket else { return }
            let token = self.generation
            do {
                try await self.send(Signal(type: "webrtc/candidate", value: candidate.sdp), on: socket)
            } catch {
                if self.generation == token { self.fail(error.localizedDescription) }
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            if newState == .failed {
                self.fail("The camera connection failed. Check the server's ICE/TURN settings or use your home VPN.")
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

struct NativeVideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack?
    var fillVideo = false
    let onSize: (CGSize) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSize: onSize) }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = fillVideo ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = fillVideo
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        view.videoContentMode = fillVideo ? .scaleAspectFill : .scaleAspectFit
        view.clipsToBounds = fillVideo
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(view)
        context.coordinator.track = track
        track?.add(view)
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.track?.remove(view)
        view.delegate = nil
    }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        var track: RTCVideoTrack?
        let onSize: (CGSize) -> Void
        init(onSize: @escaping (CGSize) -> Void) { self.onSize = onSize }
        func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            Task { @MainActor in self.onSize(size) }
        }
    }
}
