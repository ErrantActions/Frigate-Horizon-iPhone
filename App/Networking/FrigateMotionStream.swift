import Foundation
import Combine
import HorizonCore

@MainActor
final class FrigateMotionStream: ObservableObject {
    enum Status: Equatable {
        case stopped, connecting, listening
        case reconnecting(Int)
        case unavailable, invalidMessage

        var notice: String {
            switch self {
            case .stopped: return "Motion following is stopped; this camera stays live."
            case .connecting: return "Connecting motion feed; this camera stays live."
            case .listening: return "Following new detected motion; minimum hold is 8 seconds."
            case .reconnecting(let attempt):
                return "Motion feed disconnected; reconnecting (\(attempt) of 5). Keeping this camera."
            case .unavailable: return "Motion feed unavailable. Retry the feed or choose Timed cycle in settings."
            case .invalidMessage: return "Motion feed returned unsupported activity. Retry the feed or choose Timed cycle."
            }
        }
    }

    @Published private(set) var status = Status.stopped
    var available: Bool { status == .listening }
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()

    func stop() {
        generation = UUID()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        status = .stopped
    }

    func run(api: HorizonAPI, allowedCameraIDs: Set<String>,
             onMessage: @escaping @MainActor (CameraMotionMessage) -> Void) async {
        guard !Task.isCancelled else { return }
        stop()
        let token = generation
        guard !allowedCameraIDs.isEmpty else { return }
        for attempt in 0..<5 {
            guard !Task.isCancelled, generation == token else { return }
            if attempt == 0 { status = .connecting }
            else {
                status = .reconnecting(attempt + 1)
                do { try await Task.sleep(for: .seconds(1 << (attempt - 1))) }
                catch { return }
            }
            guard !Task.isCancelled, generation == token else { return }
            var request = URLRequest(url: api.address.messageWebSocket())
            for (key, value) in HTTPCookie.requestHeaderFields(with: api.cookies) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let connection = api.session.webSocketTask(with: request)
            connection.maximumMessageSize = CameraMotionParser.maximumMessageBytes
            socket = connection
            connection.resume()
            do {
                try await withTaskCancellationHandler {
                    try await connection.send(.string(#"{"topic":"onConnect","payload":"","retain":false}"#))
                    guard !Task.isCancelled, generation == token else { throw CancellationError() }
                    status = .listening
                    let heartbeat = Task { @MainActor in
                        do {
                            while !Task.isCancelled {
                                try await Task.sleep(for: .seconds(20))
                                try Task.checkCancellation()
                                try await Self.ping(connection)
                            }
                        } catch {
                            if !Task.isCancelled { connection.cancel(with: .goingAway, reason: nil) }
                        }
                    }
                    defer { heartbeat.cancel() }
                    var seeded = false
                    while !Task.isCancelled, generation == token {
                        let message = try await connection.receive()
                        try Task.checkCancellation()
                        guard generation == token else { throw CancellationError() }
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: throw FeedError.invalidMessage
                        }
                        let parsed = CameraMotionParser.parse(data, allowedCameraIDs: allowedCameraIDs)
                        guard parsed != .malformed else { throw FeedError.invalidMessage }
                        if case .snapshot = parsed {
                            guard !seeded else { continue }
                            seeded = true
                        } else if case .event = parsed {
                            seeded = true
                        }
                        onMessage(parsed)
                    }
                } onCancel: {
                    connection.cancel(with: .goingAway, reason: nil)
                }
            } catch {
                connection.cancel(with: .goingAway, reason: nil)
                guard !Task.isCancelled, generation == token else { return }
                socket = nil
                if error is FeedError {
                    status = .invalidMessage
                    return
                }
            }
            connection.cancel(with: .goingAway, reason: nil)
            guard !Task.isCancelled, generation == token else { return }
        }
        status = .unavailable
        socket = nil
    }

    private enum FeedError: Error { case invalidMessage }

    private static func ping(_ connection: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
