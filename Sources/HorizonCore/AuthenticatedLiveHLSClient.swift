import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HLSByteRange: Sendable {
    public let offset: Int64
    public let length: Int?
    public init(offset: Int64, length: Int?) throws {
        guard offset >= 0, length.map({ $0 > 0 && $0 <= 16_777_216 }) ?? true,
              !offset.addingReportingOverflow(Int64(length ?? 1) - 1).overflow else {
            throw HorizonError.invalidMediaPath
        }
        self.offset = offset
        self.length = length
    }
    var header: String {
        if let length { return "bytes=\(offset)-\(offset + Int64(length) - 1)" }
        return "bytes=\(offset)-"
    }
}

public struct LiveHLSResource: Sendable {
    public let data: Data
    public let offset: Int64
    public let totalLength: Int64
    public let pathExtension: String

    public func bytes(at requestedOffset: Int64, length: Int?, toEnd: Bool) throws -> Data {
        guard requestedOffset >= offset, requestedOffset - offset <= Int64(data.count) else {
            throw HorizonError.unexpectedResponse
        }
        let start = Int(requestedOffset - offset)
        let count = toEnd ? data.count - start : min(length ?? 0, data.count - start)
        guard count >= 0 else { throw HorizonError.unexpectedResponse }
        return data.subdata(in: start..<(start + count))
    }
}

public enum LiveHLSNetworkEvent: Sendable {
    case response(status: Int, length: Int64?, contentRange: String?)
    case data(Data)
}

