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
    private var width = 0
    private var height = 0
    private var pixelFormat = 0
    private var minimumBufferCount = 0
    private var pipelineBufferCount = 8
    private var allocationAttributes: CFDictionary?

    func useEncoderPool(_ encoderPool: CVPixelBufferPool, framesPerSecond: Double) {
        pool = encoderPool
        let pixels = CVPixelBufferPoolGetPixelBufferAttributes(encoderPool) as? [String: Any] ?? [:]
        width = (pixels[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue ?? 0
        height = (pixels[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue ?? 0
        pixelFormat = (pixels[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.intValue ?? 0
        let attributes = CVPixelBufferPoolGetAttributes(encoderPool) as? [String: Any] ?? [:]
        minimumBufferCount = (attributes[kCVPixelBufferPoolMinimumBufferCountKey as String] as? NSNumber)?.intValue ?? 0
        pipelineBufferCount = max(8, Int(ceil(framesPerSecond)))
        allocationAttributes = nil
    }

    // Called only on the owning capture queue, never on an encoder queue.
    // Recording needs just pixels. Avoid constructing a new format description,
    // sample buffer, and attachment dictionaries for every encoder submission.
    func copyPixelBuffer(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        let sourceWidth = CVPixelBufferGetWidth(source), sourceHeight = CVPixelBufferGetHeight(source)
        let sourceFormat = CVPixelBufferGetPixelFormatType(source)
        if pool == nil || width != sourceWidth || height != sourceHeight || pixelFormat != Int(sourceFormat) {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: sourceWidth, kCVPixelBufferHeightKey as String: sourceHeight,
                kCVPixelBufferPixelFormatTypeKey as String: sourceFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            guard status == kCVReturnSuccess else { throw Failure.copy("pool", status) }
            width = sourceWidth; height = sourceHeight; pixelFormat = Int(sourceFormat)
            allocationAttributes = nil
        }
        if allocationAttributes == nil {
            let capacity = max(minimumBufferCount + pipelineBufferCount, max(6, min(64, 128 * 1024 * 1024 / max(1, CVPixelBufferGetDataSize(source)))))
            allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: capacity] as CFDictionary
        }
        var destination: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool!,
            allocationAttributes, &destination)
        guard status == kCVReturnSuccess, let destination else { throw Failure.copy("allocation; SDK minimum \(minimumBufferCount)", status) }
        let sourceLock = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard sourceLock == kCVReturnSuccess else { throw Failure.copy("source lock", sourceLock) }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        let destinationLock = CVPixelBufferLockBaseAddress(destination, [])
        guard destinationLock == kCVReturnSuccess else { throw Failure.copy("destination lock", destinationLock) }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let planar = CVPixelBufferIsPlanar(source)
        let planes = planar ? CVPixelBufferGetPlaneCount(source) : 1
        for plane in 0..<planes {
            let input = planar ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source)
            let output = planar ? CVPixelBufferGetBaseAddressOfPlane(destination, plane) : CVPixelBufferGetBaseAddress(destination)
            let sourceStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
            let destinationStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane) : CVPixelBufferGetBytesPerRow(destination)
            let rows = planar ? CVPixelBufferGetHeightOfPlane(source, plane) : sourceHeight
            guard let input, let output else { throw Failure.copy("plane", -1) }
            if sourceStride == destinationStride {
                memcpy(output, input, sourceStride * rows)
            } else {
                for row in 0..<rows {
                    memcpy(output.advanced(by: row * destinationStride), input.advanced(by: row * sourceStride), min(sourceStride, destinationStride))
                }
            }
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    func copy(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard let source = CMSampleBufferGetImageBuffer(sample) else { throw Failure.copy("image", -1) }
        let destination = try copyPixelBuffer(source)
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
