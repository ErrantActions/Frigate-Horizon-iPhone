import AVFoundation
import UniformTypeIdentifiers

@MainActor
public final class AuthenticatedLiveHLSAsset: NSObject, AVAssetResourceLoaderDelegate {
    public let asset: AVURLAsset
    private let client: AuthenticatedLiveHLSClient
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var closed = false
    public var onFailure: ((Error) -> Void)?

    public init(client: AuthenticatedLiveHLSClient) throws {
        self.client = client
        asset = AVURLAsset(url: try client.policy.assetURL(client.policy.canonicalMaster))
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }

    nonisolated public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == "horizon-hls" else { return false }
        Task { @MainActor [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            self.load(loadingRequest)
        }
        return true
    }

    nonisolated public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        Task { @MainActor [weak self] in
            self?.requests.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
        }
    }

    private func load(_ request: AVAssetResourceLoadingRequest) {
        guard !closed, !request.isCancelled, !request.isFinished else { return }
        let id = ObjectIdentifier(request)
        guard requests[id] == nil else { return }
        requests[id] = Task { [weak self, weak request] in
            guard let self, let request else { return }
            defer { self.requests.removeValue(forKey: id) }
            do {
                guard let assetURL = request.request.url else { throw HorizonError.invalidMediaPath }
                let url = try self.client.policy.networkURL(assetURL)
                let dataRequest = request.dataRequest
                let offset = dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
                let length = dataRequest.map { $0.requestsAllDataToEndOfResource ? nil : $0.requestedLength } ?? nil
                let range = dataRequest == nil ? nil : try HLSByteRange(offset: offset, length: length)
                let resource = try await self.client.load(url, range: range)
                try Task.checkCancellation()
                guard !self.closed, !request.isCancelled, !request.isFinished else { return }
                if let info = request.contentInformationRequest {
                    guard let type = UTType(filenameExtension: resource.pathExtension) else {
                        throw HorizonError.unexpectedResponse
                    }
                    info.contentType = type.identifier
                    info.contentLength = resource.totalLength
                    info.isByteRangeAccessSupported = true
                }
                if let dataRequest {
                    dataRequest.respond(with: try resource.bytes(at: offset, length: length,
                        toEnd: dataRequest.requestsAllDataToEndOfResource))
                }
                request.finishLoading()
            } catch {
                guard !self.closed, !request.isCancelled, !Task.isCancelled else { return }
                request.finishLoading(with: error)
                self.onFailure?(error)
            }
        }
    }

    public func close() {
        closed = true
        asset.cancelLoading()
        asset.resourceLoader.setDelegate(nil, queue: nil)
        for task in requests.values { task.cancel() }
        requests.removeAll()
        client.invalidate()
        onFailure = nil
    }
}
