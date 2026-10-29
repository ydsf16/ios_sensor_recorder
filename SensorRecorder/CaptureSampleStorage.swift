import CoreMedia
import CoreVideo
import Foundation

/// Detaches encoder input from AVFoundation's small capture buffer pool before
/// returning its callback. CMSampleBufferCreateCopy alone does not copy pixels.
final class CaptureSampleStorage {
    enum Failure: LocalizedError {
        case copy(String, OSStatus)
        var errorDescription: String? {
            switch self { case let .copy(operation, status): return "Could not detach video input (\(operation), \(status))." }
        }
    }
    private var pool: CVPixelBufferPool?
    private var dimensions: [Int] = []
    private var minimumBufferCount = 0
    private var pipelineBufferCount = 8

    func useEncoderPool(_ encoderPool: CVPixelBufferPool, framesPerSecond: Double) {
        pool = encoderPool
        let pixels = CVPixelBufferPoolGetPixelBufferAttributes(encoderPool) as? [String: Any] ?? [:]
        dimensions = [kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey].map {
            (pixels[$0 as String] as? NSNumber)?.intValue ?? 0
        }
        let attributes = CVPixelBufferPoolGetAttributes(encoderPool) as? [String: Any] ?? [:]
        minimumBufferCount = (attributes[kCVPixelBufferPoolMinimumBufferCountKey as String] as? NSNumber)?.intValue ?? 0
        pipelineBufferCount = max(8, Int(ceil(framesPerSecond)))
    }

    // Called only on the owning capture queue, never on an encoder queue.
    func copy(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { throw Failure.copy("image", -1) }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let key = [width, height, Int(pixelFormat)]
        if pool == nil || dimensions != key {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess else { throw Failure.copy("pool", status) }
            dimensions = key
        }
        let capacity = max(minimumBufferCount + pipelineBufferCount, max(6, min(64, 128 * 1024 * 1024 / max(1, CVPixelBufferGetDataSize(source)))))
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool!,
            [kCVPixelBufferPoolAllocationThresholdKey: capacity] as CFDictionary, &destination)
        guard status == kCVReturnSuccess, let destination else { throw Failure.copy("allocation; SDK minimum \(minimumBufferCount), limit \(capacity)", status) }
        let sourceLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLock == kCVReturnSuccess else { throw Failure.copy("source lock", sourceLock) }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let destinationLock = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLock == kCVReturnSuccess else { throw Failure.copy("destination lock", destinationLock) }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let planes = CVPixelBufferIsPlanar(source) ? CVPixelBufferGetPlaneCount(source) : 1
        for plane in 0..<planes {
            let planar = CVPixelBufferIsPlanar(source)
            let input = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source)
            let output = planar ? CVPixelBufferGetBaseAddressOfPlane(destination, plane) : CVPixelBufferGetBaseAddress(destination)
            let sourceStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let destinationStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane) : CVPixelBufferGetBytesPerRow(destination)
            let rows = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : height
            guard let input, let output else { throw Failure.copy("plane", -1) }
            for row in 0..<rows {
                memcpy(output.advanced(by: row * destinationStride), input.advanced(by: row * sourceStride), min(sourceStride, destinationStride))
            }
        }
        CVBufferPropagateAttachments(source, destination)
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: destination, formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else { throw Failure.copy("format", formatStatus) }
        var timing = CMSampleTimingInfo()
        let timingStatus = CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
        guard timingStatus == noErr else { throw Failure.copy("timing", timingStatus) }
        var detached: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: destination,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &detached)
        guard sampleStatus == noErr, let detached else { throw Failure.copy("sample", sampleStatus) }
        for mode in [kCMAttachmentMode_ShouldPropagate, kCMAttachmentMode_ShouldNotPropagate] {
            if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sample, attachmentMode: mode) {
                CMSetAttachments(detached, attachments: attachments, attachmentMode: mode)
            }
        }
        return detached
    }
}