private final class HLSRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func bind(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = cancelled
        lock.unlock()
        if cancelled { task.cancel() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

// Delegate state is locked; the session uses an ephemeral, camera-scoped cookie jar.
public final class AuthenticatedLiveHLSClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public let policy: LiveHLSResourcePolicy
    private let maximumHeight: Int?
    private let lock = NSLock()
    private var session: URLSession!
    private var closed = false
    private struct Pending {
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var stream: AsyncThrowingStream<LiveHLSNetworkEvent, Error>.Continuation?
        var response: HTTPURLResponse?
        var data = Data()
        var received = 0
        let limit: Int
        let range: HLSByteRange?
    }
    private var pending: [Int: Pending] = [:]
    private var primedMaster: Data?
    private var primedUntil = Date.distantPast

    public init(policy: LiveHLSResourcePolicy, cookies: [HTTPCookie], maximumHeight: Int? = nil,
                configuration: URLSessionConfiguration = .ephemeral) {
        self.policy = policy
        self.maximumHeight = maximumHeight
        super.init()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        for cookie in cookies { configuration.httpCookieStorage?.setCookie(cookie) }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    public func prepareMaster() async throws -> LiveHLSMaster {
        let (data, _) = try await request(policy.canonicalMaster, range: nil)
        guard let text = String(data: data, encoding: .utf8) else { throw HorizonError.unexpectedResponse }
        let master = try LiveHLSMaster(text: text, policy: policy, url: policy.canonicalMaster,
            maximumHeight: maximumHeight)
        let rewritten = Data(try policy.rewritePlaylist(master.playlist, url: policy.canonicalMaster).utf8)
        storePrimedMaster(rewritten)
        return master
    }

    public func load(_ url: URL, range: HLSByteRange? = nil) async throws -> LiveHLSResource {
        let url = try policy.validate(url)
        let playlist = url.pathExtension.lowercased() == "m3u8"
        if url == policy.canonicalMaster, let primed = readPrimedMaster() {
            return LiveHLSResource(data: primed, offset: 0, totalLength: Int64(primed.count), pathExtension: "m3u8")
        }

        let (data, response) = try await request(url, range: playlist ? nil : range)
        if playlist {
            guard let text = String(data: data, encoding: .utf8) else { throw HorizonError.unexpectedResponse }
            let selected: String
            if url.path == policy.canonicalMaster.path {
                selected = try LiveHLSMaster(text: text, policy: policy, url: url, maximumHeight: maximumHeight).playlist
            } else { selected = text }
            let rewritten = Data(try policy.rewritePlaylist(selected, url: url).utf8)
            return LiveHLSResource(data: rewritten, offset: 0, totalLength: Int64(rewritten.count), pathExtension: "m3u8")
        }
        var offset: Int64 = 0
        var total = Int64(data.count)
        if response.statusCode == 206 {
            guard let header = response.value(forHTTPHeaderField: "Content-Range"), header.hasPrefix("bytes ") else {
                throw HorizonError.unexpectedResponse
            }
            let parts = header.dropFirst(6).split(separator: "/")
            guard parts.count == 2, let length = Int64(parts[1]), length > 0 else { throw HorizonError.unexpectedResponse }
            let interval = parts[0].split(separator: "-")
            guard interval.count == 2, let start = Int64(interval[0]), let end = Int64(interval[1]),
                  start >= 0, end >= start, end < length, end - start + 1 == Int64(data.count),
                  range?.offset == start,
                  range?.length.map({ end - start + 1 <= Int64($0) }) ?? true else {
                throw HorizonError.unexpectedResponse
            }
            offset = start
            total = length
        }
        return LiveHLSResource(data: data, offset: offset, totalLength: total,
            pathExtension: url.pathExtension.lowercased())
    }

    public func streamMedia(_ url: URL, range: HLSByteRange? = nil) throws -> AsyncThrowingStream<LiveHLSNetworkEvent, Error> {
        let url = try policy.validate(url)
        guard url.pathExtension.lowercased() != "m3u8" else { throw HorizonError.invalidMediaPath }
        let cancellation = HLSRequestCancellation()
        return AsyncThrowingStream { stream in
            stream.onTermination = { _ in cancellation.cancel() }
            let request = makeRequest(url, range: range)
            lock.lock()
            guard !closed, pending.count < 16 else {
                lock.unlock()
                stream.finish(throwing: HorizonError.message("Live HLS loading is closed or at its request limit."))
                return
            }
            let task = session.dataTask(with: request)
            pending[task.taskIdentifier] = Pending(stream: stream, limit: 16_777_216, range: range)
            lock.unlock()
            cancellation.bind(task)
            task.resume()
        }
    }

    private func storePrimedMaster(_ data: Data) {
        lock.lock()
        primedMaster = data
        primedUntil = Date().addingTimeInterval(10)
        lock.unlock()
    }

    private func readPrimedMaster() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return !closed && Date() < primedUntil ? primedMaster : nil
    }

    private func request(_ url: URL, range: HLSByteRange?) async throws -> (Data, HTTPURLResponse) {
        _ = try policy.validate(url)
        try Task.checkCancellation()
        let cancellation = HLSRequestCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = makeRequest(url, range: range)
                lock.lock()
                guard !closed, pending.count < 16 else {
                    lock.unlock()
                    continuation.resume(throwing: HorizonError.message("Live HLS loading is closed or at its request limit."))
                    return
                }
                let task = session.dataTask(with: request)
                pending[task.taskIdentifier] = Pending(continuation: continuation,
                    limit: url.pathExtension.lowercased() == "m3u8" ? 1_048_576 : 16_777_216, range: range)
                lock.unlock()
                cancellation.bind(task)
                task.resume()
            }

        } onCancel: { cancellation.cancel() }
    }

    private func makeRequest(_ url: URL, range: HLSByteRange?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let range { request.setValue(range.header, forHTTPHeaderField: "Range") }
        if let cookies = session.configuration.httpCookieStorage?.cookies(for: url) {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        return request
    }

    public func invalidate() {
        lock.lock()
        closed = true
        let cancelled = Array(pending.values)
        pending.removeAll()
        primedMaster = nil
        lock.unlock()
        session.invalidateAndCancel()
        for record in cancelled {
            record.continuation?.resume(throwing: CancellationError())
            record.stream?.finish(throwing: CancellationError())
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? policy.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse, let url = response.url else {
                throw HorizonError.unexpectedResponse
            }
            _ = try policy.validate(url)
            if [401, 403].contains(response.statusCode) { throw HorizonError.unauthorized }
            guard [200, 206].contains(response.statusCode) else { throw HorizonError.http(response.statusCode) }
            guard response.mimeType != "text/html", response.mimeType != "application/json" else {
                throw HorizonError.unexpectedResponse
            }
            if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding != "identity",
               url.pathExtension.lowercased() != "m3u8" { throw HorizonError.unexpectedResponse }
            lock.lock()
            let limit = pending[dataTask.taskIdentifier]?.limit
            let record = pending[dataTask.taskIdentifier]
            let allowed = limit.map { response.expectedContentLength < 0 || response.expectedContentLength <= Int64($0) } ?? false
            if allowed { pending[dataTask.taskIdentifier]?.response = response }
            lock.unlock()
            guard allowed else { throw HorizonError.message("The live HLS resource exceeds its size limit.") }
            if let stream = record?.stream {
                let contentRange = try validatedRange(response, range: record?.range)
                stream.yield(.response(status: response.statusCode,
                    length: response.expectedContentLength >= 0 ? response.expectedContentLength : nil,
                    contentRange: contentRange))
            }
            completionHandler(.allow)
        } catch {
            finish(dataTask, error: error)
            completionHandler(.cancel)
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var record = pending[dataTask.taskIdentifier] else { lock.unlock(); return }
        guard data.count <= record.limit - record.received else {
            lock.unlock()
            finish(dataTask, error: HorizonError.message("The live HLS resource exceeds its size limit."))
            dataTask.cancel()
            return
        }
        record.received += data.count
        if record.stream == nil { record.data.append(data) }
        pending[dataTask.taskIdentifier] = record
        lock.unlock()
        record.stream?.yield(.data(data))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task, error: error)
    }

    private func finish(_ task: URLSessionTask, error: Error?) {
        lock.lock()
        let record = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let record else { return }
        if let error {
            record.continuation?.resume(throwing: error)
            record.stream?.finish(throwing: error)
        } else if let response = record.response {
            record.continuation?.resume(returning: (record.data, response))
            if let stream = record.stream {
                if response.expectedContentLength >= 0 && response.expectedContentLength != Int64(record.received) {
                    stream.finish(throwing: HorizonError.unexpectedResponse)
                } else { stream.finish() }
            }
        } else {
            record.continuation?.resume(throwing: HorizonError.unexpectedResponse)
            record.stream?.finish(throwing: HorizonError.unexpectedResponse)
        }
    }

    private func validatedRange(_ response: HTTPURLResponse, range: HLSByteRange?) throws -> String? {
        guard response.statusCode == 206 else { return nil }
        guard let value = response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes ") else {
            throw HorizonError.unexpectedResponse
        }
        let pieces = value.dropFirst(6).split(separator: "/")
        guard pieces.count == 2, let total = Int64(pieces[1]), total > 0 else { throw HorizonError.unexpectedResponse }
        let bounds = pieces[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total, range?.offset == start,
              range?.length.map({ end - start + 1 <= Int64($0) }) ?? true else { throw HorizonError.unexpectedResponse }
        return "bytes \(start)-\(end)/\(total)"
    }
}
