import AVFoundation
import CoreImage
import SwiftUI
@preconcurrency import WebRTC

// A second renderer of the existing RTC track, not a second connection or decoder.
final class LivePiPVideoRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    let displayLayer: AVSampleBufferDisplayLayer
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Horizon.livePiP.frames", qos: .userInitiated)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var running = false
    private var busy = false
    private var generation = UUID()
    private var displayedAt: Date?
    @MainActor private var track: RTCVideoTrack?
    @MainActor var onFailure: ((String) -> Void)?

    private struct Sample: @unchecked Sendable {
        let buffer: CMSampleBuffer
    }

    @MainActor init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    @MainActor func follow(_ value: RTCVideoTrack) {
        guard track !== value else { return }
        stop()
        var timebase: CMTimebase?
        let clock = CMClockGetHostTimeClock()
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault, sourceClock: clock, timebaseOut: &timebase
        )
        guard status == noErr, let timebase else {
            onFailure?("The live Picture in Picture clock could not be created (\(status)).")
            return
        }
        CMTimebaseSetTime(timebase, time: CMClockGetTime(clock))
        CMTimebaseSetRate(timebase, rate: 1)
        displayLayer.controlTimebase = timebase
        track = value
        lock.lock()
        running = true
        lock.unlock()
        value.add(self)
    }

    @MainActor func stop() {
        lock.lock()
        running = false
        generation = UUID()
        displayedAt = nil
        lock.unlock()
        track?.remove(self)
        track = nil
        displayLayer.flushAndRemoveImage()
        displayLayer.controlTimebase = nil
    }

    var lastDisplayedFrame: Date? {
        lock.lock()
        defer { lock.unlock() }
        return displayedAt
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        guard running, !busy else { lock.unlock(); return }
        busy = true
        let token = generation
        lock.unlock()
        // At most one frame crosses the worker/main boundary; a slow renderer cannot build a queue.
        queue.async { [weak self] in
            guard let self else { return }
            let result = Result { Sample(buffer: try self.makeSample(frame)) }
            Task { @MainActor [weak self] in self?.display(result, generation: token) }
        }
    }

    @MainActor private func display(_ result: Result<Sample, Error>, generation token: UUID) {
        lock.lock()
        busy = false
        let current = running && generation == token
        lock.unlock()
        guard current else { return }
        switch result {
        case .failure(let error):
            onFailure?(error.localizedDescription)
        case .success(let sample):
            if displayLayer.status == .failed {
                onFailure?(displayLayer.error?.localizedDescription ?? "The WebRTC Picture in Picture renderer failed.")
                return
            }
            guard displayLayer.isReadyForMoreMediaData else { return }
            displayLayer.enqueue(sample.buffer)
            lock.lock()
            displayedAt = Date()
            lock.unlock()
        }
    }

    private func makeSample(_ frame: RTCVideoFrame) throws -> CMSampleBuffer {
        let pixels = try pixelBuffer(frame)
        var format: CMVideoFormatDescription?
        var sample: CMSampleBuffer?
        var status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw RenderError.buffer(status) }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw RenderError.buffer(status) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func pixelBuffer(_ frame: RTCVideoFrame) throws -> CVPixelBuffer {
        let image: CIImage
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            let pixels = buffer.pixelBuffer
            let crop = CGRect(
                x: Int(buffer.cropX),
                y: CVPixelBufferGetHeight(pixels) - Int(buffer.cropY) - Int(buffer.cropHeight),
                width: Int(buffer.cropWidth), height: Int(buffer.cropHeight)
            )
            guard crop.width > 0, crop.height > 0,
                  CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixels),
                         height: CVPixelBufferGetHeight(pixels)).contains(crop) else { throw RenderError.frame }
            if frame.rotation.rawValue == 0, crop.origin == .zero,
               Int(crop.width) == CVPixelBufferGetWidth(pixels),
               Int(crop.height) == CVPixelBufferGetHeight(pixels),
               Int(buffer.width) == CVPixelBufferGetWidth(pixels),
               Int(buffer.height) == CVPixelBufferGetHeight(pixels) {
                return pixels
            }
            image = CIImage(cvPixelBuffer: pixels).cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(
                    scaleX: CGFloat(buffer.width) / crop.width, y: CGFloat(buffer.height) / crop.height
                ))
        } else {
            let pixels = try softwarePixels(frame.buffer.toI420())
            if frame.rotation.rawValue == 0 { return pixels }
            image = CIImage(cvPixelBuffer: pixels)
        }
        let rotated = image.transformed(by: CGAffineTransform(
            rotationAngle: -CGFloat(frame.rotation.rawValue) * .pi / 180
        ))
        let normalized = rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.minX, y: -rotated.extent.minY
        ))
        let output = try allocate(width: Int(normalized.extent.width.rounded()),
            height: Int(normalized.extent.height.rounded()), format: kCVPixelFormatType_32BGRA)
        imageContext.render(normalized, to: output)
        return output
    }

    private func softwarePixels(_ source: any RTCI420BufferProtocol) throws -> CVPixelBuffer {
        let width = Int(source.width), height = Int(source.height)
        guard width > 0, height > 0, source.chromaWidth > 0, source.chromaHeight > 0,
              Int(source.strideY) >= width, source.strideU >= source.chromaWidth,
              source.strideV >= source.chromaWidth else {
            throw RenderError.frame
        }
        let pixels = try allocate(width: width, height: height,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        guard CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess else { throw RenderError.frame }
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
              let uvPlane = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) else { throw RenderError.frame }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        guard yStride >= width, uvStride >= Int(source.chromaWidth) * 2,
              CVPixelBufferGetHeightOfPlane(pixels, 0) >= height,
              CVPixelBufferGetHeightOfPlane(pixels, 1) >= Int(source.chromaHeight) else { throw RenderError.frame }
        for row in 0..<height {
            memcpy(yPlane.advanced(by: row * yStride),
                source.dataY.advanced(by: row * Int(source.strideY)), width)
        }
        let uvBytes = uvPlane.assumingMemoryBound(to: UInt8.self)
        for row in 0..<Int(source.chromaHeight) {
            for column in 0..<Int(source.chromaWidth) {
                uvBytes[row * uvStride + column * 2] = source.dataU[row * Int(source.strideU) + column]
                uvBytes[row * uvStride + column * 2 + 1] = source.dataV[row * Int(source.strideV) + column]
            }
        }
        return pixels
    }

    private func allocate(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw RenderError.frame }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:],
             kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw RenderError.buffer(status) }
        return buffer
    }

    private enum RenderError: LocalizedError {
        case frame
        case buffer(OSStatus)

        var errorDescription: String? {
            switch self {
            case .frame: return "This decoded WebRTC frame could not be displayed in Picture in Picture."
            case .buffer(let status): return "The WebRTC Picture in Picture frame could not be created (\(status))."
            }
        }
    }
}

struct LivePiPVideoSurface: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> HTTPSVideoHost { HTTPSVideoHost(displayLayer: displayLayer) }
    func updateUIView(_ view: HTTPSVideoHost, context: Context) {}
    static func dismantleUIView(_ view: HTTPSVideoHost, coordinator: ()) {
        if view.displayLayer.superlayer === view.layer { view.displayLayer.removeFromSuperlayer() }
    }
}
