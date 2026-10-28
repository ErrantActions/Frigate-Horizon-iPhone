import AVFoundation
import CoreImage
import HorizonCore
@preconcurrency import WebRTC

// Retains already-decoded, read-only buffers across the worker boundary; source pixels are never mutated.
struct ReflectionFrame: @unchecked Sendable {
    enum Content {
        case pixelBuffer(CVPixelBuffer, CGAffineTransform)
        case webRTC(RTCVideoFrame)
    }
    let content: Content
}

actor VideoReflectionRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func render(_ frame: ReflectionFrame, blurRadius: Double = 8) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let source: CIImage
        switch frame.content {
        case .pixelBuffer(let buffer, let transform):
            source = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        case .webRTC(let frame):
            guard let image = webRTCImage(frame) else { return nil }
            source = image
        }
        let bounds = source.extent
        guard let size = VideoReflectionPolicy.downsampledSize(bounds.size) else { return nil }
        var image = source.transformed(by: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        image = image.transformed(by: CGAffineTransform(
            a: size.width / bounds.width, b: 0, c: 0, d: -size.height / bounds.height,
            tx: 0, ty: size.height
        ))
        let outputBounds = CGRect(origin: .zero, size: size)
        if blurRadius > 0 {
            image = image.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
                .cropped(to: outputBounds)
        }
        guard !Task.isCancelled else { return nil }
        return context.createCGImage(image, from: outputBounds)
    }

    private func webRTCImage(_ frame: RTCVideoFrame) -> CIImage? {
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
                         height: CVPixelBufferGetHeight(pixels)).contains(crop) else { return nil }
            image = CIImage(cvPixelBuffer: pixels).cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(
                    scaleX: CGFloat(buffer.width) / crop.width, y: CGFloat(buffer.height) / crop.height
                ))
        } else {
            guard let pixels = softwarePixels(frame) else { return nil }
            image = CIImage(cvPixelBuffer: pixels)
        }
        return image.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(frame.rotation.rawValue) * .pi / 180))
    }

    private func softwarePixels(_ frame: RTCVideoFrame) -> CVPixelBuffer? {
        let source = frame.buffer.toI420()
        guard let size = VideoReflectionPolicy.downsampledSize(
            CGSize(width: Int(source.width), height: Int(source.height))
        ), source.chromaWidth > 0, source.chromaHeight > 0 else { return nil }
        let width = max(2, Int(size.width) / 2 * 2)
        let height = max(2, Int(size.height) / 2 * 2)
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
              let result else { return nil }
        guard CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(result, 0),
              let uvPlane = CVPixelBufferGetBaseAddressOfPlane(result, 1) else { return nil }
        let yBytes = yPlane.assumingMemoryBound(to: UInt8.self)
        let uvBytes = uvPlane.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(result, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(result, 1)
        // Software-decoded I420 is resampled before conversion; even this fallback stays small.
        for y in 0..<height {
            let row = y * Int(source.height) / height * Int(source.strideY)
            for x in 0..<width {
                yBytes[y * yStride + x] = source.dataY[row + x * Int(source.width) / width]
            }
        }
        for y in 0..<(height / 2) {
            let sourceY = y * Int(source.chromaHeight) / (height / 2)
            for x in 0..<(width / 2) {
                let sourceX = x * Int(source.chromaWidth) / (width / 2)
                uvBytes[y * uvStride + x * 2] = source.dataU[sourceY * Int(source.strideU) + sourceX]
                uvBytes[y * uvStride + x * 2 + 1] = source.dataV[sourceY * Int(source.strideV) + sourceX]
            }
        }
        return result
    }
}

final class ReflectionTrackObserver: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var gate = ReflectionSamplingGate()
    private var latest: ReflectionFrame?
    private var receivedAt: Double?

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        lock.lock()
        defer { lock.unlock() }
        guard let frame else {
            latest = nil
            receivedAt = nil
            return
        }
        let now = CACurrentMediaTime()
        guard gate.take(at: now) else { return }
        latest = ReflectionFrame(content: .webRTC(frame))
        receivedAt = now
    }

    func takeFrame() -> (frame: ReflectionFrame?, fresh: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let fresh = receivedAt.map { CACurrentMediaTime() - $0 < VideoReflectionPolicy.staleInterval } ?? false
        defer { latest = nil }
        return (fresh ? latest : nil, fresh)
    }
}
